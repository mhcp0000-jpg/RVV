// Permutation datapath: gather/slide/compress/merge/mv/mask-scan + the
// common vstart/tail/predicate policy chain, mirroring vcore_alu_slice's
// execute_lane structure. Unlike the ALU, crossbar-style routing does not
// benefit from splitting VLEN into two 64-bit phases, so this runs the full
// width in one combinational pass (see vcore_perm_pipe for the 1-cycle latch).
//
// EEW is a genuine runtime `int` inside perm_lane (call sites just happen to
// pass literals), so any element access there uses fld_get/fld_get_wide
// (variable SHIFT + mask) rather than a variable-WIDTH part-select
// (`vec[idx*EEW +: EEW]`): Verilator (and synthesis tools generally) require
// a `+:`/`-:` select width to be a true elaboration-time constant, which a
// function's `int` parameter is not, even when every call site happens to
// pass a literal -- there is no cross-call constant propagation. The 4 SEW
// dispatch branches below still use literal widths directly (e.g. `i*8 +: 8`
// inside the VSEW_8 case), which IS constant at each unrolled `i`, so those
// are untouched.
//
// LMUL>1 handling: vrgather/vrgatherei16/vslideup/vslidedown/vslide1up/
// vslide1down/vcompress can reach into ANY register of vs2's EMUL group, not
// just the register belonging to the current destination beat. vcore_perm_
// vrf_request preloads the whole group (up to MAXLMUL registers) into
// src2_group_i before the first beat executes, addressed here by GLOBAL
// element index (ctrl.group_regs * elements-per-register bounds it). vs1/vd
// still address their own beat's register normally, because index vectors
// and destinations line up 1:1 with the destination beat. vcompress's vs1
// (mask-select) and viota/vmsbf/vmsof/vmsif's vs2 (mask-to-scan) are, by
// RVV definition, single non-grouping registers regardless of vlmul -- they
// arrive as the plain `src2_i`/`src1_i` single-register ports (see
// vpop_vs1_is_mask_src/vpop_vs2_is_mask_src) and are addressed by absolute
// bit position, which is why viota's prefix count scans from bit 0 rather
// than from this beat's element_base. This scan is written as a simple
// bound-VLEN comparison-gated sum for clarity; a real implementation would
// share one prefix-popcount tree across all lanes instead of recomputing it
// per lane.
module vcore_perm_core #(
  parameter int unsigned VLEN = 128
) (
  input  vcore_perm_pkg::vcore_perm_ctrl_t ctrl_i,
  input  logic [31:0]     scalar_i,
  input  logic [VLEN-1:0] src1_i,       // vs1 data, or broadcast(scalar/imm) when form!=VV
  input  logic [VLEN-1:0] src2_i,       // this beat's own vs2 register (or the fixed single
                                        // mask register for vcompress's vs1 role is src1_i;
                                        // viota/vmsbf/vmsof/vmsif's mask-to-scan is this src2_i)
  input  logic [vcore_perm_pkg::MAXLMUL*VLEN-1:0] src2_group_i, // full vs2 EMUL group, gather/slide/compress only
  input  logic [vcore_perm_pkg::MAXLMUL*VLEN-1:0] src1_idx_group_i, // vrgatherei16's own EEW=16 index group only
  input  logic [VLEN-1:0] dst_old_i,
  input  logic [VLEN-1:0] mask_i,       // v0 snapshot, dense 1 bit/element
  output logic [VLEN-1:0] data_o,
  output logic             is_scalar_o,
  output logic [31:0]      scalar_data_o,
  output logic             illegal_o
);
  import vcore_perm_pkg::*;
  localparam int unsigned MASK_IDX_W = $clog2(VLEN);
  localparam int unsigned GROUP_W = MAXLMUL*VLEN;
  // EEW=16 index slots the group buffer can hold; kept as a localparam so
  // the width cast below has a plain constant to widen (Verilator WIDTHEXPAND).
  localparam int unsigned GROUP_IDX_SLOTS = GROUP_W/16;

  typedef struct packed {
    logic [63:0] data;
    logic        mbit;
  } lane_result_t;

  // Extract an `eew`-wide (<=64) field at element index `idx` from a
  // VLEN-wide vector, zero-extended to 64 bits. `eew`/`idx` are runtime
  // values -- this uses a variable SHIFT (always legal, any runtime amount)
  // plus a fixed-width mask, never a variable-width part-select.
  function automatic logic [63:0] fld_get(input logic [VLEN-1:0] vec, input int idx, input int eew);
    logic [VLEN-1:0] shifted;
    logic [63:0] mask;
    shifted = vec >> (idx*eew);
    mask = (eew >= 64) ? 64'hffff_ffff_ffff_ffff : ((64'h1 << eew) - 64'h1);
    fld_get = shifted[63:0] & mask;
  endfunction

  // Same, but reading from a MAXLMUL*VLEN-wide group buffer.
  function automatic logic [63:0] fld_get_wide(input logic [GROUP_W-1:0] vec, input int idx, input int eew);
    logic [GROUP_W-1:0] shifted;
    logic [63:0] mask;
    shifted = vec >> (idx*eew);
    mask = (eew >= 64) ? 64'hffff_ffff_ffff_ffff : ((64'h1 << eew) - 64'h1);
    fld_get_wide = shifted[63:0] & mask;
  endfunction

  // Computes one output lane. Runtime-valued indices (gather index, slide
  // offset, compress source position) are always range-checked before use
  // so fld_get(_wide)'s idx argument stays within the source's element count
  // regardless of which branch is architecturally "live".
  function automatic lane_result_t perm_lane(
    input logic [VLEN-1:0] src2,
    input logic [VLEN-1:0] src1,
    input logic [GROUP_W-1:0] src2_group,
    input logic [GROUP_W-1:0] src1_idx_group,
    input logic [VLEN-1:0] dst_old,
    input logic [VLEN-1:0] mask,
    input logic [31:0]     scalar,
    input int              i,
    input int              EEW,
    input int              N,
    input int              total_count,
    input vcore_perm_ctrl_t ctrl,
    input logic [16:0]     global_index
  );
    lane_result_t ret;
    logic [63:0] computed;
    logic        computed_bit;
    logic        mask_bit;            // v0 for this element: activity, not a result
    logic        slide_up_below_offset;
    logic [63:0] idx, gidx;
    logic [63:0] group_size;
    logic        in_range;
    int          idx_safe; // element index into src2_group/src1_idx_group, range-checked before use
    logic        gi16_in_range;
    int          gi16_safe;
    int k, cnt, src_pos;
    logic found_before, mbit_here;

    mask_bit = mask[global_index[MASK_IDX_W-1:0]];
    ret.data = fld_get(dst_old, i, EEW);
    // Default for a mask destination is the OLD destination bit, so an
    // element the policy chain declines to write stays undisturbed. (It used
    // to default to the v0 bit, which would have written the mask itself.)
    ret.mbit = dst_old[global_index[MASK_IDX_W-1:0]];
    computed = '0;
    computed_bit = 1'b0;
    // VLMAX, not group_regs*N: a fractional LMUL occupies a whole register
    // but only VLMAX of its elements exist (RVV 1.0 16.4 / 16.3.2).
    group_size = 64'(ctrl.vlmax);
    slide_up_below_offset = (ctrl.op == VPOP_VSLIDEUP) &&
                            (64'(global_index) < 64'(scalar));

    unique case (ctrl.op)
      VPOP_VRGATHER: begin
        // .vx/.vi take the index from the raw scalar: RVV 1.0 16.4 says it is
        // zero-extended to XLEN and NOT truncated to SEW, so the SEW-wide
        // broadcast sitting in src1 cannot be used for it.
        idx = ctrl.idx_from_scalar ? {32'd0, scalar} : fld_get(src1, i, EEW);
        in_range = idx < group_size;
        idx_safe = in_range ? int'(idx) : 0;
        computed = in_range ? fld_get_wide(src2_group, idx_safe, EEW) : 64'd0;
      end

      VPOP_VRGATHEREI16: begin
        // Index comes entirely from src1_idx_group (its own, independently
        // sized EEW=16 group buffer, see vpop_ei16_idx_regs), addressed by
        // GLOBAL element position -- vs1 lines up 1:1 with the destination
        // the same way it does for plain vrgather, just at a different EEW.
        // Bounds-checked separately since the index buffer (GROUP_W/16
        // slots) can be narrower than the 0..127 global_index range.
        gi16_in_range = (64'(global_index) < 64'(GROUP_IDX_SLOTS));
        gi16_safe = gi16_in_range ? int'(global_index) : 0;
        idx = gi16_in_range ? fld_get_wide(src1_idx_group, gi16_safe, 16) : 64'hffff_ffff_ffff_ffff;
        in_range = idx < group_size;
        idx_safe = in_range ? int'(idx) : 0;
        computed = in_range ? fld_get_wide(src2_group, idx_safe, EEW) : 64'd0;
      end

      VPOP_VSLIDEUP: begin
        if (64'(global_index) < 64'(scalar)) computed = fld_get(dst_old, i, EEW); // below offset: unchanged
        else begin
          gidx = 64'(global_index) - 64'(scalar);
          in_range = gidx < group_size;
          idx_safe = in_range ? int'(gidx) : 0;
          computed = in_range ? fld_get_wide(src2_group, idx_safe, EEW) : 64'd0;
        end
      end

      VPOP_VSLIDEDOWN: begin
        gidx = 64'(global_index) + 64'(scalar);
        in_range = gidx < group_size;
        idx_safe = in_range ? int'(gidx) : 0;
        computed = in_range ? fld_get_wide(src2_group, idx_safe, EEW) : 64'd0;
      end

      VPOP_VSLIDE1UP: begin
        if (global_index == 17'd0) computed = 64'(scalar);
        else begin
          gidx = 64'(global_index) - 64'd1;
          in_range = gidx < group_size;
          idx_safe = in_range ? int'(gidx) : 0;
          computed = in_range ? fld_get_wide(src2_group, idx_safe, EEW) : 64'd0;
        end
      end

      VPOP_VSLIDE1DOWN: begin
        if (64'(global_index) == 64'(ctrl.vl) - 64'd1) computed = 64'(scalar);
        else begin
          gidx = 64'(global_index) + 64'd1;
          in_range = gidx < group_size;
          idx_safe = in_range ? int'(gidx) : 0;
          computed = in_range ? fld_get_wide(src2_group, idx_safe, EEW) : 64'd0;
        end
      end

      VPOP_VCOMPRESS: begin
        // vs1 (src1) is the mask-select operand, a single non-grouping
        // register addressed by absolute bit position (vpop_vs1_is_mask_src);
        // src2_group holds the full vs2 source group. Destination position
        // is global_index, so we search for the global_index-th set bit
        // across the WHOLE group's mask (bound VLEN, gated by group_size).
        // RVV 1.0 16.5 packs "the first vl elements of vs2": mask bits at or
        // past vl select nothing, so the scan stops at vl, not at VLMAX.
        cnt = 0; src_pos = VLEN;
        for (k = 0; k < VLEN; k++)
          if (64'(k) < 64'(ctrl.vl) && src1[k]) begin
            if (cnt == int'(global_index)) src_pos = k;
            cnt++;
          end
        in_range = src_pos < VLEN;
        idx_safe = in_range ? src_pos : 0;
        computed = in_range ? fld_get_wide(src2_group, idx_safe, EEW) : fld_get(dst_old, i, EEW);
      end

      VPOP_VMERGE: computed = mask_bit ? fld_get(src1, i, EEW) : fld_get(src2, i, EEW);
      VPOP_VMV_V:  computed = fld_get(src1, i, EEW);

      VPOP_VIOTA: begin
        // src2 is the mask-to-scan, a single non-grouping register (vpop_vs2_
        // is_mask_src) that holds the SAME complete content on every beat --
        // so the prefix count must scan from absolute bit 0, not this beat's
        // local element_base, even though element_base itself does advance
        // (viota's destination groups with LMUL).
        // RVV 1.0 15.2: "This instruction can be masked, in which case only
        // the enabled elements contribute to the sum." Inactive elements are
        // skipped by the accumulator even though they still occupy a slot.
        cnt = 0;
        for (k = 0; k < VLEN; k++)
          if (64'(k) < 64'(global_index) && 64'(k) < 64'(ctrl.vl) &&
              (ctrl.vm || mask[k]) && src2[k]) cnt++;
        computed = 64'(cnt);
      end
      VPOP_VID: computed = 64'(global_index);

      VPOP_VMSBF, VPOP_VMSOF, VPOP_VMSIF: begin
        // Dispatched with EEW=1, N=VLEN, element_base=0 (vpop_single_beat),
        // so global_index==i and this scan is already absolute.
        // RVV 1.0 15.1: "before the first ACTIVE source element that is a 1".
        // A set bit in an inactive element must not terminate the run.
        found_before = 1'b0;
        for (k = 0; k < i; k++)
          if (64'(k) < 64'(ctrl.vl) && (ctrl.vm || mask[k]) && src2[k])
            found_before = 1'b1;
        mbit_here = src2[i];
        unique case (ctrl.op)
          VPOP_VMSBF: computed_bit = !found_before && !mbit_here;
          VPOP_VMSOF: computed_bit = !found_before &&  mbit_here;
          VPOP_VMSIF: computed_bit = !found_before;
          default: ;
        endcase
      end

      default: ; // VMV_X_S / VMV_S_X / VMVNR are handled outside the lane loop
    endcase

    // -- vstart / tail / predicate policy, mirrors vcore_alu_slice execute_lane --
    if (ctrl.vstart >= ctrl.vl) begin
      // RVV 1.0 5.4: "When vstart >= vl, there are no body elements, and no
      // elements are updated in any destination vector register group,
      // including that no tail elements are updated with agnostic values."
      // Covers vl = 0 as well. (vmv.x.s/vfmv.f.s are exempt and never reach
      // this function -- they are handled outside the lane loop.)
    end else if (global_index < ctrl.vstart) begin
      // prestart: element left undisturbed (ret already defaults to dst_old)
    end else if ((global_index >= ctrl.vl) ||
                 (ctrl.op == VPOP_VCOMPRESS && int'(global_index) >= total_count)) begin
      if (vpop_is_mask_dest(ctrl.op)) ret.mbit = 1'b1; // mask-dest tail is agnostic
      else if (ctrl.vta) ret.data = '1;
    end else if (slide_up_below_offset) begin
      // RVV 1.0 16.3.1 tabulates 0 <= i < max(vstart, OFFSET) as Unchanged.
      // That is stronger than the inactive-element policy, so an agnostic
      // fill must not reach this region even when vma = 1.
    end else if (vpop_uses_v0_selector(ctrl.op)) begin
      ret.data = computed;
    end else if (!ctrl.vm && !mask_bit && vpop_uses_predicate(ctrl.op)) begin
      if (vpop_is_mask_dest(ctrl.op)) begin
        if (ctrl.vma) ret.mbit = 1'b1;
      end else if (ctrl.vma) ret.data = '1;
    end else if (vpop_is_mask_dest(ctrl.op)) begin
      ret.mbit = computed_bit;
    end else begin
      ret.data = computed;
    end

    return ret;
  endfunction

  lane_result_t lane;
  logic [16:0] global_index;
  int unsigned total_count;

  always_comb begin : p_execute
    data_o = dst_old_i;
    is_scalar_o = 1'b0;
    scalar_data_o = '0;
    illegal_o = !vpop_supported(ctrl_i.op) || !vsew_supported(ctrl_i.sew);
    lane = '0;
    global_index = '0;
    total_count = 0;

    if (!illegal_o) begin
      unique case (ctrl_i.op)
        // Whole-register bypass: no vl/vtype/mask, no grouping. The one rule
        // that does apply is RVV 1.0 16.6 -- nothing is written when
        // vstart >= evl, with evl = NREG * VLEN / SEW carried in ctrl.vlmax.
        VPOP_VMVNR: data_o = (ctrl_i.vstart < ctrl_i.vlmax) ? src2_i : dst_old_i;

        VPOP_VMV_X_S: begin // single-beat (vpop_single_beat): vs2 never groups for this op
          is_scalar_o = 1'b1;
          unique case (ctrl_i.sew)
            VSEW_8:           scalar_data_o = {24'd0, src2_i[7:0]};
            VSEW_16:          scalar_data_o = {16'd0, src2_i[15:0]};
            VSEW_32, VSEW_64: scalar_data_o = src2_i[31:0]; // RV32: SEW>XLEN truncates to low XLEN
            default: scalar_data_o = '0;
          endcase
        end

        VPOP_VMV_S_X: begin // single-beat: only vd[0] of the one destination register
          data_o = dst_old_i;
          if ((ctrl_i.vl != 17'd0) && (ctrl_i.vstart == 17'd0)) begin // exact vstart==0 rule, not generic prestart
            unique case (ctrl_i.sew)
              VSEW_8:  data_o[7:0]  = scalar_i[7:0];
              VSEW_16: data_o[15:0] = scalar_i[15:0];
              VSEW_32: data_o[31:0] = scalar_i;
              VSEW_64: data_o[63:0] = {{32{scalar_i[31]}}, scalar_i}; // sign-extend when SEW>XLEN
              default: ;
            endcase
          end
        end

        VPOP_VMSBF, VPOP_VMSOF, VPOP_VMSIF: begin
          // Single beat, mask-format: N is VLEN raw bit positions, not VLEN/SEW
          // elements -- SEW is irrelevant to this op's own width.
          for (int i = 0; i < VLEN; i++) begin
            global_index = 17'(i);
            lane = perm_lane(src2_i,src1_i,src2_group_i,src1_idx_group_i,dst_old_i,mask_i,scalar_i,i,1,VLEN,
                              0,ctrl_i,global_index);
            data_o[i] = lane.mbit;
          end
        end

        default: begin
          unique case (ctrl_i.sew)
            VSEW_8: begin
              for (int k = 0; k < VLEN; k++)
                if (64'(k) < 64'(ctrl_i.vl) && src1_i[k]) total_count++;
              for (int i = 0; i < VLEN/8; i++) begin
                global_index = ctrl_i.element_base + 17'(i);
                lane = perm_lane(src2_i,src1_i,src2_group_i,src1_idx_group_i,dst_old_i,mask_i,scalar_i,i,8,VLEN/8,
                                  int'(total_count),ctrl_i,global_index);
                if (vpop_is_mask_dest(ctrl_i.op)) data_o[global_index[MASK_IDX_W-1:0]] = lane.mbit;
                else data_o[i*8 +: 8] = lane.data[7:0];
              end
            end
            VSEW_16: begin
              for (int k = 0; k < VLEN; k++)
                if (64'(k) < 64'(ctrl_i.vl) && src1_i[k]) total_count++;
              for (int i = 0; i < VLEN/16; i++) begin
                global_index = ctrl_i.element_base + 17'(i);
                lane = perm_lane(src2_i,src1_i,src2_group_i,src1_idx_group_i,dst_old_i,mask_i,scalar_i,i,16,VLEN/16,
                                  int'(total_count),ctrl_i,global_index);
                if (vpop_is_mask_dest(ctrl_i.op)) data_o[global_index[MASK_IDX_W-1:0]] = lane.mbit;
                else data_o[i*16 +: 16] = lane.data[15:0];
              end
            end
            VSEW_32: begin
              for (int k = 0; k < VLEN; k++)
                if (64'(k) < 64'(ctrl_i.vl) && src1_i[k]) total_count++;
              for (int i = 0; i < VLEN/32; i++) begin
                global_index = ctrl_i.element_base + 17'(i);
                lane = perm_lane(src2_i,src1_i,src2_group_i,src1_idx_group_i,dst_old_i,mask_i,scalar_i,i,32,VLEN/32,
                                  int'(total_count),ctrl_i,global_index);
                if (vpop_is_mask_dest(ctrl_i.op)) data_o[global_index[MASK_IDX_W-1:0]] = lane.mbit;
                else data_o[i*32 +: 32] = lane.data[31:0];
              end
            end
            VSEW_64: begin
              for (int k = 0; k < VLEN; k++)
                if (64'(k) < 64'(ctrl_i.vl) && src1_i[k]) total_count++;
              for (int i = 0; i < VLEN/64; i++) begin
                global_index = ctrl_i.element_base + 17'(i);
                lane = perm_lane(src2_i,src1_i,src2_group_i,src1_idx_group_i,dst_old_i,mask_i,scalar_i,i,64,VLEN/64,
                                  int'(total_count),ctrl_i,global_index);
                if (vpop_is_mask_dest(ctrl_i.op)) data_o[global_index[MASK_IDX_W-1:0]] = lane.mbit;
                else data_o[i*64 +: 64] = lane.data[63:0];
              end
            end
            default: data_o = dst_old_i;
          endcase
        end
      endcase
    end
  end

endmodule
