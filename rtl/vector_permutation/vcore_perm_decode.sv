// OP-V permutation-class instructions -> vcore_perm_decoded_t.
// funct6/funct3/vm/vs1 combinations are the measured riscv-opcodes encoding
// (see Vector_Core/outputs/rvv_instruction_20260916). vcpop.m/vfirst.m alias
// the same funct6=0x10,funct3=010 space as vmv.x.s but belong to the mask-
// reduction cluster, not this one -- rejected here via the vs1 field check.
module vcore_perm_decode #(
  parameter int unsigned VLEN = 128
) (
  input  logic                                cmd_valid_i,
  output logic                                cmd_ready_o,
  input  vcore_perm_pkg::vcore_perm_cmd_t     cmd_i,
  output logic                                decoded_valid_o,
  input  logic                                decoded_ready_i,
  output vcore_perm_pkg::vcore_perm_decoded_t decoded_o
);
  import vcore_perm_pkg::*;

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [5:0] funct6;
  logic       vm;
  logic [4:0] vd_f, vs1_f, vs2_f;
  logic operation_valid;
  logic [3:0] beats;
  int unsigned sew_bits, fraction_div, max_elements;

  assign cmd_ready_o = decoded_ready_i;
  assign decoded_valid_o = cmd_valid_i;
  assign opcode = cmd_i.inst[6:0];
  assign funct3 = cmd_i.inst[14:12];
  assign funct6 = cmd_i.inst[31:26];
  assign vm     = cmd_i.inst[25];
  assign vd_f   = cmd_i.inst[11:7];
  assign vs1_f  = cmd_i.inst[19:15];
  assign vs2_f  = cmd_i.inst[24:20];

  always_comb begin
    decoded_o = '0;
    decoded_o.ctrl.op  = VPOP_INVALID;
    decoded_o.ctrl.sew = cmd_i.sew;
    decoded_o.ctrl.vm  = vm;
    decoded_o.ctrl.vta = cmd_i.vta;
    decoded_o.ctrl.vma = cmd_i.vma;
    decoded_o.ctrl.vl  = cmd_i.vl;
    decoded_o.ctrl.vstart = cmd_i.vstart;
    decoded_o.ctrl.tag = cmd_i.tag;
    decoded_o.scalar   = cmd_i.scalar;
    decoded_o.mask_snapshot = cmd_i.mask_snapshot;
    decoded_o.vd  = vd_f;
    decoded_o.vs1 = vs1_f;
    decoded_o.vs2 = vs2_f;
    decoded_o.form = VSRC_NONE;

    operation_valid = (opcode == 7'h57);

    unique case (funct6)
      6'h0c: begin // vrgather.vv/vx/vi
        decoded_o.ctrl.op = VPOP_VRGATHER;
        unique case (funct3)
          3'b000:  decoded_o.form = VSRC_VV;
          3'b100:  decoded_o.form = VSRC_VX;
          3'b011:  begin decoded_o.form = VSRC_VI; decoded_o.scalar = {27'd0, vs1_f}; end // uimm5
          default: operation_valid = 1'b0;
        endcase
      end
      6'h0e: begin // vrgatherei16.vv / vslideup.vx,vi / vslide1up.vx / vfslide1up.vf
        unique case (funct3)
          3'b000: begin decoded_o.ctrl.op = VPOP_VRGATHEREI16; decoded_o.form = VSRC_VV; end
          3'b100: begin decoded_o.ctrl.op = VPOP_VSLIDEUP;     decoded_o.form = VSRC_VX; end
          3'b011: begin decoded_o.ctrl.op = VPOP_VSLIDEUP;     decoded_o.form = VSRC_VI; decoded_o.scalar = {27'd0, vs1_f}; end
          3'b110: begin decoded_o.ctrl.op = VPOP_VSLIDE1UP;    decoded_o.form = VSRC_VX; end
          3'b101: begin decoded_o.ctrl.op = VPOP_VSLIDE1UP;    decoded_o.form = VSRC_VX; end // vfslide1up.vf
          default: operation_valid = 1'b0;
        endcase
      end
      6'h0f: begin // vslidedown.vx,vi / vslide1down.vx / vfslide1down.vf
        unique case (funct3)
          3'b100: begin decoded_o.ctrl.op = VPOP_VSLIDEDOWN;   decoded_o.form = VSRC_VX; end
          3'b011: begin decoded_o.ctrl.op = VPOP_VSLIDEDOWN;   decoded_o.form = VSRC_VI; decoded_o.scalar = {27'd0, vs1_f}; end
          3'b110: begin decoded_o.ctrl.op = VPOP_VSLIDE1DOWN;  decoded_o.form = VSRC_VX; end
          3'b101: begin decoded_o.ctrl.op = VPOP_VSLIDE1DOWN;  decoded_o.form = VSRC_VX; end
          default: operation_valid = 1'b0;
        endcase
      end
      6'h17: begin // vcompress.vm(vm=1 only) / vmv.v.*(vm=1) / vmerge.*m(vm=0)
        unique case (funct3)
          3'b010: begin
            decoded_o.ctrl.op = VPOP_VCOMPRESS; decoded_o.form = VSRC_VV;
            operation_valid &= vm;
          end
          3'b000: begin
            decoded_o.form = VSRC_VV;
            decoded_o.ctrl.op = vm ? VPOP_VMV_V : VPOP_VMERGE;
          end
          3'b100, 3'b101: begin // .vx / vfmv.v.f,vfmerge.vfm(.vf) share the .vx datapath
            decoded_o.form = VSRC_VX;
            decoded_o.ctrl.op = vm ? VPOP_VMV_V : VPOP_VMERGE;
          end
          3'b011: begin // simm5
            decoded_o.form = VSRC_VI;
            decoded_o.scalar = {{27{vs1_f[4]}}, vs1_f};
            decoded_o.ctrl.op = vm ? VPOP_VMV_V : VPOP_VMERGE;
          end
          default: operation_valid = 1'b0;
        endcase
      end
      6'h10: begin // vmv.x.s,vfmv.f.s / vmv.s.x,vfmv.s.f (vcpop.m/vfirst.m rejected)
        unique case (funct3)
          3'b010, 3'b001: begin
            if (vs1_f == 5'h00) decoded_o.ctrl.op = VPOP_VMV_X_S;
            else operation_valid = 1'b0; // vcpop.m / vfirst.m -> different cluster
          end
          3'b110, 3'b101: begin decoded_o.ctrl.op = VPOP_VMV_S_X; decoded_o.form = VSRC_VX; end
          default: operation_valid = 1'b0;
        endcase
      end
      6'h27: begin // whole-register move: vs1 field encodes nreg-1 (0/1/3/7)
        if (funct3 == 3'b011) begin
          decoded_o.ctrl.op = VPOP_VMVNR;
          unique case (vs1_f)
            5'd0: decoded_o.beats = 4'd1;
            5'd1: decoded_o.beats = 4'd2;
            5'd3: decoded_o.beats = 4'd4;
            5'd7: decoded_o.beats = 4'd8;
            default: operation_valid = 1'b0;
          endcase
        end else operation_valid = 1'b0;
      end
      6'h14: begin // viota.m/vid.v/vmsbf.m/vmsof.m/vmsif.m, disambiguated by vs1
        if (funct3 == 3'b010) begin
          unique case (vs1_f)
            5'h11: decoded_o.ctrl.op = VPOP_VID;
            5'h10: decoded_o.ctrl.op = VPOP_VIOTA;
            5'h01: decoded_o.ctrl.op = VPOP_VMSBF;
            5'h02: decoded_o.ctrl.op = VPOP_VMSOF;
            5'h03: decoded_o.ctrl.op = VPOP_VMSIF;
            default: operation_valid = 1'b0;
          endcase
        end else operation_valid = 1'b0;
      end
      default: operation_valid = 1'b0;
    endcase

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

    // Whole-register move ignores vtype/vl entirely; beats was already set
    // above from the vs1-encoded register count, not from vlmul.
    if (!vpop_bypass_vtype(decoded_o.ctrl.op)) begin
      decoded_o.beats = beats;
      max_elements = (sew_bits == 0) ? 0 : ((VLEN / sew_bits) * int'(beats)) / fraction_div;
      if (max_elements == 0 || int'(cmd_i.vl) > max_elements || cmd_i.vill)
        operation_valid = 1'b0;
      if (beats > 1) begin
        if ((int'(decoded_o.vd) % int'(beats)) != 0 ||
            (int'(decoded_o.vs2) % int'(beats)) != 0 ||
            (decoded_o.form == VSRC_VV && (int'(decoded_o.vs1) % int'(beats)) != 0))
          operation_valid = 1'b0;
      end
    end

    decoded_o.illegal = !operation_valid;
    if (!operation_valid) decoded_o.ctrl.op = VPOP_INVALID;
  end

endmodule
