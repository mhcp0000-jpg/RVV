package vcore_alu_pkg;

  localparam int unsigned VCORE_VLEN = 128;

  // One request represents one 128-bit vector register beat.  A caller that
  // handles LMUL>1 sends successive beats and advances element_base.
  typedef enum logic [2:0] {
    VSEW_8  = 3'b000,
    VSEW_16 = 3'b001,
    VSEW_32 = 3'b010,
    VSEW_64 = 3'b011
  } vsew_e;

  typedef enum logic [5:0] {
    VOP_ADD      = 6'd0,
    VOP_SUB      = 6'd1,
    VOP_RSUB     = 6'd2,
    VOP_AND      = 6'd3,
    VOP_OR       = 6'd4,
    VOP_XOR      = 6'd5,
    VOP_SLL      = 6'd6,
    VOP_SRL      = 6'd7,
    VOP_SRA      = 6'd8,
    VOP_MINU     = 6'd9,
    VOP_MIN      = 6'd10,
    VOP_MAXU     = 6'd11,
    VOP_MAX      = 6'd12,
    VOP_EQ       = 6'd13,
    VOP_NE       = 6'd14,
    VOP_LTU      = 6'd15,
    VOP_LT       = 6'd16,
    VOP_LEU      = 6'd17,
    VOP_LE       = 6'd18,
    VOP_GTU      = 6'd19,
    VOP_GT       = 6'd20,
    VOP_SADDU    = 6'd21,
    VOP_SADD     = 6'd22,
    VOP_SSUBU    = 6'd23,
    VOP_SSUB     = 6'd24,
    VOP_MERGE    = 6'd25,
    VOP_COPY_B   = 6'd26,
    VOP_INVALID  = 6'd63
  } vop_e;

  typedef struct packed {
    logic [5:0]  op;
    logic [2:0]  sew;
    logic        vm;            // instruction bit 25: 1 = unmasked
    logic        vta;           // vtype tail policy
    logic        vma;           // vtype masked-off policy
    logic [16:0] vl;            // CSR vl, element count (up to 65536)
    logic [16:0] vstart;        // CSR vstart, first element to execute
    logic [16:0] element_base;  // global element index of this beat's first lane
    logic [15:0] tag;           // ROB/destination token, opaque to the ALU
    logic [4:0]  vd_addr;       // VRF write address for this beat
    logic        last_beat;
  } vcore_alu_ctrl_t;

  typedef struct packed {
    logic [15:0] tag;
    logic [4:0]  vd_addr;
    logic        last_beat;
    logic        vxsat;         // pulse to OR into sticky CSR vxsat on retirement
    logic        illegal_op;    // unsupported operation or SEW
  } vcore_alu_rsp_t;

  typedef enum logic [1:0] {
    VSRC_VV,
    VSRC_VX,
    VSRC_VI
  } vsrc_form_e;

  typedef struct packed {
    logic [31:0] inst;          // raw OP-V instruction
    logic [31:0] scalar;        // value of x[rs1] for .vx; ignored otherwise
    logic [2:0]  sew;           // decoded vtype.vsew
    logic [2:0]  vlmul;         // decoded vtype.vlmul
    logic        vta;
    logic        vma;
    logic        vill;
    logic [16:0] vl;
    logic [16:0] vstart;
    logic [VCORE_VLEN-1:0] mask_snapshot; // TOP's coherent v0 copy at issue
    logic [15:0] tag;
  } vcore_alu_cmd_t;

  typedef struct packed {
    vcore_alu_ctrl_t ctrl;
    logic [1:0]     form;
    logic [31:0]    scalar;
    logic [VCORE_VLEN-1:0] mask_snapshot;
    logic [4:0]     vd;
    logic [4:0]     vs1;
    logic [4:0]     vs2;
    logic [3:0]     beats;      // LMUL integer beats, 1 for fractional LMUL
    logic           illegal;
  } vcore_alu_decoded_t;

  typedef struct packed {
    vcore_alu_ctrl_t ctrl;
    logic [1:0]     form;
    logic [31:0]    scalar;
    logic [VCORE_VLEN-1:0] mask_snapshot;
    logic [4:0]     vd_addr;
    logic [4:0]     vs1_addr;
    logic [4:0]     vs2_addr;
    logic           read_vs1;
    logic           read_vs2;
    logic [2:0]     beat_index;
  } vcore_alu_uop_t;

  typedef struct packed {
    logic [4:0]  addr;
    logic [15:0] tag;
  } vcore_vrf_read_req_t;

  typedef struct packed {
    logic [4:0]  vd_addr;
    logic [15:0] tag;
  } vcore_vrf_write_req_t;

  typedef struct packed {
    logic [15:0] tag;
    logic        last_beat;
    logic        vxsat;
    logic        illegal_op;
  } vcore_alu_commit_t;

  function automatic logic vop_is_compare(input logic [5:0] op);
    case (op)
      VOP_EQ, VOP_NE, VOP_LTU, VOP_LT, VOP_LEU, VOP_LE,
      VOP_GTU, VOP_GT: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic vop_supported(input logic [5:0] op);
    case (op)
      VOP_ADD, VOP_SUB, VOP_RSUB, VOP_AND, VOP_OR, VOP_XOR,
      VOP_SLL, VOP_SRL, VOP_SRA, VOP_MINU, VOP_MIN, VOP_MAXU,
      VOP_MAX, VOP_EQ, VOP_NE, VOP_LTU, VOP_LT, VOP_LEU,
      VOP_LE, VOP_GTU, VOP_GT, VOP_SADDU, VOP_SADD,
      VOP_SSUBU, VOP_SSUB, VOP_MERGE, VOP_COPY_B: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic vsew_supported(input logic [2:0] sew);
    case (sew)
      VSEW_8, VSEW_16, VSEW_32, VSEW_64: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

endpackage
