// One IEEE-754 binary32 fused multiply-add lane. op[1] negates the product;
// op[0] negates the addend. A single significand multiplier also serves
// multiplication and addition (using c=0 or a=1 respectively).
module vcore_alu_fp32_fma (
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  input  logic [31:0] c_i,
  input  logic [1:0]  op_i,
  input  logic [2:0]  frm_i,
  output logic [31:0] result_o,
  output logic [4:0]  fflags_o
);
  logic [32:0] a_rec, b_rec, c_rec, result_rec;

  fNToRecFN #(.expWidth(8), .sigWidth(24)) u_a (
    .in(a_i), .out(a_rec)
  );
  fNToRecFN #(.expWidth(8), .sigWidth(24)) u_b (
    .in(b_i), .out(b_rec)
  );
  fNToRecFN #(.expWidth(8), .sigWidth(24)) u_c (
    .in(c_i), .out(c_rec)
  );
  mulAddRecFN #(.expWidth(8), .sigWidth(24)) u_fma (
    .control(1'b1), .op(op_i),
    .a(a_rec), .b(b_rec), .c(c_rec), .roundingMode(frm_i),
    .out(result_rec), .exceptionFlags(fflags_o)
  );
  recFNToFN #(.expWidth(8), .sigWidth(24)) u_result (
    .in(result_rec), .out(result_o)
  );
endmodule
