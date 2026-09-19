// Golden-reference verification of the vector load cluster, all RVV 1.0
// load forms.
//
// The model below is written against an INDEPENDENT data representation:
// expected state is a byte array exp_vrf[reg][byte] filled from a byte
// addressed memory image, while the DUT keeps packed VLEN-wide registers and
// a packed group buffer. It also addresses the destination the way the spec
// describes it -- field f lives in the register group at vd + f*regs_per_field
// and element i sits at register i/elems_per_reg, byte (i%elems_per_reg)*B --
// rather than through the DUT's flat slot arithmetic, so a mistake in that
// arithmetic cannot agree with itself.
//
// Legality is likewise re-derived here from the raw instruction fields.
//
// Every case compares ALL 32 vector registers, so a beat that writes the
// wrong destination, or writes one it should have left alone, fails.
module tb_vcore_vld_ref;
  import vcore_vld_pkg::*;

  localparam int unsigned VLEN   = 128;
  localparam int unsigned BPR    = VLEN/8;          // bytes per vector register
  localparam int unsigned MEMSZ  = 16384;
  localparam int unsigned MAXQ   = 64;
  // STRESS=0: zero-latency memory, always-ready ports
  // STRESS=1: random ready, random 1..8 cycle latency, out-of-order
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

  logic [31:0] lfsr_q;
  function automatic logic [31:0] lfsr_next(input logic [31:0] v);
    return {v[30:0], v[31]^v[21]^v[1]^v[0]};
  endfunction
  always @(posedge clk) lfsr_q <= lfsr_next(lfsr_q);

  // ---------------- architectural state models ----------------
  logic [VLEN-1:0] vrf [32];
  logic [7:0]      mem [MEMSZ];
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

  assign vrf_wr_ready = (STRESS == 0) ? 1'b1 : lfsr_q[7];
  always @(posedge clk)
    if (rst_n && vrf_wr_valid && vrf_wr_ready) vrf[vrf_wr_req.vd_addr] <= vrf_wr_data;

  // ---------------- tagged out-of-order memory model ----------------
  logic                 q_valid [MAXQ];
  logic [VLD_TAG_W-1:0] q_tag   [MAXQ];
  logic [63:0]          q_data  [MAXQ];
  logic                 q_err   [MAXQ];
  int unsigned          q_wait  [MAXQ];
  int unsigned          q_rot_q;
  int unsigned          rsp_sel;
  int unsigned          mem_reqs_seen, mem_peak_inflight, mem_inflight;
  // Any access that touches [flt_lo, flt_hi] answers with error=1. An empty
  // window is flt_lo > flt_hi.
  logic [31:0]          flt_lo, flt_hi;

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

  function automatic logic addr_faults(input logic [31:0] addr, input int unsigned nbytes);
    for (int b = 0; b < 8; b++)
      if (b < nbytes) begin
        logic [31:0] a = addr + 32'(b);
        if ((flt_lo <= flt_hi) && (a >= flt_lo) && (a <= flt_hi)) return 1'b1;
      end
    return 1'b0;
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
        q_err  [free_s] <= addr_faults(mem_req.addr, 1 << mem_req.size);
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
  logic        saw_last_q, saw_illegal_q, saw_memerr_q, saw_trim_q;
  logic [16:0] saw_new_vl_q;
  int unsigned beats_seen_q;
  logic clr_flags;
  assign commit_ready = (STRESS == 0) ? 1'b1 : lfsr_q[15];
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

  // ---------------- reference model ----------------
  logic        ref_illegal, ref_memerr, ref_trim;
  logic [16:0] ref_new_vl;
  int unsigned ref_beats;
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
      64: return     w[lane*64 +: 32];   // low XLEN bits
      default: return '0;
    endcase
  endfunction

  task automatic ref_exec(
    input logic [31:0] inst,
    input logic [31:0] base,
    input logic [31:0] stride_in,
    input int unsigned sew_c,
    input logic [2:0]  vlmul_c,
    input logic        vta, vma, vill,
    input int unsigned vl, vstart,
    input logic [VLEN-1:0] mask
  );
    int unsigned nf_f, mop, lumop, width, vd, vs2;
    int unsigned deb, ieb, sb, ln, ld, en, ed, regs, iregs, ien, ied;
    int unsigned nf_val, nreg, vlmax, epr, spf, evl, total_regs, eb;
    logic mew, vmb, bad, is_idx, is_whole, is_mask, is_fof;
    logic vta_e, vma_e, vm_e;
    logic [31:0] stride_eff, ea, a;
    int unsigned first_fault;
    logic        faulted;
    logic take_old, take_ones;
    begin
      nf_f  = int'(inst[31:29]);
      mew   = inst[28];
      mop   = int'(inst[27:26]);
      vmb   = inst[25];
      lumop = int'(inst[24:20]);
      vs2   = int'(inst[24:20]);
      width = int'(inst[14:12]);
      vd    = int'(inst[11:7]);

      bad = 1'b0;
      if (inst[6:0] != 7'h07) bad = 1'b1;
      if (mew) bad = 1'b1;
      if (vill) bad = 1'b1;

      ieb = eew_bits_of_width(3'(width));      // width field -> element width
      sb  = sew_bits_of(sew_c);
      if (ieb == 0) bad = 1'b1;
      if (sb  == 0) begin sb = 8; bad = 1'b1; end

      nf_val   = nf_f + 1;
      nreg     = 1;
      is_idx   = (mop == 1) || (mop == 3);
      is_whole = 1'b0;
      is_mask  = 1'b0;
      is_fof   = 1'b0;

      if (mop == 0) begin
        case (lumop)
          32'h00: ;                       // unit-stride
          32'h10: is_fof = 1'b1;
          32'h0b: begin
            is_mask = 1'b1;
            if ((width != 0) || !vmb || (nf_f != 0)) bad = 1'b1;
          end
          32'h08: begin
            is_whole = 1'b1;
            if (!vmb) bad = 1'b1;
            case (nf_f)
              0: nreg = 1; 1: nreg = 2; 3: nreg = 4; 7: nreg = 8;
              default: bad = 1'b1;
            endcase
            nf_val = 1;
          end
          default: bad = 1'b1;
        endcase
      end else if (mop != 1 && mop != 2 && mop != 3) bad = 1'b1;

      // data element width
      deb = is_idx ? sb : ieb;
      if (deb == 0) begin deb = 8; bad = 1'b1; end
      eb  = deb / 8;

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

      // data EMUL as a rational
      if (is_idx)      begin en = ln;          ed = ld;      end
      else if (is_mask) begin en = 1;          ed = 1;       end
      else              begin en = deb * ln;   ed = sb * ld; end

      if (is_whole) regs = nreg;
      else begin
        if ((en * 8 < ed) || (en > ed * 8)) bad = 1'b1;
        regs = (en + ed - 1) / ed;
        if (regs < 1) regs = 1;
      end
      if (regs > 8) begin regs = 8; bad = 1'b1; end

      // index EMUL
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
        if ((nreg > 1) && ((vd % nreg) != 0)) bad = 1'b1;
      end else if ((en >= ed) && (regs > 1) && ((vd % regs) != 0)) bad = 1'b1;

      vlmax = (ln * VLEN) / (ld * sb);
      if (!is_whole && ((vlmax == 0) || (vl > vlmax))) bad = 1'b1;
      if (!vmb && !is_mask && !is_whole && (vd == 0)) bad = 1'b1;
      if (is_idx && (nf_val > 1)) begin
        if ((vd < vs2 + iregs) && (vs2 < vd + total_regs)) bad = 1'b1;
      end

      epr = VLEN / deb;
      spf = regs * epr;

      // effective length and policy
      if (is_mask)       begin evl = (vl + 7) / 8; vta_e = 1'b1; vma_e = 1'b1; vm_e = 1'b1; end
      else if (is_whole) begin evl = spf;          vta_e = 1'b1; vma_e = 1'b1; vm_e = 1'b1; end
      else               begin evl = vl;           vta_e = vta;  vma_e = vma;  vm_e = vmb; end

      if (is_mask)        stride_eff = 32'd1;
      else if (is_whole)  stride_eff = 32'(eb);
      else if (mop == 2)  stride_eff = stride_in;
      else                stride_eff = 32'(nf_val * eb);

      // snapshot the architectural state as the baseline
      for (int r = 0; r < 32; r++)
        for (int b = 0; b < BPR; b++)
          exp_vrf[r][b] = vrf[r][b*8 +: 8];

      ref_illegal = bad;
      ref_memerr  = 1'b0;
      ref_trim    = 1'b0;
      ref_new_vl  = '0;
      ref_beats   = bad ? 1 : total_regs;
      if (bad) return;

      // per-element base address
      ea = base;
      for (int i = 0; i < 256; i++) ea_arr[i] = '0;
      for (int i = 0; i < int'(spf); i++) begin
        ea_arr[i] = is_idx ? (base + idx_of(vs2, ieb, i)) : ea;
        ea = ea + stride_eff;
      end

      // which active element faults first?
      first_fault = spf + 1;
      for (int i = 0; i < int'(evl); i++) begin
        if ((i >= int'(vstart)) && (vm_e || mask[i])) begin
          faulted = 1'b0;
          for (int f = 0; f < int'(nf_val); f++)
            if (addr_faults(ea_arr[i] + 32'(f*eb), eb)) faulted = 1'b1;
          if (faulted && (first_fault > int'(spf))) first_fault = i;
        end
      end

      if (first_fault <= int'(spf)) begin
        if (is_fof && (first_fault != 0)) begin
          ref_trim   = 1'b1;
          ref_new_vl = 17'(first_fault);
          evl        = first_fault;          // trimmed: those elements become tail
        end else begin
          ref_memerr = 1'b1;                 // trap, nothing written
          return;
        end
      end

      // fill the destination, addressed the way the spec describes it
      for (int f = 0; f < int'(nf_val); f++) begin
        for (int i = 0; i < int'(spf); i++) begin
          take_old  = 1'b0;
          take_ones = 1'b0;
          if (vstart >= evl)            take_old = 1'b1;
          else if (i < int'(vstart))    take_old = 1'b1;
          else if (i >= int'(evl))      begin take_ones = vta_e; take_old = !vta_e; end
          else if (!vm_e && !mask[i])   begin take_ones = vma_e; take_old = !vma_e; end
          a = ea_arr[i] + 32'(f*eb);
          for (int b = 0; b < int'(eb); b++) begin
            int unsigned dreg  = vd + f*regs + (i / epr);
            int unsigned dbyte = (i % epr)*eb + b;
            if (take_ones)      exp_vrf[dreg % 32][dbyte] = 8'hff;
            else if (!take_old) exp_vrf[dreg % 32][dbyte] = mem[(int'(a) + b) % MEMSZ];
          end
        end
      end
    end
  endtask

  // ---------------- driver ----------------
  int unsigned pass_cnt, fail_cnt, legal_cnt, illegal_cnt, trim_cnt, err_cnt;

  function automatic logic [31:0] mk_inst(
    input logic [2:0] width, input logic vmb, input logic [4:0] vd,
    input logic [4:0] lumop, input logic [2:0] nf = 3'b000,
    input logic mew = 1'b0, input logic [1:0] mop = 2'b00
  );
    return {nf, mew, mop, vmb, lumop, 5'd1, width, vd, 7'h07};
  endfunction

  task automatic run_case(
    input string          name,
    input logic [31:0]    inst,
    input logic [31:0]    base,
    input logic [31:0]    stride_in,
    input int unsigned    sew_c,
    input logic [2:0]     vlmul_c,
    input logic           vta, vma, vill,
    input int unsigned    vl, vstart
  );
    logic [VLEN-1:0] mask;
    logic mismatch;
    begin
      mask = vrf[0]; // v0 snapshot, exactly what TOP would hand over
      ref_exec(inst, base, stride_in, sew_c, vlmul_c, vta, vma, vill, vl, vstart, mask);

      @(negedge clk);
      clr_flags = 1'b1;
      @(negedge clk);
      clr_flags = 1'b0;
      cmd = '0;
      cmd.inst = inst; cmd.base = base; cmd.stride = stride_in;
      cmd.sew = 3'(sew_c); cmd.vlmul = vlmul_c;
      cmd.vta = vta; cmd.vma = vma; cmd.vill = vill;
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
      repeat (4) @(negedge clk);

      mismatch = 1'b0;
      if (saw_illegal_q !== ref_illegal) begin
        $display("FAIL %s: illegal_op got=%0b exp=%0b", name, saw_illegal_q, ref_illegal);
        mismatch = 1'b1;
      end
      if (saw_memerr_q !== ref_memerr) begin
        $display("FAIL %s: mem_error got=%0b exp=%0b", name, saw_memerr_q, ref_memerr);
        mismatch = 1'b1;
      end
      if (saw_trim_q !== ref_trim) begin
        $display("FAIL %s: vl_trimmed got=%0b exp=%0b", name, saw_trim_q, ref_trim);
        mismatch = 1'b1;
      end
      if (ref_trim && (saw_new_vl_q !== ref_new_vl)) begin
        $display("FAIL %s: new_vl got=%0d exp=%0d", name, saw_new_vl_q, ref_new_vl);
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
      if (ref_illegal) illegal_cnt++; else legal_cnt++;
      if (ref_trim) trim_cnt++;
      if (ref_memerr) err_cnt++;
    end
  endtask

  task automatic seed_state(input int unsigned salt);
    begin
      for (int r = 0; r < 32; r++)
        for (int b = 0; b < BPR; b++)
          vrf[r][b*8 +: 8] = 8'(((r*37) ^ (b*91) ^ (int'(salt)*13)) + 165);
      for (int a = 0; a < MEMSZ; a++)
        mem[a] = 8'((a*7) ^ (int'(salt)*29) ^ (a >> 5));
    end
  endtask

  // Fill the index registers with small, non-monotonic byte offsets so an
  // indexed load actually gathers rather than walking linearly.
  task automatic seed_index(
    input int unsigned vs2, input int unsigned idx_bits, input int unsigned n,
    input int unsigned span, input int unsigned salt
  );
    int unsigned per_reg, r, lane, v;
    begin
      per_reg = VLEN / idx_bits;
      for (int i = 0; i < int'(n); i++) begin
        r    = vs2 + (i / per_reg);
        lane = i % per_reg;
        v    = (((i * 37) + salt * 11) % span);
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

  property p_no_spurious_rsp;
    disable iff (!rst_n)
    (mem_rsp_valid && mem_rsp_ready) |-> (mem_inflight != 0);
  endproperty
  assert property (p_no_spurious_rsp) else $error("response with nothing in flight");

  property p_busy_covers_inflight;
    disable iff (!rst_n)
    (mem_inflight != 0) |-> busy;
  endproperty
  assert property (p_busy_covers_inflight) else $error("busy_o low with requests in flight");

  // ---------------- illegal-encoding table ----------------
  localparam int unsigned NBAD = 22;
  logic [2:0] bad_nf    [NBAD];
  logic       bad_mew   [NBAD];
  logic [1:0] bad_mop   [NBAD];
  logic [4:0] bad_lumop [NBAD];
  logic [2:0] bad_w     [NBAD];
  logic       bad_vm    [NBAD];
  logic [4:0] bad_vd    [NBAD];

  function automatic string bad_why(input int i);
    case (i)
      0:  return "mew=1 (EEW>64)";
      1:  return "reserved lumop=00001";
      2:  return "reserved lumop=01001";
      3:  return "width=010 is flw";
      4:  return "width=011 is fld";
      5:  return "width=001 is flh";
      6:  return "width=100 is flq";
      7:  return "vlm.v with width!=000";
      8:  return "vlm.v masked (vm=0)";
      9:  return "vlm.v with nf!=0";
      10: return "masked load with vd==v0";
      11: return "vd misaligned to EMUL";
      12: return "EMUL > 8";
      13: return "EMUL < 1/8";
      14: return "vill set";
      15: return "vl > VLMAX";
      16: return "whole-register masked (vm=0)";
      17: return "whole-register nf=2 reserved";
      18: return "whole-register vd misaligned";
      19: return "segment EMUL*NFIELDS > 8";
      20: return "segment nf*regs > 8";
      21: return "indexed EMUL out of range";
      default: return "?";
    endcase
  endfunction

  task automatic init_bad_table();
    begin
      for (int i = 0; i < NBAD; i++) begin
        bad_nf[i] = 3'b000; bad_mew[i] = 1'b0; bad_mop[i] = 2'b00;
        bad_lumop[i] = 5'b00000; bad_w[i] = 3'b110; bad_vm[i] = 1'b1; bad_vd[i] = 5'd8;
      end
      bad_mew[0]    = 1'b1;
      bad_lumop[1]  = 5'b00001;
      bad_lumop[2]  = 5'b01001;
      bad_w[3]      = 3'b010;
      bad_w[4]      = 3'b011;
      bad_w[5]      = 3'b001;
      bad_w[6]      = 3'b100;
      bad_lumop[7]  = 5'b01011; bad_w[7]  = 3'b110; bad_vd[7]  = 5'd12;
      bad_lumop[8]  = 5'b01011; bad_w[8]  = 3'b000; bad_vm[8]  = 1'b0; bad_vd[8] = 5'd12;
      bad_lumop[9]  = 5'b01011; bad_w[9]  = 3'b000; bad_nf[9]  = 3'b001; bad_vd[9] = 5'd12;
      bad_vm[10]    = 1'b0; bad_vd[10] = 5'd0;
      bad_vd[11]    = 5'd9;        // EMUL=2 at SEW32/LMUL2/EEW32
      bad_w[12]     = 3'b111;      // EEW=64 with SEW=8, LMUL=8 -> EMUL 64
      bad_w[13]     = 3'b000;      // EEW=8 with SEW=64, LMUL=1/8 -> EMUL 1/64
      bad_lumop[16] = 5'b01000; bad_vm[16] = 1'b0;
      bad_lumop[17] = 5'b01000; bad_nf[17] = 3'b010;
      bad_lumop[18] = 5'b01000; bad_nf[18] = 3'b001; bad_vd[18] = 5'd9;
      bad_nf[19]    = 3'b100;      // nf=5 with EMUL=2 -> 10 > 8
      bad_nf[20]    = 3'b111;      // nf=8 with EMUL=2 -> 16 registers
      bad_mop[21]   = 2'b01; bad_w[21] = 3'b111;  // index EEW=64 with SEW=8,LMUL=8
    end
  endtask

  // ---------------- test program ----------------
  logic [2:0] W8, W16, W32, W64;
  logic [4:0] LU_UNIT, LU_WHOLE, LU_MASK, LU_FOF;
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
    LU_UNIT = 5'b00000; LU_WHOLE = 5'b01000; LU_MASK = 5'b01011; LU_FOF = 5'b10000;
    widths[0] = W8; widths[1] = W16; widths[2] = W32; widths[3] = W64;
    lmuls[0] = 3'b101; lmuls[1] = 3'b110; lmuls[2] = 3'b111;
    lmuls[3] = 3'b000; lmuls[4] = 3'b001; lmuls[5] = 3'b010; lmuls[6] = 3'b011;

    lfsr_q = 32'h1234_5678;
    cyc = 0; pass_cnt = 0; fail_cnt = 0;
    legal_cnt = 0; illegal_cnt = 0; trim_cnt = 0; err_cnt = 0;
    cmd_valid = 1'b0; cmd = '0; flush = 1'b0; clr_flags = 1'b0;
    flt_lo = 32'd1; flt_hi = 32'd0;      // empty fault window
    init_bad_table();
    rst_n = 1'b0;
    seed_state(1);
    repeat (6) @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    // ===== sweep 1: unit-stride across EEW x SEW x LMUL x vl x policy =====
    begin
      int unsigned case_no = 0;
      for (int wi = 0; wi < 4; wi++)
        for (int sc = 0; sc < 4; sc++)
          for (int li = 0; li < 7; li++)
            for (int vi = 0; vi < 5; vi++)
              for (int pol = 0; pol < 4; pol++) begin
                int unsigned vlmax_s, vl_s, vstart_s, base_s;
                logic vta_s, vma_s, vm_s;
                vlmax_s = vlmax_of(sc, lmuls[li]);
                case (vi)
                  0: vl_s = 0;
                  1: vl_s = 1;
                  2: vl_s = (vlmax_s > 1) ? vlmax_s/2 : vlmax_s;
                  3: vl_s = (vlmax_s > 0) ? vlmax_s-1 : 0;
                  default: vl_s = vlmax_s;
                endcase
                vstart_s = (vi == 3) ? 1 : ((pol == 3) ? ((vl_s > 2) ? 2 : vl_s) : 0);
                vta_s = pol[0]; vma_s = pol[1];
                vm_s  = (pol == 0) || (pol == 3);
                base_s = 1024 + (case_no % 7) * 8 + ((case_no % 3) == 0 ? 1 : 0);
                seed_state(case_no + 3);
                run_case($sformatf("u[%0d] w%0d sew%0d lmul%03b vl%0d vs%0d vm%0b ta%0b ma%0b",
                                   case_no, eew_bits_of_width(widths[wi]), sew_bits_of(sc),
                                   lmuls[li], vl_s, vstart_s, vm_s, vta_s, vma_s),
                         mk_inst(widths[wi], vm_s, 5'd8, LU_UNIT),
                         32'(base_s), 32'd0, sc, lmuls[li], vta_s, vma_s, 1'b0, vl_s, vstart_s);
                case_no++;
              end
    end

    // ===== sweep 2: vlm.v =====
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
            run_case($sformatf("vlm[%0d] sew%0d lmul%03b vl%0d vs%0d",
                               case_no, sew_bits_of(sc), lmuls[li], vl_s, vstart_s),
                     mk_inst(W8, 1'b1, 5'd12, LU_MASK),
                     32'(2048 + case_no), 32'd0, sc, lmuls[li], 1'b0, 1'b0, 1'b0,
                     vl_s, vstart_s);
            case_no++;
          end
    end

    // ===== sweep 3: strided, including zero and negative strides =====
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
                0: str = 32'(eb);                      // contiguous
                1: str = 32'd3;                        // overlapping, unaligned
                2: str = 32'd0;                        // every element same address
                default: str = -32'(eb);               // negative
              endcase
              vm_s = (si != 1);
              seed_state(300 + case_no);
              run_case($sformatf("s[%0d] w%0d sew%0d lmul%03b vl%0d stride%0d vm%0b",
                                 case_no, eew_bits_of_width(widths[wi]), sew_bits_of(sc),
                                 lmuls[li], vl_s, $signed(str), vm_s),
                       mk_inst(widths[wi], vm_s, 5'd8, 5'd2, 3'b000, 1'b0, 2'b10),
                       32'd8192, str, sc, lmuls[li], 1'b1, 1'b1, 1'b0, vl_s, 0);
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
              vm_s = (case_no % 3) != 0;
              seed_state(600 + case_no);
              seed_index(16, eew_bits_of_width(widths[wi]),
                         (vlmax_s > 0) ? vlmax_s : 1, 512, case_no);
              run_case($sformatf("x[%0d] idx%0d sew%0d lmul%03b vl%0d %s vm%0b",
                                 case_no, eew_bits_of_width(widths[wi]), sew_bits_of(sc),
                                 lmuls[li], vl_s, (oi != 0) ? "ord" : "unord", vm_s),
                       mk_inst(widths[wi], vm_s, 5'd8, 5'd16, 3'b000, 1'b0,
                               (oi != 0) ? 2'b11 : 2'b01),
                       32'd4096, 32'd0, sc, lmuls[li], 1'b1, 1'b1, 1'b0, vl_s, 0);
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
                       mk_inst(widths[wi], vm_s, 5'd8, LU_UNIT, 3'(nf-1)),
                       32'd6144, 32'd0, sc, seg_lmuls[li], 1'b1, 1'b1, 1'b0, vl_s, 0);
              case_no++;
            end
    end

    // ===== sweep 6: segment strided and segment indexed =====
    begin
      int unsigned case_no = 0;
      int unsigned nfs [3];
      nfs[0] = 2; nfs[1] = 3; nfs[2] = 8;
      for (int ni = 0; ni < 3; ni++)
        for (int wi = 0; wi < 4; wi++)
          for (int form = 0; form < 2; form++)
            for (int li = 0; li < 2; li++) begin
              int unsigned vlmax_s, vl_s, sc, nf, eb;
              logic [2:0] lm;
              sc = 2;
              lm = (li == 0) ? 3'b111 : 3'b000;
              nf = nfs[ni];
              eb = eew_bits_of_width(widths[wi]) / 8;
              vlmax_s = vlmax_of(sc, lm);
              vl_s = vlmax_s;
              seed_state(1200 + case_no);
              if (form == 1)
                seed_index(16, eew_bits_of_width(widths[wi]),
                           (vlmax_s > 0) ? vlmax_s : 1, 256, case_no);
              run_case($sformatf("segx[%0d] nf%0d w%0d lmul%03b %s",
                                 case_no, nf, eew_bits_of_width(widths[wi]), lm,
                                 (form != 0) ? "indexed" : "strided"),
                       mk_inst(widths[wi], 1'b1, 5'd8, (form != 0) ? 5'd16 : 5'd2,
                               3'(nf-1), 1'b0, (form != 0) ? 2'b01 : 2'b10),
                       32'd10240, 32'(nf*eb + 4), sc, lm, 1'b1, 1'b1, 1'b0, vl_s, 0);
              case_no++;
            end
    end

    // ===== sweep 7: whole-register loads =====
    begin
      int unsigned case_no = 0;
      int unsigned nregs [4];
      logic [2:0]  nfenc [4];
      nregs[0] = 1; nregs[1] = 2; nregs[2] = 4; nregs[3] = 8;
      nfenc[0] = 3'd0; nfenc[1] = 3'd1; nfenc[2] = 3'd3; nfenc[3] = 3'd7;
      for (int ri = 0; ri < 4; ri++)
        for (int wi = 0; wi < 4; wi++)
          for (int vi = 0; vi < 2; vi++) begin
            int unsigned vstart_s;
            vstart_s = (vi == 0) ? 0 : 3;
            seed_state(1500 + case_no);
            // vtype is ignored by these, so drive a deliberately mismatched one
            run_case($sformatf("whole[%0d] nreg%0d w%0d vs%0d",
                               case_no, nregs[ri], eew_bits_of_width(widths[wi]), vstart_s),
                     mk_inst(widths[wi], 1'b1, 5'd8, LU_WHOLE, nfenc[ri]),
                     32'd12288, 32'd0, 1, 3'b010, 1'b0, 1'b0, 1'b0, 4, vstart_s);
            case_no++;
          end
    end

    // ===== sweep 8: fault-only-first =====
    begin
      int unsigned case_no = 0;
      int unsigned ks [5];
      ks[0] = 0; ks[1] = 1; ks[2] = 2; ks[3] = 5; ks[4] = 99;  // 99 = no fault
      for (int ki = 0; ki < 5; ki++)
        for (int wi = 0; wi < 4; wi++)
          for (int ni = 0; ni < 2; ni++) begin
            int unsigned eb, nf, vl_s, base_s, k;
            base_s = 14336;
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
            run_case($sformatf("fof[%0d] w%0d nf%0d fault_at%0d",
                               case_no, eew_bits_of_width(widths[wi]), nf, k),
                     mk_inst(widths[wi], 1'b1, 5'd8, LU_FOF, 3'(nf-1)),
                     32'(base_s), 32'd0, 2, 3'b000, 1'b1, 1'b1, 1'b0, vl_s, 0);
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
        if (i == 21) begin sc = 0; lm = 3'b011; vl_s = 128; end
        seed_state(2100 + i);
        run_case($sformatf("bad[%0d] %s", i, bad_why(i)),
                 mk_inst(bad_w[i], bad_vm[i], bad_vd[i], bad_lumop[i],
                         bad_nf[i], bad_mew[i], bad_mop[i]),
                 32'd256, 32'd4, sc, lm, 1'b1, 1'b1, vill_s, vl_s, 0);
      end
    end

    // ===== sweep 10: legal boundaries =====
    begin
      seed_state(2300);
      run_case("edge EMUL=8 (EEW64,SEW8,LMUL1)",
               mk_inst(W64, 1'b1, 5'd8, LU_UNIT), 32'd64, 32'd0, 0, 3'b000,
               1'b1, 1'b1, 1'b0, 16, 0);
      seed_state(2301);
      run_case("edge EMUL=1/8 (EEW8,SEW64,LMUL1)",
               mk_inst(W8, 1'b1, 5'd8, LU_UNIT), 32'd64, 32'd0, 3, 3'b000,
               1'b1, 1'b1, 1'b0, 2, 0);
      seed_state(2302);
      run_case("edge unmasked vd=v0",
               mk_inst(W32, 1'b1, 5'd0, LU_UNIT), 32'd64, 32'd0, 2, 3'b000,
               1'b1, 1'b1, 1'b0, 4, 0);
      seed_state(2303);
      run_case("edge vstart > vl (nothing updated)",
               mk_inst(W32, 1'b1, 5'd8, LU_UNIT), 32'd64, 32'd0, 2, 3'b001,
               1'b1, 1'b1, 1'b0, 4, 9);
      seed_state(2304);
      run_case("edge unaligned base (byte offset 3)",
               mk_inst(W32, 1'b1, 5'd8, LU_UNIT), 32'd67, 32'd0, 2, 3'b001,
               1'b1, 1'b1, 1'b0, 8, 0);
      seed_state(2305);
      run_case("edge segment nf=8 EMUL=1",
               mk_inst(W32, 1'b1, 5'd8, LU_UNIT, 3'd7), 32'd3072, 32'd0, 2, 3'b000,
               1'b1, 1'b1, 1'b0, 4, 0);
      seed_state(2306);
      seed_index(16, 32, 4, 256, 7);
      run_case("edge indexed vd overlaps index group (legal, non-segment)",
               mk_inst(W32, 1'b1, 5'd16, 5'd16, 3'b000, 1'b0, 2'b01),
               32'd4096, 32'd0, 2, 3'b000, 1'b1, 1'b1, 1'b0, 4, 0);
      seed_state(2307);
      run_case("edge whole-register vstart >= evl",
               mk_inst(W32, 1'b1, 5'd8, LU_WHOLE, 3'd0), 32'd12288, 32'd0, 2, 3'b000,
               1'b1, 1'b1, 1'b0, 4, 40);
    end

    $display("REF TOTAL: %0d cases, %0d passed, %0d failed (peak inflight %0d, %0d requests)",
             pass_cnt+fail_cnt, pass_cnt, fail_cnt, mem_peak_inflight, mem_reqs_seen);
    $display("REF MIX  : %0d executed, %0d rejected as illegal, %0d vl-trimmed, %0d trapped",
             legal_cnt, illegal_cnt, trim_cnt, err_cnt);
    if (fail_cnt != 0) $fatal(1, "reference mismatch");
    $finish;
  end

  initial begin
    #400_000_000;
    $fatal(1, "global timeout");
  end
endmodule
