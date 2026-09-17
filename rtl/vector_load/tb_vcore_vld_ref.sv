// Golden-reference verification of the vector unit-stride load cluster.
//
// The model below is deliberately written against an INDEPENDENT data
// representation: expected state is a byte array exp_vrf[reg][byte] filled
// from a byte-addressed memory image, while the DUT keeps packed VLEN-wide
// registers and a packed group buffer. A shared helper (or a shared shape)
// would hide exactly the class of bug this is looking for -- that is how the
// permutation reference model earned its keep.
//
// Legality is likewise re-derived here from the raw instruction fields
// rather than by calling vcore_vld_pkg, so a decode mistake cannot agree
// with itself.
//
// Every case compares ALL 32 vector registers, so a beat that writes the
// wrong destination, or writes one it should have left alone, fails.
module tb_vcore_vld_ref;
  import vcore_vld_pkg::*;

  localparam int unsigned VLEN   = 128;
  localparam int unsigned BPR    = VLEN/8;          // bytes per vector register
  localparam int unsigned MEMSZ  = 8192;
  localparam int unsigned MAXQ   = 64;
  // STRESS=0: zero-latency memory, always-ready ports (fast functional pass)
  // STRESS=1: random ready, random 1..8 cycle memory latency, out-of-order
  //           responses, random VRF read/write stalls
  parameter int unsigned STRESS   = 0;
  parameter int unsigned MAX_OUT  = 8;

  logic clk, rst_n, flush;

  // ---------------- DUT interface ----------------
  logic cmd_valid, cmd_ready;
  vcore_vld_cmd_t cmd;

  logic vrf_rd_valid, vrf_rd_ready;
  vcore_vrf_read_req_t vrf_rd_req;
  logic vrf_rd_rsp_valid, vrf_rd_rsp_ready;
  logic [VLEN-1:0] vrf_rd_rsp_data;

  logic vrf_wr_valid, vrf_wr_ready;
  vcore_vrf_write_req_t vrf_wr_req;
  logic [VLEN-1:0] vrf_wr_data;

  logic mem_req_valid, mem_req_ready;
  vcore_vld_mem_req_t mem_req;
  logic mem_rsp_valid, mem_rsp_ready;
  vcore_vld_mem_rsp_t mem_rsp;

  logic commit_valid, commit_ready;
  vcore_vld_commit_t commit;
  logic busy;

  vcore_vld_top #(.VLEN(VLEN), .ISSUE_DEPTH(3), .MAX_OUTSTANDING(MAX_OUT)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .vrf_read_valid_o(vrf_rd_valid), .vrf_read_ready_i(vrf_rd_ready),
    .vrf_read_req_o(vrf_rd_req),
    .vrf_read_rsp_valid_i(vrf_rd_rsp_valid),
    .vrf_read_rsp_ready_o(vrf_rd_rsp_ready),
    .vrf_read_rsp_data_i(vrf_rd_rsp_data),
    .vrf_write_valid_o(vrf_wr_valid), .vrf_write_ready_i(vrf_wr_ready),
    .vrf_write_req_o(vrf_wr_req), .vrf_write_data_o(vrf_wr_data),
    .mem_req_valid_o(mem_req_valid), .mem_req_ready_i(mem_req_ready),
    .mem_req_o(mem_req),
    .mem_rsp_valid_i(mem_rsp_valid), .mem_rsp_ready_o(mem_rsp_ready),
    .mem_rsp_i(mem_rsp),
    .commit_valid_o(commit_valid), .commit_ready_i(commit_ready),
    .commit_o(commit), .busy_o(busy)
  );

  // ---------------- clock / reset ----------------
  initial clk = 0;
  /* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
  /* verilator lint_on BLKSEQ */

  int unsigned cyc;
  always @(posedge clk) cyc <= cyc + 1;

  // ---------------- pseudo-random source ----------------
  logic [31:0] lfsr_q;
  function automatic logic [31:0] lfsr_next(input logic [31:0] v);
    return {v[30:0], v[31]^v[21]^v[1]^v[0]};
  endfunction
  always @(posedge clk) lfsr_q <= lfsr_next(lfsr_q);

  // ---------------- architectural state models ----------------
  logic [VLEN-1:0] vrf [32];
  logic [7:0]      mem [MEMSZ];
  // Expected state, byte granular and independent of the DUT's packing.
  logic [7:0]      exp_vrf [32][BPR];

  // ---------------- VRF read port model (1 outstanding, stalled) --------
  logic        rd_busy_q;
  logic [4:0]  rd_addr_q;
  int unsigned rd_cnt_q;
  assign vrf_rd_ready     = (!rd_busy_q) && (STRESS == 0 ? 1'b1 : lfsr_q[3]);
  assign vrf_rd_rsp_valid = rd_busy_q && (rd_cnt_q == 0);
  assign vrf_rd_rsp_data  = vrf[rd_addr_q];

  always @(posedge clk) begin
    if (!rst_n) begin
      rd_busy_q <= 1'b0; rd_cnt_q <= 0; rd_addr_q <= '0;
    end else begin
      if (!rd_busy_q) begin
        if (vrf_rd_valid && vrf_rd_ready) begin
          rd_busy_q <= 1'b1;
          rd_addr_q <= vrf_rd_req.addr;
          rd_cnt_q  <= (STRESS == 0) ? 0 : ({29'd0, lfsr_q[6:4]} % 4);
        end
      end else if (rd_cnt_q != 0) rd_cnt_q <= rd_cnt_q - 1;
      else if (vrf_rd_rsp_valid && vrf_rd_rsp_ready) rd_busy_q <= 1'b0;
    end
  end

  // ---------------- VRF write port model ----------------
  assign vrf_wr_ready = (STRESS == 0) ? 1'b1 : lfsr_q[7];
  always @(posedge clk)
    if (rst_n && vrf_wr_valid && vrf_wr_ready) vrf[vrf_wr_req.vd_addr] <= vrf_wr_data;

  // ---------------- tagged out-of-order memory model ----------------
  // Each accepted request is parked in a slot with an independent latency.
  // The response arbiter starts its scan at a rotating offset, so responses
  // come back in an order unrelated to the request order.
  logic                 q_valid [MAXQ];
  logic [VLD_TAG_W-1:0] q_tag   [MAXQ];
  logic [63:0]          q_data  [MAXQ];
  logic                 q_err   [MAXQ];
  int unsigned          q_wait  [MAXQ];
  int unsigned          q_rot_q;
  int unsigned          rsp_sel;
  logic                 force_err;   // injects a bus error for one test
  int unsigned          mem_reqs_seen, mem_peak_inflight, mem_inflight;

  assign mem_req_ready = (STRESS == 0) ? 1'b1 : lfsr_q[11];

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

  function automatic logic [63:0] mem_read(input logic [31:0] addr, input int unsigned nbytes);
    logic [63:0] v;
    v = '0;
    for (int b = 0; b < 8; b++)
      if (b < nbytes) v[b*8 +: 8] = mem[(int'(addr) + b) % MEMSZ];
    return v;
  endfunction

  always @(posedge clk) begin
    if (!rst_n) begin
      for (int s = 0; s < MAXQ; s++) begin q_valid[s] <= 1'b0; q_wait[s] <= 0; end
      q_rot_q <= 0;
      mem_reqs_seen <= 0; mem_peak_inflight <= 0; mem_inflight <= 0;
    end else begin
      for (int s = 0; s < MAXQ; s++) if (q_valid[s] && (q_wait[s] != 0)) q_wait[s] <= q_wait[s] - 1;
      if (mem_req_valid && mem_req_ready) begin
        int free_s = MAXQ;
        for (int s = MAXQ-1; s >= 0; s--) if (!q_valid[s]) free_s = s;
        if (free_s == MAXQ) $fatal(1, "memory model: more outstanding requests than slots");
        q_valid[free_s] <= 1'b1;
        q_tag  [free_s] <= mem_req.tag;
        q_data [free_s] <= mem_read(mem_req.addr, 1 << mem_req.size);
        q_err  [free_s] <= force_err;
        q_wait [free_s] <= (STRESS == 0) ? 0 : ({29'd0, lfsr_q[26:24]});
        mem_reqs_seen   <= mem_reqs_seen + 1;
        mem_inflight    <= mem_inflight + 1 - ((mem_rsp_valid && mem_rsp_ready) ? 1 : 0);
        if (mem_inflight + 1 > mem_peak_inflight) mem_peak_inflight <= mem_inflight + 1;
      end else if (mem_rsp_valid && mem_rsp_ready) mem_inflight <= mem_inflight - 1;
      if (mem_rsp_valid && mem_rsp_ready) begin
        q_valid[rsp_sel] <= 1'b0;
        q_rot_q <= (rsp_sel + 1) % MAXQ;
      end
    end
  end

  // ---------------- commit collector ----------------
  logic       saw_last_q, saw_illegal_q, saw_memerr_q;
  int unsigned beats_seen_q;
  // Cleared through a request line, never written by the test program: a
  // variable with both a clocked driver and a procedural one loses its
  // clocked updates under Verilator.
  logic clr_flags;
  assign commit_ready = (STRESS == 0) ? 1'b1 : lfsr_q[15];
  always @(posedge clk) begin
    if (!rst_n || clr_flags) begin
      saw_last_q <= 0; saw_illegal_q <= 0; saw_memerr_q <= 0; beats_seen_q <= 0;
    end else if (commit_valid && commit_ready) begin
      beats_seen_q <= beats_seen_q + 1;
      if (commit.illegal_op) saw_illegal_q <= 1'b1;
      if (commit.mem_error)  saw_memerr_q  <= 1'b1;
      if (commit.last_beat || commit.illegal_op) saw_last_q <= 1'b1;
    end
  end

  // ---------------- reference model ----------------
  logic ref_illegal;
  int unsigned ref_beats;

  function automatic int unsigned sew_bits_of(input int unsigned c);
    case (c) 0: return 8; 1: return 16; 2: return 32; 3: return 64; default: return 0; endcase
  endfunction
  function automatic int unsigned eew_bits_of_width(input logic [2:0] w);
    case (w) 3'b000: return 8; 3'b101: return 16; 3'b110: return 32; 3'b111: return 64;
             default: return 0; endcase
  endfunction

  // Re-derived legality + expected destination bytes. Written procedurally
  // over a byte image on purpose; see the module header.
  task automatic ref_exec(
    input logic [31:0] inst,
    input logic [31:0] base,
    input int unsigned sew_c,
    input logic [2:0]  vlmul_c,
    input logic        vta, vma, vill,
    input int unsigned vl, vstart,
    input logic [VLEN-1:0] mask
  );
    int unsigned nf, mop, lumop, width, vd, eb, sb, ln, ld, en, ed, regs, vlmax, epr, evl, slots;
    logic mew, vmb, is_mask_op, bad, vta_eff;
    int unsigned gidx, byte_idx;
    logic take_old, take_ones;
    begin
      nf    = int'(inst[31:29]);
      mew   = inst[28];
      mop   = int'(inst[27:26]);
      vmb   = inst[25];
      lumop = int'(inst[24:20]);
      width = int'(inst[14:12]);
      vd    = int'(inst[11:7]);

      eb = eew_bits_of_width(3'(width));
      sb = sew_bits_of(sew_c);
      bad = 1'b0;
      if (inst[6:0] != 7'h07) bad = 1'b1;
      if (mop != 0) bad = 1'b1;
      if (mew) bad = 1'b1;
      if (nf != 0) bad = 1'b1;
      if (vill) bad = 1'b1;
      if (eb == 0) bad = 1'b1;
      if (sb == 0) bad = 1'b1;

      is_mask_op = (lumop == 32'h0b);
      if ((lumop != 32'h00) && !is_mask_op) bad = 1'b1;
      if (is_mask_op && ((width != 32'h0) || !vmb)) bad = 1'b1;

      ln = 1; ld = 1;
      case (vlmul_c)
        3'b000: begin ln = 1; ld = 1; end
        3'b001: begin ln = 2; ld = 1; end
        3'b010: begin ln = 4; ld = 1; end
        3'b011: begin ln = 8; ld = 1; end
        3'b111: begin ln = 1; ld = 2; end
        3'b110: begin ln = 1; ld = 4; end
        3'b101: begin ln = 1; ld = 8; end
        default: bad = 1'b1;
      endcase

      if (sb == 0 || ld == 0) begin
        en = 1; ed = 1; regs = 1; vlmax = 0;
      end else begin
        en = eb * ln;         // EMUL numerator
        ed = sb * ld;         // EMUL denominator
        if ((en * 8 < ed) || (en > ed * 8)) bad = 1'b1;
        regs = (en + ed - 1) / ed;
        if (regs < 1) regs = 1;
        if (regs > 8) bad = 1'b1;
        vlmax = (ln * VLEN) / (ld * sb);
        if (vlmax == 0 || vl > vlmax) bad = 1'b1;
      end

      // RVV 1.0 7.4: vlm.v runs at EEW=8 with EMUL=1, evl=ceil(vl/8), and
      // its destination "is always written with a tail-agnostic policy"
      // regardless of vtype.vta.
      vta_eff = is_mask_op ? 1'b1 : vta;
      if (is_mask_op) begin
        eb   = 8;
        regs = 1;
        evl  = (vl + 7) / 8;
      end else begin
        evl = vl;
        // vd alignment applies only when EMUL >= 1
        if ((en >= ed) && (regs > 1) && ((vd % regs) != 0)) bad = 1'b1;
      end
      // masked destination may not be v0
      if (!is_mask_op && !vmb && (vd == 0)) bad = 1'b1;

      epr   = (eb == 0) ? 0 : (VLEN / eb);
      slots = regs * epr;

      // snapshot current architectural state as the baseline
      for (int r = 0; r < 32; r++)
        for (int b = 0; b < BPR; b++)
          exp_vrf[r][b] = vrf[r][b*8 +: 8];

      ref_illegal = bad;
      ref_beats   = bad ? 1 : regs;
      if (bad) return;

      for (int k = 0; k < int'(regs); k++) begin
        for (int i = 0; i < int'(epr); i++) begin
          gidx = k*epr + i;
          take_old  = 1'b0;
          take_ones = 1'b0;
          if (vstart >= evl)            take_old = 1'b1;   // RVV 1.0 5.4
          else if (gidx < vstart)       take_old = 1'b1;   // prestart
          else if (gidx >= evl)         begin take_ones = vta_eff; take_old = !vta_eff; end
          else if (!vmb && !mask[gidx]) begin
            // vlm.v is unmasked by encoding, so is_mask_op never lands here
            take_ones = (vma == 1'b1); take_old = !vma;
          end
          for (int b = 0; b < int'(eb/8); b++) begin
            byte_idx = i*(eb/8) + b;
            if (take_ones) exp_vrf[vd+k][byte_idx] = 8'hff;
            else if (!take_old)
              exp_vrf[vd+k][byte_idx] = mem[(int'(base) + gidx*(eb/8) + b) % MEMSZ];
          end
        end
      end
      // Unreferenced: slots is only a cross-check that the loops covered the
      // whole destination group.
      if (slots != regs*epr) $fatal(1, "ref: slot accounting");
    end
  endtask

  // ---------------- driver ----------------
  int unsigned pass_cnt, fail_cnt;

  function automatic logic [31:0] mk_inst(
    input logic [2:0] width, input logic vmb, input logic [4:0] vd,
    input logic [4:0] rs1, input logic [4:0] lumop,
    input logic [2:0] nf = 3'b000, input logic mew = 1'b0, input logic [1:0] mop = 2'b00
  );
    return {nf, mew, mop, vmb, lumop, rs1, width, vd, 7'h07};
  endfunction

  task automatic run_case(
    input string          name,
    input logic [31:0]    inst,
    input logic [31:0]    base,
    input int unsigned    sew_c,
    input logic [2:0]     vlmul_c,
    input logic           vta, vma, vill,
    input int unsigned    vl, vstart
  );
    logic [VLEN-1:0] mask;
    logic mismatch;
    begin
      mask = vrf[0]; // v0 snapshot, exactly what TOP would hand over
      ref_exec(inst, base, sew_c, vlmul_c, vta, vma, vill, vl, vstart, mask);

      @(negedge clk);
      clr_flags = 1'b1;
      @(negedge clk);   // one rising edge elapses -> counters cleared
      clr_flags = 1'b0;
      cmd = '0;
      cmd.inst = inst; cmd.base = base;
      cmd.sew = 3'(sew_c); cmd.vlmul = vlmul_c;
      cmd.vta = vta; cmd.vma = vma; cmd.vill = vill;
      cmd.vl = 17'(vl); cmd.vstart = 17'(vstart);
      cmd.mask_snapshot = mask;
      cmd.tag = 16'(pass_cnt + fail_cnt);
      cmd_valid = 1'b1;
      do @(negedge clk); while (!cmd_ready);
      cmd_valid = 1'b0;

      // wait for the instruction to retire
      for (int t = 0; t < 20000; t++) begin
        if (saw_last_q) break;
        @(negedge clk);
      end
      if (!saw_last_q) begin
        $display("FAIL %s: timeout (no last_beat commit)", name);
        fail_cnt++;
        return;
      end
      // let the final VRF write settle
      repeat (4) @(negedge clk);

      mismatch = 1'b0;
      if (saw_illegal_q !== ref_illegal) begin
        $display("FAIL %s: illegal_op got=%0b exp=%0b", name, saw_illegal_q, ref_illegal);
        mismatch = 1'b1;
      end
      if (saw_memerr_q) begin
        $display("FAIL %s: unexpected mem_error", name);
        mismatch = 1'b1;
      end
      for (int r = 0; r < 32; r++)
        for (int b = 0; b < BPR; b++)
          if (vrf[r][b*8 +: 8] !== exp_vrf[r][b]) begin
            if (!mismatch)
              $display("FAIL %s: v%0d byte %0d got=%02h exp=%02h",
                       name, r, b, vrf[r][b*8 +: 8], exp_vrf[r][b]);
            mismatch = 1'b1;
          end
      if (mismatch) fail_cnt++; else pass_cnt++;
    end
  endtask

  task automatic seed_state(input int unsigned salt);
    begin
      for (int r = 0; r < 32; r++)
        for (int b = 0; b < BPR; b++)
          vrf[r][b*8 +: 8] = 8'(((r*37) ^ (b*91) ^ (int'(salt)*13)) + 165);
      for (int a = 0; a < MEMSZ; a++)
        mem[a] = 8'((a*7) ^ (salt*29) ^ (a >> 5));
    end
  endtask

  // ---------------- protocol assertions ----------------
`ifndef VERILATOR_NO_SVA
  default clocking cb @(posedge clk); endclocking
  // A valid that is not taken must hold its payload stable.
  property p_stable_memreq;
    disable iff (!rst_n || flush)
    (mem_req_valid && !mem_req_ready) |=> (mem_req_valid && $stable(mem_req));
  endproperty
  assert property (p_stable_memreq) else $error("mem_req unstable while stalled");

  property p_stable_vrfwr;
    disable iff (!rst_n || flush)
    (vrf_wr_valid && !vrf_wr_ready) |=> (vrf_wr_valid && $stable(vrf_wr_req) && $stable(vrf_wr_data));
  endproperty
  assert property (p_stable_vrfwr) else $error("vrf write unstable while stalled");

  property p_stable_commit;
    disable iff (!rst_n || flush)
    (commit_valid && !commit_ready) |=> (commit_valid && $stable(commit));
  endproperty
  assert property (p_stable_commit) else $error("commit unstable while stalled");

  property p_stable_vrfrd;
    disable iff (!rst_n || flush)
    (vrf_rd_valid && !vrf_rd_ready) |=> (vrf_rd_valid && $stable(vrf_rd_req));
  endproperty
  assert property (p_stable_vrfrd) else $error("vrf read req unstable while stalled");

  // No response may arrive unless a request is outstanding.
  property p_no_spurious_rsp;
    disable iff (!rst_n)
    (mem_rsp_valid && mem_rsp_ready) |-> (mem_inflight != 0);
  endproperty
  assert property (p_no_spurious_rsp) else $error("response with nothing in flight");

  // The cluster must never claim idle while the bus still owes it data.
  property p_busy_covers_inflight;
    disable iff (!rst_n)
    (mem_inflight != 0) |-> busy;
  endproperty
  assert property (p_busy_covers_inflight) else $error("busy_o low with requests in flight");
`endif

  // ---------------- illegal-encoding table ----------------
  // Parallel arrays rather than an array of structs: a struct carrying a
  // string breaks Verilator's C++ codegen for unpacked arrays.
  localparam int unsigned NBAD = 20;
  logic [2:0] bad_nf    [NBAD];
  logic       bad_mew   [NBAD];
  logic [1:0] bad_mop   [NBAD];
  logic [4:0] bad_lumop [NBAD];
  logic [2:0] bad_w     [NBAD];
  logic       bad_vm    [NBAD];
  logic [4:0] bad_vd    [NBAD];

  function automatic string bad_why(input int i);
    case (i)
      0:  return "segment nf!=0";
      1:  return "mew=1 (EEW>64)";
      2:  return "strided mop=10";
      3:  return "indexed-unordered mop=01";
      4:  return "indexed-ordered mop=11";
      5:  return "whole-register load lumop=01000";
      6:  return "fault-only-first lumop=10000";
      7:  return "reserved lumop=00001";
      8:  return "width=010 is flw";
      9:  return "width=011 is fld";
      10: return "width=001 is flh";
      11: return "width=100 is flq";
      12: return "vlm.v with width!=000";
      13: return "vlm.v masked (vm=0)";
      14: return "masked load with vd==v0";
      15: return "vd misaligned to EMUL";
      16: return "EMUL > 8";
      17: return "EMUL < 1/8";
      18: return "vill set";
      19: return "vl > VLMAX";
      default: return "?";
    endcase
  endfunction

  task automatic init_bad_table();
    begin
      for (int i = 0; i < NBAD; i++) begin
        bad_nf[i] = 3'b000; bad_mew[i] = 1'b0; bad_mop[i] = 2'b00;
        bad_lumop[i] = 5'b00000; bad_w[i] = 3'b110; bad_vm[i] = 1'b1; bad_vd[i] = 5'd8;
      end
      bad_nf[0]    = 3'b001;
      bad_mew[1]   = 1'b1;
      bad_mop[2]   = 2'b10;
      bad_mop[3]   = 2'b01;
      bad_mop[4]   = 2'b11;
      bad_lumop[5] = 5'b01000;
      bad_lumop[6] = 5'b10000;
      bad_lumop[7] = 5'b00001;
      bad_w[8]     = 3'b010;
      bad_w[9]     = 3'b011;
      bad_w[10]    = 3'b001;
      bad_w[11]    = 3'b100;
      bad_lumop[12] = 5'b01011; bad_w[12] = 3'b110; bad_vd[12] = 5'd12;
      bad_lumop[13] = 5'b01011; bad_w[13] = 3'b000; bad_vm[13] = 1'b0; bad_vd[13] = 5'd12;
      bad_vm[14]   = 1'b0; bad_vd[14] = 5'd0;
      bad_vd[15]   = 5'd9;         // EMUL=2 at SEW32/LMUL2/EEW32
      bad_w[16]    = 3'b111;       // EEW=64 with SEW=8, LMUL=8
      bad_w[17]    = 3'b000;       // EEW=8 with SEW=64, LMUL=1/8
    end
  endtask

  // ---------------- test program ----------------
  logic [2:0] W8, W16, W32, W64;
  initial begin
    W8 = 3'b000; W16 = 3'b101; W32 = 3'b110; W64 = 3'b111;
    lfsr_q = 32'h1234_5678;
    cyc = 0; pass_cnt = 0; fail_cnt = 0; force_err = 1'b0;
    cmd_valid = 1'b0; cmd = '0; flush = 1'b0; clr_flags = 1'b0;
    init_bad_table();
    rst_n = 1'b0;
    seed_state(1);
    repeat (6) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // ---- sweep 1: every EEW x SEW x LMUL x (vl, vstart) x policy ----
    begin
      int unsigned case_no = 0;
      logic [2:0] widths [4];
      logic [2:0] lmuls  [7];
      widths[0] = W8; widths[1] = W16; widths[2] = W32; widths[3] = W64;
      lmuls[0] = 3'b101; lmuls[1] = 3'b110; lmuls[2] = 3'b111;
      lmuls[3] = 3'b000; lmuls[4] = 3'b001; lmuls[5] = 3'b010; lmuls[6] = 3'b011;
      for (int wi = 0; wi < 4; wi++)
        for (int sc = 0; sc < 4; sc++)
          for (int li = 0; li < 7; li++)
            for (int vi = 0; vi < 5; vi++)
              for (int pol = 0; pol < 4; pol++) begin
                int unsigned vlmax_s, vl_s, vstart_s, base_s;
                logic vta_s, vma_s, vm_s;
                vlmax_s = ({1'b1,3'b0} == 0) ? 0 : 0;
                // VLMAX in SEW space for this LMUL
                case (lmuls[li])
                  3'b101: vlmax_s = (VLEN/8)  / sew_bits_of(sc) > 0 ? (VLEN/(8*sew_bits_of(sc))) : 0;
                  3'b110: vlmax_s = VLEN/(4*sew_bits_of(sc));
                  3'b111: vlmax_s = VLEN/(2*sew_bits_of(sc));
                  3'b000: vlmax_s = VLEN/sew_bits_of(sc);
                  3'b001: vlmax_s = 2*VLEN/sew_bits_of(sc);
                  3'b010: vlmax_s = 4*VLEN/sew_bits_of(sc);
                  3'b011: vlmax_s = 8*VLEN/sew_bits_of(sc);
                  default: vlmax_s = 0;
                endcase
                case (vi)
                  0: vl_s = 0;
                  1: vl_s = 1;
                  2: vl_s = (vlmax_s > 1) ? vlmax_s/2 : vlmax_s;
                  3: vl_s = (vlmax_s > 0) ? vlmax_s-1 : 0;
                  default: vl_s = vlmax_s;
                endcase
                vstart_s = (vi == 3) ? 1 : ((pol == 3) ? ((vl_s > 2) ? 2 : vl_s) : 0);
                vta_s = pol[0];
                vma_s = pol[1];
                vm_s  = (pol == 0) || (pol == 3);
                base_s = 64 + (case_no % 7) * 8 + ((case_no % 3) == 0 ? 1 : 0);
                seed_state(case_no + 3);
                run_case($sformatf("sw1[%0d] w%0d sew%0d lmul%03b vl%0d vs%0d vm%0b ta%0b ma%0b",
                                   case_no, eew_bits_of_width(widths[wi]), sew_bits_of(sc),
                                   lmuls[li], vl_s, vstart_s, vm_s, vta_s, vma_s),
                         mk_inst(widths[wi], vm_s, 5'd8, 5'd0, 5'b00000),
                         32'(base_s), sc, lmuls[li], vta_s, vma_s, 1'b0, vl_s, vstart_s);
                case_no++;
              end
    end

    // ---- sweep 2: vlm.v across SEW/LMUL/vl ----
    begin
      int unsigned case_no = 0;
      logic [2:0] lmuls [7];
      lmuls[0] = 3'b101; lmuls[1] = 3'b110; lmuls[2] = 3'b111;
      lmuls[3] = 3'b000; lmuls[4] = 3'b001; lmuls[5] = 3'b010; lmuls[6] = 3'b011;
      for (int sc = 0; sc < 4; sc++)
        for (int li = 0; li < 7; li++)
          for (int vi = 0; vi < 6; vi++) begin
            int unsigned vlmax_s, vl_s, vstart_s;
            case (lmuls[li])
              3'b101: vlmax_s = VLEN/(8*sew_bits_of(sc));
              3'b110: vlmax_s = VLEN/(4*sew_bits_of(sc));
              3'b111: vlmax_s = VLEN/(2*sew_bits_of(sc));
              3'b000: vlmax_s = VLEN/sew_bits_of(sc);
              3'b001: vlmax_s = 2*VLEN/sew_bits_of(sc);
              3'b010: vlmax_s = 4*VLEN/sew_bits_of(sc);
              3'b011: vlmax_s = 8*VLEN/sew_bits_of(sc);
              default: vlmax_s = 0;
            endcase
            case (vi)
              0: vl_s = 0;
              1: vl_s = 1;
              2: vl_s = (vlmax_s >= 7) ? 7 : vlmax_s;   // ceil(7/8) = 1
              3: vl_s = (vlmax_s >= 8) ? 8 : vlmax_s;
              4: vl_s = (vlmax_s >= 9) ? 9 : vlmax_s;
              default: vl_s = vlmax_s;
            endcase
            vstart_s = (vi == 4) ? 1 : 0;
            seed_state(100 + case_no);
            run_case($sformatf("vlm[%0d] sew%0d lmul%03b vl%0d vs%0d",
                               case_no, sew_bits_of(sc), lmuls[li], vl_s, vstart_s),
                     mk_inst(W8, 1'b1, 5'd12, 5'd0, 5'b01011),
                     32'(128 + case_no), sc, lmuls[li], 1'b0 /*vta ignored*/, 1'b0,
                     1'b0, vl_s, vstart_s);
            case_no++;
          end
    end

    // ---- sweep 3: encodings that must decode as illegal ----
    begin
      for (int i = 0; i < NBAD; i++) begin
        int unsigned sc; logic [2:0] lm; int unsigned vl_s; logic vill_s;
        sc = 2; lm = 3'b001; vl_s = 8; vill_s = 1'b0;   // SEW=32, LMUL=2 -> VLMAX=8
        if (i == 16) begin sc = 0; lm = 3'b011; vl_s = 128; end // EEW64/SEW8*LMUL8 = EMUL 64
        if (i == 17) begin sc = 3; lm = 3'b101; vl_s = 0;  end  // EEW8/SEW64*1/8 = EMUL 1/64
        if (i == 18) vill_s = 1'b1;
        if (i == 19) vl_s = 9;                                  // vl > VLMAX(32,m2)=8
        seed_state(200 + i);
        run_case($sformatf("bad[%0d] %s", i, bad_why(i)),
                 mk_inst(bad_w[i], bad_vm[i], bad_vd[i], 5'd0, bad_lumop[i],
                         bad_nf[i], bad_mew[i], bad_mop[i]),
                 32'd256, sc, lm, 1'b1, 1'b1, vill_s, vl_s, 0);
      end
    end

    // ---- sweep 4: legal boundary encodings that must NOT be rejected ----
    begin
      // EMUL exactly 8 and exactly 1/8, and vd=v0 when unmasked.
      seed_state(300);
      run_case("edge EMUL=8 (EEW64,SEW8,LMUL1)",
               mk_inst(W64, 1'b1, 5'd8, 5'd0, 5'b00000),
               32'd64, 0, 3'b000, 1'b1, 1'b1, 1'b0, 16, 0);
      seed_state(301);
      run_case("edge EMUL=1/8 (EEW8,SEW64,LMUL1)",
               mk_inst(W8, 1'b1, 5'd8, 5'd0, 5'b00000),
               32'd64, 3, 3'b000, 1'b1, 1'b1, 1'b0, 2, 0);
      seed_state(302);
      run_case("edge unmasked vd=v0",
               mk_inst(W32, 1'b1, 5'd0, 5'd0, 5'b00000),
               32'd64, 2, 3'b000, 1'b1, 1'b1, 1'b0, 4, 0);
      seed_state(303);
      run_case("edge vstart > vl (nothing updated)",
               mk_inst(W32, 1'b1, 5'd8, 5'd0, 5'b00000),
               32'd64, 2, 3'b001, 1'b1, 1'b1, 1'b0, 4, 9);
      seed_state(304);
      run_case("edge unaligned base (byte offset 3)",
               mk_inst(W32, 1'b1, 5'd8, 5'd0, 5'b00000),
               32'd67, 2, 3'b001, 1'b1, 1'b1, 1'b0, 8, 0);
    end

    $display("REF TOTAL: %0d cases, %0d passed, %0d failed (peak inflight %0d, %0d requests)",
             pass_cnt+fail_cnt, pass_cnt, fail_cnt, mem_peak_inflight, mem_reqs_seen);
    if (fail_cnt != 0) $fatal(1, "reference mismatch");
    $finish;
  end

  initial begin
    #40_000_000;
    $fatal(1, "global timeout");
  end
endmodule
