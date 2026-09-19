// LOAD-FP (opcode 0000111) -> vcore_vld_decoded_t. All 177 official RVV 1.0
// vector load encodings.
//
//  31   29 28    27 26 25   24     20 19   15 14  12 11  7 6      0
// |  nf  | mew | mop  | vm | lumop/rs2/vs2 | rs1 | width|  vd | 0000111|
//
//   mop   = 00 unit-stride | 01 indexed-unordered | 10 strided | 11 indexed-ordered
//   lumop = 00000 vle<eew>.v | 01000 vl<nf>re<eew>.v | 01011 vlm.v | 10000 vle<eew>ff.v
//   width = 000/101/110/111 -> EEW 8/16/32/64 (with mew=0)
//           001/010/011/100 are the SCALAR FP loads flh/flw/fld/flq that
//           share this major opcode and must never be claimed here.
//   nf    = NFIELDS-1 for segment loads, NREG-1 encoded 0/1/3/7 for
//           whole-register loads, 0 otherwise.
//
// For an INDEXED load `width` gives the INDEX element width; the data
// element width is vtype.vsew and the data EMUL is vtype.vlmul. Every other
// form takes its data EEW from `width`.
//
// EMUL is carried as a LOG2 EXPONENT, not as a ratio. Every quantity the
// legality rules touch -- LMUL, EEW/SEW, EMUL, VLMAX, elements per register,
// slots per field -- is a power of two, so
//
//   emul_log2 = log2(EEW/8) - log2(SEW/8) + log2(LMUL)
//
// composes a fractional LMUL with a widening or narrowing EEW:SEW ratio
// exactly, using one signed add. Everything downstream then falls out as a
// shift or a mask: EMUL is legal iff -3 <= emul_log2 <= 3, the register
// count is 1<<max(0,emul_log2), alignment is a mask against it, and
// "EMUL * NFIELDS <= 8" collapses into the register-budget test. Writing the
// same rules as num/den ratios costs four dividers and eight multipliers in
// synthesis; this form costs none.
module vcore_vld_decode #(
  parameter int unsigned VLEN = 128
) (
  input  logic                               cmd_valid_i,
  output logic                               cmd_ready_o,
  input  vcore_vld_pkg::vcore_vld_cmd_t      cmd_i,
  output logic                               decoded_valid_o,
  input  logic                               decoded_ready_i,
  output vcore_vld_pkg::vcore_vld_decoded_t  decoded_o
);
  import vcore_vld_pkg::*;

  logic [6:0] opcode;
  logic [2:0] nf_f, width;
  logic       mew, vm;
  logic [1:0] mop;
  logic [4:0] lumop, vd_f, vs2_f;
  logic       operation_valid, is_indexed, is_whole;
  logic [2:0] width_eew, data_eew;
  // log2 of the element size in bytes: 0/1/2/3 for 8/16/32/64 bits.
  int          sew_l2b, wid_l2b, data_l2b, lmul_l2;
  int          emul_l2, iemul_l2, regs_l2, spf_l2;
  int unsigned emul_regs, idx_regs;
  int unsigned nf_val, nreg, nreg_l2, vlmax, elems_per_reg, total_regs;
  localparam int unsigned SLOT_L2 = $clog2(VLEN/8);   // 4 for VLEN=128

  // v << sh for a positive shift, v >> -sh for a negative one.
  function automatic int unsigned shl_signed(input int unsigned v, input int sh);
    if (sh >= 0) return v << sh;
    else         return v >> (-sh);
  endfunction

  assign cmd_ready_o     = decoded_ready_i;
  assign decoded_valid_o = cmd_valid_i;
  assign opcode = cmd_i.inst[6:0];
  assign nf_f   = cmd_i.inst[31:29];
  assign mew    = cmd_i.inst[28];
  assign mop    = cmd_i.inst[27:26];
  assign vm     = cmd_i.inst[25];
  assign lumop  = cmd_i.inst[24:20];
  assign vs2_f  = cmd_i.inst[24:20];   // same field, indexed forms
  assign width  = cmd_i.inst[14:12];
  assign vd_f   = cmd_i.inst[11:7];

  always_comb begin
    decoded_o = '0;
    decoded_o.ctrl.op        = VLDOP_INVALID;
    decoded_o.ctrl.vm        = vm;
    decoded_o.ctrl.vta       = cmd_i.vta;
    decoded_o.ctrl.vma       = cmd_i.vma;
    decoded_o.ctrl.vstart    = cmd_i.vstart;
    decoded_o.ctrl.base_addr = cmd_i.base;
    decoded_o.ctrl.tag       = cmd_i.tag;
    decoded_o.ctrl.idx_addr  = vs2_f;
    decoded_o.mask_snapshot  = cmd_i.mask_snapshot;
    decoded_o.vd             = vd_f;
    decoded_o.beats          = 4'd1;

    operation_valid = (opcode == 7'h07) && (mew == 1'b0) && !cmd_i.vill;

    // width -> element width. Anything else on this opcode is a scalar FP load.
    width_eew = VEEW_8;
    unique case (width)
      3'b000:  width_eew = VEEW_8;
      3'b101:  width_eew = VEEW_16;
      3'b110:  width_eew = VEEW_32;
      3'b111:  width_eew = VEEW_64;
      default: operation_valid = 1'b0;
    endcase

    nf_val  = int'(nf_f) + 1;
    nreg    = 1;
    nreg_l2 = 0;
    is_indexed = (mop == 2'b01) || (mop == 2'b11);
    is_whole   = 1'b0;

    // ---- form -------------------------------------------------------
    unique case (mop)
      2'b00: begin
        unique case (lumop)
          5'b00000: decoded_o.ctrl.op = VLDOP_UNIT;
          5'b10000: decoded_o.ctrl.op = VLDOP_FOF;
          5'b01011: begin // vlm.v -- byte-granular mask load
            decoded_o.ctrl.op = VLDOP_MASK;
            // encoded like vle8.v, unmasked and non-segment by encoding
            if ((width != 3'b000) || !vm || (nf_f != 3'b000))
              operation_valid = 1'b0;
          end
          5'b01000: begin // vl<nreg>re<eew>.v -- whole register
            decoded_o.ctrl.op = VLDOP_WHOLE;
            is_whole = 1'b1;
            operation_valid &= vm;   // unmasked by encoding
            unique case (nf_f)
              3'd0: begin nreg = 1; nreg_l2 = 0; end
              3'd1: begin nreg = 2; nreg_l2 = 1; end
              3'd3: begin nreg = 4; nreg_l2 = 2; end
              3'd7: begin nreg = 8; nreg_l2 = 3; end
              default: operation_valid = 1'b0;
            endcase
            nf_val = 1;              // one field of `nreg` registers
          end
          default: operation_valid = 1'b0;   // reserved lumop
        endcase
      end
      2'b10: decoded_o.ctrl.op = VLDOP_STRIDED;
      2'b01: decoded_o.ctrl.op = VLDOP_INDEXED;
      2'b11: decoded_o.ctrl.op = VLDOP_INDEXED;
      default: operation_valid = 1'b0;
    endcase
    decoded_o.ctrl.ordered = (mop == 2'b11);

    // ---- element widths ---------------------------------------------
    // Indexed loads take their DATA width from vtype and use `width` for
    // the index; every other form takes its data width from `width`.
    data_eew = is_indexed ? cmd_i.sew : width_eew;
    decoded_o.ctrl.eew     = data_eew;
    decoded_o.ctrl.idx_eew = width_eew;

    if (!veew_supported(cmd_i.sew)) operation_valid = 1'b0;
    sew_l2b  = int'(veew_size(cmd_i.sew));
    wid_l2b  = int'(veew_size(width_eew));
    data_l2b = int'(veew_size(data_eew));

    lmul_l2 = 0;
    unique case (cmd_i.vlmul)
      3'b000: lmul_l2 =  0;
      3'b001: lmul_l2 =  1;
      3'b010: lmul_l2 =  2;
      3'b011: lmul_l2 =  3;
      3'b111: lmul_l2 = -1;
      3'b110: lmul_l2 = -2;
      3'b101: lmul_l2 = -3;
      default: operation_valid = 1'b0;
    endcase

    // ---- data EMUL, as a log2 exponent -------------------------------
    // EMUL = (EEW/SEW) * LMUL, except an indexed load whose data group is
    // simply LMUL, and vlm.v / whole-register which are fixed.
    if (is_indexed)                             emul_l2 = lmul_l2;
    else if (decoded_o.ctrl.op == VLDOP_MASK)   emul_l2 = 0;
    else                                        emul_l2 = data_l2b - sew_l2b + lmul_l2;

    if (is_whole) begin
      regs_l2   = nreg_l2;
      emul_regs = nreg;
    end else begin
      // RVV 1.0 7.3 / 4.5: 1/8 <= EMUL <= 8, otherwise reserved.
      if ((emul_l2 < -3) || (emul_l2 > 3)) operation_valid = 1'b0;
      // A fractional EMUL still occupies one whole register.
      regs_l2   = (emul_l2 > 0) ? emul_l2 : 0;
      emul_regs = (regs_l2 > 3) ? MAXEMUL : (1 << regs_l2);
    end
    if (emul_regs > MAXEMUL) begin
      emul_regs = MAXEMUL;
      operation_valid = 1'b0;
    end

    // ---- index EMUL (indexed forms only) -----------------------------
    iemul_l2 = wid_l2b - sew_l2b + lmul_l2;
    idx_regs = (iemul_l2 <= 0) ? 1 : ((iemul_l2 > 3) ? MAXEMUL : (1 << iemul_l2));
    if (is_indexed) begin
      if ((iemul_l2 < -3) || (iemul_l2 > 3)) operation_valid = 1'b0;
      // vs2 must be aligned to the index EMUL when that EMUL is >= 1.
      if ((iemul_l2 > 0) && ((int'(vs2_f) & int'(idx_regs - 1)) != 0))
        operation_valid = 1'b0;
    end

    // ---- register budget and alignment -------------------------------
    // nf * 2^regs_l2. This single test also covers RVV 1.0 7.8's
    // "EMUL * NFIELDS <= 8": for EMUL >= 1 the two are the same expression,
    // and for a fractional EMUL the product is nf/2^k <= nf <= 8 already.
    total_regs = nf_val << regs_l2;
    if (total_regs > MAXEMUL) operation_valid = 1'b0;
    // vd is aligned to the per-field EMUL when that EMUL is >= 1, and to
    // NREG for a whole-register load.
    if (is_whole) begin
      if ((nreg > 1) && ((int'(vd_f) & int'(nreg - 1)) != 0)) operation_valid = 1'b0;
    end else if ((emul_l2 > 0) && ((int'(vd_f) & int'(emul_regs - 1)) != 0)) begin
      operation_valid = 1'b0;
    end

    // ---- vl / evl ----------------------------------------------------
    // vl counts elements in SEW space and is what vsetvli bounded, so its
    // legality check uses VLMAX(SEW, LMUL) -- not the data EEW.
    vlmax = shl_signed((VLEN/8) >> sew_l2b, lmul_l2);
    if (!is_whole) begin
      if ((vlmax == 0) || (int'(cmd_i.vl) > vlmax)) operation_valid = 1'b0;
    end

    elems_per_reg = (VLEN/8) >> data_l2b;
    spf_l2 = regs_l2 + int'(SLOT_L2) - data_l2b;
    decoded_o.ctrl.nf              = 4'(nf_val);
    decoded_o.ctrl.regs_per_field  = 4'(emul_regs);
    decoded_o.ctrl.slots_per_field = 17'(1 << spf_l2);
    decoded_o.ctrl.dst_slots       = 17'(nf_val << spf_l2);
    decoded_o.ctrl.idx_regs        = 4'(idx_regs);
    decoded_o.beats                = 4'(total_regs);

    unique case (decoded_o.ctrl.op)
      VLDOP_MASK: begin
        // RVV 1.0 7.4: evl = ceil(vl/8), EMUL=1, always tail-agnostic.
        decoded_o.ctrl.evl    = 17'((int'(cmd_i.vl) + 7) >> 3);
        decoded_o.ctrl.vta    = 1'b1;
        decoded_o.ctrl.vma    = 1'b1;
        decoded_o.ctrl.vm     = 1'b1;
        decoded_o.ctrl.stride = 32'd1;
      end
      VLDOP_WHOLE: begin
        // RVV 1.0 7.9: vtype and vl are ignored; evl = NREG*VLEN/EEW and
        // every slot is written, so there is no tail and no mask.
        decoded_o.ctrl.evl    = 17'(1 << spf_l2);
        decoded_o.ctrl.vta    = 1'b1;
        decoded_o.ctrl.vma    = 1'b1;
        decoded_o.ctrl.vm     = 1'b1;
        decoded_o.ctrl.stride = 32'd1 << data_l2b;
      end
      VLDOP_STRIDED: begin
        decoded_o.ctrl.evl    = cmd_i.vl;
        decoded_o.ctrl.stride = cmd_i.stride;   // signed byte stride, 0 legal
      end
      VLDOP_INDEXED: begin
        decoded_o.ctrl.evl    = cmd_i.vl;
        decoded_o.ctrl.stride = '0;             // unused: addr = base + index[i]
      end
      default: begin // UNIT and FOF
        decoded_o.ctrl.evl    = cmd_i.vl;
        // consecutive segments are nf elements apart; nf = 1 for a plain load
        decoded_o.ctrl.stride = 32'(nf_val) << data_l2b;
      end
    endcase

    // RVV 1.0 5.3: the destination group of a masked instruction cannot
    // overlap v0 unless it is being written with a mask value. vd is the
    // lowest register of the group, so the test is vd == v0.
    if (!decoded_o.ctrl.vm && (vd_f == 5'd0)) operation_valid = 1'b0;

    // RVV 1.0 7.8.3: for an indexed SEGMENT load the destination groups
    // cannot overlap the index group. (A non-segment indexed load may
    // overlap: the index is consumed before any destination is written.)
    if (is_indexed && (nf_val > 1)) begin
      if (vld_regs_overlap(vd_f, total_regs, vs2_f, idx_regs))
        operation_valid = 1'b0;
    end

    if (!veew_supported(decoded_o.ctrl.eew) ||
        !veew_supported(decoded_o.ctrl.idx_eew)) operation_valid = 1'b0;
    if (decoded_o.beats == 4'd0) operation_valid = 1'b0;

    decoded_o.illegal = !operation_valid;
    if (!operation_valid) begin
      decoded_o.ctrl.op = VLDOP_INVALID;
      decoded_o.beats   = 4'd1;
    end
  end

endmodule
