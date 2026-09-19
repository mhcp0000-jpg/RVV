// RVV 1.0 vector LOAD cluster -- shared types and policy helpers.
//
// Covers all 177 official vector load encodings: unit-stride, strided,
// indexed (unordered and ordered), fault-only-first, whole-register, the
// mask load, and the segment form of each.
//
// ---------------------------------------------------------------------
// The one idea that keeps the hardware small
// ---------------------------------------------------------------------
// Every vector load visits a set of (element i, field f) pairs and maps
// each one to an address and a destination slot. Only the ADDRESS differs
// between the forms:
//
//   unit-stride / mask / whole-reg   addr = base + i*stride  (stride fixed
//                                           at decode: nf*EEW/8, 1, EEW/8)
//   strided                          addr = base + i*stride  (stride = x[rs2])
//   indexed                          addr = base + index[i]
//   segment (any of the above)       ... + f*EEW/8
//
// So one accumulator (`base + i*stride`, stepped once per element, never a
// multiplier), one adder for the field offset, and a mux to swap in the
// index value covers every form. The destination side needs nothing new at
// all: the group buffer is already laid out in destination-register order,
// so slot = f*slots_per_field + i lands each returned element exactly where
// its beat will slice it out.
//
// Fault model: the host checks addresses before commit (Saturn-style
// pre-commit fault checking), so an `error` response is a design escape and
// suppresses the VRF write -- except for fault-only-first, where an error on
// an element after index 0 is architectural and trims vl instead.
package vcore_vld_pkg;

  localparam int unsigned VCORE_VLEN = 128;
  // Widest destination group: EMUL*NFIELDS <= 8 registers.
  localparam int unsigned MAXEMUL = 8;
  // Widest destination slot space: 8 registers of EEW=8 elements.
  localparam int unsigned MAX_ELEMS = MAXEMUL * VCORE_VLEN / 8; // 128
  // Memory tag = destination slot index. The sequencer runs one instruction
  // at a time, so this is unique across all in-flight requests with no
  // allocation state at all.
  localparam int unsigned VLD_TAG_W = $clog2(MAX_ELEMS);        // 7

  // Same 3-bit encoding vtype.vsew uses; names an element width, which for
  // an indexed load is the INDEX width and otherwise the data width.
  typedef enum logic [2:0] {
    VEEW_8  = 3'b000,
    VEEW_16 = 3'b001,
    VEEW_32 = 3'b010,
    VEEW_64 = 3'b011
  } veew_e;

  typedef enum logic [2:0] {
    VLDOP_UNIT,     // vle<eew>.v          + vlseg<nf>e<eew>.v
    VLDOP_MASK,     // vlm.v
    VLDOP_STRIDED,  // vlse<eew>.v         + vlsseg<nf>e<eew>.v
    VLDOP_INDEXED,  // vluxei/vloxei<eew>.v + their segment forms
    VLDOP_WHOLE,    // vl<nreg>re<eew>.v
    VLDOP_FOF,      // vle<eew>ff.v        + vlseg<nf>e<eew>ff.v
    VLDOP_INVALID
  } vldop_e;

  typedef struct packed {
    vldop_e      op;
    logic [2:0]  eew;          // DATA element width (veew_e)
    logic [2:0]  idx_eew;      // INDEX element width, VLDOP_INDEXED only
    logic        ordered;      // vloxei: element-ordered memory access
    logic        vm;           // 1 = unmasked
    logic        vta;
    logic        vma;
    // Elements per field. vl, or ceil(vl/8) for vlm.v, or NREG*VLEN/EEW for
    // a whole-register load.
    logic [16:0] evl;
    logic [16:0] vstart;       // in data elements (bytes for vlm.v)
    logic [31:0] base_addr;    // x[rs1]
    // Signed byte distance between consecutive elements (or segments).
    // Fixed at decode for every form except strided, where it is x[rs2].
    // Unused for indexed.
    logic [31:0] stride;
    logic [3:0]  nf;           // fields per segment, 1..8
    logic [3:0]  regs_per_field;   // ceil(EMUL) of the data group
    logic [16:0] slots_per_field;  // regs_per_field * VLEN/EEW, a power of 2
    logic [16:0] dst_slots;        // nf * slots_per_field
    logic [3:0]  idx_regs;         // ceil(index EMUL), VLDOP_INDEXED only
    logic [4:0]  idx_addr;         // vs2, first index register
    logic [16:0] element_base;     // destination slot index of this beat's lane 0
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
    logic        vl_trimmed;   // fault-only-first reduced vl
    logic [16:0] new_vl;       // valid when vl_trimmed
  } vcore_vld_rsp_t;

  typedef struct packed {
    logic [31:0] inst;          // raw LOAD-FP instruction
    logic [31:0] base;          // x[rs1]
    logic [31:0] stride;        // x[rs2], strided forms only
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
    logic [3:0]  beats;         // nf * regs_per_field (1 when illegal)
    logic        illegal;
  } vcore_vld_decoded_t;

  typedef struct packed {
    vcore_vld_ctrl_t ctrl;
    logic [VCORE_VLEN-1:0] mask_snapshot;
    logic [4:0]  vd_addr;
    logic [2:0]  beat_index;
  } vcore_vld_uop_t;

  // ---- external memory interface -------------------------------------
  // One request per element-field. size is AXI-style log2(bytes); response
  // data is right-justified in the low 1<<size bytes and carries the
  // request's tag, so the bus may answer out of order.
  typedef struct packed {
    logic [31:0]          addr;
    logic [2:0]           size;   // 0=1B, 1=2B, 2=4B, 3=8B
    logic [VLD_TAG_W-1:0] tag;    // destination slot index
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
    logic        vl_trimmed;
    logic [16:0] new_vl;
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

  function automatic logic vld_is_indexed(input vldop_e op);
    return (op == VLDOP_INDEXED);
  endfunction

  // Is destination slot `slot` one this instruction must fetch?
  // RVV 1.0 7: loads "only access memory or raise exceptions for active
  // elements". Prestart, tail and mask-inactive elements are never
  // requested -- architectural, not an optimisation, because an inactive
  // element may legitimately address an unmapped page.
  function automatic logic vld_elem_active(
    input vcore_vld_ctrl_t ctrl,
    input logic [VCORE_VLEN-1:0] mask,
    input logic [16:0] elem_idx
  );
    if (elem_idx < ctrl.vstart) return 1'b0;
    if (elem_idx >= ctrl.evl)   return 1'b0;
    if (ctrl.vm)                return 1'b1;
    if (int'(elem_idx) >= int'(VCORE_VLEN)) return 1'b0; // no mask bit exists
    return mask[elem_idx[$clog2(VCORE_VLEN)-1:0]];
  endfunction

  // Does this beat have to fetch the OLD destination register?
  //
  // Only if some slot can survive unwritten: a prestart region, an
  // undisturbed tail, or a mask-inactive element under vma=0. For a load
  // this is the cluster's ONLY VRF read, so eliding it removes VRF traffic
  // entirely for the common case. Fault-only-first always reads: a trim
  // turns body elements into tail after the requests have already gone out.
  function automatic logic vld_needs_dst_old(input vcore_vld_ctrl_t ctrl);
    if (ctrl.op == VLDOP_INVALID) return 1'b0;
    if (ctrl.op == VLDOP_FOF)     return 1'b1;
    return !((ctrl.vm || ctrl.vma) && ctrl.vta &&
             (ctrl.vstart == 17'd0) && (ctrl.evl != 17'd0));
  endfunction

  // Conservative register-group overlap test (no wraparound).
  function automatic logic vld_regs_overlap(
    input logic [4:0] a, input int unsigned cnt_a,
    input logic [4:0] b, input int unsigned cnt_b
  );
    return (int'(a) < int'(b) + int'(cnt_b)) && (int'(b) < int'(a) + int'(cnt_a));
  endfunction

endpackage
