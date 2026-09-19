// STORE-FP (opcode 0100111) -> vcore_vst_decoded_t. All 133 official RVV 1.0
// vector store encodings.
//
//  31   29 28    27 26 25   24     20 19   15 14  12 11  7 6      0
// |  nf  | mew | mop  | vm | sumop/rs2/vs2 | rs1 | width| vs3 | 0100111|
//
//   mop   = 00 unit-stride | 01 indexed-unordered | 10 strided | 11 indexed-ordered
//   sumop = 00000 vse<eew>.v | 01000 vs<nf>r.v | 01011 vsm.v
//   width = 000/101/110/111 -> EEW 8/16/32/64 (with mew=0)
//           001/010/011/100 are the SCALAR FP stores fsh/fsw/fsd/fsq that
//           share this major opcode and must never be claimed here.
//
// Differences from the load decoder, all of them consequences of a store
// having no vector destination:
//   * no vta / vma -- there is no tail or inactive element to fill
//   * no fault-only-first sumop
//   * whole-register is one encoding per register count, width fixed to
//     000, EEW = 8, evl = NREG*VLEN/8
//   * RVV 1.0 5.3's v0-overlap rule does not apply, so a masked store with
//     vs3 = v0 is legal
//   * an indexed segment store has no source/index overlap restriction,
//     because vs2 and vs3 are both sources
//
// EMUL is carried as a log2 exponent for the same reason as in the load
// decoder: every quantity involved is a power of two, so the legality rules
// become adds, shifts and masks rather than dividers and multipliers.
module vcore_vst_decode #(
  parameter int unsigned VLEN = 128
) (
  input  logic                               cmd_valid_i,
  output logic                               cmd_ready_o,
  input  vcore_vst_pkg::vcore_vst_cmd_t      cmd_i,
  output logic                               decoded_valid_o,
  input  logic                               decoded_ready_i,
  output vcore_vst_pkg::vcore_vst_decoded_t  decoded_o
);
  import vcore_vst_pkg::*;

  logic [6:0] opcode;
  logic [2:0] nf_f, width;
  logic       mew, vm;
  logic [1:0] mop;
  logic [4:0] sumop, vs3_f, vs2_f;
  logic       operation_valid, is_indexed, is_whole;
  logic [2:0] width_eew, data_eew;
  int         sew_l2b, wid_l2b, data_l2b, lmul_l2;
  int         emul_l2, iemul_l2, regs_l2, spf_l2;
  int unsigned emul_regs, idx_regs;
  int unsigned nf_val, nreg, nreg_l2, vlmax, total_regs;
  localparam int unsigned SLOT_L2 = $clog2(VLEN/8);   // 4 for VLEN=128

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
  assign sumop  = cmd_i.inst[24:20];
  assign vs2_f  = cmd_i.inst[24:20];   // same field, indexed forms
  assign width  = cmd_i.inst[14:12];
  assign vs3_f  = cmd_i.inst[11:7];

  always_comb begin
    decoded_o = '0;
    decoded_o.ctrl.op        = VSTOP_INVALID;
    decoded_o.ctrl.vm        = vm;
    decoded_o.ctrl.vstart    = cmd_i.vstart;
    decoded_o.ctrl.base_addr = cmd_i.base;
    decoded_o.ctrl.tag       = cmd_i.tag;
    decoded_o.ctrl.idx_addr  = vs2_f;
    decoded_o.mask_snapshot  = cmd_i.mask_snapshot;
    decoded_o.vs3            = vs3_f;
    decoded_o.beats          = 4'd1;

    operation_valid = (opcode == 7'h27) && (mew == 1'b0) && !cmd_i.vill;

    width_eew = VEEW_8;
    unique case (width)
      3'b000:  width_eew = VEEW_8;
      3'b101:  width_eew = VEEW_16;
      3'b110:  width_eew = VEEW_32;
      3'b111:  width_eew = VEEW_64;
      default: operation_valid = 1'b0;   // scalar FP store
    endcase

    nf_val     = int'(nf_f) + 1;
    nreg       = 1;
    nreg_l2    = 0;
    is_indexed = (mop == 2'b01) || (mop == 2'b11);
    is_whole   = 1'b0;

    unique case (mop)
      2'b00: begin
        unique case (sumop)
          5'b00000: decoded_o.ctrl.op = VSTOP_UNIT;
          5'b01011: begin // vsm.v
            decoded_o.ctrl.op = VSTOP_MASK;
            if ((width != 3'b000) || !vm || (nf_f != 3'b000)) operation_valid = 1'b0;
          end
          5'b01000: begin // vs<nreg>r.v -- whole register, EEW fixed to 8
            decoded_o.ctrl.op = VSTOP_WHOLE;
            is_whole = 1'b1;
            operation_valid &= vm;
            if (width != 3'b000) operation_valid = 1'b0;
            unique case (nf_f)
              3'd0: begin nreg = 1; nreg_l2 = 0; end
              3'd1: begin nreg = 2; nreg_l2 = 1; end
              3'd3: begin nreg = 4; nreg_l2 = 2; end
              3'd7: begin nreg = 8; nreg_l2 = 3; end
              default: operation_valid = 1'b0;
            endcase
            nf_val = 1;
          end
          default: operation_valid = 1'b0;   // reserved sumop (no fof for stores)
        endcase
      end
      2'b10: decoded_o.ctrl.op = VSTOP_STRIDED;
      2'b01: decoded_o.ctrl.op = VSTOP_INDEXED;
      2'b11: decoded_o.ctrl.op = VSTOP_INDEXED;
      default: operation_valid = 1'b0;
    endcase
    decoded_o.ctrl.ordered = (mop == 2'b11);

    // An indexed store takes its DATA width from vtype and uses `width` for
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

    // ---- source EMUL, as a log2 exponent ------------------------------
    if (is_indexed)                             emul_l2 = lmul_l2;
    else if (decoded_o.ctrl.op == VSTOP_MASK)   emul_l2 = 0;
    else                                        emul_l2 = data_l2b - sew_l2b + lmul_l2;

    if (is_whole) begin
      regs_l2   = nreg_l2;
      emul_regs = nreg;
    end else begin
      if ((emul_l2 < -3) || (emul_l2 > 3)) operation_valid = 1'b0;
      regs_l2   = (emul_l2 > 0) ? emul_l2 : 0;
      emul_regs = (regs_l2 > 3) ? MAXEMUL : (1 << regs_l2);
    end
    if (emul_regs > MAXEMUL) begin
      emul_regs = MAXEMUL;
      operation_valid = 1'b0;
    end

    // ---- index EMUL (indexed forms only) ------------------------------
    iemul_l2 = wid_l2b - sew_l2b + lmul_l2;
    idx_regs = (iemul_l2 <= 0) ? 1 : ((iemul_l2 > 3) ? MAXEMUL : (1 << iemul_l2));
    if (is_indexed) begin
      if ((iemul_l2 < -3) || (iemul_l2 > 3)) operation_valid = 1'b0;
      if ((iemul_l2 > 0) && ((int'(vs2_f) & int'(idx_regs - 1)) != 0))
        operation_valid = 1'b0;
    end

    // ---- register budget and alignment --------------------------------
    total_regs = nf_val << regs_l2;
    if (total_regs > MAXEMUL) operation_valid = 1'b0;
    if (is_whole) begin
      if ((nreg > 1) && ((int'(vs3_f) & int'(nreg - 1)) != 0)) operation_valid = 1'b0;
    end else if ((emul_l2 > 0) && ((int'(vs3_f) & int'(emul_regs - 1)) != 0)) begin
      operation_valid = 1'b0;
    end

    // ---- vl / evl -----------------------------------------------------
    vlmax = shl_signed((VLEN/8) >> sew_l2b, lmul_l2);
    if (!is_whole) begin
      if ((vlmax == 0) || (int'(cmd_i.vl) > vlmax)) operation_valid = 1'b0;
    end

    spf_l2 = regs_l2 + int'(SLOT_L2) - data_l2b;
    decoded_o.ctrl.nf              = 4'(nf_val);
    decoded_o.ctrl.regs_per_field  = 4'(emul_regs);
    decoded_o.ctrl.slots_per_field = 17'(1 << spf_l2);
    decoded_o.ctrl.src_slots       = 17'(nf_val << spf_l2);
    decoded_o.ctrl.idx_regs        = 4'(idx_regs);
    decoded_o.beats                = 4'(total_regs);

    unique case (decoded_o.ctrl.op)
      VSTOP_MASK: begin
        // RVV 1.0 7.4: evl = ceil(vl/8), EMUL = 1, unmasked, vstart in bytes.
        decoded_o.ctrl.evl    = 17'((int'(cmd_i.vl) + 7) >> 3);
        decoded_o.ctrl.vm     = 1'b1;
        decoded_o.ctrl.stride = 32'd1;
      end
      VSTOP_WHOLE: begin
        // RVV 1.0 7.9: vtype and vl are ignored; the store moves whole
        // registers, so EEW is 8 and evl = NREG*VLEN/8 bytes.
        decoded_o.ctrl.evl    = 17'(1 << spf_l2);
        decoded_o.ctrl.vm     = 1'b1;
        decoded_o.ctrl.stride = 32'd1;
      end
      VSTOP_STRIDED: begin
        decoded_o.ctrl.evl    = cmd_i.vl;
        decoded_o.ctrl.stride = cmd_i.stride;   // signed; 0 is legal but see pkg note 6
      end
      VSTOP_INDEXED: begin
        decoded_o.ctrl.evl    = cmd_i.vl;
        decoded_o.ctrl.stride = '0;             // addr = base + index[i]
      end
      default: begin // UNIT
        decoded_o.ctrl.evl    = cmd_i.vl;
        decoded_o.ctrl.stride = 32'(nf_val) << data_l2b;
      end
    endcase

    // NOTE: no v0-overlap check and no index/source overlap check. A store
    // has no vector destination, so RVV 1.0 5.3 does not apply and vs2/vs3
    // are both sources.

    if (!veew_supported(decoded_o.ctrl.eew) ||
        !veew_supported(decoded_o.ctrl.idx_eew)) operation_valid = 1'b0;
    if (decoded_o.beats == 4'd0) operation_valid = 1'b0;

    decoded_o.illegal = !operation_valid;
    if (!operation_valid) begin
      decoded_o.ctrl.op = VSTOP_INVALID;
      decoded_o.beats   = 4'd1;
    end
  end

endmodule
