// Shared, iterative IEEE binary32 divide/square-root unit.
// The ALU pipe launches one active element when in_ready is high and always
// captures the out_valid pulse in its wait state.
module vcore_alu_fp32_divsqrt (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        in_valid_i,
  output logic        in_ready_o,
  input  logic        sqrt_i,
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  input  logic [2:0]  frm_i,
  output logic        out_valid_o,
  output logic [31:0] result_o,
  output logic [4:0]  fflags_o
);
  logic [32:0] a_rec, b_rec, result_rec;
  logic sqrt_out;

  fNToRecFN #(.expWidth(8), .sigWidth(24)) u_a (
    .in(a_i), .out(a_rec)
  );
  fNToRecFN #(.expWidth(8), .sigWidth(24)) u_b (
    .in(b_i), .out(b_rec)
  );
  divSqrtRecFN_small #(.expWidth(8), .sigWidth(24)) u_divsqrt (
    .nReset(rst_ni), .clock(clk_i), .control(1'b1),
    .inReady(in_ready_o), .inValid(in_valid_i), .sqrtOp(sqrt_i),
    .a(a_rec), .b(b_rec), .roundingMode(frm_i),
    .outValid(out_valid_o), .sqrtOpOut(sqrt_out),
    .out(result_rec), .exceptionFlags(fflags_o)
  );
  recFNToFN #(.expWidth(8), .sigWidth(24)) u_result (
    .in(result_rec), .out(result_o)
  );
endmodule
