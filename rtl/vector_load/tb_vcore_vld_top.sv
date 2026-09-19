// Directed feature tests for the vector load cluster.
//
// The golden-reference bench (tb_vcore_vld_ref) proves the DATA is right and
// tb_vcore_vld_decode_table proves the SCOPE is right. This one covers what
// neither can see:
//
//  T1  the exact SET of memory requests, for every addressing form. RVV 1.0
//      7 requires that a load "only access memory or raise exceptions for
//      active elements", so a request for a masked-off, prestart or tail
//      element is a real bug -- it can fault on an unmapped page -- even
//      though it changes no architectural data.
//  T2  flush while requests are outstanding: the bus is still owed
//      responses, so the cluster must drain them rather than drop ready.
//  T3  an error response leaves the destination untouched and surfaces as
//      mem_error (the non-fault-only-first contract).
//  T4  busy_o covers the whole window in which the bus owes data.
//  T5  back-to-back issue through the issue FIFO.
//  T6  multiple-outstanding actually shortens the instruction.
//  T7  an ORDERED indexed load never has two requests in flight.
//  T8  fault-only-first trims vl instead of trapping, and reports it.
//  T9  a whole-register load ignores vtype and vl entirely.
module tb_vcore_vld_top;
  import vcore_vld_pkg::*;

  localparam int unsigned VLEN  = 128;
  localparam int unsigned BPR   = VLEN/8;
  localparam int unsigned MEMSZ = 16384;
  localparam int unsigned MAXQ  = 64;
  parameter  int unsigned MAX_OUT = 8;
  parameter  int unsigned LAT     = 6;   // fixed memory latency, in cycles

  logic clk, rst_n, flush;

  logic cmd_valid, cmd_ready;
  vcore_vld_cmd_t cmd;
  logic vrf_rd_valid, vrf_rd_ready, vrf_rd_rsp_valid, vrf_rd_rsp_ready;
  vcore_vrf_read_req_t vrf_rd_req;
  logic [VLEN-1:0] vrf_rd_rsp_data;
  logic vrf_wr_valid, vrf_wr_ready;
  vcore_vrf_write_req_t vrf_wr_req;
  logic [VLEN-1:0] vrf_wr_data;
  logic mem_req_valid, mem_req_ready, mem_rsp_valid, mem_rsp_ready;
  vcore_vld_mem_req_t mem_req;
  vcore_vld_mem_rsp_t mem_rsp;
  logic commit_valid, commit_ready;
  vcore_vld_commit_t commit;
  logic busy;

  vcore_vld_top #(.VLEN(VLEN), .ISSUE_DEPTH(3), .MAX_OUTSTANDING(MAX_OUT)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .vrf_read_valid_o(vrf_rd_valid), .vrf_read_ready_i(vrf_rd_ready),
    .vrf_read_req_o(vrf_rd_req),
    .vrf_read_rsp_valid_i(vrf_rd_rsp_valid), .vrf_read_rsp_ready_o(vrf_rd_rsp_ready),
    .vrf_read_rsp_data_i(vrf_rd_rsp_data),
    .vrf_write_valid_o(vrf_wr_valid), .vrf_write_ready_i(vrf_wr_ready),
    .vrf_write_req_o(vrf_wr_req), .vrf_write_data_o(vrf_wr_data),
    .mem_req_valid_o(mem_req_valid), .mem_req_ready_i(mem_req_ready), .mem_req_o(mem_req),
    .mem_rsp_valid_i(mem_rsp_valid), .mem_rsp_ready_o(mem_rsp_ready), .mem_rsp_i(mem_rsp),
    .commit_valid_o(commit_valid), .commit_ready_i(commit_ready), .commit_o(commit),
    .busy_o(busy)
  );

  initial clk = 0;
  /* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
  /* verilator lint_on BLKSEQ */
  int unsigned cyc;
  always @(posedge clk) cyc <= cyc + 1;

  // ---------------- state models ----------------
  logic [VLEN-1:0] vrf [32];
  logic [7:0]      mem [MEMSZ];

  logic       rd_busy_q;
  logic [4:0] rd_addr_q;
  assign vrf_rd_ready     = !rd_busy_q;
  assign vrf_rd_rsp_valid = rd_busy_q;
  assign vrf_rd_rsp_data  = vrf[rd_addr_q];
  always @(posedge clk) begin
    if (!rst_n || flush) rd_busy_q <= 1'b0;
    else if (!rd_busy_q) begin
      if (vrf_rd_valid && vrf_rd_ready) begin rd_busy_q <= 1'b1; rd_addr_q <= vrf_rd_req.addr; end
    end else if (vrf_rd_rsp_valid && vrf_rd_rsp_ready) rd_busy_q <= 1'b0;
  end

  assign vrf_wr_ready = 1'b1;
  int unsigned wr_count;
  always @(posedge clk)
    if (rst_n && vrf_wr_valid && vrf_wr_ready) begin
      vrf[vrf_wr_req.vd_addr] <= vrf_wr_data;
      wr_count <= wr_count + 1;
    end

  // ---------------- tagged OoO memory model ----------------
  logic                 q_valid [MAXQ];
  logic [VLD_TAG_W-1:0] q_tag   [MAXQ];
  logic [63:0]          q_data  [MAXQ];
  logic                 q_err   [MAXQ];
  int unsigned          q_wait  [MAXQ];
  int unsigned          q_rot_q, rsp_sel, inflight_model, peak_inflight;
  logic [31:0]          flt_lo, flt_hi;

  assign mem_req_ready = 1'b1;
  always_comb begin
    rsp_sel = MAXQ;
    for (int j = 0; j < MAXQ; j++) begin
      int s = (int'(q_rot_q) + j) % MAXQ;
      if ((rsp_sel == MAXQ) && q_valid[s] && (q_wait[s] == 0)) rsp_sel = s;
    end
  end
  assign mem_rsp_valid = (rsp_sel != MAXQ);
  assign mem_rsp.tag   = (rsp_sel != MAXQ) ? q_tag[rsp_sel]  : '0;
  assign mem_rsp.data  = (rsp_sel != MAXQ) ? q_data[rsp_sel] : '0;
  assign mem_rsp.error = (rsp_sel != MAXQ) ? q_err[rsp_sel]  : 1'b0;

  function automatic logic [63:0] mem_read(input logic [31:0] addr, input int unsigned nb);
    logic [63:0] v; v = '0;
    for (int b = 0; b < 8; b++) if (b < nb) v[b*8 +: 8] = mem[(int'(addr) + b) % MEMSZ];
    return v;
  endfunction
  function automatic logic addr_faults(input logic [31:0] addr, input int unsigned nb);
    for (int b = 0; b < 8; b++)
      if (b < nb) begin
        logic [31:0] a = addr + 32'(b);
        if ((flt_lo <= flt_hi) && (a >= flt_lo) && (a <= flt_hi)) return 1'b1;
      end
    return 1'b0;
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      for (int s = 0; s < MAXQ; s++) begin q_valid[s] <= 1'b0; q_wait[s] <= 0; end
      q_rot_q <= 0; inflight_model <= 0; peak_inflight <= 0;
    end else begin
      for (int s = 0; s < MAXQ; s++) if (q_valid[s] && (q_wait[s] != 0)) q_wait[s] <= q_wait[s] - 1;
      if (mem_req_valid && mem_req_ready) begin
        int free_s = MAXQ;
        for (int s = MAXQ-1; s >= 0; s--) if (!q_valid[s]) free_s = s;
        if (free_s == MAXQ) $fatal(1, "memory model: out of slots");
        q_valid[free_s] <= 1'b1;
        q_tag  [free_s] <= mem_req.tag;
        q_data [free_s] <= mem_read(mem_req.addr, 1 << mem_req.size);
        q_err  [free_s] <= addr_faults(mem_req.addr, 1 << mem_req.size);
        q_wait [free_s] <= LAT;
        inflight_model  <= inflight_model + 1 - ((mem_rsp_valid && mem_rsp_ready) ? 1 : 0);
        if (inflight_model + 1 > peak_inflight) peak_inflight <= inflight_model + 1;
      end else if (mem_rsp_valid && mem_rsp_ready) inflight_model <= inflight_model - 1;
      if (mem_rsp_valid && mem_rsp_ready) begin
        q_valid[rsp_sel] <= 1'b0;
        q_rot_q <= (rsp_sel + 1) % MAXQ;
      end
    end
  end

  int unsigned busy_violations;
  always @(posedge clk)
    if (rst_n && (inflight_model != 0) && !busy) busy_violations <= busy_violations + 1;

  // ---------------- request-set monitor (T1) ----------------
  logic        exp_seen  [MAX_ELEMS];
  logic        exp_want  [MAX_ELEMS];
  logic [31:0] exp_addr  [MAX_ELEMS];
  int unsigned req_errors, req_count;
  logic        monitor_on, clr_flags;

  always @(posedge clk)
    if (!rst_n || clr_flags) begin
      req_errors <= 0;
      req_count  <= 0;
    end else if (monitor_on && mem_req_valid && mem_req_ready) begin
      int t = int'(mem_req.tag);
      req_count <= req_count + 1;
      if (!exp_want[t]) begin
        $display("  T1 FAIL: request for slot %0d that is NOT active (addr %08h)", t, mem_req.addr);
        req_errors <= req_errors + 1;
      end else if (exp_seen[t]) begin
        $display("  T1 FAIL: duplicate request for slot %0d", t);
        req_errors <= req_errors + 1;
      end else if (mem_req.addr !== exp_addr[t]) begin
        $display("  T1 FAIL: slot %0d address got %08h exp %08h", t, mem_req.addr, exp_addr[t]);
        req_errors <= req_errors + 1;
      end
      exp_seen[t] <= 1'b1;
    end

  // ---------------- commit collector ----------------
  logic        saw_last_q, saw_illegal_q, saw_memerr_q, saw_trim_q;
  logic [16:0] saw_new_vl_q;
  int unsigned beats_seen_q;
  assign commit_ready = 1'b1;
  always @(posedge clk) begin
    if (!rst_n || clr_flags) begin
      saw_last_q <= 0; saw_illegal_q <= 0; saw_memerr_q <= 0;
      saw_trim_q <= 0; saw_new_vl_q <= '0; beats_seen_q <= 0;
    end else if (commit_valid && commit_ready) begin
      beats_seen_q <= beats_seen_q + 1;
      if (commit.illegal_op) saw_illegal_q <= 1'b1;
      if (commit.mem_error)  saw_memerr_q  <= 1'b1;
      if (commit.vl_trimmed) begin saw_trim_q <= 1'b1; saw_new_vl_q <= commit.new_vl; end
      if (commit.last_beat || commit.illegal_op) saw_last_q <= 1'b1;
    end
  end

  // ---------------- helpers ----------------
  int unsigned pass_cnt, fail_cnt;

  task automatic chk(input string name, input logic ok);
    begin
      if (ok) begin pass_cnt++; $display("PASS %s", name); end
      else    begin fail_cnt++; $display("FAIL %s", name); end
    end
  endtask

  function automatic logic [31:0] mk_inst(
    input logic [2:0] width, input logic vmb, input logic [4:0] vd,
    input logic [4:0] lumop, input logic [2:0] nf = 3'b000, input logic [1:0] mop = 2'b00
  );
    return {nf, 1'b0, mop, vmb, lumop, 5'd1, width, vd, 7'h07};
  endfunction

  task automatic seed_state(input int unsigned salt);
    begin
      for (int r = 0; r < 32; r++)
        for (int b = 0; b < BPR; b++)
          vrf[r][b*8 +: 8] = 8'(((r*31) ^ (b*77) ^ (int'(salt)*17)) + 11);
      for (int a = 0; a < MEMSZ; a++) mem[a] = 8'((a*5) ^ (int'(salt)*23));
    end
  endtask

  function automatic logic [31:0] idx_of(
    input int unsigned idx_base, input int unsigned idx_bits, input int unsigned i
  );
    int unsigned per_reg, r, lane;
    logic [VLEN-1:0] w;
    per_reg = VLEN / idx_bits;
    r = i / per_reg; lane = i % per_reg;
    w = vrf[(idx_base + r) % 32];
    case (idx_bits)
      8:  return 32'(w[lane*8  +: 8]);
      16: return 32'(w[lane*16 +: 16]);
      32: return     w[lane*32 +: 32];
      64: return     w[lane*64 +: 32];
      default: return '0;
    endcase
  endfunction

  task automatic seed_index(
    input int unsigned vs2, input int unsigned idx_bits, input int unsigned n,
    input int unsigned span, input int unsigned salt
  );
    int unsigned per_reg, r, lane, v;
    begin
      per_reg = VLEN / idx_bits;
      for (int i = 0; i < int'(n); i++) begin
        r = vs2 + (i / per_reg); lane = i % per_reg;
        v = (((i * 53) + salt * 7) % span);
        case (idx_bits)
          8:  vrf[r % 32][lane*8  +: 8]  = 8'(v);
          16: vrf[r % 32][lane*16 +: 16] = 16'(v);
          32: vrf[r % 32][lane*32 +: 32] = 32'(v);
          64: begin vrf[r % 32][lane*64 +: 32] = 32'(v);
                    vrf[r % 32][lane*64+32 +: 32] = 32'd0; end
          default: ;
        endcase
      end
    end
  endtask

  // Expected request set, built from the architectural definition of an
  // active element and the addressing rule of the form under test.
  task automatic set_expect(
    input int unsigned nf, input int unsigned eb, input int unsigned spf,
    input int unsigned evl, input int unsigned vstart,
    input logic vmb, input logic [VLEN-1:0] mask,
    input logic [31:0] base, input logic [31:0] stride,
    input logic indexed, input int unsigned idx_base, input int unsigned idx_bits
  );
    logic [31:0] ea;
    begin
      for (int e = 0; e < int'(MAX_ELEMS); e++) begin
        exp_want[e] = 1'b0; exp_seen[e] = 1'b0; exp_addr[e] = '0;
      end
      ea = base;
      for (int i = 0; i < int'(spf); i++) begin
        logic [31:0] this_ea;
        this_ea = indexed ? (base + idx_of(idx_base, idx_bits, i)) : ea;
        if ((i >= int'(vstart)) && (i < int'(evl)) && (vmb || mask[i]))
          for (int f = 0; f < int'(nf); f++) begin
            exp_want[f*spf + i] = 1'b1;
            exp_addr[f*spf + i] = this_ea + 32'(f*eb);
          end
        ea = ea + stride;
      end
    end
  endtask

  function automatic logic all_expected_seen();
    for (int e = 0; e < int'(MAX_ELEMS); e++)
      if (exp_want[e] && !exp_seen[e]) return 1'b0;
    return 1'b1;
  endfunction

  function automatic int unsigned expected_count();
    int unsigned n = 0;
    for (int e = 0; e < int'(MAX_ELEMS); e++) if (exp_want[e]) n++;
    return n;
  endfunction

  task automatic issue(input vcore_vld_cmd_t c);
    begin
      @(negedge clk);
      cmd = c; cmd_valid = 1'b1;
      do @(negedge clk); while (!cmd_ready);
      cmd_valid = 1'b0;
    end
  endtask

  task automatic wait_retire(input int unsigned limit = 20000);
    begin
      for (int t = 0; t < int'(limit); t++) begin
        if (saw_last_q) break;
        @(negedge clk);
      end
      repeat (3) @(negedge clk);
    end
  endtask

  task automatic clear_flags();
    begin
      @(negedge clk);
      clr_flags = 1'b1;
      @(negedge clk);
      clr_flags = 1'b0;
    end
  endtask

  // ---------------- test program ----------------
  vcore_vld_cmd_t c;
  logic [2:0] W8, W16, W32, W64;
  logic [4:0] LU_UNIT, LU_WHOLE, LU_MASK, LU_FOF;
  int unsigned t6_cycles;

  initial begin
    W8 = 3'b000; W16 = 3'b101; W32 = 3'b110; W64 = 3'b111;
    LU_UNIT = 5'b00000; LU_WHOLE = 5'b01000; LU_MASK = 5'b01011; LU_FOF = 5'b10000;
    cyc = 0; pass_cnt = 0; fail_cnt = 0; wr_count = 0; busy_violations = 0;
    monitor_on = 1'b0; clr_flags = 1'b0;
    flt_lo = 32'd1; flt_hi = 32'd0;
    cmd_valid = 1'b0; cmd = '0; flush = 1'b0; rst_n = 1'b0;
    seed_state(1);
    for (int e = 0; e < int'(MAX_ELEMS); e++) begin
      exp_want[e] = 0; exp_seen[e] = 0; exp_addr[e] = 0;
    end
    repeat (6) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // ================= T1: request set is exactly the active elements ====
    monitor_on = 1'b1;

    // T1a masked unit-stride, half the mask bits clear
    seed_state(2);
    vrf[0] = 128'h0000_0000_0000_0000_0000_0000_0000_00a5;
    c = '0;
    c.inst = mk_inst(W32, 1'b0, 5'd8, LU_UNIT);
    c.base = 32'd256; c.sew = 3'd2; c.vlmul = 3'b001;   // SEW=32 LMUL=2 -> VLMAX=8
    c.vta = 1'b1; c.vma = 1'b1; c.vl = 17'd8; c.vstart = 17'd0;
    c.mask_snapshot = vrf[0]; c.tag = 16'h1;
    set_expect(1, 4, 8, 8, 0, 1'b0, c.mask_snapshot, c.base, 32'd4, 1'b0, 0, 32);
    clear_flags(); issue(c); wait_retire();
    chk("T1a masked unit-stride requests only active elements",
        (req_errors == 0) && all_expected_seen() && (req_count == 4));

    // T1b vstart skips the prestart region
    seed_state(3);
    vrf[0] = '1;
    c.tag = 16'h2; c.vstart = 17'd3; c.inst = mk_inst(W32, 1'b1, 5'd8, LU_UNIT);
    c.mask_snapshot = vrf[0];
    set_expect(1, 4, 8, 8, 3, 1'b1, c.mask_snapshot, c.base, 32'd4, 1'b0, 0, 32);
    clear_flags(); issue(c); wait_retire();
    chk("T1b prestart elements are never requested",
        (req_errors == 0) && all_expected_seen() && (req_count == 5));

    // T1c tail never requested
    seed_state(4);
    c.tag = 16'h3; c.vstart = 17'd0; c.vl = 17'd3;
    set_expect(1, 4, 8, 3, 0, 1'b1, c.mask_snapshot, c.base, 32'd4, 1'b0, 0, 32);
    clear_flags(); issue(c); wait_retire();
    chk("T1c tail elements are never requested",
        (req_errors == 0) && all_expected_seen() && (req_count == 3));

    // T1d vstart >= vl touches memory at all
    seed_state(5);
    c.tag = 16'h4; c.vstart = 17'd5; c.vl = 17'd3;
    set_expect(1, 4, 8, 3, 5, 1'b1, c.mask_snapshot, c.base, 32'd4, 1'b0, 0, 32);
    clear_flags(); issue(c); wait_retire();
    chk("T1d vstart >= vl issues no requests", (req_errors == 0) && (req_count == 0));

    // T1e vlm.v requests ceil(vl/8) bytes
    seed_state(6);
    c = '0;
    c.inst = mk_inst(W8, 1'b1, 5'd12, LU_MASK);
    c.base = 32'd512; c.sew = 3'd0; c.vlmul = 3'b001;   // SEW=8 LMUL=2 -> VLMAX=32
    c.vta = 1'b0; c.vma = 1'b0; c.vl = 17'd17; c.vstart = 17'd0;
    c.mask_snapshot = '1; c.tag = 16'h5;
    set_expect(1, 1, 16, 3, 0, 1'b1, c.mask_snapshot, c.base, 32'd1, 1'b0, 0, 8);
    clear_flags(); issue(c); wait_retire();
    chk("T1e vlm.v requests ceil(vl/8) bytes",
        (req_errors == 0) && all_expected_seen() && (req_count == 3));

    // T1f a genuinely reserved encoding still touches nothing
    seed_state(7);
    c.inst = mk_inst(W32, 1'b1, 5'd8, 5'b00001);   // reserved lumop
    c.tag = 16'h6;
    set_expect(1, 4, 8, 0, 0, 1'b1, c.mask_snapshot, c.base, 32'd4, 1'b0, 0, 32);
    clear_flags(); issue(c); wait_retire();
    chk("T1f reserved encoding: no bus traffic, illegal_op reported",
        (req_count == 0) && saw_illegal_q);

    // T1g strided, including a negative stride
    seed_state(8);
    c = '0;
    c.inst = mk_inst(W32, 1'b1, 5'd8, 5'd2, 3'b000, 2'b10);
    c.base = 32'd4096; c.stride = -32'd12;
    c.sew = 3'd2; c.vlmul = 3'b001; c.vta = 1'b1; c.vma = 1'b1;
    c.vl = 17'd8; c.vstart = 17'd0; c.mask_snapshot = '1; c.tag = 16'h7;
    set_expect(1, 4, 8, 8, 0, 1'b1, c.mask_snapshot, c.base, c.stride, 1'b0, 0, 32);
    clear_flags(); issue(c); wait_retire();
    chk("T1g strided walks base + i*stride, negative stride included",
        (req_errors == 0) && all_expected_seen() && (req_count == 8));

    // T1h indexed takes its addresses from the index vector
    seed_state(9);
    seed_index(16, 32, 8, 1024, 3);
    c = '0;
    c.inst = mk_inst(W32, 1'b1, 5'd8, 5'd16, 3'b000, 2'b01);
    c.base = 32'd2048; c.sew = 3'd2; c.vlmul = 3'b001;
    c.vta = 1'b1; c.vma = 1'b1; c.vl = 17'd8; c.vstart = 17'd0;
    c.mask_snapshot = '1; c.tag = 16'h8;
    set_expect(1, 4, 8, 8, 0, 1'b1, c.mask_snapshot, c.base, 32'd0, 1'b1, 16, 32);
    clear_flags(); issue(c); wait_retire();
    chk("T1h indexed addresses come from the index vector",
        (req_errors == 0) && all_expected_seen() && (req_count == 8));

    // T1i segment: element-major, field-minor, nf addresses per active element
    seed_state(10);
    vrf[0] = 128'h0000_0000_0000_0000_0000_0000_0000_000b;  // elements 0,1,3
    c = '0;
    c.inst = mk_inst(W32, 1'b0, 5'd8, LU_UNIT, 3'd2);       // nf = 3
    c.base = 32'd6144; c.sew = 3'd2; c.vlmul = 3'b000;      // SEW=32 LMUL=1 -> VLMAX=4
    c.vta = 1'b1; c.vma = 1'b1; c.vl = 17'd4; c.vstart = 17'd0;
    c.mask_snapshot = vrf[0]; c.tag = 16'h9;
    set_expect(3, 4, 4, 4, 0, 1'b0, c.mask_snapshot, c.base, 32'd12, 1'b0, 0, 32);
    clear_flags(); issue(c); wait_retire();
    chk("T1i segment load requests nf fields per active element",
        (req_errors == 0) && all_expected_seen() && (req_count == 9));

    monitor_on = 1'b0;

    // ================= T5: back-to-back issue through the FIFO ==========
    begin
      int unsigned before_wr;
      seed_state(20);
      c = '0;
      c.base = 32'd1024; c.sew = 3'd2; c.vlmul = 3'b000;
      c.vta = 1'b1; c.vma = 1'b1; c.vl = 17'd4; c.vstart = 17'd0; c.mask_snapshot = '1;
      before_wr = wr_count;
      clear_flags();
      for (int k = 0; k < 3; k++) begin
        c.inst = mk_inst(W32, 1'b1, 5'(8 + k), LU_UNIT);
        c.tag  = 16'(16 + k);
        issue(c);
      end
      for (int t = 0; t < 20000; t++) begin
        if (wr_count - before_wr >= 3) break;
        @(negedge clk);
      end
      repeat (3) @(negedge clk);
      chk("T5 three queued instructions all retire", (wr_count - before_wr == 3));
      begin
        logic ok = 1'b1;
        for (int k = 0; k < 3; k++)
          for (int b = 0; b < 16; b++)
            if (vrf[8+k][b*8 +: 8] !== mem[(1024 + b) % MEMSZ]) ok = 1'b0;
        chk("T5 all three destinations hold the loaded data", ok);
      end
    end

    // ================= T2: flush while requests are outstanding =========
    begin
      logic drained, reusable;
      seed_state(21);
      c = '0;
      c.inst = mk_inst(W8, 1'b1, 5'd16, LU_UNIT);
      c.base = 32'd2048; c.sew = 3'd0; c.vlmul = 3'b011; // SEW=8 LMUL=8 -> 128 elems
      c.vta = 1'b1; c.vma = 1'b1; c.vl = 17'd128; c.vstart = 17'd0; c.mask_snapshot = '1;
      c.tag = 16'h30;
      clear_flags(); issue(c);
      for (int t = 0; t < 200; t++) begin
        if (inflight_model >= ((MAX_OUT > 1) ? 2 : 1)) break;
        @(negedge clk);
      end
      chk("T2 requests were in flight before the flush",
          (inflight_model >= ((MAX_OUT > 1) ? 2 : 1)));
      @(negedge clk);
      flush = 1'b1;
      repeat (2) @(negedge clk);
      flush = 1'b0;
      drained = 1'b0;
      for (int t = 0; t < 500; t++) begin
        if ((inflight_model == 0) && !busy) begin drained = 1'b1; break; end
        @(negedge clk);
      end
      chk("T2 outstanding responses drain after flush and busy_o drops", drained);

      seed_state(22);
      c = '0;
      c.inst = mk_inst(W32, 1'b1, 5'd8, LU_UNIT);
      c.base = 32'd1024; c.sew = 3'd2; c.vlmul = 3'b000;
      c.vta = 1'b1; c.vma = 1'b1; c.vl = 17'd4; c.vstart = 17'd0; c.mask_snapshot = '1;
      c.tag = 16'h31;
      clear_flags(); issue(c); wait_retire();
      reusable = saw_last_q && !saw_illegal_q;
      for (int b = 0; b < 16; b++)
        if (vrf[8][b*8 +: 8] !== mem[(1024 + b) % MEMSZ]) reusable = 1'b0;
      chk("T2 cluster executes correctly after a flush", reusable);
    end

    // ================= T3: bus error suppresses the write ===============
    begin
      logic [VLEN-1:0] vd_before;
      seed_state(23);
      vd_before = vrf[8];
      flt_lo = 32'd1024; flt_hi = 32'd1039;
      c = '0;
      c.inst = mk_inst(W32, 1'b1, 5'd8, LU_UNIT);     // plain load, not fof
      c.base = 32'd1024; c.sew = 3'd2; c.vlmul = 3'b000;
      c.vta = 1'b1; c.vma = 1'b1; c.vl = 17'd4; c.vstart = 17'd0; c.mask_snapshot = '1;
      c.tag = 16'h40;
      clear_flags(); issue(c); wait_retire();
      flt_lo = 32'd1; flt_hi = 32'd0;
      chk("T3 bus error is reported as mem_error", saw_memerr_q);
      chk("T3 bus error leaves the destination register untouched", (vrf[8] === vd_before));
    end

    // ================= T7: ordered indexed keeps one request in flight ==
    begin
      int unsigned peak_before;
      seed_state(24);
      seed_index(16, 32, 8, 1024, 5);
      c = '0;
      c.inst = mk_inst(W32, 1'b1, 5'd8, 5'd16, 3'b000, 2'b11);  // vloxei32.v
      c.base = 32'd2048; c.sew = 3'd2; c.vlmul = 3'b001;
      c.vta = 1'b1; c.vma = 1'b1; c.vl = 17'd8; c.vstart = 17'd0;
      c.mask_snapshot = '1; c.tag = 16'h50;
      peak_inflight = 0; peak_before = 0;
      clear_flags(); issue(c); wait_retire();
      chk("T7 ordered indexed never has two requests in flight",
          (peak_inflight == 1) && (peak_before == 0));
      begin
        logic ok = 1'b1;
        for (int i = 0; i < 8; i++) begin
          logic [31:0] a = 32'd2048 + idx_of(16, 32, i);
          for (int b = 0; b < 4; b++)
            if (vrf[8 + (i/4)][((i%4)*4 + b)*8 +: 8] !== mem[(int'(a) + b) % MEMSZ]) ok = 1'b0;
        end
        chk("T7 ordered indexed gathers the right elements", ok);
      end
      // and the unordered form is free to run the full window
      seed_state(25);
      seed_index(16, 32, 8, 1024, 5);
      c.inst = mk_inst(W32, 1'b1, 5'd8, 5'd16, 3'b000, 2'b01);  // vluxei32.v
      c.tag = 16'h51;
      peak_inflight = 0;
      clear_flags(); issue(c); wait_retire();
      chk("T7 unordered indexed uses the full outstanding window",
          (peak_inflight > 1) || (MAX_OUT == 1));
    end

    // ================= T8: fault-only-first trims vl ====================
    begin
      logic ok;
      seed_state(26);
      // SEW=32, LMUL=1, vl=4, EEW=32: elements at 3072, 3076, 3080, 3084.
      // Fault element 2 only.
      flt_lo = 32'd3080; flt_hi = 32'd3083;
      c = '0;
      c.inst = mk_inst(W32, 1'b1, 5'd8, LU_FOF);
      c.base = 32'd3072; c.sew = 3'd2; c.vlmul = 3'b000;
      c.vta = 1'b1; c.vma = 1'b1; c.vl = 17'd4; c.vstart = 17'd0;
      c.mask_snapshot = '1; c.tag = 16'h60;
      clear_flags(); issue(c); wait_retire();
      flt_lo = 32'd1; flt_hi = 32'd0;
      chk("T8 fault-only-first reports a trimmed vl", saw_trim_q && (saw_new_vl_q == 17'd2));
      chk("T8 fault-only-first does not trap", !saw_memerr_q);
      ok = 1'b1;
      for (int i = 0; i < 2; i++)                    // elements below the trim: loaded
        for (int b = 0; b < 4; b++)
          if (vrf[8][(i*4 + b)*8 +: 8] !== mem[(3072 + i*4 + b) % MEMSZ]) ok = 1'b0;
      for (int i = 2; i < 4; i++)                    // at and above: tail, vta=1
        for (int b = 0; b < 4; b++)
          if (vrf[8][(i*4 + b)*8 +: 8] !== 8'hff) ok = 1'b0;
      chk("T8 elements below the trim are loaded, the rest become tail", ok);

      // a fault on element 0 is a real trap, not a trim
      seed_state(27);
      flt_lo = 32'd3072; flt_hi = 32'd3075;
      c.tag = 16'h61;
      clear_flags(); issue(c); wait_retire();
      flt_lo = 32'd1; flt_hi = 32'd0;
      chk("T8 a fault on element 0 traps instead of trimming",
          saw_memerr_q && !saw_trim_q);
    end

    // ================= T9: whole-register ignores vtype and vl ==========
    begin
      logic ok;
      seed_state(28);
      c = '0;
      c.inst = mk_inst(W32, 1'b1, 5'd8, LU_WHOLE, 3'd3);   // vl4re32.v
      c.base = 32'd8192;
      c.sew = 3'd0; c.vlmul = 3'b101;    // deliberately mismatched vtype
      c.vta = 1'b0; c.vma = 1'b0; c.vl = 17'd1; c.vstart = 17'd0;
      c.mask_snapshot = '0;              // and an all-zero mask
      c.tag = 16'h70;
      clear_flags(); issue(c); wait_retire();
      ok = !saw_illegal_q;
      for (int r = 0; r < 4; r++)
        for (int b = 0; b < 16; b++)
          if (vrf[8+r][b*8 +: 8] !== mem[(8192 + r*16 + b) % MEMSZ]) ok = 1'b0;
      chk("T9 vl4re32.v loads 4 whole registers regardless of vtype, vl and v0", ok);
    end

    // ================= T6: MO cycle count ===============================
    begin
      int unsigned t0;
      seed_state(29);
      c = '0;
      c.inst = mk_inst(W8, 1'b1, 5'd16, LU_UNIT);
      c.base = 32'd2048; c.sew = 3'd0; c.vlmul = 3'b010; // SEW=8 LMUL=4 -> 64 elems
      c.vta = 1'b1; c.vma = 1'b1; c.vl = 17'd64; c.vstart = 17'd0; c.mask_snapshot = '1;
      c.tag = 16'h80;
      clear_flags();
      t0 = cyc;
      issue(c); wait_retire();
      t6_cycles = cyc - t0;
      begin
        logic ok = 1'b1;
        for (int k = 0; k < 4; k++)
          for (int b = 0; b < 16; b++)
            if (vrf[16+k][b*8 +: 8] !== mem[(2048 + k*16 + b) % MEMSZ]) ok = 1'b0;
        chk("T6 LMUL=4 EEW=8 load (64 elements) is correct", ok);
      end
      $display("T6 MAX_OUTSTANDING=%0d LAT=%0d : 64-element load took %0d cycles",
               MAX_OUT, LAT, t6_cycles);
    end

    chk("T4 busy_o never low with requests in flight", (busy_violations == 0));

    $display("TOTAL: %0d passed, %0d failed", pass_cnt, fail_cnt);
    if (fail_cnt != 0) $fatal(1, "directed test failures");
    $finish;
  end

  initial begin
    #60_000_000;
    $fatal(1, "global timeout");
  end
endmodule
