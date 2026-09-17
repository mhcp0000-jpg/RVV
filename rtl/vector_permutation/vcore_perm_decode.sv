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
          3'b100:  begin decoded_o.form = VSRC_VX; decoded_o.ctrl.idx_from_scalar = 1'b1; end
          3'b011:  begin decoded_o.form = VSRC_VI; decoded_o.scalar = {27'd0, vs1_f};
                         decoded_o.ctrl.idx_from_scalar = 1'b1; end // uimm5
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
          // vmv.v.* is vmerge with vm=1, and the encoding fixes vs2 to v0;
          // a non-zero vs2 there is a reserved encoding.
          3'b000: begin
            decoded_o.form = VSRC_VV;
            decoded_o.ctrl.op = vm ? VPOP_VMV_V : VPOP_VMERGE;
            if (vm && (vs2_f != 5'd0)) operation_valid = 1'b0;
          end
          3'b100, 3'b101: begin // .vx / vfmv.v.f,vfmerge.vfm(.vf) share the .vx datapath
            decoded_o.form = VSRC_VX;
            decoded_o.ctrl.op = vm ? VPOP_VMV_V : VPOP_VMERGE;
            if (vm && (vs2_f != 5'd0)) operation_valid = 1'b0;
          end
          3'b011: begin // simm5
            decoded_o.form = VSRC_VI;
            decoded_o.scalar = {{27{vs1_f[4]}}, vs1_f};
            decoded_o.ctrl.op = vm ? VPOP_VMV_V : VPOP_VMERGE;
            if (vm && (vs2_f != 5'd0)) operation_valid = 1'b0;
          end
          default: operation_valid = 1'b0;
        endcase
      end
      6'h10: begin // vmv.x.s,vfmv.f.s / vmv.s.x,vfmv.s.f (vcpop.m/vfirst.m rejected)
        unique case (funct3)
          3'b010, 3'b001: begin
            if (vs1_f == 5'h00) begin
              decoded_o.ctrl.op = VPOP_VMV_X_S;
              decoded_o.ctrl.is_fp = (funct3 == 3'b001); // 001=OPFVV(vfmv.f.s)->FPR, 010=OPMVV(vmv.x.s)->GPR
              operation_valid &= vm; // masked vmv.x.s/vfmv.f.s is reserved
            end else operation_valid = 1'b0; // vcpop.m / vfirst.m -> different cluster
          end
          3'b110, 3'b101: begin
            decoded_o.ctrl.op = VPOP_VMV_S_X; decoded_o.form = VSRC_VX;
            // masked form is reserved; the encoding also fixes vs2 to v0
            operation_valid &= vm;
            if (vs2_f != 5'd0) operation_valid = 1'b0;
          end
          default: operation_valid = 1'b0;
        endcase
      end
      6'h27: begin // whole-register move: vs1 field encodes nreg-1 (0/1/3/7)
        if (funct3 == 3'b011) begin
          decoded_o.ctrl.op = VPOP_VMVNR;
          operation_valid &= vm; // vmv<nr>r.v is unmasked by encoding
          decoded_o.beats = 4'd1; // safe default so an invalid vs1_f below can't leave beats==0
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

    // group_regs reflects the real LMUL grouping regardless of the
    // single-beat override below; vcore_perm_sequencer re-derives its own
    // copy from decoded.beats independently, this one is only for the
    // ei16 index-register legality check right after.
    decoded_o.ctrl.group_regs = beats;

    // Whole-register move ignores vtype/vl entirely; beats was already set
    // above from the vs1-encoded register count, not from vlmul.
    if (!vpop_bypass_vtype(decoded_o.ctrl.op)) begin
      // vl's legal range is still governed by the real LMUL grouping (max_elements
      // below), even for vmsbf/vmsof/vmsif whose own operands never group --
      // only the sequencer's iteration count collapses to a single beat for them.
      decoded_o.beats = vpop_single_beat(decoded_o.ctrl.op) ? 4'd1 : beats;
      max_elements = (sew_bits == 0) ? 0 : ((VLEN / sew_bits) * int'(beats)) / fraction_div;
      // VLMAX must reach the datapath: a fractional LMUL still occupies one
      // whole register, so group_regs alone cannot express it and the
      // "index >= VLMAX returns 0" rule would use the wrong bound.
      decoded_o.ctrl.vlmax = 17'(max_elements);
      if (max_elements == 0 || int'(cmd_i.vl) > max_elements || cmd_i.vill)
        operation_valid = 1'b0;

      // RVV 1.0 15.1/15.2/16.5: these raise an illegal-instruction exception
      // on a non-zero vstart rather than resuming mid-way.
      if (vpop_requires_vstart_zero(decoded_o.ctrl.op) && (cmd_i.vstart != 17'd0))
        operation_valid = 1'b0;
      // vd/vs2/vs1 must each be aligned to a multiple of beats ONLY when that
      // operand actually groups with LMUL. viota's vs2, vcompress's vs1 and
      // vmsbf/vmsof/vmsif's vd are single non-grouping mask registers (see
      // vpop_vs2_is_mask_src/vpop_vs1_is_mask_src/vpop_is_mask_dest) and are
      // exempt -- otherwise, e.g., "viota.m v4, v1" at LMUL=2 (vs2=1) would
      // be wrongly rejected even though v1 is never grouped.
      // RVV 1.0 16.1: "The integer scalar read/write instructions ... ignore
      // LMUL and vector register groups." vmv.x.s writes a scalar rd, and
      // vmv.s.x touches exactly one vector register, so neither operand is
      // subject to the EMUL alignment rule. vmsbf/vmsof/vmsif are likewise
      // single-register on both sides; they were already exempt through the
      // mask-operand tests below, these two were not.
      if ((beats > 1) && !vpop_single_beat(decoded_o.ctrl.op)) begin
        if ((!vpop_is_mask_dest(decoded_o.ctrl.op) && (int'(decoded_o.vd) % int'(beats)) != 0) ||
            (!vpop_vs2_is_mask_src(decoded_o.ctrl.op) && (int'(decoded_o.vs2) % int'(beats)) != 0) ||
            (decoded_o.form == VSRC_VV && !vpop_vs1_is_mask_src(decoded_o.ctrl.op) &&
             (int'(decoded_o.vs1) % int'(beats)) != 0))
          operation_valid = 1'b0;
      end

      // vrgatherei16's index operand (vs1, EEW=16) can need more physical
      // registers than the data group when SEW<16 -- reject combinations
      // the group buffer (sized MAXLMUL registers) can't hold.
      if (decoded_o.ctrl.op == VPOP_VRGATHEREI16) begin
        if (vpop_ei16_idx_regs(decoded_o.ctrl, VLEN) > MAXLMUL)
          operation_valid = 1'b0;
      end

      // Destination-overlaps-source is illegal for gather/slide/compress:
      // an implementation may read and route source elements out of order,
      // so vd must not alias any register vs2 (or the grouping vs1 index/
      // compress mask-select) will be read from during the same instruction.
      unique case (decoded_o.ctrl.op)
        // Only vslideup and vslide1up carry the non-overlap constraint
        // (RVV 1.0 16.3.1 / 16.3.3). vslidedown and vslide1down read towards
        // higher indices and are explicitly allowed to work in place, so
        // rejecting them would turn legal code into an illegal instruction.
        VPOP_VRGATHER, VPOP_VRGATHEREI16,
        VPOP_VSLIDEUP, VPOP_VSLIDE1UP: begin
          if (regs_overlap(decoded_o.vd, int'(beats), decoded_o.vs2, int'(beats)))
            operation_valid = 1'b0;
          if (decoded_o.form == VSRC_VV) begin
            if (decoded_o.ctrl.op == VPOP_VRGATHEREI16) begin
              if (regs_overlap(decoded_o.vd, int'(beats), decoded_o.vs1,
                                vpop_ei16_idx_regs(decoded_o.ctrl, VLEN)))
                operation_valid = 1'b0;
            end else if (regs_overlap(decoded_o.vd, int'(beats), decoded_o.vs1, int'(beats)))
              operation_valid = 1'b0;
          end
        end
        VPOP_VCOMPRESS: begin
          if (regs_overlap(decoded_o.vd, int'(beats), decoded_o.vs2, int'(beats)) ||
              regs_overlap(decoded_o.vd, int'(beats), decoded_o.vs1, 1))
            operation_valid = 1'b0;
        end
        // viota.m and the vmsbf/vmsof/vmsif scans: "The destination register
        // group cannot overlap the source register and, if masked, cannot
        // overlap the mask register (v0)." (RVV 1.0 15.1 / 15.2). viota's
        // destination groups with LMUL; the scans' destination is a single
        // mask register. Their vs2 is always one non-grouping register.
        VPOP_VIOTA, VPOP_VMSBF, VPOP_VMSOF, VPOP_VMSIF: begin
          if (regs_overlap(decoded_o.vd,
                           vpop_is_mask_dest(decoded_o.ctrl.op) ? 1 : int'(beats),
                           decoded_o.vs2, 1))
            operation_valid = 1'b0;
          if (!vm && regs_overlap(decoded_o.vd,
                                  vpop_is_mask_dest(decoded_o.ctrl.op) ? 1 : int'(beats),
                                  5'd0, 1))
            operation_valid = 1'b0;
        end
        default: ;
      endcase
    end else begin
      // VPOP_VMVNR: vd and vs2 must each be aligned to a multiple of the
      // whole-register count (decoded_o.beats, set from the vs1 field above).
      if (int'(decoded_o.vd) % int'(decoded_o.beats) != 0 ||
          int'(decoded_o.vs2) % int'(decoded_o.beats) != 0)
        operation_valid = 1'b0;
      // RVV 1.0 16.6: the usual "nothing written when vstart >= vl" does not
      // apply here; the bound is evl = NREG * VLEN / SEW instead. Carried in
      // ctrl.vlmax. An unusable SEW cannot gate a vtype-independent move, so
      // it degenerates to "always write".
      decoded_o.ctrl.vlmax = (sew_bits == 0) ? 17'h1ffff
                           : 17'(int'(decoded_o.beats) * (VLEN / sew_bits));
    end

    decoded_o.illegal = !operation_valid;
    if (!operation_valid) decoded_o.ctrl.op = VPOP_INVALID;
  end

endmodule
