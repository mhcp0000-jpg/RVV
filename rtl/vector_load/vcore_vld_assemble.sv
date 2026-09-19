// Load datapath: slice this beat's destination register out of the group
// buffer and apply the RVV prestart / tail / mask policy chain. Purely
// combinational, and with no routing network -- element i of field f always
// lands in destination slot f*slots_per_field + i, which is where the
// request engine already wrote it.
//
// Policy is decided by the ELEMENT index, not the slot: for a segment load
// every field sees the same prestart/body/tail split, so the element index
// is the slot with the field number masked off. slots_per_field is always a
// power of two (regs_per_field and VLEN/EEW both are), so that mask is free.
//
//   vstart >= evl              -> nothing updated at all (RVV 1.0 5.4)
//   slot's element < vstart    -> prestart, undisturbed
//   slot's element >= evl      -> tail, vta ? agnostic-ones : undisturbed
//   masked off (vm=0, v0[i]=0) -> inactive, vma ? agnostic-ones : undisturbed
//   otherwise                  -> the value fetched from memory
//
// `evl` arrives already trimmed when a fault-only-first load hit an error,
// so a trim simply turns body elements into tail.
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

  logic [16:0] slots_mask;
  assign slots_mask = ctrl_i.slots_per_field - 17'd1;

  // Which of the three sources owns this destination slot?
  function automatic sel_e slot_sel(
    input vcore_vld_ctrl_t ctrl,
    input logic [VLEN-1:0] mask,
    input logic [16:0] elem
  );
    logic mbit;
    // RVV 1.0 5.4: when vstart >= vl no element is updated in any
    // destination group, not even a tail element with an agnostic value.
    if (ctrl.vstart >= ctrl.evl) return SEL_OLD;
    if (elem < ctrl.vstart)      return SEL_OLD;              // prestart
    if (elem >= ctrl.evl)        return ctrl.vta ? SEL_ONES : SEL_OLD;
    mbit = (int'(elem) < int'(VLEN)) ? mask[elem[MASK_IDX_W-1:0]] : 1'b0;
    // RVV 1.0 7: masked loads do not update inactive elements unless
    // mask-agnostic is set.
    if (!ctrl.vm && !mbit)       return ctrl.vma ? SEL_ONES : SEL_OLD;
    return SEL_LOAD;
  endfunction

  logic [16:0] gslot, gelem;
  sel_e sel;

  always_comb begin
    data_o    = dst_old_i;
    illegal_o = !vld_supported(ctrl_i.op) || !veew_supported(ctrl_i.eew);
    gslot     = '0;
    gelem     = '0;
    sel       = SEL_OLD;

    if (!illegal_o) begin
      unique case (ctrl_i.eew)
        VEEW_8: for (int i = 0; i < VLEN/8; i++) begin
          gslot = ctrl_i.element_base + 17'(i);
          gelem = gslot & slots_mask;
          sel   = slot_sel(ctrl_i, mask_i, gelem);
          unique case (sel)
            SEL_ONES: data_o[i*8 +: 8] = '1;
            SEL_LOAD: data_o[i*8 +: 8] = data_group_i[(int'(gslot) % SLOTS8)*8 +: 8];
            default:  data_o[i*8 +: 8] = dst_old_i[i*8 +: 8];
          endcase
        end
        VEEW_16: for (int i = 0; i < VLEN/16; i++) begin
          gslot = ctrl_i.element_base + 17'(i);
          gelem = gslot & slots_mask;
          sel   = slot_sel(ctrl_i, mask_i, gelem);
          unique case (sel)
            SEL_ONES: data_o[i*16 +: 16] = '1;
            SEL_LOAD: data_o[i*16 +: 16] = data_group_i[(int'(gslot) % SLOTS16)*16 +: 16];
            default:  data_o[i*16 +: 16] = dst_old_i[i*16 +: 16];
          endcase
        end
        VEEW_32: for (int i = 0; i < VLEN/32; i++) begin
          gslot = ctrl_i.element_base + 17'(i);
          gelem = gslot & slots_mask;
          sel   = slot_sel(ctrl_i, mask_i, gelem);
          unique case (sel)
            SEL_ONES: data_o[i*32 +: 32] = '1;
            SEL_LOAD: data_o[i*32 +: 32] = data_group_i[(int'(gslot) % SLOTS32)*32 +: 32];
            default:  data_o[i*32 +: 32] = dst_old_i[i*32 +: 32];
          endcase
        end
        VEEW_64: for (int i = 0; i < VLEN/64; i++) begin
          gslot = ctrl_i.element_base + 17'(i);
          gelem = gslot & slots_mask;
          sel   = slot_sel(ctrl_i, mask_i, gelem);
          unique case (sel)
            SEL_ONES: data_o[i*64 +: 64] = '1;
            SEL_LOAD: data_o[i*64 +: 64] = data_group_i[(int'(gslot) % SLOTS64)*64 +: 64];
            default:  data_o[i*64 +: 64] = dst_old_i[i*64 +: 64];
          endcase
        end
        default: ;
      endcase
    end
  end

endmodule
