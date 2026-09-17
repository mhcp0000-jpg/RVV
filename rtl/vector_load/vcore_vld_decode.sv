// LOAD-FP (opcode 0000111) vector unit-stride loads -> vcore_vld_decoded_t.
//
//  31   29 28    27 26 25   24     20 19   15 14  12 11  7 6      0
// |  nf  | mew | mop  | vm |  lumop  |  rs1  | width|  vd | 0000111|
//
//   mop   = 00 unit-stride, 01 indexed-unordered, 10 strided, 11 indexed-ordered
//   lumop = 00000 vle<eew>.v | 01000 vl<nf>re<eew>.v | 01011 vlm.v | 10000 vle<eew>ff.v
//   width = 000/101/110/111 -> EEW 8/16/32/64 (with mew=0)
//           001/010/011/100 are the SCALAR FP loads flh/flw/fld/flq that
//           share this major opcode and must not be claimed here.
//
// Only mop=00 with lumop=00000 or 01011 is in scope; see vcore_vld_pkg.
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
  logic [2:0] nf, width;
  logic       mew, vm;
  logic [1:0] mop;
  logic [4:0] lumop, vd_f;
  logic       operation_valid;
  logic [2:0] eew_sel;
  int unsigned eew_bits, sew_bits;
  int unsigned lmul_num, lmul_den;
  int unsigned emul_num, emul_den, emul_regs, vlmax, elems_per_reg;

  assign cmd_ready_o     = decoded_ready_i;
  assign decoded_valid_o = cmd_valid_i;
  assign opcode = cmd_i.inst[6:0];
  assign nf     = cmd_i.inst[31:29];
  assign mew    = cmd_i.inst[28];
  assign mop    = cmd_i.inst[27:26];
  assign vm     = cmd_i.inst[25];
  assign lumop  = cmd_i.inst[24:20];
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
    decoded_o.mask_snapshot  = cmd_i.mask_snapshot;
    decoded_o.vd             = vd_f;
    decoded_o.beats          = 4'd1;

    operation_valid = (opcode == 7'h07) && (mop == 2'b00) && (mew == 1'b0) &&
                      (nf == 3'b000) && !cmd_i.vill;

    // width -> EEW. Anything else on this opcode is a scalar FP load.
    eew_sel = VEEW_8;
    unique case (width)
      3'b000:  eew_sel = VEEW_8;
      3'b101:  eew_sel = VEEW_16;
      3'b110:  eew_sel = VEEW_32;
      3'b111:  eew_sel = VEEW_64;
      default: operation_valid = 1'b0;
    endcase

    unique case (lumop)
      5'b00000: decoded_o.ctrl.op = VLDOP_UNIT;
      5'b01011: begin // vlm.v -- byte-granular mask load
        decoded_o.ctrl.op = VLDOP_MASK;
        // Encoded like vle8.v (width=000) and unmasked by encoding.
        if ((width != 3'b000) || !vm) operation_valid = 1'b0;
      end
      // Out of scope: whole-register (01000) and fault-only-first (10000).
      // Reported illegal so TOP routes them somewhere else rather than
      // having this cluster quietly execute the wrong thing.
      default: operation_valid = 1'b0;
    endcase

    eew_bits = veew_bits(eew_sel);
    case (cmd_i.sew)
      VEEW_8:  sew_bits = 8;
      VEEW_16: sew_bits = 16;
      VEEW_32: sew_bits = 32;
      VEEW_64: sew_bits = 64;
      default: begin sew_bits = 8; operation_valid = 1'b0; end
    endcase

    lmul_num = 1; lmul_den = 1;
    unique case (cmd_i.vlmul)
      3'b000: begin lmul_num = 1; lmul_den = 1; end
      3'b001: begin lmul_num = 2; lmul_den = 1; end
      3'b010: begin lmul_num = 4; lmul_den = 1; end
      3'b011: begin lmul_num = 8; lmul_den = 1; end
      3'b111: begin lmul_num = 1; lmul_den = 2; end
      3'b110: begin lmul_num = 1; lmul_den = 4; end
      3'b101: begin lmul_num = 1; lmul_den = 8; end
      default: operation_valid = 1'b0;
    endcase

    // EMUL = (EEW/SEW) * LMUL, kept as a rational so fractional LMUL and a
    // widening/narrowing EEW:SEW ratio compose exactly.
    emul_num = eew_bits * lmul_num;
    emul_den = sew_bits * lmul_den;
    // RVV 1.0 7.3/4.5: 1/8 <= EMUL <= 8, otherwise the encoding is reserved.
    if ((emul_num * 8 < emul_den) || (emul_num > emul_den * 8))
      operation_valid = 1'b0;
    // A fractional EMUL still occupies one whole physical register.
    emul_regs = (emul_num + emul_den - 1) / emul_den;
    if (emul_regs < 1) emul_regs = 1;
    if (emul_regs > MAXEMUL) begin
      emul_regs = MAXEMUL;
      operation_valid = 1'b0;
    end

    // vl is an element count in SEW space and is what vsetvli bounded, so
    // its legality check uses VLMAX(SEW,LMUL) -- not EEW.
    vlmax = (lmul_num * VLEN) / (lmul_den * sew_bits);
    if ((vlmax == 0) || (int'(cmd_i.vl) > vlmax)) operation_valid = 1'b0;

    elems_per_reg = (eew_bits == 0) ? 0 : (VLEN / eew_bits);

    if (decoded_o.ctrl.op == VLDOP_MASK) begin
      // RVV 1.0 7.4: "the effective vector length is evl=ceil(vl/8) (i.e.
      // EMUL=1), and the destination register is always written with a
      // tail-agnostic policy".
      decoded_o.ctrl.eew       = VEEW_8;
      decoded_o.ctrl.evl       = 17'((int'(cmd_i.vl) + 7) / 8);
      decoded_o.ctrl.vm        = 1'b1;
      decoded_o.ctrl.vta       = 1'b1;
      decoded_o.ctrl.vma       = 1'b1; // unmasked: no inactive elements exist
      decoded_o.ctrl.emul_regs = 4'd1;
      decoded_o.ctrl.dst_slots = 17'(VLEN / 8);
      decoded_o.beats          = 4'd1;
    end else begin
      decoded_o.ctrl.eew       = eew_sel;
      decoded_o.ctrl.evl       = cmd_i.vl;
      decoded_o.ctrl.emul_regs = 4'(emul_regs);
      // RVV 1.0 5.4 bounds the tail at max(VLMAX, VLEN/SEW): with a
      // fractional EMUL the slots above VLMAX inside the single destination
      // register are tail and must still receive the agnostic fill.
      decoded_o.ctrl.dst_slots = 17'(emul_regs * elems_per_reg);
      decoded_o.beats          = 4'(emul_regs);
      // vd must be aligned to the destination EMUL when EMUL >= 1.
      if ((emul_num >= emul_den) && (emul_regs > 1) &&
          ((int'(vd_f) % int'(emul_regs)) != 0))
        operation_valid = 1'b0;
    end

    // RVV 1.0 5.3: "The destination vector register group for a masked
    // vector instruction cannot overlap the source mask register (v0),
    // unless the destination ... is being written with a mask value or the
    // scalar result of a reduction. These instruction encodings are
    // reserved." A masked load's destination holds data, so vd (which is
    // EMUL-aligned) may not be v0.
    if (!decoded_o.ctrl.vm && (vd_f == 5'd0)) operation_valid = 1'b0;

    if (!veew_supported(decoded_o.ctrl.eew)) operation_valid = 1'b0;

    decoded_o.illegal = !operation_valid;
    if (!operation_valid) begin
      decoded_o.ctrl.op = VLDOP_INVALID;
      decoded_o.beats   = 4'd1;
    end
  end

endmodule
