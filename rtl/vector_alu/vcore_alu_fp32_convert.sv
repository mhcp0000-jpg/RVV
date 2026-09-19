// One FP32/integer32 conversion lane. The two signed variants share each
// directional converter; RTZ selects a fixed rounding mode on the same path.
module vcore_alu_fp32_convert (
  input  logic [31:0] src_i,
  input  logic [7:0]  op_i,
  input  logic [2:0]  frm_i,
  output logic [31:0] result_o,
  output logic [4:0]  fflags_o
);
  import vcore_alu_pkg::*;
  logic signed_input, signed_output, to_float;
  logic [2:0] rounding_mode, int_flags;
  logic [4:0] fp_flags;
  logic [32:0] source_rec, float_rec;
  logic [31:0] float_bits, integer_bits;

  assign signed_input = (op_i == VOP_FCVT_F_X);
  assign signed_output = (op_i == VOP_FCVT_X_F) ||
                         (op_i == VOP_FCVT_RTZ_X_F);
  assign to_float = (op_i == VOP_FCVT_F_XU) || signed_input;
  assign rounding_mode = ((op_i == VOP_FCVT_RTZ_XU_F) ||
                          (op_i == VOP_FCVT_RTZ_X_F)) ? 3'b001 : frm_i;

  fNToRecFN #(.expWidth(8), .sigWidth(24)) u_source (
    .in(src_i), .out(source_rec)
  );
  iNToRecFN #(.intWidth(32), .expWidth(8), .sigWidth(24)) u_from_integer (
    .control(1'b1), .signedIn(signed_input), .in(src_i),
    .roundingMode(rounding_mode), .out(float_rec),
    .exceptionFlags(fp_flags)
  );
  recFNToFN #(.expWidth(8), .sigWidth(24)) u_to_ieee (
    .in(float_rec), .out(float_bits)
  );
  recFNToIN #(.expWidth(8), .sigWidth(24), .intWidth(32)) u_to_integer (
    .control(1'b1), .in(source_rec), .roundingMode(rounding_mode),
    .signedOut(signed_output), .out(integer_bits),
    .intExceptionFlags(int_flags)
  );

  assign result_o = to_float ? float_bits : integer_bits;
  // HardFloat integer-conversion flags are {invalid, overflow, inexact}.
  // Integer overflow maps to RISC-V NV; FP OF/UF/DZ never arise here.
  assign fflags_o = to_float ? fp_flags :
                    {int_flags[2] | int_flags[1], 3'b000, int_flags[0]};
endmodule
