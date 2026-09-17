// Self-checking Verilator testbench for vcore_perm_top. Provides a
// behavioral 1R1W VRF + scalar sink, issues a handful of instructions that
// specifically exercise LMUL>1 group-buffering (vrgather/vslideup/vcompress
// reaching across register boundaries), viota's absolute mask scan, the
// vmsbf single-beat path, and the vmv.x.s/vfmv.f.s GPR-vs-FPR routing.
module tb_vcore_perm_top #(
  // 0 = the original zero-backpressure, fixed-1-cycle VRF model.
  // 1 = every handshake stalls pseudo-randomly and the read response takes
  //     1..4 cycles. Same checks, same expected values -- a design that only
  //     works with an always-ready VRF fails here.
  parameter bit STRESS = 1'b0
);
  import vcore_perm_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  int pass_count = 0;
  int fail_count = 0;

  task automatic check(input string name, input logic [127:0] got, input logic [127:0] exp);
    if (got === exp) begin
      pass_count++;
      $display("[PASS] %s", name);
    end else begin
      fail_count++;
      $display("[FAIL] %s : got=%032h exp=%032h", name, got, exp);
    end
  endtask

  task automatic check32(input string name, input logic [31:0] got, input logic [31:0] exp);
    if (got === exp) begin
      pass_count++;
      $display("[PASS] %s", name);
    end else begin
      fail_count++;
      $display("[FAIL] %s : got=%08h exp=%08h", name, got, exp);
    end
  endtask

  task automatic checkb(input string name, input logic got, input logic exp);
    if (got === exp) begin
      pass_count++;
      $display("[PASS] %s", name);
    end else begin
      fail_count++;
      $display("[FAIL] %s : got=%0b exp=%0b", name, got, exp);
    end
  endtask

  // ------------------------------------------------------------------
  // DUT
  // ------------------------------------------------------------------
  logic cmd_valid, cmd_ready;
  vcore_perm_cmd_t cmd;

  logic rd_valid, rd_ready;
  vcore_vrf_read_req_t rd_req;
  logic rd_rsp_valid, rd_rsp_ready;
  logic [127:0] rd_rsp_data;

  logic wr_valid, wr_ready;
  vcore_vrf_write_req_t wr_req;
  logic [127:0] wr_data;

  logic sc_valid, sc_ready;
  vcore_scalar_write_req_t sc_req;
  logic [31:0] sc_data;

  logic commit_valid, commit_ready;
  vcore_perm_commit_t commit;

  vcore_perm_top #(.VLEN(128)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .vrf_read_valid_o(rd_valid), .vrf_read_ready_i(rd_ready), .vrf_read_req_o(rd_req),
    .vrf_read_rsp_valid_i(rd_rsp_valid), .vrf_read_rsp_ready_o(rd_rsp_ready), .vrf_read_rsp_data_i(rd_rsp_data),
    .vrf_write_valid_o(wr_valid), .vrf_write_ready_i(wr_ready), .vrf_write_req_o(wr_req), .vrf_write_data_o(wr_data),
    .scalar_write_valid_o(sc_valid), .scalar_write_ready_i(sc_ready), .scalar_write_req_o(sc_req), .scalar_write_data_o(sc_data),
    .commit_valid_o(commit_valid), .commit_ready_i(commit_ready), .commit_o(commit)
  );

  // ------------------------------------------------------------------
  // Behavioral 1R1W VRF (32 x 128b) + scalar sink
  // ------------------------------------------------------------------
  logic [127:0] vrf [0:31];
  logic [127:0] rd_data_q;
  logic         rd_busy_q;
  logic [1:0]   rd_delay_q;

  // Deterministic stall source. Free-running so the phase relative to the
  // DUT's own state machine keeps shifting across the run.
  logic [15:0] lfsr_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) lfsr_q <= 16'hACE1;
    else        lfsr_q <= {lfsr_q[14:0], lfsr_q[15]^lfsr_q[13]^lfsr_q[12]^lfsr_q[10]};
  end

  // Request side: with STRESS the VRF refuses new reads at random, and never
  // accepts one while a read is still in flight (a real 1R1W port).
  assign rd_ready = STRESS ? (!rd_busy_q && lfsr_q[0]) : 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_busy_q  <= 1'b0;
      rd_delay_q <= '0;
      rd_data_q  <= '0;
    end else if (!rd_busy_q) begin
      if (rd_valid && rd_ready) begin
        rd_busy_q  <= 1'b1;
        // Registered read: sample at acceptance, like real SRAM.
        rd_data_q  <= vrf[rd_req.addr];
        rd_delay_q <= STRESS ? lfsr_q[5:4] : 2'd0;   // 1..4 cycles total
      end
    end else if (rd_delay_q != 0) begin
      rd_delay_q <= rd_delay_q - 1'b1;
    end else if (rd_rsp_valid && rd_rsp_ready) begin
      rd_busy_q <= 1'b0;
    end
  end
  // Response is held until the requester takes it, as the protocol requires.
  assign rd_rsp_valid = rd_busy_q && (rd_delay_q == 0);
  assign rd_rsp_data  = rd_data_q;

  assign wr_ready = STRESS ? lfsr_q[1] : 1'b1;
  always_ff @(posedge clk) if (wr_valid && wr_ready) vrf[wr_req.vd_addr] <= wr_data;

  logic [4:0] last_sc_addr; logic [31:0] last_sc_data; logic last_sc_is_fp;
  int sc_event_count = 0;
  assign sc_ready = STRESS ? lfsr_q[2] : 1'b1;
  always_ff @(posedge clk) begin
    if (sc_valid && sc_ready) begin
      last_sc_addr <= sc_req.rd_addr;
      last_sc_data <= sc_data;
      last_sc_is_fp <= sc_req.is_fp;
      sc_event_count <= sc_event_count + 1;
    end
  end

  assign commit_ready = STRESS ? lfsr_q[3] : 1'b1;

  int lastbeat_count = 0;
  always_ff @(posedge clk)
    if (commit_valid && commit_ready && commit.last_beat)
      lastbeat_count <= lastbeat_count + 1;

  // ------------------------------------------------------------------
  // Handshake protocol checks
  //
  // Data matching is not enough: a producer that drops `valid` before the
  // consumer is ready, or that changes the payload mid-handshake, can still
  // produce the right answer against a permissive model and then fail
  // against a real VRF. These hold the DUT to the rule on all five ports.
  // ------------------------------------------------------------------
  int unsigned rd_stall_cycles = 0, wr_stall_cycles = 0, cm_stall_cycles = 0;
  always_ff @(posedge clk) if (rst_n) begin
    if (rd_valid && !rd_ready)         rd_stall_cycles <= rd_stall_cycles + 1;
    if (wr_valid && !wr_ready)         wr_stall_cycles <= wr_stall_cycles + 1;
    if (commit_valid && !commit_ready) cm_stall_cycles <= cm_stall_cycles + 1;
  end

  // valid must stay up until the transfer happens
  property p_hold(valid, ready);
    @(posedge clk) disable iff (!rst_n) (valid && !ready) |=> valid;
  endproperty
  a_rd_hold: assert property (p_hold(rd_valid, rd_ready))
    else $fatal(1, "VRF read request dropped valid before ready");
  a_wr_hold: assert property (p_hold(wr_valid, wr_ready))
    else $fatal(1, "VRF write dropped valid before ready");
  a_sc_hold: assert property (p_hold(sc_valid, sc_ready))
    else $fatal(1, "scalar write dropped valid before ready");
  a_cm_hold: assert property (p_hold(commit_valid, commit_ready))
    else $fatal(1, "commit dropped valid before ready");
  a_rsp_rdy_hold: assert property (
      @(posedge clk) disable iff (!rst_n)
      (rd_rsp_valid && !rd_rsp_ready) |=> rd_rsp_valid)
    else $fatal(1, "read response withdrawn -- model bug");

  // payload must be stable across a stalled handshake
  a_rd_stable: assert property (
      @(posedge clk) disable iff (!rst_n)
      (rd_valid && !rd_ready) |=> $stable(rd_req))
    else $fatal(1, "VRF read address changed while stalled");
  a_wr_stable: assert property (
      @(posedge clk) disable iff (!rst_n)
      (wr_valid && !wr_ready) |=> ($stable(wr_req) && $stable(wr_data)))
    else $fatal(1, "VRF write payload changed while stalled");
  a_sc_stable: assert property (
      @(posedge clk) disable iff (!rst_n)
      (sc_valid && !sc_ready) |=> ($stable(sc_req) && $stable(sc_data)))
    else $fatal(1, "scalar write payload changed while stalled");
  a_cm_stable: assert property (
      @(posedge clk) disable iff (!rst_n)
      (commit_valid && !commit_ready) |=> $stable(commit))
    else $fatal(1, "commit payload changed while stalled");

  // the cluster is single-outstanding on the read port by construction
  a_one_read: assert property (
      @(posedge clk) disable iff (!rst_n)
      (rd_valid && rd_ready) |-> !rd_busy_q)
    else $fatal(1, "second VRF read issued while one was still in flight");

  // ------------------------------------------------------------------
  // Instruction assembly + issue helpers
  // ------------------------------------------------------------------
  function automatic logic [31:0] mkinst(
    input logic [5:0] f6, input logic vm, input logic [4:0] vs2,
    input logic [4:0] vs1, input logic [2:0] f3, input logic [4:0] vd
  );
    mkinst = {f6, vm, vs2, vs1, f3, vd, 7'h57};
  endfunction

  task automatic issue(
    input logic [31:0] inst, input logic [31:0] scalar,
    input logic [2:0] sew, input logic [2:0] vlmul,
    input logic [16:0] vl, input logic vta
  );
    cmd = '0;
    cmd.inst = inst;
    cmd.scalar = scalar;
    cmd.sew = sew;
    cmd.vlmul = vlmul;
    cmd.vta = vta;
    cmd.vma = 1'b1;
    cmd.vill = 1'b0;
    cmd.vl = vl;
    cmd.vstart = '0;
    cmd.mask_snapshot = '0;
    cmd.tag = 16'hAAAA;
    cmd_valid = 1'b1;
    @(posedge clk);
    while (!cmd_ready) @(posedge clk);
    cmd_valid = 1'b0;
    last_illegal = 1'b0;
    forever begin
      @(posedge clk);
      if (commit_valid && commit_ready && commit.last_beat) begin
        last_illegal = commit.illegal_op;
        if (commit.illegal_op) $display("[WARN] instruction flagged illegal_op (inst=%08h)", inst);
        break;
      end
    end
  endtask

  // Full-control issue: mask snapshot, vstart, vma and vm all settable.
  // `issue` above stays as-is so the original 29 checks are untouched.
  task automatic issue_full(
    input logic [31:0] inst, input logic [31:0] scalar,
    input logic [2:0] sew, input logic [2:0] vlmul,
    input logic [16:0] vl, input logic vta, input logic vma,
    input logic [16:0] vstart, input logic [127:0] v0
  );
    cmd = '0;
    cmd.inst = inst;
    cmd.scalar = scalar;
    cmd.sew = sew;
    cmd.vlmul = vlmul;
    cmd.vta = vta;
    cmd.vma = vma;
    cmd.vill = 1'b0;
    cmd.vl = vl;
    cmd.vstart = vstart;
    cmd.mask_snapshot = v0;
    cmd.tag = 16'hAAAA;
    cmd_valid = 1'b1;
    @(posedge clk);
    while (!cmd_ready) @(posedge clk);
    cmd_valid = 1'b0;
    last_illegal = 1'b0;
    forever begin
      @(posedge clk);
      if (commit_valid && commit_ready && commit.last_beat) begin
        last_illegal = commit.illegal_op;
        break;
      end
    end
  endtask

  // Hand a command over and return as soon as it is accepted, without
  // waiting for it to retire. Lets several instructions sit in the issue
  // FIFO at once -- the depth-3 buffer is dead code otherwise.
  task automatic issue_nowait(
    input logic [31:0] inst, input logic [31:0] scalar,
    input logic [2:0] sew, input logic [2:0] vlmul,
    input logic [16:0] vl, input logic vta
  );
    cmd = '0;
    cmd.inst = inst; cmd.scalar = scalar; cmd.sew = sew; cmd.vlmul = vlmul;
    cmd.vta = vta; cmd.vma = 1'b1; cmd.vill = 1'b0;
    cmd.vl = vl; cmd.vstart = '0; cmd.mask_snapshot = '0; cmd.tag = 16'hAAAA;
    cmd_valid = 1'b1;
    @(posedge clk);
    while (!cmd_ready) @(posedge clk);
    cmd_valid = 1'b0;
  endtask

  task automatic wait_for(input int unsigned n);
    int unsigned target;
    target = lastbeat_count + n;
    while (lastbeat_count < target) @(posedge clk);
    repeat (2) @(posedge clk);
  endtask

  localparam logic [2:0] LMUL1 = 3'b000;
  localparam logic [2:0] LMUL2 = 3'b001;
  localparam logic [2:0] LMUL8 = 3'b011;
  localparam logic [2:0] LMULF2 = 3'b111;  // mf2
  localparam logic [2:0] LMULF4 = 3'b110;  // mf4

  int i;
  logic last_illegal;

  initial begin
    rst_n = 0;
    cmd_valid = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ---------------- TEST 1: vid.v, SEW32 LMUL1 ----------------
    vrf[3] = '0;
    issue(mkinst(6'h14, 1'b1, 5'd0, 5'h11, 3'b010, 5'd3), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0);
    check("vid.v (LMUL1)", vrf[3], {32'd3,32'd2,32'd1,32'd0});

    // ---------------- TEST 2: vrgather.vv, LMUL1 ----------------
    vrf[1] = {32'd2,32'd3,32'd0,32'd1};   // index vector: elem0=1,elem1=0,elem2=3,elem3=2
    vrf[2] = {32'd400,32'd300,32'd200,32'd100}; // data: elem0=100,elem1=200,elem2=300,elem3=400
    vrf[5] = '0;
    issue(mkinst(6'h0c, 1'b1, 5'd2, 5'd1, 3'b000, 5'd5), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0);
    check("vrgather.vv (LMUL1)", vrf[5], {32'd300,32'd400,32'd100,32'd200});

    // ---------------- TEST 3: vrgather.vv, LMUL2, cross-register ----------------
    // src group v2:v3 = {10,20,30,40 | 50,60,70,80}; idx group v6:v7 picks the OTHER half.
    vrf[2] = {32'd40,32'd30,32'd20,32'd10};
    vrf[3] = {32'd80,32'd70,32'd60,32'd50};
    vrf[6] = {32'd7,32'd6,32'd5,32'd4};   // dest reg0 indices -> source reg1 (elems 4..7)
    vrf[7] = {32'd3,32'd2,32'd1,32'd0};   // dest reg1 indices -> source reg0 (elems 0..3)
    vrf[4] = '0; vrf[5] = '0;
    issue(mkinst(6'h0c, 1'b1, 5'd2, 5'd6, 3'b000, 5'd4), 32'd0, VSEW_32, LMUL2, 17'd8, 1'b0);
    check("vrgather.vv (LMUL2 reg0<-src reg1)", vrf[4], {32'd80,32'd70,32'd60,32'd50});
    check("vrgather.vv (LMUL2 reg1<-src reg0)", vrf[5], {32'd40,32'd30,32'd20,32'd10});

    // ---------------- TEST 4: vslideup.vx, LMUL2, offset=5 (cross-register) ----------------
    vrf[2] = {32'd4,32'd3,32'd2,32'd1};
    vrf[3] = {32'd8,32'd7,32'd6,32'd5};
    vrf[4] = {4{32'hDEADDEAD}};
    vrf[5] = {4{32'hDEADDEAD}};
    issue(mkinst(6'h0e, 1'b1, 5'd2, 5'd0, 3'b100, 5'd4), 32'd5, VSEW_32, LMUL2, 17'd8, 1'b0);
    check("vslideup.vx reg0 (all below offset)", vrf[4], {4{32'hDEADDEAD}});
    check("vslideup.vx reg1 (cross-register fetch)", vrf[5], {32'd3,32'd2,32'd1,32'hDEADDEAD});

    // ---------------- TEST 5: vcompress.vm, LMUL2, vta=1 ----------------
    vrf[2] = {32'd4,32'd3,32'd2,32'd1};
    vrf[3] = {32'd8,32'd7,32'd6,32'd5};
    vrf[1] = 128'b10110101; // mask bits [7:0] = 1 0 1 1 0 1 0 1 (bit0=1,bit1=0,bit2=1,bit3=0,bit4=1,bit5=1,bit6=0,bit7=1)
    vrf[4] = '0; vrf[5] = '0;
    issue(mkinst(6'h17, 1'b1, 5'd2, 5'd1, 3'b010, 5'd4), 32'd0, VSEW_32, LMUL2, 17'd5, 1'b1);
    // vl=5, so only mask bits 0..4 select. Bits 5 and 7 are past vl and
    // select nothing (RVV 1.0 16.5: "the first vl elements of vs2"). Actives
    // are elements 0,2,4 -> values 1,3,5; everything from index 3 on is tail
    // and vta=1 makes it agnostic. The previous expectation here counted the
    // out-of-vl mask bits as well, which is what F1 fixed.
    check("vcompress.vm reg0 (packed actives, vl=5)", vrf[4], {32'hFFFFFFFF,32'd5,32'd3,32'd1});
    check("vcompress.vm reg1 (entirely tail-agnostic)", vrf[5], {4{32'hFFFFFFFF}});

    // ---------------- TEST 6: viota.m, LMUL2, absolute mask scan ----------------
    vrf[1] = 128'b01011010; // same-shaped mask as above but reused for viota (vs2=1, non-grouping)
    vrf[4] = '0; vrf[5] = '0;
    issue(mkinst(6'h14, 1'b1, 5'd1, 5'h10, 3'b010, 5'd4), 32'd0, VSEW_32, LMUL2, 17'd8, 1'b0);
    check("viota.m reg0 (prefix count 0..3)", vrf[4], {32'd1,32'd1,32'd0,32'd0});
    check("viota.m reg1 (prefix count 4..7)", vrf[5], {32'd4,32'd3,32'd3,32'd2});

    // ---------------- TEST 7: vmsbf.m / vmsof.m / vmsif.m, single beat despite LMUL2 ----------------
    vrf[1] = 128'b01011010;
    vrf[4] = {4{32'hCAFECAFE}}; // old value to confirm upper bits preserved as tail-agnostic 1s, not old
    issue(mkinst(6'h14, 1'b1, 5'd1, 5'h01, 3'b010, 5'd4), 32'd0, VSEW_32, LMUL2, 17'd8, 1'b0);
    check("vmsbf.m", vrf[4], {120'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, 8'b0000_0001});
    vrf[4] = {4{32'hCAFECAFE}};
    issue(mkinst(6'h14, 1'b1, 5'd1, 5'h02, 3'b010, 5'd4), 32'd0, VSEW_32, LMUL2, 17'd8, 1'b0);
    check("vmsof.m", vrf[4], {120'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, 8'b0000_0010});
    vrf[4] = {4{32'hCAFECAFE}};
    issue(mkinst(6'h14, 1'b1, 5'd1, 5'h03, 3'b010, 5'd4), 32'd0, VSEW_32, LMUL2, 17'd8, 1'b0);
    check("vmsif.m", vrf[4], {120'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, 8'b0000_0011});

    // ---------------- TEST 8: vmv.x.s (GPR) vs vfmv.f.s (FPR) ----------------
    vrf[2] = {96'h0, 32'hCAFEBABE};
    i = sc_event_count;
    issue(mkinst(6'h10, 1'b1, 5'd2, 5'd0, 3'b010, 5'd9), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0); // vmv.x.s rd=x9
    checkb("vmv.x.s issued a scalar write", (sc_event_count > i), 1'b1);
    check32("vmv.x.s data", last_sc_data, 32'hCAFEBABE);
    checkb("vmv.x.s targets GPR (is_fp=0)", last_sc_is_fp, 1'b0);

    i = sc_event_count;
    issue(mkinst(6'h10, 1'b1, 5'd2, 5'd0, 3'b001, 5'd9), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0); // vfmv.f.s fd=f9
    checkb("vfmv.f.s issued a scalar write", (sc_event_count > i), 1'b1);
    check32("vfmv.f.s data", last_sc_data, 32'hCAFEBABE);
    checkb("vfmv.f.s targets FPR (is_fp=1)", last_sc_is_fp, 1'b1);

    // ---------------- TEST 9: vmv.s.x writes vd[0], preserves the rest ----------------
    vrf[4] = {4{32'h11111111}};
    issue(mkinst(6'h10, 1'b1, 5'd0, 5'd0, 3'b110, 5'd4), 32'hBEEFCAFE, VSEW_32, LMUL1, 17'd4, 1'b0);
    check("vmv.s.x", vrf[4], {32'h11111111,32'h11111111,32'h11111111,32'hBEEFCAFE});

    // ---------------- TEST 10: vmv2r.v whole-register move ----------------
    vrf[10] = 128'hDEAD_0000_0000_0000_0000_0000_0000_0001;
    vrf[11] = 128'hBEEF_0000_0000_0000_0000_0000_0000_0002;
    vrf[20] = '0; vrf[21] = '0;
    issue(mkinst(6'h27, 1'b1, 5'd10, 5'd1, 3'b011, 5'd20), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0); // vmv2r.v v20,v10
    check("vmv2r.v reg0", vrf[20], vrf[10]);
    check("vmv2r.v reg1", vrf[21], 128'hBEEF_0000_0000_0000_0000_0000_0000_0002);

    // ================= LMUL=8 (MAXLMUL) boundary tests =================
    // vrgather.vv, SEW8, LMUL8: full 128-element reversal across all 8
    // source/index/destination registers -- every destination register
    // pulls from the mirror-image source register (reg0<-reg7, reg1<-reg6...).
    begin
      logic [127:0] w;
      logic all_ok;
      for (int r = 0; r < 8; r++) begin
        w = '0;
        for (int j = 0; j < 16; j++) w[j*8 +: 8] = 8'(r*16+j);
        vrf[r] = w; // src v0..v7 : elem value = global position
      end
      for (int r = 0; r < 8; r++) begin
        w = '0;
        for (int j = 0; j < 16; j++) w[j*8 +: 8] = 8'(127 - (r*16+j));
        vrf[8+r] = w; // idx v8..v15 : reversed global position
      end
      for (int r = 0; r < 8; r++) vrf[16+r] = '0;
      issue(mkinst(6'h0c, 1'b1, 5'd0, 5'd8, 3'b000, 5'd16), 32'd0, VSEW_8, LMUL8, 17'd128, 1'b0);
      all_ok = 1'b1;
      for (int r = 0; r < 8; r++) begin
        w = '0;
        for (int j = 0; j < 16; j++) w[j*8 +: 8] = 8'(127 - (r*16+j));
        if (vrf[16+r] !== w) begin
          all_ok = 1'b0;
          fail_count++;
          $display("[FAIL] vrgather.vv LMUL8 reg%0d got=%032h exp=%032h", r, vrf[16+r], w);
        end
      end
      if (all_ok) begin pass_count++; $display("[PASS] vrgather.vv LMUL8 full 128-element reversal"); end
    end

    // vrgatherei16.vv, SEW32, LMUL8: idx_regs(4) != group_regs(8) -- index
    // buffer is deliberately SMALLER than the data group.
    begin
      logic [127:0] w;
      logic all_ok;
      for (int r = 0; r < 8; r++) begin
        w = '0;
        for (int j = 0; j < 4; j++) w[j*32 +: 32] = 32'(r*4+j);
        vrf[r] = w; // src v0..v7, SEW32: elem value = global position
      end
      for (int r = 0; r < 4; r++) begin
        w = '0;
        for (int j = 0; j < 8; j++) w[j*16 +: 16] = 16'(31 - (r*8+j));
        vrf[8+r] = w; // idx v8..v11, EEW16: reversed global position
      end
      for (int r = 0; r < 8; r++) vrf[16+r] = '0;
      issue(mkinst(6'h0e, 1'b1, 5'd0, 5'd8, 3'b000, 5'd16), 32'd0, VSEW_32, LMUL8, 17'd32, 1'b0);
      all_ok = 1'b1;
      for (int r = 0; r < 8; r++) begin
        w = '0;
        for (int j = 0; j < 4; j++) w[j*32 +: 32] = 32'(31 - (r*4+j));
        if (vrf[16+r] !== w) begin
          all_ok = 1'b0;
          fail_count++;
          $display("[FAIL] vrgatherei16.vv LMUL8/SEW32 reg%0d got=%032h exp=%032h", r, vrf[16+r], w);
        end
      end
      if (all_ok) begin pass_count++; $display("[PASS] vrgatherei16.vv LMUL8/SEW32 (idx_regs=4 != group_regs=8)"); end
    end

    // vrgatherei16.vv, SEW8, LMUL8: idx_regs would need 16 > MAXLMUL(8) -> illegal
    issue(mkinst(6'h0e, 1'b1, 5'd0, 5'd8, 3'b000, 5'd16), 32'd0, VSEW_8, LMUL8, 17'd128, 1'b0);
    checkb("vrgatherei16.vv SEW8/LMUL8 rejected (idx_regs=16>MAXLMUL)", last_illegal, 1'b1);

    // vslideup.vx, SEW8, LMUL8, offset=100 (crosses 6 register boundaries)
    begin
      logic [127:0] w;
      logic all_ok;
      for (int r = 0; r < 8; r++) begin
        w = '0;
        for (int j = 0; j < 16; j++) w[j*8 +: 8] = 8'(r*16+j);
        vrf[r] = w; // src v0..v7
      end
      for (int r = 0; r < 8; r++) vrf[16+r] = {16{8'hEE}};
      issue(mkinst(6'h0e, 1'b1, 5'd0, 5'd0, 3'b100, 5'd16), 32'd100, VSEW_8, LMUL8, 17'd128, 1'b0);
      all_ok = 1'b1;
      for (int p = 0; p < 128; p++) begin
        logic [7:0] exp_e;
        logic [7:0] got_e;
        exp_e = (p < 100) ? 8'hEE : 8'(p - 100);
        got_e = vrf[16 + p/16][ (p%16)*8 +: 8 ];
        if (got_e !== exp_e) begin
          all_ok = 1'b0;
          fail_count++;
          $display("[FAIL] vslideup.vx LMUL8 elem%0d got=%02h exp=%02h", p, got_e, exp_e);
        end
      end
      if (all_ok) begin pass_count++; $display("[PASS] vslideup.vx LMUL8 offset=100 (crosses 6 register boundaries)"); end
    end

    // vcompress.vm, SEW8, LMUL8, vl=32: mask bit set every 4th position.
    // Only the first vl=32 elements select (RVV 1.0 16.5), so 8 actives --
    // positions 0,4,...,28 -- not the 32 you get by scanning all of VLMAX.
    // The old expectation scanned all 128 mask bits; that was F1.
    begin
      logic [127:0] mask_w;
      logic [127:0] w;
      logic all_ok;
      mask_w = '0;
      for (int p = 0; p < 128; p++) if (p % 4 == 0) mask_w[p] = 1'b1;
      vrf[8] = mask_w;
      for (int r = 0; r < 8; r++) begin
        w = '0;
        for (int j = 0; j < 16; j++) w[j*8 +: 8] = 8'(r*16+j);
        vrf[r] = w; // src v0..v7
      end
      for (int r = 0; r < 8; r++) vrf[16+r] = '0;
      issue(mkinst(6'h17, 1'b1, 5'd0, 5'd8, 3'b010, 5'd16), 32'd0, VSEW_8, LMUL8, 17'd32, 1'b1);
      all_ok = 1'b1;
      for (int p = 0; p < 128; p++) begin
        logic [7:0] exp_e;
        logic [7:0] got_e;
        exp_e = (p < 8) ? 8'(4*p) : 8'hFF; // 8 actives packed, then vta tail
        got_e = vrf[16 + p/16][ (p%16)*8 +: 8 ];
        if (got_e !== exp_e) begin
          all_ok = 1'b0;
          fail_count++;
          $display("[FAIL] vcompress.vm LMUL8 elem%0d got=%02h exp=%02h", p, got_e, exp_e);
        end
      end
      if (all_ok) begin pass_count++; $display("[PASS] vcompress.vm LMUL8 (vl=32 -> 8 actives, rest tail)"); end
    end

    // viota.m, SEW8, LMUL8: mask bit set every 8th position, full vl=128 (no tail)
    begin
      logic [127:0] mask_w;
      logic all_ok;
      mask_w = '0;
      for (int p = 0; p < 128; p++) if (p % 8 == 0) mask_w[p] = 1'b1;
      vrf[8] = mask_w; // vs2 = single mask register (non-grouping)
      for (int r = 0; r < 8; r++) vrf[16+r] = '0;
      issue(mkinst(6'h14, 1'b1, 5'd8, 5'h10, 3'b010, 5'd16), 32'd0, VSEW_8, LMUL8, 17'd128, 1'b0);
      all_ok = 1'b1;
      for (int p = 0; p < 128; p++) begin
        logic [7:0] exp_e;
        logic [7:0] got_e;
        exp_e = 8'((p+7)/8); // closed form for "# of multiples of 8 strictly below p"
        got_e = vrf[16 + p/16][ (p%16)*8 +: 8 ];
        if (got_e !== exp_e) begin
          all_ok = 1'b0;
          fail_count++;
          $display("[FAIL] viota.m LMUL8 elem%0d got=%02h exp=%02h", p, got_e, exp_e);
        end
      end
      if (all_ok) begin pass_count++; $display("[PASS] viota.m LMUL8 (single mask src, 8-register dest group)"); end
    end

    // vmv8r.v: whole 8-register move
    begin
      logic all_ok;
      for (int r = 0; r < 8; r++) vrf[r] = {16{r[7:0]}};
      for (int r = 0; r < 8; r++) vrf[24+r] = '0;
      issue(mkinst(6'h27, 1'b1, 5'd0, 5'd7, 3'b011, 5'd24), 32'd0, VSEW_8, LMUL1, 17'd16, 1'b0); // vmv8r.v v24,v0
      all_ok = 1'b1;
      for (int r = 0; r < 8; r++) begin
        if (vrf[24+r] !== {16{r[7:0]}}) begin
          all_ok = 1'b0;
          fail_count++;
          $display("[FAIL] vmv8r.v reg%0d got=%032h exp=%032h", r, vrf[24+r], {16{r[7:0]}});
        end
      end
      if (all_ok) begin pass_count++; $display("[PASS] vmv8r.v (8-register whole move)"); end
    end

    // ================================================================
    // REGRESSION: RVV 1.0 conformance cases (F1..F11)
    // Every case below is quoted from the spec in the comment above it.
    // ================================================================

    // ---- F1  vcompress: "the first vl elements of vs2" (spec 16.5) ----
    // SEW32/LMUL1 -> VLMAX=4, vl=2. vs1 has bits set only at 2 and 3, i.e.
    // entirely past vl, so NO element is active and vd keeps its old value
    // (vta=0 -> tail undisturbed).
    vrf[6] = {32'd40,32'd30,32'd20,32'd10};   // vs2 = v6
    vrf[7] = {124'd0, 4'b1100};               // vs1 = v7, bits 2,3 only
    vrf[8] = {4{32'hA5A5A5A5}};               // vd  = v8
    issue(mkinst(6'h17, 1'b1, 5'd6, 5'd7, 3'b010, 5'd8), 32'd0, VSEW_32, LMUL1, 17'd2, 1'b0);
    check("F1 vcompress ignores mask bits past vl", vrf[8], {4{32'hA5A5A5A5}});

    // ---- F2  vrgather: "index >= VLMAX -> 0" with fractional LMUL (16.4) ----
    // mf2 at SEW32 -> VLMAX = (128/32)/2 = 2. Index 3 is past VLMAX.
    vrf[6] = {32'd40,32'd30,32'd20,32'd10};
    vrf[8] = {4{32'hA5A5A5A5}};
    issue(mkinst(6'h0c, 1'b1, 5'd6, 5'd3, 3'b011, 5'd8), 32'd0, VSEW_32, LMULF2, 17'd2, 1'b1);
    // vl=2, vta=1 -> elements 0,1 = 0 (index out of range), 2,3 = tail agnostic
    check32("F2 vrgather.vi out-of-VLMAX index -> 0 (mf2)", vrf[8][31:0], 32'd0);

    // ---- F2b vslidedown: "VLMAX <= i+OFFSET -> src[i]=0" (spec 16.3.2) ----
    vrf[6] = {32'd40,32'd30,32'd20,32'd10};
    vrf[8] = {4{32'hA5A5A5A5}};
    issue(mkinst(6'h0f, 1'b1, 5'd6, 5'd1, 3'b011, 5'd8), 32'd0, VSEW_32, LMULF2, 17'd2, 1'b1);
    // VLMAX=2: elem0 <- vs2[1]=20, elem1 <- vs2[2] which is >= VLMAX -> 0
    check32("F2b vslidedown.vi past VLMAX -> 0 (mf2) elem0", vrf[8][31:0], 32'd20);
    check32("F2b vslidedown.vi past VLMAX -> 0 (mf2) elem1", vrf[8][63:32], 32'd0);

    // ---- F3  viota.m: "destination cannot overlap the source" (15.2) ----
    vrf[2] = {124'd0, 4'b0101};
    issue(mkinst(6'h14, 1'b1, 5'd2, 5'h10, 3'b010, 5'd2), 32'd0, VSEW_32, LMUL2, 17'd8, 1'b0);
    checkb("F3 viota.m vd overlapping vs2 is illegal", last_illegal, 1'b1);

    // ---- F3b vmsbf.m: same overlap rule (15.1) ----
    vrf[2] = {124'd0, 4'b0100};
    issue(mkinst(6'h14, 1'b1, 5'd2, 5'h01, 3'b010, 5'd2), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0);
    checkb("F3b vmsbf.m vd overlapping vs2 is illegal", last_illegal, 1'b1);

    // ---- F4  vslidedown has NO overlap restriction (16.3.2) ----
    // Only vslideup / vslide1up are restricted; in-place slidedown is legal.
    vrf[8] = {32'd40,32'd30,32'd20,32'd10};
    issue(mkinst(6'h0f, 1'b1, 5'd8, 5'd1, 3'b011, 5'd8), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b1);
    checkb("F4 in-place vslidedown.vi is legal", last_illegal, 1'b0);
    check32("F4 in-place vslidedown.vi result", vrf[8][31:0], 32'd20);

    // ---- F4b vslide1down likewise unrestricted ----
    vrf[8] = {32'd40,32'd30,32'd20,32'd10};
    issue(mkinst(6'h0f, 1'b1, 5'd8, 5'd0, 3'b110, 5'd8), 32'd99, VSEW_32, LMUL1, 17'd4, 1'b1);
    checkb("F4b in-place vslide1down.vx is legal", last_illegal, 1'b0);

    // ---- F4c vslideup overlap IS illegal (16.3.1) - must stay rejected ----
    vrf[8] = {32'd40,32'd30,32'd20,32'd10};
    issue(mkinst(6'h0e, 1'b1, 5'd8, 5'd1, 3'b011, 5'd8), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0);
    checkb("F4c in-place vslideup.vi stays illegal", last_illegal, 1'b1);

    // ---- F5  vstart != 0 raises illegal for vcompress/viota/vmsbf-family ----
    vrf[6] = {32'd40,32'd30,32'd20,32'd10};
    vrf[7] = {124'd0, 4'b1111};
    issue_full(mkinst(6'h17, 1'b1, 5'd6, 5'd7, 3'b010, 5'd8), 32'd0, VSEW_32, LMUL1,
               17'd4, 1'b0, 1'b1, 17'd1, 128'd0);
    checkb("F5 vcompress with vstart!=0 is illegal", last_illegal, 1'b1);

    vrf[2] = {124'd0, 4'b0101};
    issue_full(mkinst(6'h14, 1'b1, 5'd2, 5'h10, 3'b010, 5'd8), 32'd0, VSEW_32, LMUL1,
               17'd4, 1'b0, 1'b1, 17'd1, 128'd0);
    checkb("F5b viota.m with vstart!=0 is illegal", last_illegal, 1'b1);

    vrf[2] = {124'd0, 4'b0100};
    issue_full(mkinst(6'h14, 1'b1, 5'd2, 5'h02, 3'b010, 5'd8), 32'd0, VSEW_32, LMUL1,
               17'd4, 1'b0, 1'b1, 17'd1, 128'd0);
    checkb("F5c vmsof.m with vstart!=0 is illegal", last_illegal, 1'b1);

    // ---- F6  vslideup: "0 <= i < max(vstart,OFFSET) Unchanged" (16.3.1) ----
    // Masked, vma=1. Element 0 is below OFFSET=1 AND inactive. The spec says
    // Unchanged wins; the agnostic fill must not reach it.
    vrf[6] = {32'd40,32'd30,32'd20,32'd10};
    vrf[8] = {4{32'hA5A5A5A5}};
    issue_full(mkinst(6'h0e, 1'b0, 5'd6, 5'd1, 3'b011, 5'd8), 32'd0, VSEW_32, LMUL1,
               17'd4, 1'b0, 1'b1, 17'd0, 128'hE);  // v0 = 1110 -> elem0 inactive
    check32("F6 vslideup below-offset stays undisturbed", vrf[8][31:0], 32'hA5A5A5A5);

    // ---- F7  viota.m: "only the enabled elements contribute to the sum" ----
    // Spec 15.2 worked example, transcribed to SEW=8 / 8 elements.
    //   v0 = 1110_1011  v2 = 1001_0001  old v4 = 2 3 4 5 6 7 8 9 (e7..e0)
    //   result          = 1 1 1 5 1 7 1 0  (e7..e0)
    vrf[2] = {120'd0, 8'b1001_0001};
    vrf[4] = {64'd0, 8'd2,8'd3,8'd4,8'd5,8'd6,8'd7,8'd8,8'd9};
    issue_full(mkinst(6'h14, 1'b0, 5'd2, 5'h10, 3'b010, 5'd4), 32'd0, VSEW_8, LMUL1,
               17'd8, 1'b0, 1'b0, 17'd0, 128'hEB);  // vma=0 -> inactive undisturbed
    check("F7 masked viota.m counts only active elements",
          vrf[4][63:0], {8'd1,8'd1,8'd1,8'd5,8'd1,8'd7,8'd1,8'd0});

    // ---- F7b vmsbf.m: "first ACTIVE source element that is a 1" (15.1) ----
    // vs2 bit 1 is set but element 1 is inactive, so the first active set
    // element is 3. Active destination elements 0 and 2 get 1; 3 onward get 0.
    // vma=1 -> inactive destination elements read back as 1 (agnostic).
    vrf[2] = {120'd0, 8'b0000_1010};   // set at 1 and 3
    vrf[5] = '0;
    issue_full(mkinst(6'h14, 1'b0, 5'd2, 5'h01, 3'b010, 5'd5), 32'd0, VSEW_8, LMUL1,
               17'd8, 1'b0, 1'b0, 17'd0, 128'hFD);  // v0 = 1111_1101, elem1 inactive
    // active elems 0,2 -> before first active set bit (3) -> 1
    // active elems 3..7 -> 0 ; inactive elem1 -> undisturbed 0
    check32("F7b vmsbf.m scans only active source elements",
            {24'd0, vrf[5][7:0]}, {24'd0, 8'b0000_0101});

    // ---- F9  "When vstart >= vl ... no elements are updated ... including
    //          that no tail elements are updated with agnostic values" (5.4) ----
    vrf[8] = {4{32'hA5A5A5A5}};
    issue_full(mkinst(6'h17, 1'b1, 5'd0, 5'd3, 3'b011, 5'd8), 32'd0, VSEW_32, LMUL1,
               17'd0, 1'b1, 1'b1, 17'd0, 128'd0);   // vmv.v.i v8, 3 with vl=0, vta=1
    check("F9 vl=0 leaves the destination completely untouched",
          vrf[8], {4{32'hA5A5A5A5}});

    vrf[8] = {4{32'hA5A5A5A5}};
    issue_full(mkinst(6'h17, 1'b1, 5'd0, 5'd3, 3'b011, 5'd8), 32'd0, VSEW_32, LMUL1,
               17'd2, 1'b1, 1'b1, 17'd3, 128'd0);   // vstart=3 >= vl=2
    check("F9b vstart>=vl leaves the destination completely untouched",
          vrf[8], {4{32'hA5A5A5A5}});

    // ---- F10 vrgather.vx: "If XLEN > SEW, the index is NOT truncated" (16.4)
    // SEW=8, VLMAX=16. x[rs1]=0x104 = 260. Truncated to 8 bits it would be 4
    // (in range, wrong data); untruncated it is >= VLMAX, so the answer is 0.
    for (int e = 0; e < 16; e++) vrf[6][e*8 +: 8] = 8'(8'hC0 + e[7:0]);
    vrf[8] = '0;
    issue(mkinst(6'h0c, 1'b1, 5'd6, 5'd0, 3'b100, 5'd8), 32'h0000_0104, VSEW_8, LMUL1, 17'd16, 1'b0);
    check("F10 vrgather.vx index is not truncated to SEW", vrf[8], 128'd0);

    // ---- F11 vmv<nr>r.v: "no elements are written if vstart >= evl" (16.6) --
    // SEW=32 -> evl for vmv1r.v is 4. vstart=4 means no write.
    vrf[10] = 128'hDEAD_BEEF_0000_0000_0000_0000_0000_0001;
    vrf[11] = 128'hFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
    issue_full(mkinst(6'h27, 1'b1, 5'd10, 5'd0, 3'b011, 5'd11), 32'd0, VSEW_32, LMUL1,
               17'd4, 1'b0, 1'b1, 17'd4, 128'd0);
    check("F11 vmv1r.v with vstart>=evl writes nothing", vrf[11], {128{1'b1}});

    // ---- F8  reserved encodings ----
    issue(mkinst(6'h17, 1'b1, 5'd3, 5'd0, 3'b000, 5'd8), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0);
    checkb("F8 vmv.v.v with vs2!=0 is illegal", last_illegal, 1'b1);
    issue(mkinst(6'h10, 1'b0, 5'd2, 5'd0, 3'b010, 5'd9), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0);
    checkb("F8b masked vmv.x.s (vm=0) is illegal", last_illegal, 1'b1);
    issue(mkinst(6'h27, 1'b0, 5'd0, 5'd0, 3'b011, 5'd11), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0);
    checkb("F8c masked vmv1r.v (vm=0) is illegal", last_illegal, 1'b1);

    // ---- regression guards: previously-untested mnemonics still work ----
    vrf[6] = {32'd40,32'd30,32'd20,32'd10};
    vrf[8] = '0;
    issue(mkinst(6'h0c, 1'b1, 5'd6, 5'd2, 3'b011, 5'd8), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0);
    check("vrgather.vi splat", vrf[8], {4{32'd30}});

    vrf[6] = {32'd40,32'd30,32'd20,32'd10};
    vrf[7] = {32'd4,32'd3,32'd2,32'd1};
    vrf[8] = '0;
    issue_full(mkinst(6'h17, 1'b0, 5'd6, 5'd7, 3'b000, 5'd8), 32'd0, VSEW_32, LMUL1,
               17'd4, 1'b0, 1'b1, 17'd0, 128'b0101);
    check("vmerge.vvm", vrf[8], {32'd40,32'd3,32'd20,32'd1});

    vrf[6] = {32'd40,32'd30,32'd20,32'd10};
    vrf[8] = '0;
    issue(mkinst(6'h0e, 1'b1, 5'd6, 5'd0, 3'b110, 5'd8), 32'd77, VSEW_32, LMUL1, 17'd4, 1'b0);
    check("vslide1up.vx", vrf[8], {32'd30,32'd20,32'd10,32'd77});

    vrf[6] = {32'd40,32'd30,32'd20,32'd10};
    vrf[8] = '0;
    issue(mkinst(6'h0f, 1'b1, 5'd6, 5'd0, 3'b110, 5'd8), 32'd88, VSEW_32, LMUL1, 17'd4, 1'b0);
    check("vslide1down.vx", vrf[8], {32'd88,32'd40,32'd30,32'd20});

    // ---- issue FIFO: three instructions in flight at once ----
    // `issue()` waits for each one to retire, so the depth-3 FIFO never held
    // more than a single entry. This hands over three without waiting.
    vrf[12] = '0; vrf[13] = '0; vrf[14] = '0;
    issue_nowait(mkinst(6'h14, 1'b1, 5'd0, 5'h11, 3'b010, 5'd12), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0);
    issue_nowait(mkinst(6'h14, 1'b1, 5'd0, 5'h11, 3'b010, 5'd13), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0);
    issue_nowait(mkinst(6'h14, 1'b1, 5'd0, 5'h11, 3'b010, 5'd14), 32'd0, VSEW_32, LMUL1, 17'd4, 1'b0);
    wait_for(3);
    check("FIFO 3 back-to-back vid.v (a)", vrf[12], {32'd3,32'd2,32'd1,32'd0});
    check("FIFO 3 back-to-back vid.v (b)", vrf[13], {32'd3,32'd2,32'd1,32'd0});
    check("FIFO 3 back-to-back vid.v (c)", vrf[14], {32'd3,32'd2,32'd1,32'd0});

    $display("========================================");
    $display("STALLS INJECTED: read_req=%0d vrf_write=%0d commit=%0d",
             rd_stall_cycles, wr_stall_cycles, cm_stall_cycles);
    $display("MODE: %s", STRESS ? "STRESS (random backpressure + 1..4 cycle read latency)" : "IDEAL (always-ready VRF)");
    $display("TOTAL: %0d passed, %0d failed", pass_count, fail_count);
    $display("========================================");
    if (fail_count != 0) $fatal(1, "permutation testbench had failures");
    $finish;
  end

  initial begin
    #400000;
    $fatal(1, "testbench timeout");
  end

endmodule
