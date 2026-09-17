// Vector unit-stride LOAD cluster -- shared types and policy helpers.
//
// Scope (deliberately narrowed, everything else decodes as illegal here):
//   * vle8.v / vle16.v / vle32.v / vle64.v   (mop=00, lumop=00000)
//   * vlm.v                                  (mop=00, lumop=01011)
// Out of scope and therefore reported illegal so TOP can route them
// elsewhere rather than silently mis-executing: strided (mop=10), indexed
// (mop=01/11), whole-register vl<nf>re<eew>.v (lumop=01000), fault-only-
// first vle<eew>ff.v (lumop=10000), segment loads (nf != 0) and EEW>64
// (mew=1).
//
// Fault model: the host checks addresses BEFORE commit (Saturn-style
// pre-commit fault checking), so this cluster issues memory requests for
// active elements only and assumes they cannot fault. A response that still
// comes back with error=1 is a design escape, not an architectural trap; it
// is latched and reported on the commit event as mem_error so the host can
// take over instead of the cluster writing poisoned data silently.
package vcore_vld_pkg;

  localparam int unsigned VCORE_VLEN = 128;
  // Widest destination group one in-scope instruction can occupy: EMUL <= 8.
  localparam int unsigned MAXEMUL = 8;
  // Widest element-index space: EMUL=8 registers of EEW=8 elements.
  localparam int unsigned MAX_ELEMS = MAXEMUL * VCORE_VLEN / 8; // 128
  // Memory tag = global element index inside the instruction. The sequencer
  // runs one instruction at a time, so this is unique among all in-flight
  // requests without any extra allocation state.
  localparam int unsigned VLD_TAG_W = $clog2(MAX_ELEMS);        // 7

  // Same 3-bit encoding vtype.vsew uses; here it names the *element* width
  // actually loaded (EEW from the width field), not necessarily vtype.vsew.
  typedef enum logic [2:0] {
    VEEW_8  = 3'b000,
    VEEW_16 = 3'b001,
    VEEW_32 = 3'b010,
    VEEW_64 = 3'b011
  } veew_e;

  typedef enum logic [1:0] {
    VLDOP_UNIT,    // vle8/16/32/64.v -- EEW from width, EMUL = EEW/SEW*LMUL
    VLDOP_MASK,    // vlm.v -- EEW=8, EMUL=1, evl=ceil(vl/8), always tail-agnostic
    VLDOP_INVALID
  } vldop_e;

  typedef struct packed {
    vldop_e      op;
    logic [2:0]  eew;          // veew_e: element width actually fetched
    logic        vm;           // 1 = unmasked (vlm.v forces 1)
    logic        vta;          // vlm.v forces 1: "always written with a
                               // tail-agnostic policy" (RVV 1.0 7.4)
    logic        vma;
    // Effective vector length in EEW elements: vl for vle<eew>.v,
    // ceil(vl/8) for vlm.v.
    logic [16:0] evl;
    // vstart in EEW elements. RVV 1.0 7.4 makes vstart a BYTE index for
    // vlm.v, which is the same thing because vlm.v runs at EEW=8.
    logic [16:0] vstart;
    logic [31:0] base_addr;    // x[rs1], already resolved by TOP
    // Total EEW-wide slots the destination group physically holds, i.e.
    // emul_regs * VLEN/EEW. RVV 1.0 5.4 defines the tail as
    // vl <= x < max(VLMAX, VLEN/SEW), so with a fractional EMUL the slots
    // above VLMAX inside the single register ARE tail and must be filled.
    logic [16:0] dst_slots;
    logic [3:0]  emul_regs;    // ceil(EMUL): registers in the destination group
    logic [16:0] element_base; // global element index of this beat's first slot
    logic [15:0] tag;
    logic [4:0]  vd_addr;
    logic        last_beat;
  } vcore_vld_ctrl_t;

  typedef struct packed {
    logic [15:0] tag;
    logic [4:0]  vd_addr;
    logic        last_beat;
    logic        illegal_op;
    logic        mem_error;
  } vcore_vld_rsp_t;

  typedef struct packed {
    logic [31:0] inst;          // raw LOAD-FP instruction
    logic [31:0] base;          // x[rs1]
    logic [2:0]  sew;           // vtype.vsew
    logic [2:0]  vlmul;         // vtype.vlmul
    logic        vta;
    logic        vma;
    logic        vill;
    logic [16:0] vl;
    logic [16:0] vstart;
    logic [VCORE_VLEN-1:0] mask_snapshot; // TOP's coherent v0 copy at issue
    logic [15:0] tag;
  } vcore_vld_cmd_t;

  typedef struct packed {
    vcore_vld_ctrl_t ctrl;
    logic [VCORE_VLEN-1:0] mask_snapshot;
    logic [4:0]  vd;
    logic [3:0]  beats;         // == ctrl.emul_regs (1 when illegal)
    logic        illegal;
  } vcore_vld_decoded_t;

  typedef struct packed {
    vcore_vld_ctrl_t ctrl;
    logic [VCORE_VLEN-1:0] mask_snapshot;
    logic [4:0]  vd_addr;
    logic [2:0]  beat_index;
  } vcore_vld_uop_t;

  // ---- external memory interface -------------------------------------
  // One request per element. size is AXI-style log2(bytes); response data is
  // right-justified in the low `1<<size` bytes, exactly like a scalar load
  // return, and carries the request's tag so the bus may answer out of order.
  typedef struct packed {
    logic [31:0]          addr;
    logic [2:0]           size;   // 0=1B, 1=2B, 2=4B, 3=8B
    logic [VLD_TAG_W-1:0] tag;    // global element index
  } vcore_vld_mem_req_t;

  typedef struct packed {
    logic [VLD_TAG_W-1:0] tag;
    logic [63:0]          data;
    logic                 error;
  } vcore_vld_mem_rsp_t;

  typedef struct packed {
    logic [4:0]  vd_addr;
    logic [15:0] tag;
  } vcore_vrf_write_req_t;

  typedef struct packed {
    logic [4:0]  addr;
    logic [15:0] tag;
  } vcore_vrf_read_req_t;

  typedef struct packed {
    logic [15:0] tag;
    logic        last_beat;
    logic        illegal_op;
    logic        mem_error;
  } vcore_vld_commit_t;

  function automatic int unsigned veew_bits(input logic [2:0] eew);
    case (eew)
      VEEW_8:  return 8;
      VEEW_16: return 16;
      VEEW_32: return 32;
      VEEW_64: return 64;
      default: return 0;
    endcase
  endfunction

  function automatic int unsigned veew_bytes(input logic [2:0] eew);
    case (eew)
      VEEW_8:  return 1;
      VEEW_16: return 2;
      VEEW_32: return 4;
      VEEW_64: return 8;
      default: return 1;
    endcase
  endfunction

  // AXI-style log2(bytes) for the memory request.
  function automatic logic [2:0] veew_size(input logic [2:0] eew);
    case (eew)
      VEEW_8:  return 3'd0;
      VEEW_16: return 3'd1;
      VEEW_32: return 3'd2;
      VEEW_64: return 3'd3;
      default: return 3'd0;
    endcase
  endfunction

  function automatic logic veew_supported(input logic [2:0] eew);
    case (eew)
      VEEW_8, VEEW_16, VEEW_32, VEEW_64: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic vld_supported(input vldop_e op);
    return (op != VLDOP_INVALID);
  endfunction

  // Is global element `idx` one this instruction must actually fetch?
  // RVV 1.0 7: "Vector loads and stores ... only access memory or raise
  // exceptions for active elements", where active = body && mask. Prestart
  // (idx < vstart), tail (idx >= evl) and mask-inactive elements are never
  // requested -- that is an architectural requirement (an inactive element
  // may point at an unmapped page), not an optimisation.
  function automatic logic vld_elem_active(
    input vcore_vld_ctrl_t ctrl,
    input logic [VCORE_VLEN-1:0] mask,
    input logic [16:0] idx
  );
    if (idx < ctrl.vstart)  return 1'b0;
    if (idx >= ctrl.evl)    return 1'b0;
    if (ctrl.vm)            return 1'b1;
    if (int'(idx) >= int'(VCORE_VLEN)) return 1'b0; // no mask bit exists
    return mask[idx[$clog2(VCORE_VLEN)-1:0]];
  endfunction

  // Does this beat have to fetch the OLD destination register?
  //
  // Only if some slot of the beat can survive unwritten: a prestart region
  // (vstart != 0), an undisturbed tail (vta=0), or a mask-inactive element
  // under vma=0. When the instruction is unmasked or mask-agnostic, the tail
  // is agnostic and vstart is 0, every slot of every beat gets a new value
  // and the read is pure pressure on a shared 1R1W VRF port -- which for a
  // load is its ONLY VRF read. Note vstart >= evl deliberately keeps the
  // read: nothing may be updated in that case, and this cluster expresses
  // "unchanged" by writing the old value back.
  function automatic logic vld_needs_dst_old(input vcore_vld_ctrl_t ctrl);
    if (ctrl.op == VLDOP_INVALID) return 1'b0;
    return !((ctrl.vm || ctrl.vma) && ctrl.vta &&
             (ctrl.vstart == 17'd0) && (ctrl.evl != 17'd0));
  endfunction

endpackage
