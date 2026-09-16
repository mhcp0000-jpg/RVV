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

  typedef enum logic [7:0] {
    VOP_ADD      = 8'd0,
    VOP_SUB      = 8'd1,
    VOP_RSUB     = 8'd2,
    VOP_AND      = 8'd3,
    VOP_OR       = 8'd4,
    VOP_XOR      = 8'd5,
    VOP_SLL      = 8'd6,
    VOP_SRL      = 8'd7,
    VOP_SRA      = 8'd8,
    VOP_MINU     = 8'd9,
    VOP_MIN      = 8'd10,
    VOP_MAXU     = 8'd11,
    VOP_MAX      = 8'd12,
    VOP_EQ       = 8'd13,
    VOP_NE       = 8'd14,
    VOP_LTU      = 8'd15,
    VOP_LT       = 8'd16,
    VOP_LEU      = 8'd17,
    VOP_LE       = 8'd18,
    VOP_GTU      = 8'd19,
    VOP_GT       = 8'd20,
    VOP_SADDU    = 8'd21,
    VOP_SADD     = 8'd22,
    VOP_SSUBU    = 8'd23,
    VOP_SSUB     = 8'd24,
    VOP_MERGE    = 8'd25,
    VOP_COPY_B   = 8'd26,
    VOP_ADC      = 8'd27,
    VOP_MADC     = 8'd28,
    VOP_SBC      = 8'd29,
    VOP_MSBC     = 8'd30,
    VOP_AADDU    = 8'd31,
    VOP_AADD     = 8'd32,
    VOP_ASUBU    = 8'd33,
    VOP_ASUB     = 8'd34,
    VOP_SSRL     = 8'd35,
    VOP_SSRA     = 8'd36,
    VOP_SMUL     = 8'd37,
    VOP_MANDN    = 8'd38,
    VOP_MAND     = 8'd39,
    VOP_MOR      = 8'd40,
    VOP_MXOR     = 8'd41,
    VOP_MORN     = 8'd42,
    VOP_MNAND    = 8'd43,
    VOP_MNOR     = 8'd44,
    VOP_MXNOR    = 8'd45,
    VOP_REDSUM   = 8'd46,
    VOP_REDAND   = 8'd47,
    VOP_REDOR    = 8'd48,
    VOP_REDXOR   = 8'd49,
    VOP_REDMINU  = 8'd50,
    VOP_REDMIN   = 8'd51,
    VOP_REDMAXU  = 8'd52,
    VOP_REDMAX   = 8'd53,
    VOP_WREDSUMU = 8'd54,
    VOP_WREDSUM  = 8'd55,
    VOP_CPOP     = 8'd56,
    VOP_FIRST    = 8'd57,
    VOP_MUL      = 8'd58,
    VOP_MULHU    = 8'd59,
    VOP_MULHSU   = 8'd60,
    VOP_MULH     = 8'd61,
    VOP_MADD     = 8'd62,
    VOP_NMSUB    = 8'd63,
    VOP_MACC     = 8'd64,
    VOP_NMSAC    = 8'd65,
    VOP_DIVU     = 8'd66,
    VOP_DIV      = 8'd67,
    VOP_REMU     = 8'd68,
    VOP_REM      = 8'd69,
    VOP_INVALID  = 8'hff
  } vop_e;

  typedef struct packed {
    logic [7:0]  op;
    logic [2:0]  sew;
    logic [1:0]  vxrm;          // fixed-point rounding mode
    logic        vm;            // instruction bit 25: 1 = unmasked
    logic        vta;           // vtype tail policy
    logic        vma;           // vtype masked-off policy
    logic [16:0] vl;            // CSR vl, element count (up to 65536)
    logic [16:0] vstart;        // CSR vstart, first element to execute
    logic [16:0] element_base;  // global element index of this beat's first lane
    logic [15:0] tag;           // ROB/destination token, opaque to the ALU
    logic [4:0]  vd_addr;       // VRF write address for this beat
    logic        first_beat;
    logic        last_beat;
  } vcore_alu_ctrl_t;

  typedef struct packed {
    logic [15:0] tag;
    logic [4:0]  vd_addr;
    logic        last_beat;
    logic        vxsat;         // pulse to OR into sticky CSR vxsat on retirement
    logic        write_enable;  // intermediate reduction beats do not write VRF
    logic        scalar_valid;
    logic [4:0]  scalar_rd;
    logic [31:0] scalar_data;
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
    logic [1:0]  vxrm;          // CSR vxrm
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
    logic           read_vd;
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
    logic        scalar_valid;
    logic [4:0]  scalar_rd;
    logic [31:0] scalar_data;
    logic        illegal_op;
  } vcore_alu_commit_t;

  function automatic logic vop_is_compare(input logic [7:0] op);
    case (op)
      VOP_EQ, VOP_NE, VOP_LTU, VOP_LT, VOP_LEU, VOP_LE,
      VOP_GTU, VOP_GT, VOP_MADC, VOP_MSBC: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic vop_is_mask_logic(input logic [7:0] op);
    case (op)
      VOP_MANDN, VOP_MAND, VOP_MOR, VOP_MXOR, VOP_MORN,
      VOP_MNAND, VOP_MNOR, VOP_MXNOR: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic vop_uses_carry(input logic [7:0] op);
    case (op)
      VOP_ADC, VOP_MADC, VOP_SBC, VOP_MSBC: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic vop_is_reduction(input logic [7:0] op);
    case (op)
      VOP_REDSUM, VOP_REDAND, VOP_REDOR, VOP_REDXOR,
      VOP_REDMINU, VOP_REDMIN, VOP_REDMAXU, VOP_REDMAX,
      VOP_WREDSUMU, VOP_WREDSUM: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic vop_is_widen_reduction(input logic [7:0] op);
    return (op == VOP_WREDSUMU) || (op == VOP_WREDSUM);
  endfunction

  function automatic logic vop_is_scalar_mask_reduce(input logic [7:0] op);
    return (op == VOP_CPOP) || (op == VOP_FIRST);
  endfunction

  function automatic logic vop_is_divide(input logic [7:0] op);
    return (op == VOP_DIVU) || (op == VOP_DIV) ||
           (op == VOP_REMU) || (op == VOP_REM);
  endfunction

  function automatic logic vop_supported(input logic [7:0] op);
    case (op)
      VOP_ADD, VOP_SUB, VOP_RSUB, VOP_AND, VOP_OR, VOP_XOR,
      VOP_SLL, VOP_SRL, VOP_SRA, VOP_MINU, VOP_MIN, VOP_MAXU,
      VOP_MAX, VOP_EQ, VOP_NE, VOP_LTU, VOP_LT, VOP_LEU,
      VOP_LE, VOP_GTU, VOP_GT, VOP_SADDU, VOP_SADD,
      VOP_SSUBU, VOP_SSUB, VOP_MERGE, VOP_COPY_B,
      VOP_ADC, VOP_MADC, VOP_SBC, VOP_MSBC,
      VOP_AADDU, VOP_AADD, VOP_ASUBU, VOP_ASUB,
      VOP_SSRL, VOP_SSRA, VOP_SMUL,
      VOP_MANDN, VOP_MAND, VOP_MOR, VOP_MXOR,
      VOP_MORN, VOP_MNAND, VOP_MNOR, VOP_MXNOR,
      VOP_REDSUM, VOP_REDAND, VOP_REDOR, VOP_REDXOR,
      VOP_REDMINU, VOP_REDMIN, VOP_REDMAXU, VOP_REDMAX,
      VOP_WREDSUMU, VOP_WREDSUM, VOP_CPOP, VOP_FIRST,
      VOP_MUL, VOP_MULHU, VOP_MULHSU, VOP_MULH,
      VOP_MADD, VOP_NMSUB, VOP_MACC, VOP_NMSAC,
      VOP_DIVU, VOP_DIV, VOP_REMU, VOP_REM: return 1'b1;
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
