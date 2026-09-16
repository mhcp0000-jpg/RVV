module vcore_alu_decode #(
  parameter int unsigned VLEN = 128
) (
  input  logic                               cmd_valid_i,
  output logic                               cmd_ready_o,
  input  vcore_alu_pkg::vcore_alu_cmd_t       cmd_i,
  output logic                               decoded_valid_o,
  input  logic                               decoded_ready_i,
  output vcore_alu_pkg::vcore_alu_decoded_t  decoded_o
);
  import vcore_alu_pkg::*;

  logic [2:0] funct3;
  logic [5:0] funct6;
  logic form_vv, form_vx, form_vi, form_valid, opiv, opm, opf;
  logic operation_valid;
  logic [3:0] beats;
  int unsigned sew_bits, fraction_div, max_elements;

  assign cmd_ready_o = decoded_ready_i;
  assign decoded_valid_o = cmd_valid_i;
  assign funct3 = cmd_i.inst[14:12];
  assign funct6 = cmd_i.inst[31:26];
  assign opiv = (funct3 == 3'b000) || (funct3 == 3'b100) ||
                (funct3 == 3'b011);
  assign opm = (funct3 == 3'b010) || (funct3 == 3'b110);
  assign opf = (funct3 == 3'b001) || (funct3 == 3'b101);
  assign form_vv = (funct3 == 3'b000) || (funct3 == 3'b010) ||
                   (funct3 == 3'b001);
  assign form_vx = (funct3 == 3'b100) || (funct3 == 3'b110) ||
                   (funct3 == 3'b101);
  assign form_vi = (funct3 == 3'b011);
  assign form_valid = form_vv || form_vx || form_vi;

  always_comb begin
    decoded_o = '0;
    decoded_o.ctrl.op = VOP_INVALID;
    decoded_o.ctrl.sew = cmd_i.sew;
    decoded_o.ctrl.vxrm = cmd_i.vxrm;
    decoded_o.ctrl.vm = cmd_i.inst[25];
    decoded_o.ctrl.vta = cmd_i.vta;
    decoded_o.ctrl.vma = cmd_i.vma;
    decoded_o.ctrl.vl = cmd_i.vl;
    decoded_o.ctrl.vstart = cmd_i.vstart;
    decoded_o.ctrl.tag = cmd_i.tag;
    decoded_o.scalar = cmd_i.scalar;
    decoded_o.mask_snapshot = cmd_i.mask_snapshot;
    decoded_o.vd = cmd_i.inst[11:7];
    decoded_o.vs1 = cmd_i.inst[19:15];
    decoded_o.vs2 = cmd_i.inst[24:20];
    decoded_o.form = form_vv ? VSRC_VV : form_vx ? VSRC_VX : VSRC_VI;

    // Integer/immediate forms handled by this execution cluster.
    operation_valid = form_valid && (cmd_i.inst[6:0] == 7'h57);
    if (opiv) begin
    case (funct6)
      6'h00: decoded_o.ctrl.op = VOP_ADD;
      6'h02: begin decoded_o.ctrl.op = VOP_SUB;   operation_valid &= !form_vi; end
      6'h03: begin decoded_o.ctrl.op = VOP_RSUB;  operation_valid &= !form_vv; end
      6'h04: begin decoded_o.ctrl.op = VOP_MINU;  operation_valid &= !form_vi; end
      6'h05: begin decoded_o.ctrl.op = VOP_MIN;   operation_valid &= !form_vi; end
      6'h06: begin decoded_o.ctrl.op = VOP_MAXU;  operation_valid &= !form_vi; end
      6'h07: begin decoded_o.ctrl.op = VOP_MAX;   operation_valid &= !form_vi; end
      6'h09: decoded_o.ctrl.op = VOP_AND;
      6'h0a: decoded_o.ctrl.op = VOP_OR;
      6'h0b: decoded_o.ctrl.op = VOP_XOR;
      6'h10: begin decoded_o.ctrl.op = VOP_ADC;  operation_valid &= !cmd_i.inst[25]; end
      6'h11: decoded_o.ctrl.op = VOP_MADC;
      6'h12: begin decoded_o.ctrl.op = VOP_SBC;
        operation_valid &= !cmd_i.inst[25] && !form_vi; end
      6'h13: begin decoded_o.ctrl.op = VOP_MSBC;
        operation_valid &= !form_vi; end
      6'h17: begin
        if (cmd_i.inst[25]) begin
          decoded_o.ctrl.op = VOP_COPY_B;
          operation_valid &= (cmd_i.inst[24:20] == 5'b0);
        end else decoded_o.ctrl.op = VOP_MERGE;
      end
      6'h18: decoded_o.ctrl.op = VOP_EQ;
      6'h19: decoded_o.ctrl.op = VOP_NE;
      6'h1a: begin decoded_o.ctrl.op = VOP_LTU;   operation_valid &= !form_vi; end
      6'h1b: begin decoded_o.ctrl.op = VOP_LT;    operation_valid &= !form_vi; end
      6'h1c: decoded_o.ctrl.op = VOP_LEU;
      6'h1d: decoded_o.ctrl.op = VOP_LE;
      6'h1e: begin decoded_o.ctrl.op = VOP_GTU;   operation_valid &= !form_vv; end
      6'h1f: begin decoded_o.ctrl.op = VOP_GT;    operation_valid &= !form_vv; end
      6'h20: decoded_o.ctrl.op = VOP_SADDU;
      6'h21: decoded_o.ctrl.op = VOP_SADD;
      6'h22: begin decoded_o.ctrl.op = VOP_SSUBU; operation_valid &= !form_vi; end
      6'h23: begin decoded_o.ctrl.op = VOP_SSUB;  operation_valid &= !form_vi; end
      6'h25: decoded_o.ctrl.op = VOP_SLL;
      6'h27: begin decoded_o.ctrl.op = VOP_SMUL;
        operation_valid &= !form_vi; end
      6'h28: decoded_o.ctrl.op = VOP_SRL;
      6'h29: decoded_o.ctrl.op = VOP_SRA;
      6'h2a: decoded_o.ctrl.op = VOP_SSRL;
      6'h2b: decoded_o.ctrl.op = VOP_SSRA;
      6'h30: begin decoded_o.ctrl.op = VOP_WREDSUMU;
        operation_valid &= (funct3 == 3'b000) && (cmd_i.sew <= VSEW_32); end
      6'h31: begin decoded_o.ctrl.op = VOP_WREDSUM;
        operation_valid &= (funct3 == 3'b000) && (cmd_i.sew <= VSEW_32); end
      default: operation_valid = 1'b0;
    endcase
    end else if (opm) begin
      case (funct6)
        6'h00: decoded_o.ctrl.op = VOP_REDSUM;
        6'h01: decoded_o.ctrl.op = VOP_REDAND;
        6'h02: decoded_o.ctrl.op = VOP_REDOR;
        6'h03: decoded_o.ctrl.op = VOP_REDXOR;
        6'h04: decoded_o.ctrl.op = VOP_REDMINU;
        6'h05: decoded_o.ctrl.op = VOP_REDMIN;
        6'h06: decoded_o.ctrl.op = VOP_REDMAXU;
        6'h07: decoded_o.ctrl.op = VOP_REDMAX;
        6'h08: decoded_o.ctrl.op = VOP_AADDU;
        6'h09: decoded_o.ctrl.op = VOP_AADD;
        6'h0a: decoded_o.ctrl.op = VOP_ASUBU;
        6'h0b: decoded_o.ctrl.op = VOP_ASUB;
        6'h10: begin
          case (cmd_i.inst[19:15])
            5'h10: decoded_o.ctrl.op = VOP_CPOP;
            5'h11: decoded_o.ctrl.op = VOP_FIRST;
            default: operation_valid = 1'b0;
          endcase
          operation_valid &= (funct3 == 3'b010);
        end
        6'h18: decoded_o.ctrl.op = VOP_MANDN;
        6'h19: decoded_o.ctrl.op = VOP_MAND;
        6'h1a: decoded_o.ctrl.op = VOP_MOR;
        6'h1b: decoded_o.ctrl.op = VOP_MXOR;
        6'h1c: decoded_o.ctrl.op = VOP_MORN;
        6'h1d: decoded_o.ctrl.op = VOP_MNAND;
        6'h1e: decoded_o.ctrl.op = VOP_MNOR;
        6'h1f: decoded_o.ctrl.op = VOP_MXNOR;
        6'h20: decoded_o.ctrl.op = VOP_DIVU;
        6'h21: decoded_o.ctrl.op = VOP_DIV;
        6'h22: decoded_o.ctrl.op = VOP_REMU;
        6'h23: decoded_o.ctrl.op = VOP_REM;
        6'h24: decoded_o.ctrl.op = VOP_MULHU;
        6'h25: decoded_o.ctrl.op = VOP_MUL;
        6'h26: decoded_o.ctrl.op = VOP_MULHSU;
        6'h27: decoded_o.ctrl.op = VOP_MULH;
        6'h29: decoded_o.ctrl.op = VOP_MADD;
        6'h2b: decoded_o.ctrl.op = VOP_NMSUB;
        6'h2d: decoded_o.ctrl.op = VOP_MACC;
        6'h2f: decoded_o.ctrl.op = VOP_NMSAC;
        default: operation_valid = 1'b0;
      endcase
      if (vop_is_mask_logic(decoded_o.ctrl.op))
        operation_valid &= (funct3 == 3'b010) && cmd_i.inst[25];
      if (vop_is_reduction(decoded_o.ctrl.op))
        operation_valid &= (funct3 == 3'b010);
    end else if (opf) begin
      case (funct6)
        6'h04: decoded_o.ctrl.op = VOP_FMIN;
        6'h06: decoded_o.ctrl.op = VOP_FMAX;
        6'h08: decoded_o.ctrl.op = VOP_FSGNJ;
        6'h09: decoded_o.ctrl.op = VOP_FSGNJN;
        6'h0a: decoded_o.ctrl.op = VOP_FSGNJX;
        6'h13: begin
          decoded_o.ctrl.op = VOP_FCLASS;
          operation_valid &= (funct3 == 3'b001) &&
                             (cmd_i.inst[19:15] == 5'h10);
        end
        6'h18: decoded_o.ctrl.op = VOP_FEQ;
        6'h19: decoded_o.ctrl.op = VOP_FLE;
        6'h1b: decoded_o.ctrl.op = VOP_FLT;
        6'h1c: decoded_o.ctrl.op = VOP_FNE;
        6'h1d: begin decoded_o.ctrl.op = VOP_FGT;
          operation_valid &= (funct3 == 3'b101); end
        6'h1f: begin decoded_o.ctrl.op = VOP_FGE;
          operation_valid &= (funct3 == 3'b101); end
        default: operation_valid = 1'b0;
      endcase
      // RV32IMFC has F, but no D or Zfh: floating SEW is 32 only.
      operation_valid &= (cmd_i.sew == VSEW_32);
    end else operation_valid = 1'b0;

    if (form_vi)
      decoded_o.scalar = {{27{cmd_i.inst[19]}},cmd_i.inst[19:15]};

    case (cmd_i.sew)
      VSEW_8:  sew_bits = 8;
      VSEW_16: sew_bits = 16;
      VSEW_32: sew_bits = 32;
      VSEW_64: sew_bits = 64;
      default: sew_bits = 0;
    endcase
    beats = 4'd1;
    fraction_div = 1;
    case (cmd_i.vlmul)
      3'b000: beats = 4'd1;
      3'b001: beats = 4'd2;
      3'b010: beats = 4'd4;
      3'b011: beats = 4'd8;
      3'b111: fraction_div = 2;
      3'b110: fraction_div = 4;
      3'b101: fraction_div = 8;
      default: operation_valid = 1'b0;
    endcase
    decoded_o.beats = (vop_is_scalar_mask_reduce(decoded_o.ctrl.op) ||
                       vop_is_mask_logic(decoded_o.ctrl.op)) ?
                      4'd1 : beats;
    max_elements = (sew_bits == 0) ? 0 : ((VLEN / sew_bits) * int'(beats)) / fraction_div;
    if (max_elements == 0 || int'(cmd_i.vl) > max_elements || cmd_i.vill)
      operation_valid = 1'b0;
    if ((vop_is_reduction(decoded_o.ctrl.op) ||
         vop_is_scalar_mask_reduce(decoded_o.ctrl.op)) && cmd_i.vstart != 0)
      operation_valid = 1'b0;
    if (!cmd_i.inst[25] && decoded_o.vd == 5'd0 &&
        !vop_is_compare(decoded_o.ctrl.op) &&
        !vop_is_reduction(decoded_o.ctrl.op) &&
        !vop_is_scalar_mask_reduce(decoded_o.ctrl.op))
      operation_valid = 1'b0;
    if (beats > 1) begin
      if ((!vop_is_compare(decoded_o.ctrl.op) &&
           !vop_is_mask_logic(decoded_o.ctrl.op) &&
           !vop_is_reduction(decoded_o.ctrl.op) &&
           !vop_is_scalar_mask_reduce(decoded_o.ctrl.op) &&
           (int'(decoded_o.vd) % int'(beats)) != 0) ||
          ((decoded_o.ctrl.op != VOP_COPY_B) &&
           !vop_is_mask_logic(decoded_o.ctrl.op) &&
           !vop_is_scalar_mask_reduce(decoded_o.ctrl.op) &&
           (int'(decoded_o.vs2) % int'(beats)) != 0) ||
          (form_vv && !vop_is_reduction(decoded_o.ctrl.op) &&
           !vop_is_mask_logic(decoded_o.ctrl.op) &&
           !vop_is_scalar_mask_reduce(decoded_o.ctrl.op) &&
           (int'(decoded_o.vs1) % int'(beats)) != 0))
        operation_valid = 1'b0;
    end
    decoded_o.illegal = !operation_valid;
    if (!operation_valid) decoded_o.ctrl.op = VOP_INVALID;
  end

endmodule
