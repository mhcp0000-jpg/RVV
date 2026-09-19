// Golden-reference verification of the vector store cluster, all RVV 1.0
// store forms.
//
// The model below is written against an INDEPENDENT data representation:
// expected state is a byte image exp_mem[] filled from the pre-instruction
// vector register file, while the DUT keeps a packed VLEN-wide group buffer
// and addresses it with flat slot arithmetic. The source is addressed the
// way the spec describes it -- field f of element i lives in register
// vs3 + f*regs + i/elems_per_reg at byte (i%elems_per_reg)*B -- so a mistake
// in the DUT's slot arithmetic cannot agree with itself.
//
// Legality is likewise re-derived here from the raw instruction fields.
//
// Every case compares the WHOLE memory image, so a request to the wrong
// address, a write of an element that should have stayed inactive, and a
// missing write all fail.
//
// ---------------------------------------------------------------------
// The one thing a reference model cannot do for stores
// ---------------------------------------------------------------------
// Within a single vector store the element accesses are unordered (RVWMO)
// except for vsoxei/vsoxseg. So when two active elements write the same
// byte -- a strided store with stride 0 or a stride smaller than the
// segment, an indexed store with duplicate or near-duplicate indices --
// the resulting memory image is architecturally UNPREDICTABLE, and no
// reference can name it. Such a case is detected here (ref_ambiguous) and
// its memory image is not compared; everything else about it still is.
// The ordered forms have a defined last writer, so they are compared in
// full, duplicates and all.
module tb_vcore_vst_ref;
  import vcore_vst_pkg::*;

  localparam int unsigned VLEN  = 128;
  localparam int unsigned BPR   = VLEN/8;
  localparam int unsigned MEMSZ = 8192;
  localparam int unsigned MAXQ  = 64;
  // STRESS=0: zero-latency memory, always-ready ports
  // STRESS=1: random ready, random latency, out-of-order acks, VRF stalls
  parameter int unsigned STRESS  = 0;
  parameter int unsigned MAX_OUT = 8;

  logic clk, rst_n, flush;

  // ---------------- DUT interface ----------------
  logic cmd_valid, cmd_ready;
  vcore_vst_cmd_t cmd;

  logic vrf_rd_valid, vrf_rd_ready, vrf_rd_rsp_valid, vrf_rd_rsp_ready;
  vcore_vrf_read_req_t vrf_rd_req;
  logic [VLEN-1:0] vrf_rd_rsp_data;

  logic mem_req_valid, mem_req_ready, mem_rsp_valid, mem_rsp_ready;
  vcore_vst_mem_req_t mem_req;
  vcore_vst_mem_rsp_t mem_rsp;

  logic commit_valid, commit_ready;
  vcore_vst_commit_t commit;
  logic busy;

  vcore_vst_top #(.VLEN(VLEN), .ISSUE_DEPTH(3), .MAX_OUTSTANDING(MAX_OUT)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .vrf_read_valid_o(vrf_rd_valid), .vrf_read_ready_i(vrf_rd_ready),
    .vrf_read_req_o(vrf_rd_req),
    .vrf_read_rsp_valid_i(vrf_rd_rsp_valid), .vrf_read_rsp_ready_o(vrf_rd_rsp_ready),
    .vrf_read_rsp_data_i(vrf_rd_rsp_data),
    .mem_req_valid_o(mem_req_valid), .mem_req_ready_i(mem_req_ready), .mem_req_o(mem_req),
    .mem_rsp_valid_i(mem_rsp_valid), .mem_rsp_ready_o(mem_rsp_ready), .mem_rsp_i(mem_rsp),
    .commit_valid_o(commit_valid), .commit_ready_i(commit_ready), .commit_o(commit),
    .busy_o(busy)
  );

  // ---------------- clock ----------------
  initial clk = 0;
  /* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
  /* verilator lint_on BLKSEQ */

  logic [31:0] lfsr_q;
  function automatic logic [31:0] lfsr_next(input logic [31:0] v);
    return {v[30:0], v[31]^v[21]^v[1]^v[0]};
  endfunction
  always @(posedge clk) lfsr_q <= lfsr_next(lfsr_q);

  // ---------------- architectural state ----------------
  logic [VLEN-1:0] vrf     [32];
  logic [7:0]      mem     [MEMSZ];
  logic [7:0]      exp_mem [MEMSZ];
  int unsigned     wr_cnt  [MEMSZ];   // reference-side writes per byte

  // `mem` has a clocked driver (the memory model), so the test program must
  // never assign it directly -- a variable with both a clocked and a
  // procedural driver loses its clocked updates under Verilator. Seeding
  // goes through this request line instead. exp_mem and wr_cnt have a single
  // driver each and are written from the test program.
  logic        seed_req;
  int unsigned seed_salt;

  // ---------------- VRF read port model ----------------
  logic        rd_busy_q;
  logic [4:0]  rd_addr_q;
  int unsigned rd_cnt_q;
  int unsigned vrf_reads_seen;
  assign vrf_rd_ready     = (!rd_busy_q) && ((STRESS == 0) ? 1'b1 : lfsr_q[3]);
  assign vrf_rd_rsp_valid = rd_busy_q && (rd_cnt_q == 0);
  assign vrf_rd_rsp_data  = vrf[rd_addr_q];

  // Flush clears the port model too. That is not a convenience: the cluster
  // drops vrf_rsp_ready_o on flush and never collects a response that was
  // already in the air, so the VRF read arbiter in TOP has to be flushed
  // together with the cluster or that response is stranded forever. Modelling
  // it any other way would be modelling a TOP that deadlocks.
  always @(posedge clk) begin
    if (!rst_n || flush) begin
      rd_busy_q <= 1'b0; rd_cnt_q <= 0; rd_addr_q <= '0;
      if (!rst_n) vrf_reads_seen <= 0;
    end else begin
      if (!rd_busy_q) begin
        if (vrf_rd_valid && vrf_rd_ready) begin
          rd_busy_q      <= 1'b1;
          rd_addr_q      <= vrf_rd_req.addr;
          rd_cnt_q       <= (STRESS == 0) ? 0 : ({29'd0, lfsr_q[6:4]} % 4);
          vrf_reads_seen <= vrf_reads_seen + 1;
        end
      end else if (rd_cnt_q != 0) rd_cnt_q <= rd_cnt_q - 1;
      else if (vrf_rd_rsp_valid && vrf_rd_rsp_ready) rd_busy_q <= 1'b0;
    end
  end

  // ---------------- tagged out-of-order memory model ----------------
  // The write lands when the REQUEST is accepted; the ack may come back much
  // later and in any order. That is the contract the cluster is written to.
  logic                 q_valid [MAXQ];
  logic [VST_TAG_W-1:0] q_tag   [MAXQ];
  logic                 q_err   [MAXQ];
  int unsigned          q_wait  [MAXQ];
  int unsigned          q_rot_q, rsp_sel;
  int unsigned          mem_writes_seen, mem_peak_inflight, mem_inflight;
  logic [31:0]          flt_lo, flt_hi;    // empty window is flt_lo > flt_hi

  assign mem_req_ready = (STRESS == 0) ? 1'b1 : lfsr_q[11];

  always_comb begin
    rsp_sel = MAXQ;
    for (int j = 0; j < MAXQ; j++) begin
      int s = (int'(q_rot_q) + j) % MAXQ;
      if ((rsp_sel == MAXQ) && q_valid[s] && (q_wait[s] == 0)) rsp_sel = s;
    end
  end
  assign mem_rsp_valid = (rsp_sel != MAXQ);
  assign mem_rsp.tag   = (rsp_sel != MAXQ) ? q_tag[rsp_sel] : '0;
  assign mem_rsp.error = (rsp_sel != MAXQ) ? q_err[rsp_sel] : 1'b0;

  function automatic logic addr_faults(input logic [31:0] addr, input int unsigned nbytes);
    for (int b = 0; b < 8; b++)
      if (b < nbytes) begin
        logic [31:0] a = addr + 32'(b);
        if ((flt_lo <= flt_hi) && (a >= flt_lo) && (a <= flt_hi)) return 1'b1;
      end
    return 1'b0;
  endfunction

  always @(posedge clk) begin
    if (seed_req) begin
      /* verilator lint_off BLKSEQ */
      for (int a = 0; a < MEMSZ; a++) mem[a] = 8'((a*3) ^ (int'(seed_salt)*11) ^ (a >> 6));
      /* verilator lint_on BLKSEQ */
    end else if (!rst_n) begin
      for (int s = 0; s < MAXQ; s++) begin q_valid[s] <= 1'b0; q_wait[s] <= 0; end
      q_rot_q <= 0; mem_writes_seen <= 0; mem_peak_inflight <= 0; mem_inflight <= 0;
    end else begin
      for (int s = 0; s < MAXQ; s++) if (q_valid[s] && (q_wait[s] != 0)) q_wait[s] <= q_wait[s] - 1;
      if (mem_req_valid && mem_req_ready) begin
        int free_s = MAXQ;
        for (int s = MAXQ-1; s >= 0; s--) if (!q_valid[s]) free_s = s;
        if (free_s == MAXQ) $fatal(1, "memory model: more outstanding writes than slots");
        for (int b = 0; b < 8; b++)
          if (b < (1 << mem_req.size))
            mem[(int'(mem_req.addr) + b) % MEMSZ] <= mem_req.data[b*8 +: 8];
        q_valid[free_s]   <= 1'b1;
        q_tag  [free_s]   <= mem_req.tag;
        q_err  [free_s]   <= addr_faults(mem_req.addr, 1 << mem_req.size);
        q_wait [free_s]   <= (STRESS == 0) ? 0 : ({29'd0, lfsr_q[26:24]});
        mem_writes_seen   <= mem_writes_seen + 1;
        mem_inflight      <= mem_inflight + 1 - ((mem_rsp_valid && mem_rsp_ready) ? 1 : 0);
        if (mem_inflight + 1 > mem_peak_inflight) mem_peak_inflight <= mem_inflight + 1;
      end else if (mem_rsp_valid && mem_rsp_ready) mem_inflight <= mem_inflight - 1;
      if (mem_rsp_valid && mem_rsp_ready) begin
        q_valid[rsp_sel] <= 1'b0;
        q_rot_q <= (rsp_sel + 1) % MAXQ;
      end
    end
  end

  // ---------------- commit collector ----------------
  logic        saw_last_q, saw_illegal_q, saw_memerr_q, clr_flags;
  int unsigned beats_seen_q;
  int unsigned inflight_at_last_q;
  assign commit_ready = (STRESS == 0) ? 1'b1 : lfsr_q[15];
  always @(posedge clk) begin
    if (!rst_n || clr_flags) begin
      saw_last_q <= 0; saw_illegal_q <= 0; saw_memerr_q <= 0; beats_seen_q <= 0;
      inflight_at_last_q <= 0;
    end else if (commit_valid && commit_ready) begin
      beats_seen_q <= beats_seen_q + 1;
      if (commit.illegal_op) saw_illegal_q <= 1'b1;
      if (commit.mem_error)  saw_memerr_q  <= 1'b1;
      if (commit.last_beat || commit.illegal_op) begin
        saw_last_q <= 1'b1;
        inflight_at_last_q <= mem_inflight - ((mem_rsp_valid && mem_rsp_ready) ? 1 : 0);
      end
    end
  end

  // ---------------- reference model ----------------
  logic        ref_illegal, ref_memerr, ref_ambiguous;
  logic [31:0] ea_arr [0:255];

  function automatic int unsigned sew_bits_of(input int unsigned c);
    case (c) 0: return 8; 1: return 16; 2: return 32; 3: return 64; default: return 0; endcase
  endfunction
  function automatic int unsigned eew_bits_of_width(input logic [2:0] w);
    case (w) 3'b000: return 8; 3'b101: return 16; 3'b110: return 32; 3'b111: return 64;
             default: return 0; endcase
  endfunction

  // Index element i, read from the pre-instruction VRF, unsigned, truncated
  // to the 32-bit address width (RVV 1.0 7.8.2).
  function automatic logic [31:0] idx_of(
    input int unsigned idx_base, input int unsigned idx_bits, input int unsigned i
  );
    int unsigned per_reg, r, lane;
    logic [VLEN-1:0] w;
    per_reg = VLEN / idx_bits;
    r    = i / per_reg;
    lane = i % per_reg;
    w = vrf[(idx_base + r) % 32];
    case (idx_bits)
      8:  return 32'(w[lane*8  +: 8]);
      16: return 32'(w[lane*16 +: 16]);
      32: return     w[lane*32 +: 32];
      64: return     w[lane*64 +: 32];
      default: return '0;
    endcase
  endfunction

  task automatic ref_exec(
    input logic [31:0] inst,
    input logic [31:0] base,
    input logic [31:0] stride_in,
    input int unsigned sew_c,
    input logic [2:0]  vlmul_c,
    input logic        vill,
    input int unsigned vl, vstart,
    input logic [VLEN-1:0] mask
  );
    int unsigned nf_f, mop, sumop, width, vs3, vs2;
    int unsigned deb, ieb, sb, ln, ld, en, ed, regs, iregs, ien, ied;
    int unsigned nf_val, nreg, vlmax, epr, spf, evl, total_regs, eb;
    logic mew, vmb, bad, is_idx, is_ord, is_whole, is_mask, vm_e;
    logic [31:0] stride_eff, ea, a;
    logic faulted;
    begin
      nf_f  = int'(inst[31:29]);
      mew   = inst[28];
      mop   = int'(inst[27:26]);
      vmb   = inst[25];
      sumop = int'(inst[24:20]);
      vs2   = int'(inst[24:20]);
      width = int'(inst[14:12]);
      vs3   = int'(inst[11:7]);

      bad = 1'b0;
      if (inst[6:0] != 7'h27) bad = 1'b1;
      if (mew)  bad = 1'b1;
      if (vill) bad = 1'b1;

      ieb = eew_bits_of_width(3'(width));
      sb  = sew_bits_of(sew_c);
      if (ieb == 0) bad = 1'b1;
      if (sb  == 0) begin sb = 8; bad = 1'b1; end

      nf_val   = nf_f + 1;
      nreg     = 1;
      is_idx   = (mop == 1) || (mop == 3);
      is_ord   = (mop == 3);
      is_whole = 1'b0;
      is_mask  = 1'b0;

      if (mop == 0) begin
        case (sumop)
          32'h00: ;                              // unit-stride
          32'h0b: begin                          // vsm.v
            is_mask = 1'b1;
            if ((width != 0) || !vmb || (nf_f != 0)) bad = 1'b1;
          end
          32'h08: begin                          // vs<nreg>r.v
            is_whole = 1'b1;
            if (!vmb)        bad = 1'b1;
            if (width != 0)  bad = 1'b1;         // stores fix EEW=8; loads do not
            case (nf_f)
              0: nreg = 1; 1: nreg = 2; 3: nreg = 4; 7: nreg = 8;
              default: bad = 1'b1;
            endcase
            nf_val = 1;
          end
          default: bad = 1'b1;                   // no fault-only-first for stores
        endcase
      end else if (mop != 1 && mop != 2 && mop != 3) bad = 1'b1;

      deb = is_idx ? sb : ieb;                   // indexed: data EEW comes from vtype
      if (deb == 0) begin deb = 8; bad = 1'b1; end
      eb = deb / 8;

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

      if (is_idx)       begin en = ln;         ed = ld;      end
      else if (is_mask) begin en = 1;          ed = 1;       end
      else              begin en = deb * ln;   ed = sb * ld; end

      if (is_whole) regs = nreg;
      else begin
        if ((en * 8 < ed) || (en > ed * 8)) bad = 1'b1;
        regs = (en + ed - 1) / ed;
        if (regs < 1) regs = 1;
      end
      if (regs > 8) begin regs = 8; bad = 1'b1; end

      ien   = ieb * ln;
      ied   = sb * ld;
      iregs = (ien + ied - 1) / ied;
      if (iregs < 1) iregs = 1;
      if (is_idx) begin
        if ((ien * 8 < ied) || (ien > ied * 8)) bad = 1'b1;
        if (iregs > 8) bad = 1'b1;
        if ((ien >= ied) && (iregs > 1) && ((vs2 % iregs) != 0)) bad = 1'b1;
      end

      total_regs = nf_val * regs;
      if (total_regs > 8) bad = 1'b1;
      if (!is_whole && (en * nf_val > ed * 8)) bad = 1'b1;
      if (is_whole) begin
        if ((nreg > 1) && ((vs3 % nreg) != 0)) bad = 1'b1;
      end else if ((en >= ed) && (regs > 1) && ((vs3 % regs) != 0)) bad = 1'b1;

      vlmax = (ln * VLEN) / (ld * sb);
      if (!is_whole && ((vlmax == 0) || (vl > vlmax))) bad = 1'b1;

      // Deliberately ABSENT, and this is the point of the store decoder:
      //   - no "masked op cannot write v0" rule: a store has no destination,
      //     so vs3 == v0 with vm == 0 is legal.
      //   - no destination/index overlap rule for indexed segments: vs2 and
      //     vs3 are both sources.

      epr = VLEN / deb;
      spf = regs * epr;

      if (is_mask)       begin evl = (vl + 7) / 8; vm_e = 1'b1; end
      else if (is_whole) begin evl = spf;          vm_e = 1'b1; end
      else               begin evl = vl;           vm_e = vmb; end

      if (is_mask)       stride_eff = 32'd1;
      else if (is_whole) stride_eff = 32'd1;
      else if (mop == 2) stride_eff = stride_in;
      else               stride_eff = 32'(nf_val * eb);

      // baseline: memory as it stands
      for (int x = 0; x < MEMSZ; x++) begin
        exp_mem[x] = mem[x];
        wr_cnt[x]  = 0;
      end

      ref_illegal   = bad;
      ref_memerr    = 1'b0;
      ref_ambiguous = 1'b0;
      if (bad) return;

      ea = base;
      for (int i = 0; i < 256; i++) ea_arr[i] = '0;
      for (int i = 0; i < int'(spf); i++) begin
        ea_arr[i] = is_idx ? (base + idx_of(vs2, ieb, i)) : ea;
        ea = ea + stride_eff;
      end

      // Does any active element fault? A store that faults leaves memory in
      // a state no reference can name, because the writes that were already
      // accepted have landed. Only the flag is checked for those.
      for (int i = 0; i < int'(evl); i++)
        if ((i >= int'(vstart)) && (vm_e || mask[i])) begin
          faulted = 1'b0;
          for (int f = 0; f < int'(nf_val); f++)
            if (addr_faults(ea_arr[i] + 32'(f*eb), eb)) faulted = 1'b1;
          if (faulted) ref_memerr = 1'b1;
        end

      // Apply the writes in increasing element order, then increasing field
      // order. For an ordered store that IS the architectural order, so the
      // last writer to a repeated byte is the right one. For an unordered
      // store any repeat makes the image unpredictable, flagged below.
      for (int i = 0; i < int'(spf); i++) begin
        if ((i >= int'(vstart)) && (i < int'(evl)) && (vm_e || mask[i]))
          for (int f = 0; f < int'(nf_val); f++) begin
            int unsigned sreg  = vs3 + f*regs + (i / epr);
            int unsigned sbyte = (i % epr)*eb;
            a = ea_arr[i] + 32'(f*eb);
            for (int b = 0; b < int'(eb); b++) begin
              int unsigned ma = (int'(a) + b) % MEMSZ;
              exp_mem[ma] = vrf[sreg % 32][(sbyte + b)*8 +: 8];
              wr_cnt[ma]  = wr_cnt[ma] + 1;
            end
          end
      end

      if (!is_ord)
        for (int x = 0; x < MEMSZ; x++)
          if (wr_cnt[x] > 1) ref_ambiguous = 1'b1;
    end
  endtask

  // ---------------- driver ----------------
  int unsigned pass_cnt, fail_cnt, legal_cnt, illegal_cnt, ambig_cnt, err_cnt;

  // Every encoding this bench actually EXECUTES (decoded legal and run to
  // completion) is logged, and generate_store_checklist.py turns that log
  // into the checklist's `execute` column. The column is therefore evidence
  // from the run, not a claim typed by hand.
  int exec_fh;

  function automatic logic [31:0] mk_inst(
    input logic [2:0] width, input logic vmb, input logic [4:0] vs3,
    input logic [4:0] sumop, input logic [2:0] nf = 3'b000,
    input logic mew = 1'b0, input logic [1:0] mop = 2'b00
  );
    return {nf, mew, mop, vmb, sumop, 5'd1, width, vs3, 7'h27};
  endfunction

  task automatic run_case(
    input string       name,
    input logic [31:0] inst,
    input logic [31:0] base,
    input logic [31:0] stride_in,
    input int unsigned sew_c,
    input logic [2:0]  vlmul_c,
    input logic        vill,
    input int unsigned vl, vstart
  );
    logic [VLEN-1:0] mask;
    logic mismatch;
    begin
      mask = vrf[0];                      // v0 snapshot, what TOP would hand over
      ref_exec(inst, base, stride_in, sew_c, vlmul_c, vill, vl, vstart, mask);

      @(negedge clk);
      clr_flags = 1'b1;
      @(negedge clk);
      clr_flags = 1'b0;
      cmd = '0;
      cmd.inst = inst; cmd.base = base; cmd.stride = stride_in;
      cmd.sew = 3'(sew_c); cmd.vlmul = vlmul_c; cmd.vill = vill;
      cmd.vl = 17'(vl); cmd.vstart = 17'(vstart);
      cmd.mask_snapshot = mask;
      cmd.tag = 16'(pass_cnt + fail_cnt);
      cmd_valid = 1'b1;
      do @(negedge clk); while (!cmd_ready);
      cmd_valid = 1'b0;

      for (int t = 0; t < 60000; t++) begin
        if (saw_last_q) break;
        @(negedge clk);
      end
      if (!saw_last_q) begin
        $display("FAIL %s: timeout (no last_beat commit)", name);
        fail_cnt++;
        return;
      end
      repeat (6) @(negedge clk);

      mismatch = 1'b0;
      if (saw_illegal_q !== ref_illegal) begin
        $display("FAIL %s: illegal_op got=%0b exp=%0b", name, saw_illegal_q, ref_illegal);
        mismatch = 1'b1;
      end
      if (saw_memerr_q !== ref_memerr) begin
        $display("FAIL %s: mem_error got=%0b exp=%0b", name, saw_memerr_q, ref_memerr);
        mismatch = 1'b1;
      end
      // A store must not report last_beat while its writes are still in the
      // air: the host needs every write acknowledged before it commits.
      if (inflight_at_last_q != 0) begin
        $display("FAIL %s: retired with %0d writes still outstanding",
                 name, inflight_at_last_q);
        mismatch = 1'b1;
      end
      if (!ref_memerr && !ref_ambiguous) begin
        for (int x = 0; x < MEMSZ; x++)
          if (mem[x] !== exp_mem[x]) begin
            if (!mismatch)
              $display("FAIL %s: mem[%0d] got=%02h exp=%02h", name, x, mem[x], exp_mem[x]);
            mismatch = 1'b1;
          end
      end
      if (mismatch) fail_cnt++; else pass_cnt++;
      if (!mismatch && !ref_illegal)
        $fdisplay(exec_fh, "%0d %0d %0d %0d",
                  int'(inst[31:29]), int'(inst[27:26]),
                  int'(inst[24:20]), int'(inst[14:12]));
      if (ref_illegal)   illegal_cnt++; else legal_cnt++;
      if (ref_ambiguous) ambig_cnt++;
      if (ref_memerr)    err_cnt++;
    end
  endtask

  // Flush while the store is mid-scan. The cluster must stop issuing, drain
  // whatever it already put on the bus (a write that has been accepted
  // cannot be recalled), drop busy, and then be usable again. The memory
  // image after a flushed store is by definition partial, so what is checked
  // here is the drain and the recovery, not the bytes.
  int unsigned flush_pass, flush_fail;
  task automatic run_flush_case(
    input string       name,
    input logic [31:0] inst,
    input logic [31:0] base,
    input logic [31:0] stride_in,
    input int unsigned sew_c,
    input logic [2:0]  vlmul_c,
    input int unsigned vl,
    input int unsigned wait_cycles
  );
    int unsigned reqs_at_flush, reqs_after_drain;
    logic ok;
    begin
      ok = 1'b1;
      @(negedge clk);
      clr_flags = 1'b1;
      @(negedge clk);
      clr_flags = 1'b0;
      cmd = '0;
      cmd.inst = inst; cmd.base = base; cmd.stride = stride_in;
      cmd.sew = 3'(sew_c); cmd.vlmul = vlmul_c;
      cmd.vl = 17'(vl); cmd.mask_snapshot = vrf[0];
      cmd.tag = 16'hF000;
      cmd_valid = 1'b1;
      do @(negedge clk); while (!cmd_ready);
      cmd_valid = 1'b0;

      repeat (wait_cycles) @(negedge clk);
      reqs_at_flush = mem_writes_seen;
      flush = 1'b1;
      repeat (2) @(negedge clk);
      flush = 1'b0;

      // busy must fall once the accepted writes have been acknowledged
      for (int t = 0; t < 2000; t++) begin
        if (!busy) break;
        @(negedge clk);
      end
      if (busy) begin
        $display("FAIL %s: busy never fell after flush", name);
        ok = 1'b0;
      end
      repeat (10) @(negedge clk);
      reqs_after_drain = mem_writes_seen;

      // nothing may be left in flight, and the cluster must accept work again
      if (mem_inflight != 0) begin
        $display("FAIL %s: %0d writes still in flight after drain", name, mem_inflight);
        ok = 1'b0;
      end
      if (!cmd_ready) begin
        $display("FAIL %s: cluster did not become ready again", name);
        ok = 1'b0;
      end
      if (reqs_after_drain < reqs_at_flush) begin
        $display("FAIL %s: write counter went backwards", name);
        ok = 1'b0;
      end
      if (ok) flush_pass++; else flush_fail++;
    end
  endtask

  task automatic seed_state(input int unsigned salt);
    begin
      for (int r = 0; r < 32; r++)
        for (int b = 0; b < BPR; b++)
          vrf[r][b*8 +: 8] = 8'(((r*41) ^ (b*67) ^ (int'(salt)*19)) + 7);
      @(negedge clk);
      seed_salt = salt;
      seed_req  = 1'b1;
      @(negedge clk);
      seed_req  = 1'b0;
      @(negedge clk);
    end
  endtask

  // Index registers holding a PERMUTATION of n slots, each `spacing` bytes
  // apart. Non-monotonic, so the store really scatters, but no two elements
  // can land on the same byte -- which is what keeps an unordered indexed
  // store predictable enough to compare.
  task automatic seed_index(
    input int unsigned vs2, input int unsigned idx_bits,
    input int unsigned n, input int unsigned spacing, input int unsigned salt
  );
    int unsigned per_reg, r, lane, v;
    begin
      per_reg = VLEN / idx_bits;
      for (int i = 0; i < int'(n); i++) begin
        r    = vs2 + (i / per_reg);
        lane = i % per_reg;
        v    = (((i * 5) + salt) % ((n == 0) ? 1 : n)) * spacing;
        case (idx_bits)
          8:  vrf[r % 32][lane*8  +: 8]  = 8'(v);
          16: vrf[r % 32][lane*16 +: 16] = 16'(v);
          32: vrf[r % 32][lane*32 +: 32] = 32'(v);
          64: begin vrf[r % 32][lane*64 +: 32] = 32'(v);
                    vrf[r % 32][lane*64 + 32 +: 32] = 32'd0; end
          default: ;
        endcase
      end
    end
  endtask

  // ---------------- protocol assertions ----------------
  default clocking cb @(posedge clk); endclocking
  property p_stable_memreq;
    disable iff (!rst_n || flush)
    (mem_req_valid && !mem_req_ready) |=> (mem_req_valid && $stable(mem_req));
  endproperty
  assert property (p_stable_memreq) else $error("mem_req unstable while stalled");

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

  property p_no_spurious_rsp;
    disable iff (!rst_n)
    (mem_rsp_valid && mem_rsp_ready) |-> (mem_inflight != 0);
  endproperty
  assert property (p_no_spurious_rsp) else $error("ack with nothing in flight");

  property p_busy_covers_inflight;
    disable iff (!rst_n)
    (mem_inflight != 0) |-> busy;
  endproperty
  assert property (p_busy_covers_inflight) else $error("busy_o low with writes in flight");

  // ---------------- illegal-encoding table ----------------
  localparam int unsigned NBAD = 20;
  logic [2:0] bad_nf    [NBAD];
  logic       bad_mew   [NBAD];
  logic [1:0] bad_mop   [NBAD];
  logic [4:0] bad_sumop [NBAD];
  logic [2:0] bad_w     [NBAD];
  logic       bad_vm    [NBAD];
  logic [4:0] bad_vs3   [NBAD];

  function automatic string bad_why(input int i);
    case (i)
      0:  return "mew=1 (EEW>64)";
      1:  return "reserved sumop=00001";
      2:  return "reserved sumop=01001";
      3:  return "sumop=10000 is fault-only-first, loads only";
      4:  return "width=010 is fsw";
      5:  return "width=011 is fsd";
      6:  return "width=001 is fsh";
      7:  return "width=100 is fsq";
      8:  return "vsm.v with width!=000";
      9:  return "vsm.v masked (vm=0)";
      10: return "vsm.v with nf!=0";
      11: return "vs3 misaligned to EMUL";
      12: return "EMUL > 8";
      13: return "EMUL < 1/8";
      14: return "vill set";
      15: return "vl > VLMAX";
      16: return "whole-register masked (vm=0)";
      17: return "whole-register nf=2 reserved";
      18: return "whole-register width!=000";
      19: return "segment EMUL*NFIELDS > 8";
      default: return "?";
    endcase
  endfunction

  task automatic init_bad_table();
    begin
      for (int i = 0; i < NBAD; i++) begin
        bad_nf[i] = 3'b000; bad_mew[i] = 1'b0; bad_mop[i] = 2'b00;
        bad_sumop[i] = 5'b00000; bad_w[i] = 3'b110; bad_vm[i] = 1'b1; bad_vs3[i] = 5'd8;
      end
      bad_mew[0]     = 1'b1;
      bad_sumop[1]   = 5'b00001;
      bad_sumop[2]   = 5'b01001;
      bad_sumop[3]   = 5'b10000;
      bad_w[4]       = 3'b010;
      bad_w[5]       = 3'b011;
      bad_w[6]       = 3'b001;
      bad_w[7]       = 3'b100;
      bad_sumop[8]   = 5'b01011; bad_w[8]  = 3'b110; bad_vs3[8]  = 5'd12;
      bad_sumop[9]   = 5'b01011; bad_w[9]  = 3'b000; bad_vm[9]   = 1'b0; bad_vs3[9] = 5'd12;
      bad_sumop[10]  = 5'b01011; bad_w[10] = 3'b000; bad_nf[10]  = 3'b001; bad_vs3[10] = 5'd12;
      bad_vs3[11]    = 5'd9;        // EMUL=2 at SEW32/LMUL2/EEW32
      bad_w[12]      = 3'b111;      // EEW=64 with SEW=8, LMUL=8
      bad_w[13]      = 3'b000;      // EEW=8 with SEW=64, LMUL=1/8
      bad_sumop[16]  = 5'b01000; bad_w[16] = 3'b000; bad_vm[16] = 1'b0;
      bad_sumop[17]  = 5'b01000; bad_w[17] = 3'b000; bad_nf[17] = 3'b010;
      bad_sumop[18]  = 5'b01000; bad_w[18] = 3'b110;
      bad_nf[19]     = 3'b100;      // nf=5 with EMUL=2 -> 10 > 8
    end
  endtask

  // ---------------- test program ----------------
  logic [2:0] W8, W16, W32, W64;
  logic [4:0] SU_UNIT, SU_WHOLE, SU_MASK;
  logic [2:0] widths [4];
  logic [2:0] lmuls  [7];

  function automatic int unsigned vlmax_of(input int unsigned sc, input logic [2:0] lm);
    case (lm)
      3'b101: return VLEN/(8*sew_bits_of(sc));
      3'b110: return VLEN/(4*sew_bits_of(sc));
      3'b111: return VLEN/(2*sew_bits_of(sc));
      3'b000: return VLEN/sew_bits_of(sc);
      3'b001: return 2*VLEN/sew_bits_of(sc);
      3'b010: return 4*VLEN/sew_bits_of(sc);
      3'b011: return 8*VLEN/sew_bits_of(sc);
      default: return 0;
    endcase
  endfunction

  initial begin
    W8 = 3'b000; W16 = 3'b101; W32 = 3'b110; W64 = 3'b111;
    SU_UNIT = 5'b00000; SU_WHOLE = 5'b01000; SU_MASK = 5'b01011;
    widths[0] = W8; widths[1] = W16; widths[2] = W32; widths[3] = W64;
    lmuls[0] = 3'b101; lmuls[1] = 3'b110; lmuls[2] = 3'b111;
    lmuls[3] = 3'b000; lmuls[4] = 3'b001; lmuls[5] = 3'b010; lmuls[6] = 3'b011;

    lfsr_q = 32'h2468_ace0;
    pass_cnt = 0; fail_cnt = 0; legal_cnt = 0; illegal_cnt = 0;
    ambig_cnt = 0; err_cnt = 0; flush_pass = 0; flush_fail = 0;
    cmd_valid = 1'b0; cmd = '0; flush = 1'b0; clr_flags = 1'b0;
    seed_req = 1'b0; seed_salt = 0;
    flt_lo = 32'd1; flt_hi = 32'd0;
    exec_fh = $fopen("exec_coverage.txt", "w");
    if (exec_fh == 0) $fatal(1, "cannot open exec_coverage.txt");
    init_bad_table();
    rst_n = 1'b0;
    seed_state(1);
    repeat (6) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // ===== sweep 1: unit-stride across EEW x SEW x LMUL x vl x mask/vstart =====
    begin
      int unsigned case_no = 0;
      for (int wi = 0; wi < 4; wi++)
        for (int sc = 0; sc < 4; sc++)
          for (int li = 0; li < 7; li++)
            for (int vi = 0; vi < 5; vi++)
              for (int pol = 0; pol < 2; pol++) begin
                int unsigned vlmax_s, vl_s, vstart_s, base_s;
                logic vm_s;
                vlmax_s = vlmax_of(sc, lmuls[li]);
                case (vi)
                  0: vl_s = 0;
                  1: vl_s = 1;
                  2: vl_s = (vlmax_s > 1) ? vlmax_s/2 : vlmax_s;
                  3: vl_s = (vlmax_s > 0) ? vlmax_s-1 : 0;
                  default: vl_s = vlmax_s;
                endcase
                vstart_s = (vi == 3) ? 1 : ((pol == 1) ? ((vl_s > 2) ? 2 : vl_s) : 0);
                vm_s     = (pol == 0);
                base_s   = 1024 + (case_no % 7) * 8 + (((case_no % 3) == 0) ? 1 : 0);
                seed_state(case_no + 3);
                run_case($sformatf("u[%0d] w%0d sew%0d lmul%03b vl%0d vs%0d vm%0b",
                                   case_no, eew_bits_of_width(widths[wi]), sew_bits_of(sc),
                                   lmuls[li], vl_s, vstart_s, vm_s),
                         mk_inst(widths[wi], vm_s, 5'd8, SU_UNIT),
                         32'(base_s), 32'd0, sc, lmuls[li], 1'b0, vl_s, vstart_s);
                case_no++;
              end
    end

    // ===== sweep 2: vsm.v =====
    begin
      int unsigned case_no = 0;
      for (int sc = 0; sc < 4; sc++)
        for (int li = 0; li < 7; li++)
          for (int vi = 0; vi < 6; vi++) begin
            int unsigned vlmax_s, vl_s, vstart_s;
            vlmax_s = vlmax_of(sc, lmuls[li]);
            case (vi)
              0: vl_s = 0;
              1: vl_s = 1;
              2: vl_s = (vlmax_s >= 7) ? 7 : vlmax_s;
              3: vl_s = (vlmax_s >= 8) ? 8 : vlmax_s;
              4: vl_s = (vlmax_s >= 9) ? 9 : vlmax_s;
              default: vl_s = vlmax_s;
            endcase
            vstart_s = (vi == 4) ? 1 : 0;
            seed_state(100 + case_no);
            run_case($sformatf("vsm[%0d] sew%0d lmul%03b vl%0d vs%0d",
                               case_no, sew_bits_of(sc), lmuls[li], vl_s, vstart_s),
                     mk_inst(W8, 1'b1, 5'd12, SU_MASK),
                     32'(2048 + case_no), 32'd0, sc, lmuls[li], 1'b0, vl_s, vstart_s);
            case_no++;
          end
    end

    // ===== sweep 3: strided =====
    // si==2 (stride 0) and si==1 (stride smaller than the element) make the
    // image unpredictable for an unordered store; they still run, and
    // everything except the image is checked.
    begin
      int unsigned case_no = 0;
      for (int wi = 0; wi < 4; wi++)
        for (int sc = 0; sc < 4; sc++)
          for (int li = 0; li < 7; li++)
            for (int si = 0; si < 4; si++) begin
              int unsigned vlmax_s, vl_s, eb;
              logic [31:0] str;
              logic vm_s;
              vlmax_s = vlmax_of(sc, lmuls[li]);
              vl_s = (vlmax_s > 8) ? 8 : vlmax_s;
              eb = eew_bits_of_width(widths[wi]) / 8;
              case (si)
                0: str = 32'(eb);             // contiguous
                1: str = 32'd3;               // overlapping, unaligned
                2: str = 32'd0;               // every element to one address
                default: str = -32'(eb);      // negative
              endcase
              vm_s = (si != 1);
              seed_state(300 + case_no);
              run_case($sformatf("s[%0d] w%0d sew%0d lmul%03b vl%0d stride%0d vm%0b",
                                 case_no, eew_bits_of_width(widths[wi]), sew_bits_of(sc),
                                 lmuls[li], vl_s, $signed(str), vm_s),
                       mk_inst(widths[wi], vm_s, 5'd8, 5'd2, 3'b000, 1'b0, 2'b10),
                       32'd4096, str, sc, lmuls[li], 1'b0, vl_s, 0);
              case_no++;
            end
    end

    // ===== sweep 4: indexed, unordered and ordered =====
    begin
      int unsigned case_no = 0;
      for (int wi = 0; wi < 4; wi++)
        for (int sc = 0; sc < 4; sc++)
          for (int li = 0; li < 7; li++)
            for (int oi = 0; oi < 2; oi++) begin
              int unsigned vlmax_s, vl_s;
              logic vm_s;
              vlmax_s = vlmax_of(sc, lmuls[li]);
              vl_s = (vlmax_s > 8) ? 8 : vlmax_s;
              vm_s = ((case_no % 3) != 0);
              seed_state(600 + case_no);
              seed_index(16, eew_bits_of_width(widths[wi]),
                         (vlmax_s > 0) ? vlmax_s : 1, 16, case_no);
              run_case($sformatf("x[%0d] idx%0d sew%0d lmul%03b vl%0d %s vm%0b",
                                 case_no, eew_bits_of_width(widths[wi]), sew_bits_of(sc),
                                 lmuls[li], vl_s, (oi != 0) ? "ord" : "unord", vm_s),
                       mk_inst(widths[wi], vm_s, 5'd8, 5'd16, 3'b000, 1'b0,
                               (oi != 0) ? 2'b11 : 2'b01),
                       32'd3072, 32'd0, sc, lmuls[li], 1'b0, vl_s, 0);
              case_no++;
            end
    end

    // ===== sweep 5: segment unit-stride =====
    begin
      int unsigned case_no = 0;
      logic [2:0] seg_lmuls [3];
      seg_lmuls[0] = 3'b111; seg_lmuls[1] = 3'b000; seg_lmuls[2] = 3'b001;
      for (int nf = 2; nf <= 8; nf++)
        for (int wi = 0; wi < 4; wi++)
          for (int li = 0; li < 3; li++)
            for (int pol = 0; pol < 2; pol++) begin
              int unsigned vlmax_s, vl_s, sc;
              logic vm_s;
              sc = 2;                                   // SEW=32
              vlmax_s = vlmax_of(sc, seg_lmuls[li]);
              vl_s = (pol == 0) ? vlmax_s : ((vlmax_s > 1) ? vlmax_s-1 : vlmax_s);
              vm_s = (pol == 0);
              seed_state(900 + case_no);
              run_case($sformatf("seg[%0d] nf%0d w%0d lmul%03b vl%0d vm%0b",
                                 case_no, nf, eew_bits_of_width(widths[wi]),
                                 seg_lmuls[li], vl_s, vm_s),
                       mk_inst(widths[wi], vm_s, 5'd8, SU_UNIT, 3'(nf-1)),
                       32'd5120, 32'd0, sc, seg_lmuls[li], 1'b0, vl_s, 0);
              case_no++;
            end
    end

    // ===== sweep 6: segment strided and segment indexed, every nf =====
    // SEW=32 with LMUL=1/2 keeps the data group at one register for every
    // EEW, so nf can go all the way to 8 without busting the 8-register
    // budget; LMUL=1 is run alongside it for the wider element counts.
    begin
      int unsigned case_no = 0;
      for (int nf = 2; nf <= 8; nf++)
        for (int wi = 0; wi < 4; wi++)
          for (int form = 0; form < 3; form++)
            for (int li = 0; li < 2; li++) begin
              int unsigned vlmax_s, vl_s, sc, eb;
              logic [2:0] lm;
              logic [4:0] su;
              logic [1:0] mp;
              sc = 2;                                  // SEW=32
              lm = (li == 0) ? 3'b111 : 3'b000;        // LMUL 1/2, then 1
              eb = eew_bits_of_width(widths[wi]) / 8;
              vlmax_s = vlmax_of(sc, lm);
              vl_s = vlmax_s;
              case (form)
                0: begin su = 5'd2;  mp = 2'b10; end   // vssseg
                1: begin su = 5'd16; mp = 2'b01; end   // vsuxseg
                default: begin su = 5'd16; mp = 2'b11; end // vsoxseg
              endcase
              seed_state(1200 + case_no);
              if (form != 0)
                // one segment is nf*4 bytes wide at SEW=32, so 64 bytes of
                // spacing keeps every element's segment clear of the next --
                // without that an unordered indexed segment store would have
                // no predictable image to compare against
                seed_index(16, eew_bits_of_width(widths[wi]),
                           (vlmax_s > 0) ? vlmax_s : 1, 64, case_no);
              run_case($sformatf("segx[%0d] nf%0d w%0d lmul%03b %s",
                                 case_no, nf, eew_bits_of_width(widths[wi]), lm,
                                 (form == 0) ? "strided" :
                                 ((form == 1) ? "unord-indexed" : "ord-indexed")),
                       mk_inst(widths[wi], 1'b1, 5'd8, su, 3'(nf-1), 1'b0, mp),
                       32'd1536, 32'(nf*eb + 4), sc, lm, 1'b0, vl_s, 0);
              case_no++;
            end
    end

    // ===== sweep 7: whole-register stores =====
    begin
      int unsigned case_no = 0;
      int unsigned nregs [4];
      logic [2:0]  nfenc [4];
      nregs[0] = 1; nregs[1] = 2; nregs[2] = 4; nregs[3] = 8;
      nfenc[0] = 3'd0; nfenc[1] = 3'd1; nfenc[2] = 3'd3; nfenc[3] = 3'd7;
      for (int ri = 0; ri < 4; ri++)
        for (int vi = 0; vi < 3; vi++) begin
          int unsigned vstart_s;
          case (vi) 0: vstart_s = 0; 1: vstart_s = 3; default: vstart_s = 300; endcase
          seed_state(1500 + case_no);
          // vtype is deliberately mismatched: these instructions ignore it
          run_case($sformatf("whole[%0d] nreg%0d vs%0d", case_no, nregs[ri], vstart_s),
                   mk_inst(W8, 1'b1, 5'd8, SU_WHOLE, nfenc[ri]),
                   32'd6144, 32'd0, 1, 3'b010, 1'b0, 4, vstart_s);
          case_no++;
        end
    end

    // ===== sweep 8: faulting stores -- flag only, image unpredictable =====
    begin
      int unsigned case_no = 0;
      int unsigned ks [4];
      ks[0] = 0; ks[1] = 1; ks[2] = 3; ks[3] = 99;   // 99 = no fault
      for (int ki = 0; ki < 4; ki++)
        for (int wi = 0; wi < 4; wi++)
          for (int ni = 0; ni < 2; ni++) begin
            int unsigned eb, nf, vl_s, base_s, k;
            base_s = 7168;
            eb = eew_bits_of_width(widths[wi]) / 8;
            nf = (ni == 0) ? 1 : 3;
            vl_s = 4;                        // SEW=32, LMUL=1 -> VLMAX 4
            k = ks[ki];
            seed_state(1800 + case_no);
            if (k < vl_s) begin
              flt_lo = 32'(base_s + k*nf*eb);
              flt_hi = flt_lo + 32'(eb) - 32'd1;
            end else begin
              flt_lo = 32'd1; flt_hi = 32'd0;
            end
            run_case($sformatf("flt[%0d] w%0d nf%0d fault_at%0d",
                               case_no, eew_bits_of_width(widths[wi]), nf, k),
                     mk_inst(widths[wi], 1'b1, 5'd8, SU_UNIT, 3'(nf-1)),
                     32'(base_s), 32'd0, 2, 3'b000, 1'b0, vl_s, 0);
            flt_lo = 32'd1; flt_hi = 32'd0;
            case_no++;
          end
    end

    // ===== sweep 9: illegal encodings =====
    begin
      for (int i = 0; i < NBAD; i++) begin
        int unsigned sc; logic [2:0] lm; int unsigned vl_s; logic vill_s;
        sc = 2; lm = 3'b001; vl_s = 8; vill_s = 1'b0;   // SEW=32, LMUL=2 -> VLMAX=8
        if (i == 12) begin sc = 0; lm = 3'b011; vl_s = 128; end
        if (i == 13) begin sc = 3; lm = 3'b101; vl_s = 0;  end
        if (i == 14) vill_s = 1'b1;
        if (i == 15) vl_s = 9;
        seed_state(2100 + i);
        run_case($sformatf("bad[%0d] %s", i, bad_why(i)),
                 mk_inst(bad_w[i], bad_vm[i], bad_vs3[i], bad_sumop[i],
                         bad_nf[i], bad_mew[i], bad_mop[i]),
                 32'd256, 32'd4, sc, lm, vill_s, vl_s, 0);
      end
    end

    // ===== sweep 10: legal boundaries, and the rules a store does NOT have =====
    begin
      seed_state(2300);
      run_case("edge EMUL=8 (EEW64,SEW8,LMUL1)",
               mk_inst(W64, 1'b1, 5'd8, SU_UNIT), 32'd64, 32'd0, 0, 3'b000,
               1'b0, 16, 0);
      seed_state(2301);
      run_case("edge EMUL=1/8 (EEW8,SEW64,LMUL1)",
               mk_inst(W8, 1'b1, 5'd8, SU_UNIT), 32'd64, 32'd0, 3, 3'b000,
               1'b0, 2, 0);
      seed_state(2302);
      vrf[0] = 128'h0f0f_0f0f_0f0f_0f0f_0f0f_0f0f_0f0f_0f0f;
      run_case("edge masked store with vs3 == v0 is LEGAL (no destination)",
               mk_inst(W32, 1'b0, 5'd0, SU_UNIT), 32'd512, 32'd0, 2, 3'b000,
               1'b0, 4, 0);
      seed_state(2303);
      run_case("edge vstart > evl (nothing written)",
               mk_inst(W32, 1'b1, 5'd8, SU_UNIT), 32'd64, 32'd0, 2, 3'b001,
               1'b0, 4, 9);
      seed_state(2304);
      run_case("edge unaligned base (byte offset 3)",
               mk_inst(W32, 1'b1, 5'd8, SU_UNIT), 32'd67, 32'd0, 2, 3'b001,
               1'b0, 8, 0);
      seed_state(2305);
      run_case("edge segment nf=8 EMUL=1",
               mk_inst(W32, 1'b1, 5'd8, SU_UNIT, 3'd7), 32'd2560, 32'd0, 2, 3'b000,
               1'b0, 4, 0);
      seed_state(2306);
      seed_index(8, 32, 4, 16, 3);
      run_case("edge indexed vs3 group overlaps index group (legal for a store)",
               mk_inst(W32, 1'b1, 5'd8, 5'd8, 3'b000, 1'b0, 2'b01),
               32'd3072, 32'd0, 2, 3'b000, 1'b0, 4, 0);
      // Ordered indexed with every index the same: the last element wins, and
      // that is the only form where the answer is defined at all.
      seed_state(2307);
      for (int i = 0; i < 8; i++) vrf[16][i*32 +: 32] = 32'd64;
      run_case("edge vsoxei32 with duplicate indices: highest element wins",
               mk_inst(W32, 1'b1, 5'd8, 5'd16, 3'b000, 1'b0, 2'b11),
               32'd3072, 32'd0, 2, 3'b001, 1'b0, 8, 0);
    end

    // ===== sweep 11: flush mid-scan, then recover =====
    begin
      int unsigned case_no = 0;
      for (int wc = 0; wc < 5; wc++)
        for (int form = 0; form < 3; form++) begin
          int unsigned waitc;
          waitc = 4 + wc*3;
          seed_state(2400 + case_no);
          case (form)
            0: run_flush_case($sformatf("flush[%0d] vse32 wait%0d", case_no, waitc),
                              mk_inst(W32, 1'b1, 5'd8, SU_UNIT),
                              32'd1024, 32'd0, 2, 3'b010, 16, waitc);
            1: run_flush_case($sformatf("flush[%0d] vsseg4e32 wait%0d", case_no, waitc),
                              mk_inst(W32, 1'b1, 5'd8, SU_UNIT, 3'd3),
                              32'd1024, 32'd0, 2, 3'b000, 4, waitc);
            default: begin
              seed_index(16, 32, 4, 16, case_no);
              run_flush_case($sformatf("flush[%0d] vsoxei32 wait%0d", case_no, waitc),
                             mk_inst(W32, 1'b1, 5'd8, 5'd16, 3'b000, 1'b0, 2'b11),
                             32'd3072, 32'd0, 2, 3'b000, 4, waitc);
            end
          endcase
          case_no++;
        end
      // and the cluster still works afterwards
      seed_state(2500);
      run_case("post-flush vse32.v still correct",
               mk_inst(W32, 1'b1, 5'd8, SU_UNIT), 32'd1024, 32'd0, 2, 3'b001,
               1'b0, 8, 0);
    end

    $display("REF TOTAL: %0d cases, %0d passed, %0d failed (peak inflight %0d, %0d writes, %0d vrf reads)",
             pass_cnt+fail_cnt, pass_cnt, fail_cnt, mem_peak_inflight,
             mem_writes_seen, vrf_reads_seen);
    $display("REF MIX  : %0d executed, %0d rejected as illegal, %0d trapped, %0d image-unpredictable",
             legal_cnt, illegal_cnt, err_cnt, ambig_cnt);
    $display("REF FLUSH: %0d drained and recovered, %0d failed", flush_pass, flush_fail);
    $fclose(exec_fh);
    if ((fail_cnt != 0) || (flush_fail != 0)) $fatal(1, "reference mismatch");
    $finish;
  end

  initial begin
    #400_000_000;
    $fatal(1, "global timeout");
  end
endmodule
