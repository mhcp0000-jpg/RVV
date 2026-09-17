package vcore_perm_pkg;

  localparam int unsigned VCORE_VLEN = 128;
  localparam int unsigned MAXLMUL = 8; // widest EMUL group vs2 group-buffering must hold

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
    logic        is_fp;         // vmv.x.s(0)/vfmv.f.s(1): which scalar regfile the result targets
    logic        vta;
    logic        vma;
    logic [16:0] vl;
    logic [16:0] vstart;
    logic [16:0] element_base;  // global element index of this beat's first lane
    logic [3:0]  group_regs;    // registers in the source EMUL group (for vs2 group-buffer bound checks)
    logic [15:0] tag;
    logic [4:0]  vd_addr;
    logic        last_beat;
  } vcore_perm_ctrl_t;

  typedef struct packed {
    logic [15:0] tag;
    logic [4:0]  dest_addr;     // vd (vector) or rd/fd (scalar), context = is_scalar
    logic        is_scalar;
    logic        is_fp;         // valid only when is_scalar: 0=GPR(vmv.x.s) 1=FPR(vfmv.f.s)
    logic [31:0] scalar_data;   // valid only when is_scalar (vmv.x.s/vfmv.f.s)
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
    logic [4:0]  vs2_base_addr; // un-adjusted vs2 (decode's vs2 field), for group preload addressing
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
    logic        is_fp;   // 0 -> integer regfile (vmv.x.s), 1 -> FP regfile (vfmv.f.s)
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

  // mask operands never group with LMUL: vcompress's vs1 (mask-select) and
  // viota/vmsbf/vmsof/vmsif's vs2 (mask-to-scan) always address the same
  // single physical register across every beat, exactly like v0/mask_snapshot.
  function automatic logic vpop_vs1_is_mask_src(input vpop_e op);
    return (op == VPOP_VCOMPRESS);
  endfunction

  function automatic logic vpop_vs2_is_mask_src(input vpop_e op);
    case (op)
      VPOP_VIOTA, VPOP_VMSBF, VPOP_VMSOF, VPOP_VMSIF: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // vs2 can supply data to ANY lane of the destination group (gather index /
  // slide offset can reach into a different physical register than the one
  // this beat's destination lives in). These ops need the whole vs2 EMUL
  // group preloaded into a buffer before any destination beat is emitted --
  // see vcore_perm_vrf_request's PRELOAD states and vcore_perm_core's
  // src2_group_i port. Everything else only ever needs its own beat's vs2.
  function automatic logic vpop_needs_group_buf(input vpop_e op);
    case (op)
      VPOP_VRGATHER, VPOP_VRGATHEREI16,
      VPOP_VSLIDEUP, VPOP_VSLIDEDOWN, VPOP_VSLIDE1UP, VPOP_VSLIDE1DOWN,
      VPOP_VCOMPRESS: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // vmsbf/vmsof/vmsif: both source (vs2, via vpop_vs2_is_mask_src) and
  // destination (via vpop_is_mask_dest) are single, non-grouping mask
  // registers regardless of vlmul -- so unlike viota (whose destination DOES
  // group with LMUL), these need exactly one beat, covering up to VLMAX
  // (<=VLEN) bit positions in that one pass. vmv.x.s/vfmv.f.s and
  // vmv.s.x/vfmv.s.f likewise always touch exactly one register (element 0),
  // never grouping with LMUL regardless of vtype.
  function automatic logic vpop_single_beat(input vpop_e op);
    case (op)
      VPOP_VMSBF, VPOP_VMSOF, VPOP_VMSIF,
      VPOP_VMV_X_S, VPOP_VMV_S_X: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // vrgatherei16's index operand (vs1) always uses EEW=16, so its own EMUL
  // (EMUL_index = 16*LMUL/SEW) can differ from the data group's EMUL and, for
  // SEW=8, needs MORE registers than the data side -- it gets its own group
  // buffer (vcore_perm_vrf_request's vs1_idx_group_q), sized by
  // vpop_ei16_idx_regs, instead of following one destination beat like a
  // normal vs1 operand does.
  function automatic logic vpop_vs1_needs_group_buf(input vpop_e op);
    return (op == VPOP_VRGATHEREI16);
  endfunction

  // Number of 128-bit-wide (VLEN) registers needed to hold ctrl.group_regs *
  // (VLEN/SEW) index elements at EEW=16, rounded up. Used both for the
  // vrgatherei16 legality check (must be <= MAXLMUL) in decode and for the
  // vs1 index-group preload loop bound in vrf_request.
  function automatic int unsigned vpop_ei16_idx_regs(
    input vcore_perm_ctrl_t ctrl,
    input int unsigned vlen
  );
    int unsigned n, group_size, idx_bits, regs;
    case (ctrl.sew)
      VSEW_8:  n = vlen/8;
      VSEW_16: n = vlen/16;
      VSEW_32: n = vlen/32;
      VSEW_64: n = vlen/64;
      default: n = 0;
    endcase
    group_size = int'(ctrl.group_regs) * n;
    idx_bits = group_size * 16;
    regs = (idx_bits + vlen - 1) / vlen;
    if (regs < 1) regs = 1;
    return regs;
  endfunction

  // Conservative register-group overlap test (no wraparound): true when
  // [a, a+cnt_a) and [b, b+cnt_b) share any register number.
  function automatic logic regs_overlap(
    input logic [4:0] a, input int unsigned cnt_a,
    input logic [4:0] b, input int unsigned cnt_b
  );
    return (int'(a) < int'(b) + int'(cnt_b)) && (int'(b) < int'(a) + int'(cnt_a));
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
