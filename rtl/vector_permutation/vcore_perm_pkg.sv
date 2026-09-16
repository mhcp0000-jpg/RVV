package vcore_perm_pkg;

  localparam int unsigned VCORE_VLEN = 128;

  typedef enum logic [2:0] {
    VSEW_8  = 3'b000,
    VSEW_16 = 3'b001,
    VSEW_32 = 3'b010,
    VSEW_64 = 3'b011
  } vsew_e;

  // FP forms (vfmv.*, vfslide1*.vf, vfmerge.vfm) share the same datapath as
  // their integer counterparts below -- bits are bits, this cluster does not
  // interpret them as floating point.
  typedef enum logic [4:0] {
    VPOP_VRGATHER,      // vv/vx/vi, form_e selects operand-2 source
    VPOP_VRGATHEREI16,  // vv only, index EEW fixed to 16 regardless of SEW
    VPOP_VSLIDEUP,      // vx/vi
    VPOP_VSLIDEDOWN,    // vx/vi
    VPOP_VSLIDE1UP,     // vx (+ vfslide1up.vf)
    VPOP_VSLIDE1DOWN,   // vx (+ vfslide1down.vf)
    VPOP_VCOMPRESS,     // vs1 = dense mask-select vector
    VPOP_VMERGE,        // vvm/vxm/vim (+ vfmerge.vfm), v0 = per-element selector
    VPOP_VMV_V,         // v.v/v.x/v.i (+ vfmv.v.f), unconditional copy/broadcast
    VPOP_VMV_X_S,       // (+ vfmv.f.s) vs2[0] -> scalar destination
    VPOP_VMV_S_X,       // (+ vfmv.s.f) scalar -> vd[0]
    VPOP_VMVNR,         // whole-register move, beats = 1/2/4/8
    VPOP_VIOTA,         // vs2 read AS a dense mask, output = prefix popcount
    VPOP_VID,           // vd[i] = i
    VPOP_VMSBF,         // vs2 read AS a dense mask, output = dense mask
    VPOP_VMSOF,
    VPOP_VMSIF,
    VPOP_INVALID
  } vpop_e;

  typedef enum logic [1:0] { VSRC_VV, VSRC_VX, VSRC_VI, VSRC_NONE } vsrc_form_e;

  typedef struct packed {
    vpop_e       op;
    logic [2:0]  sew;
    logic        vm;            // instruction bit 25: 1 = unmasked
    logic        vta;
    logic        vma;
    logic [16:0] vl;
    logic [16:0] vstart;
    logic [16:0] element_base;  // global element index of this beat's first lane
    logic [15:0] tag;
    logic [4:0]  vd_addr;
    logic        last_beat;
  } vcore_perm_ctrl_t;

  typedef struct packed {
    logic [15:0] tag;
    logic [4:0]  dest_addr;     // vd (vector) or rd/fd (scalar), context = is_scalar
    logic        is_scalar;
    logic        last_beat;
    logic        illegal_op;
  } vcore_perm_rsp_t;

  typedef struct packed {
    logic [31:0] inst;          // raw OP-V/OP-FP instruction
    logic [31:0] scalar;        // x[rs1]/f[rs1] already resolved, for .vx/.vf forms
    logic [2:0]  sew;
    logic [2:0]  vlmul;
    logic        vta;
    logic        vma;
    logic        vill;
    logic [16:0] vl;
    logic [16:0] vstart;
    logic [VCORE_VLEN-1:0] mask_snapshot; // TOP's coherent v0 copy at issue
    logic [15:0] tag;
  } vcore_perm_cmd_t;

  typedef struct packed {
    vcore_perm_ctrl_t ctrl;
    logic [1:0]  form;          // vsrc_form_e
    logic [31:0] scalar;
    logic [VCORE_VLEN-1:0] mask_snapshot;
    logic [4:0]  vd, vs1, vs2;
    logic [3:0]  beats;         // EMUL beats, or whole-register count for VPOP_VMVNR
    logic        illegal;
  } vcore_perm_decoded_t;

  typedef struct packed {
    vcore_perm_ctrl_t ctrl;
    logic [1:0]  form;
    logic [31:0] scalar;
    logic [VCORE_VLEN-1:0] mask_snapshot;
    logic [4:0]  vd_addr, vs1_addr, vs2_addr;
    logic        read_vs1, read_vs2;
    logic [2:0]  beat_index;
  } vcore_perm_uop_t;

  typedef struct packed {
    logic [4:0]  addr;
    logic [15:0] tag;
  } vcore_vrf_read_req_t;

  typedef struct packed {
    logic [4:0]  vd_addr;
    logic [15:0] tag;
  } vcore_vrf_write_req_t;

  typedef struct packed {
    logic [4:0]  rd_addr;
    logic [15:0] tag;
  } vcore_scalar_write_req_t;

  typedef struct packed {
    logic [15:0] tag;
    logic        last_beat;
    logic        illegal_op;
  } vcore_perm_commit_t;

  // standard vl/vstart/v0 tail-mask-undisturbed policy applies
  function automatic logic vpop_uses_predicate(input vpop_e op);
    case (op)
      VPOP_VRGATHER, VPOP_VRGATHEREI16,
      VPOP_VSLIDEUP, VPOP_VSLIDEDOWN, VPOP_VSLIDE1UP, VPOP_VSLIDE1DOWN,
      VPOP_VIOTA, VPOP_VID, VPOP_VMSBF, VPOP_VMSOF, VPOP_VMSIF: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // v0 picks between two full operands per element; vm field is encoding-fixed to 0
  function automatic logic vpop_uses_v0_selector(input vpop_e op);
    return (op == VPOP_VMERGE);
  endfunction

  // result is a dense 1-bit/element mask -> destination is always a single
  // physical register, never advances with beat_index (mirrors ALU mask_dest)
  function automatic logic vpop_is_mask_dest(input vpop_e op);
    case (op)
      VPOP_VMSBF, VPOP_VMSOF, VPOP_VMSIF: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // whole-register move ignores vl/vtype/vstart/v0 entirely
  function automatic logic vpop_bypass_vtype(input vpop_e op);
    return (op == VPOP_VMVNR);
  endfunction

  function automatic logic vpop_scalar_dest(input vpop_e op);
    return (op == VPOP_VMV_X_S);
  endfunction

  // only element 0 written, and only when vstart==0 (not the generic vstart rule)
  function automatic logic vpop_elem0_dest(input vpop_e op);
    return (op == VPOP_VMV_S_X);
  endfunction

  function automatic logic vpop_supported(input vpop_e op);
    return (op != VPOP_INVALID);
  endfunction

  function automatic logic vsew_supported(input logic [2:0] sew);
    case (sew)
      VSEW_8, VSEW_16, VSEW_32, VSEW_64: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

endpackage
