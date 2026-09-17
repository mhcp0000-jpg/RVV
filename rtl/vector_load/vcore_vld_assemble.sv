// Load datapath: slice this beat's destination register out of the group
// buffer and apply the RVV prestart / tail / mask policy chain. Purely
// combinational, mirroring vcore_perm_core (which does the same job for
// permutation results) -- with no routing network, because a unit-stride
// load's element e always lands in destination slot e.
//
// The policy chain is the same one the permutation cluster uses, reduced to
// the three cases a load can produce:
//
//   vstart >= evl              -> nothing updated at all (RVV 1.0 5.4)
//   slot < vstart              -> prestart, undisturbed
//   slot >= evl                -> tail, vta ? agnostic-ones : undisturbed
//   masked off (vm=0, v0[e]=0) -> inactive, vma ? agnostic-ones : undisturbed
//   otherwise                  -> the value fetched from memory
//
// "Agnostic" is implemented as all-ones, the same choice the permutation
// cluster and the ALU make, so the golden reference can be exact.
//
// EEW is a runtime value, so each width gets its own literal-width branch:
// a `+:` part-select width must be an elaboration-time constant, and a
// function argument of type int is not one even when every call site passes
// a literal (see the note at the top of vcore_perm_core).
module vcore_vld_assemble #(
  parameter int unsigned VLEN = 128
) (
  input  vcore_vld_pkg::vcore_vld_ctrl_t ctrl_i,
  input  logic [vcore_vld_pkg::MAXEMUL*VLEN-1:0] data_group_i,
  input  logic [VLEN-1:0] dst_old_i,
  input  logic [VLEN-1:0] mask_i,      // v0 snapshot, dense 1 bit per element
  output logic [VLEN-1:0] data_o,
  output logic            illegal_o
);
  import vcore_vld_pkg::*;
  localparam int unsigned MASK_IDX_W = $clog2(VLEN);
  localparam int unsigned GROUP_W    = MAXEMUL*VLEN;
  localparam int unsigned SLOTS8     = GROUP_W/8;
  localparam int unsigned SLOTS16    = GROUP_W/16;
  localparam int unsigned SLOTS32    = GROUP_W/32;
  localparam int unsigned SLOTS64    = GROUP_W/64;

  typedef enum logic [1:0] {SEL_OLD, SEL_ONES, SEL_LOAD} sel_e;

  // Which of the three sources owns destination slot `gidx` (a GLOBAL
  // element index inside the destination EMUL group)?
  function automatic sel_e slot_sel(
    input vcore_vld_ctrl_t ctrl,
    input logic [VLEN-1:0] mask,
    input logic [16:0] gidx
  );
    logic mbit;
    // RVV 1.0 5.4: "When vstart >= vl, there are no body elements, and no
    // elements are updated in any destination vector register group,
    // including that no tail elements are updated with agnostic values."
    if (ctrl.vstart >= ctrl.evl) return SEL_OLD;
    if (gidx < ctrl.vstart)      return SEL_OLD;              // prestart
    if (gidx >= ctrl.evl)        return ctrl.vta ? SEL_ONES : SEL_OLD; // tail
    mbit = (int'(gidx) < int'(VLEN)) ? mask[gidx[MASK_IDX_W-1:0]] : 1'b0;
    // RVV 1.0 7: "Masked vector loads do not update inactive elements in
    // the destination vector register group, unless mask agnostic is
    // specified (vtype.vma=1)."
    if (!ctrl.vm && !mbit)       return ctrl.vma ? SEL_ONES : SEL_OLD;
    return SEL_LOAD;
  endfunction

  logic [16:0] gidx;
  sel_e sel;

  always_comb begin
    data_o    = dst_old_i;
    illegal_o = !vld_supported(ctrl_i.op) || !veew_supported(ctrl_i.eew);
    gidx      = '0;
    sel       = SEL_OLD;

    if (!illegal_o) begin
      unique case (ctrl_i.eew)
        VEEW_8: for (int i = 0; i < VLEN/8; i++) begin
          gidx = ctrl_i.element_base + 17'(i);
          sel  = slot_sel(ctrl_i, mask_i, gidx);
          unique case (sel)
            SEL_ONES: data_o[i*8 +: 8] = '1;
            SEL_LOAD: data_o[i*8 +: 8] = data_group_i[(int'(gidx) % SLOTS8)*8 +: 8];
            default:  data_o[i*8 +: 8] = dst_old_i[i*8 +: 8];
          endcase
        end
        VEEW_16: for (int i = 0; i < VLEN/16; i++) begin
          gidx = ctrl_i.element_base + 17'(i);
          sel  = slot_sel(ctrl_i, mask_i, gidx);
          unique case (sel)
            SEL_ONES: data_o[i*16 +: 16] = '1;
            SEL_LOAD: data_o[i*16 +: 16] = data_group_i[(int'(gidx) % SLOTS16)*16 +: 16];
            default:  data_o[i*16 +: 16] = dst_old_i[i*16 +: 16];
          endcase
        end
        VEEW_32: for (int i = 0; i < VLEN/32; i++) begin
          gidx = ctrl_i.element_base + 17'(i);
          sel  = slot_sel(ctrl_i, mask_i, gidx);
          unique case (sel)
            SEL_ONES: data_o[i*32 +: 32] = '1;
            SEL_LOAD: data_o[i*32 +: 32] = data_group_i[(int'(gidx) % SLOTS32)*32 +: 32];
            default:  data_o[i*32 +: 32] = dst_old_i[i*32 +: 32];
          endcase
        end
        VEEW_64: for (int i = 0; i < VLEN/64; i++) begin
          gidx = ctrl_i.element_base + 17'(i);
          sel  = slot_sel(ctrl_i, mask_i, gidx);
          unique case (sel)
            SEL_ONES: data_o[i*64 +: 64] = '1;
            SEL_LOAD: data_o[i*64 +: 64] = data_group_i[(int'(gidx) % SLOTS64)*64 +: 64];
            default:  data_o[i*64 +: 64] = dst_old_i[i*64 +: 64];
          endcase
        end
        default: ;
      endcase
    end
  end

endmodule
