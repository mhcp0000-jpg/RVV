// RVV 1.0 vector STORE cluster -- shared types and helpers.
//
// Covers all 133 official vector store encodings: unit-stride, strided,
// indexed (unordered and ordered), whole-register, the mask store, and the
// segment form of each.
//
// ---------------------------------------------------------------------
// What is the same as the load cluster, and what is not
// ---------------------------------------------------------------------
// Same: the addressing rules, the (element, field) -> slot mapping, the
// group buffer laid out in register order, the log2 legality arithmetic,
// the tagged out-of-order memory interface, and the flush drain.
//
// Different, and these are the ones that shape the design:
//
//  1. The data flows the other way. The group buffer is filled by VRF READS
//     and drained by memory WRITES. A store therefore reads up to 8 vector
//     registers where a load reads at most one -- on a shared 1R1W VRF this
//     is the cluster's dominant cost, and the opposite of the load's
//     profile.
//  2. There is no destination register, so the whole tail / prestart /
//     mask-agnostic policy chain disappears. An element that is prestart,
//     tail or mask-inactive is simply not written to memory. `vta` and
//     `vma` never appear, and there is no old-destination read.
//  3. The response carries no data -- it is an acknowledgement plus an
//     error bit. The unit still waits for every ack before the instruction
//     retires, so the host knows the writes have been accepted and so a
//     flush has something definite to drain.
//  4. No fault-only-first form exists, so nothing trims vl.
//  5. RVV 1.0 5.3's "destination group cannot overlap v0" does NOT apply:
//     a store has no vector destination. A masked store with vs3 = v0 is
//     legal. Likewise an indexed segment store has no destination/index
//     overlap rule, because vs2 and vs3 are both sources.
//  6. Element order matters in a way it never did for loads. Within one
//     store the element accesses are unordered (RVWMO) except for
//     `vsoxei`, so when two elements target the SAME address -- a strided
//     store with stride 0, or an indexed store with duplicate indices --
//     the result is only defined for the ordered form. That is a
//     verification constraint as much as a design one: a golden reference
//     cannot predict an unordered store to overlapping addresses.
package vcore_vst_pkg;

  localparam int unsigned VCORE_VLEN = 128;
  localparam int unsigned MAXEMUL = 8;
  localparam int unsigned MAX_ELEMS = MAXEMUL * VCORE_VLEN / 8; // 128
  localparam int unsigned VST_TAG_W = $clog2(MAX_ELEMS);        // 7

  typedef enum logic [2:0] {
    VEEW_8  = 3'b000,
    VEEW_16 = 3'b001,
    VEEW_32 = 3'b010,
    VEEW_64 = 3'b011
  } veew_e;

  typedef enum logic [2:0] {
    VSTOP_UNIT,     // vse<eew>.v          + vsseg<nf>e<eew>.v
    VSTOP_MASK,     // vsm.v
    VSTOP_STRIDED,  // vsse<eew>.v         + vssseg<nf>e<eew>.v
    VSTOP_INDEXED,  // vsuxei/vsoxei<eew>.v + their segment forms
    VSTOP_WHOLE,    // vs<nreg>r.v
    VSTOP_INVALID
  } vstop_e;

  typedef struct packed {
    vstop_e      op;
    logic [2:0]  eew;          // DATA element width
    logic [2:0]  idx_eew;      // INDEX element width, VSTOP_INDEXED only
    logic        ordered;      // vsoxei: element-ordered memory access
    logic        vm;           // 1 = unmasked
    // Elements per field: vl, ceil(vl/8) for vsm.v, NREG*VLEN/8 for a
    // whole-register store.
    logic [16:0] evl;
    logic [16:0] vstart;       // in data elements (bytes for vsm.v and vs<nr>r.v)
    logic [31:0] base_addr;    // x[rs1]
    logic [31:0] stride;       // signed byte distance; unused for indexed
    logic [3:0]  nf;           // fields per segment, 1..8
    logic [3:0]  regs_per_field;   // ceil(EMUL) of the source group
    logic [16:0] slots_per_field;  // regs_per_field * VLEN/EEW, a power of 2
    logic [16:0] src_slots;        // nf * slots_per_field
    logic [3:0]  idx_regs;         // ceil(index EMUL), VSTOP_INDEXED only
    logic [4:0]  idx_addr;         // vs2, first index register
    logic [16:0] element_base;     // source slot index of this beat's lane 0
    logic [15:0] tag;
    logic [4:0]  vs3_addr;         // this beat's source data register
    logic        last_beat;
  } vcore_vst_ctrl_t;

  typedef struct packed {
    logic [31:0] inst;          // raw STORE-FP instruction
    logic [31:0] base;          // x[rs1]
    logic [31:0] stride;        // x[rs2], strided forms only
    logic [2:0]  sew;
    logic [2:0]  vlmul;
    logic        vill;
    logic [16:0] vl;
    logic [16:0] vstart;
    logic [VCORE_VLEN-1:0] mask_snapshot; // TOP's coherent v0 copy at issue
    logic [15:0] tag;
  } vcore_vst_cmd_t;

  typedef struct packed {
    vcore_vst_ctrl_t ctrl;
    logic [VCORE_VLEN-1:0] mask_snapshot;
    logic [4:0]  vs3;
    logic [3:0]  beats;         // nf * regs_per_field (1 when illegal)
    logic        illegal;
  } vcore_vst_decoded_t;

  typedef struct packed {
    vcore_vst_ctrl_t ctrl;
    logic [VCORE_VLEN-1:0] mask_snapshot;
    logic [4:0]  vs3_addr;
    logic [2:0]  beat_index;
  } vcore_vst_uop_t;

  // ---- external memory interface -------------------------------------
  // One request per element-field, carrying the data. `size` is AXI-style
  // log2(bytes); the data is right-justified in the low 1<<size bytes, the
  // same placement a load response uses. The response is an acknowledgement
  // only -- tag plus an error bit, no payload.
  typedef struct packed {
    logic [31:0]          addr;
    logic [2:0]           size;   // 0=1B, 1=2B, 2=4B, 3=8B
    logic [63:0]          data;   // right-justified, low 1<<size bytes
    logic [VST_TAG_W-1:0] tag;    // source slot index
  } vcore_vst_mem_req_t;

  typedef struct packed {
    logic [VST_TAG_W-1:0] tag;
    logic                 error;
  } vcore_vst_mem_rsp_t;

  typedef struct packed {
    logic [4:0]  addr;
    logic [15:0] tag;
  } vcore_vrf_read_req_t;

  typedef struct packed {
    logic [15:0] tag;
    logic        last_beat;
    logic        illegal_op;
    logic        mem_error;
  } vcore_vst_commit_t;

  function automatic int unsigned veew_bits(input logic [2:0] eew);
    case (eew)
      VEEW_8: return 8; VEEW_16: return 16; VEEW_32: return 32; VEEW_64: return 64;
      default: return 0;
    endcase
  endfunction

  function automatic int unsigned veew_bytes(input logic [2:0] eew);
    case (eew)
      VEEW_8: return 1; VEEW_16: return 2; VEEW_32: return 4; VEEW_64: return 8;
      default: return 1;
    endcase
  endfunction

  function automatic logic [2:0] veew_size(input logic [2:0] eew);
    case (eew)
      VEEW_8: return 3'd0; VEEW_16: return 3'd1;
      VEEW_32: return 3'd2; VEEW_64: return 3'd3;
      default: return 3'd0;
    endcase
  endfunction

  function automatic logic veew_supported(input logic [2:0] eew);
    case (eew)
      VEEW_8, VEEW_16, VEEW_32, VEEW_64: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic vst_supported(input vstop_e op);
    return (op != VSTOP_INVALID);
  endfunction

  function automatic logic vst_is_indexed(input vstop_e op);
    return (op == VSTOP_INDEXED);
  endfunction

  // Is element `elem_idx` one this instruction must write?
  // RVV 1.0 7: stores "only access memory or raise exceptions for active
  // elements". For a store that is the WHOLE policy -- prestart, tail and
  // mask-inactive elements are simply not written, and there is no tail
  // fill to decide because there is no destination register.
  function automatic logic vst_elem_active(
    input vcore_vst_ctrl_t ctrl,
    input logic [VCORE_VLEN-1:0] mask,
    input logic [16:0] elem_idx
  );
    if (elem_idx < ctrl.vstart) return 1'b0;
    if (elem_idx >= ctrl.evl)   return 1'b0;
    if (ctrl.vm)                return 1'b1;
    if (int'(elem_idx) >= int'(VCORE_VLEN)) return 1'b0;
    return mask[elem_idx[$clog2(VCORE_VLEN)-1:0]];
  endfunction

endpackage
