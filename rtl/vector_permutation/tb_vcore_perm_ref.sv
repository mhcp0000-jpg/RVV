// Golden-reference cross-check for every RVV 1.0 permutation-class
// instruction this cluster claims.
//
// The reference model below is written from the spec text, in a different
// representation from the RTL: elements live in a flat unpacked array
// indexed by global element number, not as shift/mask extractions out of a
// 1024-bit group buffer. A bug that the RTL and a paraphrase of the RTL
// would share does not survive that.
//
// Agnostic regions (vta=1 tail, vma=1 inactive, and mask-destination tails,
// which RVV 1.0 5.4 makes agnostic regardless of vta) are pinned to
// all-ones, which is the legal choice this implementation makes.
module tb_vcore_perm_ref #(
  parameter bit          STRESS = 1'b0,
  parameter int unsigned NRAND  = 400,
  parameter int unsigned SEED   = 32'h5EED_1234
);
  import vcore_perm_pkg::*;

  localparam int VLENB = 128;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic cmd_valid, cmd_ready;        vcore_perm_cmd_t cmd;
  logic rd_valid, rd_ready;          vcore_vrf_read_req_t rd_req;
  logic rd_rsp_valid, rd_rsp_ready;  logic [127:0] rd_rsp_data;
  logic wr_valid, wr_ready;          vcore_vrf_write_req_t wr_req;
  logic [127:0] wr_data;
  logic sc_valid, sc_ready;          vcore_scalar_write_req_t sc_req;
  logic [31:0] sc_data;
  logic commit_valid, commit_ready;  vcore_perm_commit_t commit;

  vcore_perm_top #(.VLEN(128)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .vrf_read_valid_o(rd_valid), .vrf_read_ready_i(rd_ready), .vrf_read_req_o(rd_req),
    .vrf_read_rsp_valid_i(rd_rsp_valid), .vrf_read_rsp_ready_o(rd_rsp_ready),
    .vrf_read_rsp_data_i(rd_rsp_data),
    .vrf_write_valid_o(wr_valid), .vrf_write_ready_i(wr_ready),
    .vrf_write_req_o(wr_req), .vrf_write_data_o(wr_data),
    .scalar_write_valid_o(sc_valid), .scalar_write_ready_i(sc_ready),
    .scalar_write_req_o(sc_req), .scalar_write_data_o(sc_data),
    .commit_valid_o(commit_valid), .commit_ready_i(commit_ready), .commit_o(commit)
  );

  // ---------------- behavioural VRF ----------------
  logic [127:0] vrf     [0:31];
  logic [127:0] exp_vrf [0:31];
  logic [127:0] rd_data_q;
  logic         rd_busy_q;
  logic [1:0]   rd_delay_q;
  logic [15:0]  lfsr_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) lfsr_q <= 16'hBEEF;
    else lfsr_q <= {lfsr_q[14:0], lfsr_q[15]^lfsr_q[13]^lfsr_q[12]^lfsr_q[10]};
  end
  assign rd_ready = STRESS ? (!rd_busy_q && lfsr_q[0]) : !rd_busy_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rd_busy_q <= 0; rd_delay_q <= 0; rd_data_q <= '0; end
    else if (!rd_busy_q) begin
      if (rd_valid && rd_ready) begin
        rd_busy_q <= 1'b1; rd_data_q <= vrf[rd_req.addr];
        rd_delay_q <= STRESS ? lfsr_q[5:4] : 2'd0;
      end
    end else if (rd_delay_q != 0) rd_delay_q <= rd_delay_q - 1'b1;
    else if (rd_rsp_valid && rd_rsp_ready) rd_busy_q <= 1'b0;
  end
  assign rd_rsp_valid = rd_busy_q && (rd_delay_q == 0);
  assign rd_rsp_data  = rd_data_q;

  assign wr_ready = STRESS ? lfsr_q[1] : 1'b1;
  always_ff @(posedge clk) if (wr_valid && wr_ready) vrf[wr_req.vd_addr] <= wr_data;

  logic [31:0] got_sc_data; logic got_sc, got_sc_fp; logic [4:0] got_sc_addr;
  assign sc_ready = STRESS ? lfsr_q[2] : 1'b1;
  always_ff @(posedge clk) if (sc_valid && sc_ready) begin
    got_sc <= 1'b1; got_sc_data <= sc_data;
    got_sc_fp <= sc_req.is_fp; got_sc_addr <= sc_req.rd_addr;
  end
  assign commit_ready = STRESS ? lfsr_q[3] : 1'b1;

  // ---------------- element helpers ----------------
  // 5-bit signed immediate, sign-extended to 64 bits (vmv.v.i / vmerge.vim).
  // The gather and slide immediates are zero-extended instead.
  function automatic logic [63:0] simm5(input logic [31:0] v);
    simm5 = {{59{v[4]}}, v[4:0]};
  endfunction

  function automatic logic [63:0] m64(input int sewb);
    m64 = (sewb >= 64) ? 64'hFFFF_FFFF_FFFF_FFFF : ((64'd1 << sewb) - 64'd1);
  endfunction

  function automatic logic [63:0] get_e(input int base, input int idx, input int sewb);
    int epr; logic [127:0] w;
    epr = VLENB / sewb;
    w = vrf[base + idx/epr] >> ((idx % epr) * sewb);
    get_e = w[63:0] & m64(sewb);
  endfunction

  task automatic put_e(input int base, input int idx, input int sewb, input logic [63:0] v);
    int epr; logic [127:0] m, d;
    epr = VLENB / sewb;
    m = 128'(m64(sewb)) << ((idx % epr) * sewb);
    d = 128'(v & m64(sewb)) << ((idx % epr) * sewb);
    exp_vrf[base + idx/epr] = (exp_vrf[base + idx/epr] & ~m) | d;
  endtask

  // ---------------- test-case description ----------------
  typedef enum int {
    O_RGATHER_VV, O_RGATHER_VX, O_RGATHER_VI, O_RGATHEREI16,
    O_SLIDEUP_VX, O_SLIDEUP_VI, O_SLIDEDOWN_VX, O_SLIDEDOWN_VI,
    O_SLIDE1UP, O_FSLIDE1UP, O_SLIDE1DOWN, O_FSLIDE1DOWN,
    O_COMPRESS,
    O_MERGE_VVM, O_MERGE_VXM, O_MERGE_VIM, O_FMERGE,
    O_MV_V_V, O_MV_V_X, O_MV_V_I, O_FMV_V_F,
    O_MV_X_S, O_FMV_F_S, O_MV_S_X, O_FMV_S_F,
    O_MV1R, O_MV2R, O_MV4R, O_MV8R,
    O_IOTA, O_ID, O_MSBF, O_MSOF, O_MSIF
  } top_e;

  // one register per mnemonic, for the coverage report
  int unsigned hit_count [O_RGATHER_VV:O_MSIF];

  top_e        t_op;
  int          t_sewb, t_beats, t_frac, t_vlmax, t_vl, t_vstart;
  logic        t_vta, t_vma, t_vm;
  int          t_vd, t_vs1, t_vs2;
  logic [31:0] t_scalar;
  logic [127:0] t_v0;

  function automatic logic [31:0] mkinst(
    input logic [5:0] f6, input logic vm, input logic [4:0] vs2,
    input logic [4:0] vs1, input logic [2:0] f3, input logic [4:0] vd);
    mkinst = {f6, vm, vs2, vs1, f3, vd, 7'h57};
  endfunction

  function automatic logic [31:0] enc();
    logic [4:0] vd, vs1, vs2; logic vm;
    vd = 5'(t_vd); vs1 = 5'(t_vs1); vs2 = 5'(t_vs2); vm = t_vm;
    case (t_op)
      O_RGATHER_VV  : enc = mkinst(6'h0c, vm, vs2, vs1,        3'b000, vd);
      O_RGATHER_VX  : enc = mkinst(6'h0c, vm, vs2, 5'd0,       3'b100, vd);
      O_RGATHER_VI  : enc = mkinst(6'h0c, vm, vs2, t_scalar[4:0], 3'b011, vd);
      O_RGATHEREI16 : enc = mkinst(6'h0e, vm, vs2, vs1,        3'b000, vd);
      O_SLIDEUP_VX  : enc = mkinst(6'h0e, vm, vs2, 5'd0,       3'b100, vd);
      O_SLIDEUP_VI  : enc = mkinst(6'h0e, vm, vs2, t_scalar[4:0], 3'b011, vd);
      O_SLIDEDOWN_VX: enc = mkinst(6'h0f, vm, vs2, 5'd0,       3'b100, vd);
      O_SLIDEDOWN_VI: enc = mkinst(6'h0f, vm, vs2, t_scalar[4:0], 3'b011, vd);
      O_SLIDE1UP    : enc = mkinst(6'h0e, vm, vs2, 5'd0,       3'b110, vd);
      O_FSLIDE1UP   : enc = mkinst(6'h0e, vm, vs2, 5'd0,       3'b101, vd);
      O_SLIDE1DOWN  : enc = mkinst(6'h0f, vm, vs2, 5'd0,       3'b110, vd);
      O_FSLIDE1DOWN : enc = mkinst(6'h0f, vm, vs2, 5'd0,       3'b101, vd);
      O_COMPRESS    : enc = mkinst(6'h17, 1'b1, vs2, vs1,      3'b010, vd);
      O_MERGE_VVM   : enc = mkinst(6'h17, 1'b0, vs2, vs1,      3'b000, vd);
      O_MERGE_VXM   : enc = mkinst(6'h17, 1'b0, vs2, 5'd0,     3'b100, vd);
      O_MERGE_VIM   : enc = mkinst(6'h17, 1'b0, vs2, t_scalar[4:0], 3'b011, vd);
      O_FMERGE      : enc = mkinst(6'h17, 1'b0, vs2, 5'd0,     3'b101, vd);
      O_MV_V_V      : enc = mkinst(6'h17, 1'b1, 5'd0, vs1,     3'b000, vd);
      O_MV_V_X      : enc = mkinst(6'h17, 1'b1, 5'd0, 5'd0,    3'b100, vd);
      O_MV_V_I      : enc = mkinst(6'h17, 1'b1, 5'd0, t_scalar[4:0], 3'b011, vd);
      O_FMV_V_F     : enc = mkinst(6'h17, 1'b1, 5'd0, 5'd0,    3'b101, vd);
      O_MV_X_S      : enc = mkinst(6'h10, 1'b1, vs2, 5'd0,     3'b010, vd);
      O_FMV_F_S     : enc = mkinst(6'h10, 1'b1, vs2, 5'd0,     3'b001, vd);
      O_MV_S_X      : enc = mkinst(6'h10, 1'b1, 5'd0, 5'd0,    3'b110, vd);
      O_FMV_S_F     : enc = mkinst(6'h10, 1'b1, 5'd0, 5'd0,    3'b101, vd);
      O_MV1R        : enc = mkinst(6'h27, 1'b1, vs2, 5'd0,     3'b011, vd);
      O_MV2R        : enc = mkinst(6'h27, 1'b1, vs2, 5'd1,     3'b011, vd);
      O_MV4R        : enc = mkinst(6'h27, 1'b1, vs2, 5'd3,     3'b011, vd);
      O_MV8R        : enc = mkinst(6'h27, 1'b1, vs2, 5'd7,     3'b011, vd);
      O_IOTA        : enc = mkinst(6'h14, vm, vs2, 5'h10,      3'b010, vd);
      O_ID          : enc = mkinst(6'h14, vm, 5'd0, 5'h11,     3'b010, vd);
      O_MSBF        : enc = mkinst(6'h14, vm, vs2, 5'h01,      3'b010, vd);
      O_MSOF        : enc = mkinst(6'h14, vm, vs2, 5'h02,      3'b010, vd);
      O_MSIF        : enc = mkinst(6'h14, vm, vs2, 5'h03,      3'b010, vd);
      default       : enc = '0;
    endcase
  endfunction

  function automatic logic is_mask_dest(); 
    is_mask_dest = (t_op == O_MSBF) || (t_op == O_MSOF) || (t_op == O_MSIF);
  endfunction
  function automatic logic is_scalar_dest();
    is_scalar_dest = (t_op == O_MV_X_S) || (t_op == O_FMV_F_S);
  endfunction
  function automatic logic active(input int i);
    // active(i) = body(i) && mask(i)   (RVV 1.0 5.4)
    active = (i >= t_vstart) && (i < t_vl) && (t_vm || t_v0[i]);
  endfunction

  // ---------------- the reference model ----------------
  logic [31:0] exp_scalar; logic exp_is_scalar;

  task automatic ref_exec();
    logic [63:0] val, idx;
    int cnt, src, nreg, evl, n_packed, vtail;
    logic bit_v, found;

    for (int r = 0; r < 32; r++) exp_vrf[r] = vrf[r];
    exp_scalar = '0; exp_is_scalar = 1'b0;

    // --- scalar destination: runs even when vstart >= vl (RVV 1.0 5.4) ---
    if (is_scalar_dest()) begin
      exp_is_scalar = 1'b1;
      val = get_e(t_vs2, 0, t_sewb);
      // RV32: SEW > XLEN truncates to the low XLEN bits
      exp_scalar = val[31:0];
      return;
    end

    // --- whole-register move: ignores vtype, bounded by evl ---
    if (t_op inside {O_MV1R, O_MV2R, O_MV4R, O_MV8R}) begin
      case (t_op) O_MV1R: nreg=1; O_MV2R: nreg=2; O_MV4R: nreg=4; default: nreg=8; endcase
      evl = nreg * (VLENB / t_sewb);
      if (t_vstart < evl)
        for (int r = 0; r < nreg; r++) exp_vrf[t_vd + r] = vrf[t_vs2 + r];
      return;
    end

    // --- vmv.s.x / vfmv.s.f: element 0 only, nothing when vstart >= vl ---
    if (t_op inside {O_MV_S_X, O_FMV_S_F}) begin
      if (t_vstart == 0 && t_vl != 0) begin
        val = (t_sewb == 64) ? {{32{t_scalar[31]}}, t_scalar} : {32'd0, t_scalar};
        put_e(t_vd, 0, t_sewb, val);
      end
      return;
    end

    // "When vstart >= vl ... no elements are updated ... including that no
    //  tail elements are updated with agnostic values."
    if (t_vstart >= t_vl) return;

    // --- vcompress needs its packed count up front. RVV 1.0 16.5 counts
    //     set bits among "the first vl elements", not across VLMAX. ---
    n_packed = 0;
    if (t_op == O_COMPRESS)
      for (int j = 0; j < t_vl; j++) if (vrf[t_vs1][j]) n_packed++;

    // RVV 1.0 5.4: tail(x) = (vl <= x < max(VLMAX, VLEN/SEW)). With a
    // fractional LMUL the destination register holds more element slots than
    // VLMAX, and those extra slots are tail -- not untouched.
    vtail = (t_vlmax > (VLENB / t_sewb)) ? t_vlmax : (VLENB / t_sewb);

    for (int i = 0; i < vtail; i++) begin
      val = '0; bit_v = 1'b0;

      // ---- what the operation would produce for element i ----
      case (t_op)
        O_RGATHER_VV: begin
          idx = get_e(t_vs1, i, t_sewb);
          val = (idx < t_vlmax) ? get_e(t_vs2, int'(idx), t_sewb) : 64'd0;
        end
        O_RGATHER_VX, O_RGATHER_VI: begin
          // index comes from the scalar, zero-extended to XLEN, NOT truncated to SEW
          idx = {32'd0, t_scalar};
          val = (idx < t_vlmax) ? get_e(t_vs2, int'(idx), t_sewb) : 64'd0;
        end
        O_RGATHEREI16: begin
          idx = get_e(t_vs1, i, 16);           // index EEW is always 16
          val = (idx < t_vlmax) ? get_e(t_vs2, int'(idx), t_sewb) : 64'd0;
        end
        O_SLIDEUP_VX, O_SLIDEUP_VI: begin
          if (i >= int'(t_scalar)) begin
            src = i - int'(t_scalar);
            val = (src < t_vlmax) ? get_e(t_vs2, src, t_sewb) : 64'd0;
          end
        end
        O_SLIDEDOWN_VX, O_SLIDEDOWN_VI: begin
          src = i + int'(t_scalar);
          val = (src < t_vlmax) ? get_e(t_vs2, src, t_sewb) : 64'd0;
        end
        O_SLIDE1UP, O_FSLIDE1UP: begin
          if (i == 0) val = {32'd0, t_scalar} & m64(t_sewb);
          else        val = ((i-1) < t_vlmax) ? get_e(t_vs2, i-1, t_sewb) : 64'd0;
        end
        O_SLIDE1DOWN, O_FSLIDE1DOWN: begin
          if (i == t_vl-1) val = {32'd0, t_scalar} & m64(t_sewb);
          else             val = ((i+1) < t_vlmax) ? get_e(t_vs2, i+1, t_sewb) : 64'd0;
        end
        O_COMPRESS: begin
          // the i-th set bit of vs1 among the first vl elements
          src = -1; cnt = 0;
          for (int j = 0; j < t_vl; j++)
            if (vrf[t_vs1][j]) begin
              if (cnt == i) src = j;
              cnt++;
            end
          if (src >= 0) val = get_e(t_vs2, src, t_sewb);
        end
        O_MERGE_VVM: val = t_v0[i] ? get_e(t_vs1, i, t_sewb) : get_e(t_vs2, i, t_sewb);
        O_MERGE_VXM, O_FMERGE:
          val = t_v0[i] ? ({32'd0, t_scalar} & m64(t_sewb)) : get_e(t_vs2, i, t_sewb);
        O_MERGE_VIM:   // simm5: sign-extended, unlike the gather/slide immediates
          val = t_v0[i] ? (simm5(t_scalar) & m64(t_sewb)) : get_e(t_vs2, i, t_sewb);
        O_MV_V_V: val = get_e(t_vs1, i, t_sewb);
        O_MV_V_X, O_FMV_V_F:
          val = (t_sewb == 64) ? {{32{t_scalar[31]}}, t_scalar} : ({32'd0, t_scalar} & m64(t_sewb));
        O_MV_V_I:      // simm5
          val = simm5(t_scalar) & m64(t_sewb);
        O_IOTA: begin
          // "only the enabled elements contribute to the sum"
          cnt = 0;
          for (int j = 0; j < i; j++) if (active(j) && vrf[t_vs2][j]) cnt++;
          val = 64'(cnt);
        end
        O_ID: val = 64'(i);
        O_MSBF, O_MSOF, O_MSIF: begin
          // "before the first ACTIVE source element that is a 1"
          found = 1'b0;
          for (int j = 0; j < i; j++) if (active(j) && vrf[t_vs2][j]) found = 1'b1;
          case (t_op)
            O_MSBF: bit_v = !found && !vrf[t_vs2][i];
            O_MSOF: bit_v = !found &&  vrf[t_vs2][i];
            default: bit_v = !found;              // vmsif
          endcase
        end
        default: ;
      endcase

      // ---- destination policy ----
      if (i < t_vstart) begin
        // prestart: undisturbed
      end else if ((i >= t_vl) || (t_op == O_COMPRESS && i >= n_packed)) begin
        // tail. Mask destinations are agnostic regardless of vta (5.4).
        if (is_mask_dest())   exp_vrf[t_vd][i] = 1'b1;
        else if (t_vta)       put_e(t_vd, i, t_sewb, m64(t_sewb));
      end else if (t_op inside {O_MERGE_VVM, O_MERGE_VXM, O_MERGE_VIM, O_FMERGE}) begin
        put_e(t_vd, i, t_sewb, val);          // v0 is a selector here, not a predicate
      end else if ((t_op inside {O_SLIDEUP_VX, O_SLIDEUP_VI}) && (i < int'(t_scalar))) begin
        // 16.3.1: 0 <= i < max(vstart, OFFSET) is Unchanged, mask policy does
        // not get to overwrite it
      end else if (!t_vm && !t_v0[i]) begin
        if (is_mask_dest()) begin if (t_vma) exp_vrf[t_vd][i] = 1'b1; end
        else if (t_vma)     put_e(t_vd, i, t_sewb, m64(t_sewb));
      end else if (is_mask_dest()) begin
        exp_vrf[t_vd][i] = bit_v;
      end else begin
        put_e(t_vd, i, t_sewb, val);
      end
    end

    // mask destinations may have their whole register overwritten (5.4), and
    // this implementation does: bits past VLMAX come out as tail = 1
    if (is_mask_dest())
      for (int i = vtail; i < VLENB; i++) exp_vrf[t_vd][i] = 1'b1;
  endtask

  // ---------------- driver ----------------
  int pass_count = 0, fail_count = 0, run_count = 0;
  string t_name;

  task automatic issue_and_wait();
    cmd = '0;
    cmd.inst = enc(); cmd.scalar = t_scalar;
    case (t_sewb) 8: cmd.sew = VSEW_8; 16: cmd.sew = VSEW_16;
                 32: cmd.sew = VSEW_32; default: cmd.sew = VSEW_64; endcase
    case (t_frac)
      2: cmd.vlmul = 3'b111;
      4: cmd.vlmul = 3'b110;
      8: cmd.vlmul = 3'b101;
      default: case (t_beats) 1: cmd.vlmul=3'b000; 2: cmd.vlmul=3'b001;
                              4: cmd.vlmul=3'b010; default: cmd.vlmul=3'b011; endcase
    endcase
    cmd.vta = t_vta; cmd.vma = t_vma; cmd.vill = 1'b0;
    cmd.vl = 17'(t_vl); cmd.vstart = 17'(t_vstart);
    cmd.mask_snapshot = t_v0; cmd.tag = 16'h55;
    got_sc = 1'b0;
    cmd_valid = 1'b1;
    @(posedge clk);
    while (!cmd_ready) @(posedge clk);
    cmd_valid = 1'b0;
    forever begin
      @(posedge clk);
      if (commit_valid && commit_ready && commit.last_beat) begin
        if (commit.illegal_op) begin
          fail_count++;
          $display("[FAIL] %s : unexpectedly ILLEGAL (inst=%08h)", t_name, enc());
        end
        break;
      end
    end
    repeat (3) @(posedge clk);
  endtask

  task automatic run_case();
    bit ok;
    run_count++;
    hit_count[t_op]++;
    ref_exec();
    issue_and_wait();
    ok = 1'b1;
    for (int r = 0; r < 32; r++)
      if (vrf[r] !== exp_vrf[r]) begin
        ok = 1'b0;
        $display("[FAIL] %s : v%0d got=%032h exp=%032h", t_name, r, vrf[r], exp_vrf[r]);
      end
    if (exp_is_scalar) begin
      if (!got_sc) begin ok = 1'b0; $display("[FAIL] %s : no scalar write", t_name); end
      else if (got_sc_data !== exp_scalar) begin
        ok = 1'b0;
        $display("[FAIL] %s : scalar got=%08h exp=%08h", t_name, got_sc_data, exp_scalar);
      end
    end else if (got_sc) begin
      ok = 1'b0; $display("[FAIL] %s : unexpected scalar write", t_name);
    end
    if (ok) pass_count++; else fail_count++;
  endtask

  // fill the architectural state with something distinctive
  task automatic seed_state(input int unsigned k);
    for (int r = 0; r < 32; r++)
      for (int b = 0; b < 16; b++)
        vrf[r][b*8 +: 8] = 8'((r*16 + b) ^ k);
    t_v0 = {$urandom, $urandom, $urandom, $urandom};
  endtask

  // ---------------- coverage sweep ----------------
  function automatic string op_name(input top_e o);
    op_name = "?";
    case (o)
      O_RGATHER_VV: op_name="vrgather.vv"; O_RGATHER_VX: op_name="vrgather.vx";
      O_RGATHER_VI: op_name="vrgather.vi"; O_RGATHEREI16: op_name="vrgatherei16.vv";
      O_SLIDEUP_VX: op_name="vslideup.vx"; O_SLIDEUP_VI: op_name="vslideup.vi";
      O_SLIDEDOWN_VX: op_name="vslidedown.vx"; O_SLIDEDOWN_VI: op_name="vslidedown.vi";
      O_SLIDE1UP: op_name="vslide1up.vx"; O_FSLIDE1UP: op_name="vfslide1up.vf";
      O_SLIDE1DOWN: op_name="vslide1down.vx"; O_FSLIDE1DOWN: op_name="vfslide1down.vf";
      O_COMPRESS: op_name="vcompress.vm";
      O_MERGE_VVM: op_name="vmerge.vvm"; O_MERGE_VXM: op_name="vmerge.vxm";
      O_MERGE_VIM: op_name="vmerge.vim"; O_FMERGE: op_name="vfmerge.vfm";
      O_MV_V_V: op_name="vmv.v.v"; O_MV_V_X: op_name="vmv.v.x";
      O_MV_V_I: op_name="vmv.v.i"; O_FMV_V_F: op_name="vfmv.v.f";
      O_MV_X_S: op_name="vmv.x.s"; O_FMV_F_S: op_name="vfmv.f.s";
      O_MV_S_X: op_name="vmv.s.x"; O_FMV_S_F: op_name="vfmv.s.f";
      O_MV1R: op_name="vmv1r.v"; O_MV2R: op_name="vmv2r.v";
      O_MV4R: op_name="vmv4r.v"; O_MV8R: op_name="vmv8r.v";
      O_IOTA: op_name="viota.m"; O_ID: op_name="vid.v";
      O_MSBF: op_name="vmsbf.m"; O_MSOF: op_name="vmsof.m"; O_MSIF: op_name="vmsif.m";
    endcase
  endfunction

  function automatic logic masked_ok(input top_e o);
    // vcompress and the whole-register moves are unmasked by encoding
    masked_ok = !(o inside {O_COMPRESS, O_MV1R, O_MV2R, O_MV4R, O_MV8R,
                            O_MV_X_S, O_FMV_F_S, O_MV_S_X, O_FMV_S_F,
                            O_MV_V_V, O_MV_V_X, O_MV_V_I, O_FMV_V_F});
  endfunction

  function automatic logic vstart_ok(input top_e o);
    // 15.1/15.2/16.5 make a non-zero vstart illegal for these
    vstart_ok = !(o inside {O_COMPRESS, O_IOTA, O_MSBF, O_MSOF, O_MSIF});
  endfunction

  task automatic set_regs(input top_e o);
    t_vs2 = 0; t_vs1 = 8; t_vd = 16;
    case (o)
      O_COMPRESS:                       t_vs1 = 24;              // mask select
      O_IOTA:                           t_vs2 = 24;              // mask source
      O_MSBF, O_MSOF, O_MSIF: begin     t_vs2 = 24; t_vd = 25; end
      O_MV_X_S, O_FMV_F_S:              t_vd  = 9;               // scalar rd/fd
      O_MV1R:  begin t_vs2 = 0; t_vd = 8; end
      O_MV2R:  begin t_vs2 = 0; t_vd = 8; end
      O_MV4R:  begin t_vs2 = 0; t_vd = 8; end
      O_MV8R:  begin t_vs2 = 0; t_vd = 8; end
      default: ;
    endcase
  endtask

  // ei16 needs ceil(VLMAX*16/VLEN) index registers and that must be <= 8
  function automatic logic cfg_ok(input top_e o);
    cfg_ok = 1'b1;
    if (o == O_RGATHEREI16)
      if ((t_vlmax*16 + VLENB - 1)/VLENB > 8) cfg_ok = 1'b0;
    // whole-register moves are vtype-independent; run them at LMUL1 only
    if (o inside {O_MV1R, O_MV2R, O_MV4R, O_MV8R} && (t_beats != 1 || t_frac != 1))
      cfg_ok = 1'b0;
  endfunction

  int cfg_sew  [0:5] = '{8, 16, 32, 64, 32, 8};
  int cfg_beat [0:5] = '{1,  2,  8,  2,  1, 4};
  int cfg_frac [0:5] = '{1,  1,  1,  1,  2, 1};

  int unsigned seed_v;

  initial begin
    seed_v = SEED;
    rst_n = 0; cmd_valid = 0; got_sc = 0;
    for (int o = O_RGATHER_VV; o <= O_MSIF; o++) hit_count[o] = 0;
    for (int r = 0; r < 32; r++) vrf[r] = '0;
    repeat (3) @(posedge clk); rst_n = 1; @(posedge clk);

    $display("");
    $display("=== golden-reference cross-check, STRESS=%0d ===", STRESS);

    // ---- directed sweep: every mnemonic x SEW/LMUL x vl x policy ----
    for (int oi = O_RGATHER_VV; oi <= O_MSIF; oi++) begin
      for (int ci = 0; ci < 6; ci++) begin
        t_sewb = cfg_sew[ci]; t_beats = cfg_beat[ci]; t_frac = cfg_frac[ci];
        t_vlmax = (VLENB / t_sewb) * t_beats / t_frac;
        t_op = top_e'(oi);
        if (!cfg_ok(t_op)) continue;
        set_regs(t_op);
        for (int vi = 0; vi < 3; vi++) begin
          case (vi)
            0: t_vl = t_vlmax;
            1: t_vl = (t_vlmax > 1) ? t_vlmax/2 : 1;
            default: t_vl = 1;
          endcase
          for (int pi = 0; pi < 4; pi++) begin
            t_vta = pi[0]; t_vma = pi[1];
            t_vm  = (pi < 2) || !masked_ok(t_op);
            if (t_op inside {O_MERGE_VVM, O_MERGE_VXM, O_MERGE_VIM, O_FMERGE})
              t_vm = 1'b0;   // encoding fixes vm=0; v0 is a selector, not a predicate
            t_vstart = 0;
            t_scalar = 32'(seed_v[7:0]) % 32'(t_vlmax + 3);  // in and out of range
            if (t_op inside {O_MV_V_X, O_MV_V_I, O_MERGE_VXM, O_MERGE_VIM,
                             O_FMERGE, O_FMV_V_F, O_MV_S_X, O_FMV_S_F,
                             O_SLIDE1UP, O_FSLIDE1UP, O_SLIDE1DOWN, O_FSLIDE1DOWN})
              t_scalar = 32'hA5 + 32'(pi);
            if (t_op inside {O_RGATHER_VI, O_SLIDEUP_VI, O_SLIDEDOWN_VI,
                             O_MERGE_VIM, O_MV_V_I})
              t_scalar = t_scalar & 32'h1f;   // 5-bit immediate field
            seed_v = seed_v * 32'd1103515245 + 32'd12345;
            seed_state(seed_v);
            t_name = $sformatf("%s sew%0d lmul%0d/%0d vl%0d vta%0d vma%0d vm%0d",
                               op_name(t_op), t_sewb, t_beats, t_frac,
                               t_vl, t_vta, t_vma, t_vm);
            run_case();
          end
          // a non-zero vstart where the spec allows one
          if (vstart_ok(t_op) && t_vlmax > 2) begin
            t_vta = 1'b1; t_vma = 1'b1; t_vm = 1'b1;
            t_vstart = 1;
            t_vl = t_vlmax;
            seed_v = seed_v * 32'd1103515245 + 32'd12345;
            seed_state(seed_v);
            t_name = $sformatf("%s sew%0d lmul%0d/%0d vstart1",
                               op_name(t_op), t_sewb, t_beats, t_frac);
            run_case();
          end
        end
      end
    end

    // ---- vstart >= vl, including vl = 0 ----
    for (int oi = O_RGATHER_VV; oi <= O_MSIF; oi++) begin
      t_op = top_e'(oi);
      t_sewb = 32; t_beats = 1; t_frac = 1; t_vlmax = 4;
      if (!cfg_ok(t_op)) continue;
      if (!vstart_ok(t_op)) continue;
      set_regs(t_op);
      t_vta = 1'b1; t_vma = 1'b1; t_vm = 1'b1; t_scalar = 32'd1;
      t_vl = 0; t_vstart = 0;
      seed_v = seed_v * 32'd1103515245 + 32'd12345; seed_state(seed_v);
      t_name = $sformatf("%s vl=0", op_name(t_op));
      run_case();
      t_vl = 2; t_vstart = 3;
      seed_v = seed_v * 32'd1103515245 + 32'd12345; seed_state(seed_v);
      t_name = $sformatf("%s vstart>=vl", op_name(t_op));
      run_case();
    end

    // ---- randomized ----
    for (int n = 0; n < NRAND; n++) begin
      int ci;
      seed_v = seed_v * 32'd1103515245 + 32'd12345;
      t_op = top_e'(O_RGATHER_VV + (seed_v >> 8) % (O_MSIF - O_RGATHER_VV + 1));
      ci = (seed_v >> 20) % 6;
      t_sewb = cfg_sew[ci]; t_beats = cfg_beat[ci]; t_frac = cfg_frac[ci];
      t_vlmax = (VLENB / t_sewb) * t_beats / t_frac;
      if (!cfg_ok(t_op)) continue;
      set_regs(t_op);
      seed_v = seed_v * 32'd1103515245 + 32'd12345;
      t_vl = ((seed_v >> 4) % (t_vlmax + 1));
      t_vstart = vstart_ok(t_op) ? ((seed_v >> 12) % 3) : 0;
      t_vta = seed_v[17]; t_vma = seed_v[18];
      t_vm = masked_ok(t_op) ? seed_v[19] : 1'b1;
      if (t_op inside {O_MERGE_VVM, O_MERGE_VXM, O_MERGE_VIM, O_FMERGE}) t_vm = 1'b0;
      t_scalar = seed_v;
      if (t_op inside {O_RGATHER_VI, O_SLIDEUP_VI, O_SLIDEDOWN_VI,
                       O_MERGE_VIM, O_MV_V_I}) t_scalar = t_scalar & 32'h1f;
      if (t_op inside {O_RGATHER_VX, O_SLIDEUP_VX, O_SLIDEDOWN_VX})
        t_scalar = t_scalar % 32'(t_vlmax + 4);
      seed_v = seed_v * 32'd1103515245 + 32'd12345;
      seed_state(seed_v);
      t_name = $sformatf("rand[%0d] %s sew%0d lmul%0d/%0d vl%0d vstart%0d vta%0d vma%0d vm%0d",
                         n, op_name(t_op), t_sewb, t_beats, t_frac,
                         t_vl, t_vstart, t_vta, t_vma, t_vm);
      run_case();
    end

    $display("");
    $display("--- per-mnemonic case count ---");
    for (int o = O_RGATHER_VV; o <= O_MSIF; o++)
      $display("  %-18s %0d", op_name(top_e'(o)), hit_count[o]);
    $display("");
    $display("========================================");
    $display("REF TOTAL: %0d cases, %0d passed, %0d failed", run_count, pass_count, fail_count);
    $display("========================================");
    if (fail_count != 0) $fatal(1, "reference cross-check failed");
    $finish;
  end

  initial begin #50000000; $fatal(1, "ref tb timeout"); end
endmodule
