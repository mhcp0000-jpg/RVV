`timescale 1ns/1ps
module tb_vcore_alu_pipe;
  import vcore_alu_pkg::*;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, flush = 0;
  logic req_valid = 0, req_ready;
  vcore_alu_ctrl_t ctrl = '0;
  logic [127:0] src1 = '0, src2 = '0, old_data = '0, mask = '1;
  logic rsp_valid, rsp_ready = 1;
  logic [127:0] result;
  vcore_alu_rsp_t rsp_meta;

  vcore_alu_pipe dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .req_valid_i(req_valid), .req_ready_o(req_ready), .ctrl_i(ctrl),
    .src1_i(src1), .src2_i(src2), .dst_old_i(old_data), .mask_i(mask),
    .rsp_valid_o(rsp_valid), .rsp_ready_i(rsp_ready),
    .result_o(result), .rsp_meta_o(rsp_meta)
  );

  task automatic execute_check(
    input logic [127:0] expected,
    input logic expected_sat,
    input logic expected_illegal,
    input logic [4:0] expected_fflags = 5'b0
  );
    @(negedge clk);
    req_valid = 1;
    while (!req_ready) @(negedge clk);
    @(posedge clk);
    #1;
    req_valid = 0;
    if (rsp_valid) $fatal(1, "result appeared after one compute edge");
    @(posedge clk);
    #1;
    if (!rsp_valid || result !== expected ||
        rsp_meta.vxsat !== expected_sat ||
        rsp_meta.illegal_op !== expected_illegal ||
        rsp_meta.fflags !== expected_fflags)
      $fatal(1, "pipe mismatch: got=%h expected=%h sat=%b illegal=%b flags=%h",
             result, expected, rsp_meta.vxsat, rsp_meta.illegal_op,
             rsp_meta.fflags);
    @(posedge clk);
    #1;
    if (rsp_valid) $fatal(1, "response did not retire");
  endtask

  task automatic execute_variable_check(input logic [127:0] expected);
    @(negedge clk);
    req_valid = 1;
    while (!req_ready) @(negedge clk);
    @(posedge clk);
    #1 req_valid = 0;
    for (int cycle=0; cycle<1200; cycle++) begin
      @(posedge clk);
      #1;
      if (rsp_valid) begin
        if (result !== expected || rsp_meta.illegal_op)
          $fatal(1,"variable pipe mismatch op=%0d got=%h expected=%h",
                 ctrl.op,result,expected);
        @(posedge clk);
        #1;
        if (rsp_valid) $fatal(1,"variable response did not retire");
        return;
      end
    end
    $fatal(1,"variable pipe timed out op=%0d",ctrl.op);
  endtask

  initial begin
    repeat (2) @(posedge clk);
    #1 rst_n = 1;
    ctrl.vm = 1;
    ctrl.vl = 16;
    ctrl.sew = VSEW_8;
    ctrl.op = VOP_ADD;
    src2 = {16{8'h01}};
    src1 = {16{8'h02}};
    execute_check({16{8'h03}},0,0);

    ctrl.vm = 0;
    ctrl.vma = 0;
    mask = 128'h5555;
    old_data = {16{8'haa}};
    execute_check({8{16'haa03}},0,0);

    ctrl.vm = 1;
    ctrl.vl = 8;
    ctrl.sew = VSEW_16;
    ctrl.op = VOP_SADD;
    src2 = {8{16'h7fff}};
    src1 = {8{16'h0001}};
    execute_check({8{16'h7fff}},1,0);

    ctrl.vl = 4;
    ctrl.sew = VSEW_32;
    ctrl.op = VOP_SUB;
    src2 = {32'd4,32'd3,32'd2,32'd1};
    src1 = {4{32'd1}};
    execute_check({32'd3,32'd2,32'd1,32'd0},0,0);

    ctrl.vl = 2;
    ctrl.sew = VSEW_64;
    ctrl.op = VOP_ADD;
    src2 = {64'd9,64'd7};
    src1 = {64'd1,64'd1};
    execute_check({64'd10,64'd8},0,0);

    ctrl.vl = 4;
    ctrl.sew = VSEW_32;
    ctrl.op = VOP_EQ;
    src2 = {4{32'd5}};
    src1 = {4{32'd5}};
    old_data = '0;
    execute_check(128'hf,0,0);

    ctrl.op = VOP_ADD;
    ctrl.vl = 0;
    ctrl.vstart = 0;
    ctrl.vta = 1;
    old_data = 128'h1234;
    execute_check(old_data,0,0);

    ctrl.op = VOP_INVALID;
    ctrl.vl = 4;
    ctrl.vstart = 0;
    execute_check(old_data,0,1);

    ctrl.op = VOP_ADC;
    ctrl.sew = VSEW_8;
    ctrl.vl = 16;
    ctrl.vm = 0;
    mask = 128'h5555;
    src2 = {16{8'hff}};
    src1 = '0;
    execute_check({8{16'hff00}},0,0);

    ctrl.op = VOP_MADC;
    old_data = '0;
    execute_check(128'h5555,0,0);

    ctrl.op = VOP_AADDU;
    ctrl.vm = 1;
    ctrl.vxrm = 2'b00;
    src2 = {16{8'd1}};
    src1 = {16{8'd2}};
    execute_check({16{8'd2}},0,0);

    ctrl.op = VOP_SSRL;
    ctrl.vxrm = 2'b01;
    src2 = {16{8'd3}};
    src1 = {16{8'd1}};
    execute_check({16{8'd2}},0,0);

    ctrl.op = VOP_SMUL;
    ctrl.vxrm = 2'b00;
    src2 = {16{8'h80}};
    src1 = {16{8'h80}};
    execute_check({16{8'h7f}},1,0);

    ctrl.op = VOP_MAND;
    old_data = '0;
    src2 = '1;
    src1 = 128'ha5a5;
    execute_check({{112{1'b1}},16'ha5a5},0,0);

    // All eight single-width integer multiply and multiply-accumulate ops.
    ctrl.sew = VSEW_8;
    ctrl.vl = 16;
    ctrl.vm = 1;
    src2 = {16{8'hff}};
    src1 = {16{8'h02}};
    old_data = {16{8'h03}};
    ctrl.op = VOP_MUL;
    execute_check({16{8'hfe}},0,0);
    ctrl.op = VOP_MULHU;
    execute_check({16{8'h01}},0,0);
    ctrl.op = VOP_MULHSU;
    execute_check({16{8'hff}},0,0);
    ctrl.op = VOP_MULH;
    execute_check({16{8'hff}},0,0);
    src2 = {16{8'h04}};
    ctrl.op = VOP_MACC;
    execute_check({16{8'h0b}},0,0);
    ctrl.op = VOP_NMSAC;
    execute_check({16{8'hfb}},0,0);
    ctrl.op = VOP_MADD;
    execute_check({16{8'h0a}},0,0);
    ctrl.op = VOP_NMSUB;
    execute_check({16{8'hfe}},0,0);

    // The signed/unsigned high halves also need full 64-bit products.
    ctrl.sew = VSEW_64;
    ctrl.vl = 2;
    src2 = {2{64'h8000_0000_0000_0000}};
    src1 = {2{64'hffff_ffff_ffff_ffff}};
    ctrl.op = VOP_MULHU;
    execute_check({2{64'h7fff_ffff_ffff_ffff}},0,0);
    ctrl.op = VOP_MULHSU;
    execute_check({2{64'h8000_0000_0000_0000}},0,0);
    ctrl.op = VOP_MULH;
    execute_check(128'b0,0,0);

    ctrl.sew = VSEW_8;
    ctrl.vl = 16;
    src2 = {16{8'hff}};
    src1 = {16{8'h02}};
    ctrl.op = VOP_DIVU;
    execute_variable_check({16{8'h7f}});
    ctrl.op = VOP_REMU;
    execute_variable_check({16{8'h01}});
    src2 = {16{8'hf9}}; // -7
    ctrl.op = VOP_DIV;
    execute_variable_check({16{8'hfd}}); // -3, truncation toward zero
    ctrl.op = VOP_REM;
    execute_variable_check({16{8'hff}}); // -1, dividend sign
    src2 = {16{8'h80}};
    src1 = {16{8'hff}};
    ctrl.op = VOP_DIV;
    execute_variable_check({16{8'h80}}); // min / -1 overflow
    ctrl.op = VOP_REM;
    execute_variable_check(128'b0);
    src1 = '0;
    ctrl.op = VOP_DIVU;
    execute_variable_check('1);
    ctrl.op = VOP_REM;
    execute_variable_check({16{8'h80}});
    ctrl.sew = VSEW_16;
    ctrl.vl = 8;
    src2 = {8{16'hffff}};
    src1 = {8{16'h0100}};
    ctrl.op = VOP_DIVU;
    execute_variable_check({8{16'h00ff}});
    ctrl.op = VOP_REMU;
    execute_variable_check({8{16'h00ff}});
    ctrl.sew = VSEW_32;
    ctrl.vl = 4;
    src2 = {4{32'h8000_0000}};
    src1 = {4{32'hffff_ffff}};
    ctrl.op = VOP_DIV;
    execute_variable_check({4{32'h8000_0000}});
    ctrl.op = VOP_REM;
    execute_variable_check(128'b0);
    ctrl.sew = VSEW_64;
    ctrl.vl = 2;
    src2 = {2{64'd100}};
    src1 = {2{64'd7}};
    ctrl.op = VOP_DIVU;
    execute_variable_check({2{64'd14}});
    ctrl.op = VOP_REMU;
    execute_variable_check({2{64'd2}});
    src2 = {2{64'hffff_ffff_ffff_ff9c}}; // -100
    ctrl.op = VOP_DIV;
    execute_variable_check({2{64'hffff_ffff_ffff_fff2}}); // -14
    ctrl.op = VOP_REM;
    execute_variable_check({2{64'hffff_ffff_ffff_fffe}}); // -2

    ctrl.sew = VSEW_32;
    ctrl.vl = 4;
    src2 = {4{32'h3f80_0000}}; // +1.0f
    src1 = {4{32'h8000_0000}}; // negative sign
    ctrl.op = VOP_FSGNJ;
    execute_check({4{32'hbf80_0000}},0,0);
    ctrl.op = VOP_FSGNJN;
    execute_check({4{32'h3f80_0000}},0,0);
    ctrl.op = VOP_FSGNJX;
    execute_check({4{32'hbf80_0000}},0,0);
    src2 = {32'h7fc0_0001,32'h7f80_0001,32'h8000_0000,32'h7f80_0000};
    ctrl.op = VOP_FCLASS;
    execute_check({32'h200,32'h100,32'h008,32'h080},0,0);

    src2 = {4{32'h7fc0_0001}}; // quiet NaN
    src1 = {4{32'h3f80_0000}};
    ctrl.op = VOP_FMIN;
    execute_check({4{32'h3f80_0000}},0,0);
    ctrl.op = VOP_FEQ;
    old_data = '0;
    execute_check(128'b0,0,0);
    ctrl.op = VOP_FNE;
    execute_check(128'hf,0,0);
    ctrl.op = VOP_FLE;
    execute_check(128'b0,0,0,5'h10);
    src2 = {4{32'h7f80_0001}}; // signaling NaN
    ctrl.op = VOP_FMAX;
    execute_check({4{32'h3f80_0000}},0,0,5'h10);
    ctrl.op = VOP_FEQ;
    execute_check(128'b0,0,0,5'h10);
    src2 = {4{32'h0000_0000}};
    src1 = {4{32'h8000_0000}};
    ctrl.op = VOP_FMIN;
    execute_check({4{32'h8000_0000}},0,0);
    ctrl.op = VOP_FMAX;
    execute_check(128'b0,0,0);
    ctrl.op = VOP_FEQ;
    execute_check(128'hf,0,0);
    ctrl.op = VOP_FLT;
    execute_check(128'b0,0,0);
    ctrl.op = VOP_FEQ;
    ctrl.vm = 0;
    ctrl.vma = 0;
    mask = 128'h5;
    src2 = {32'h7f80_0001,32'h3f80_0000,
            32'h7f80_0001,32'h3f80_0000};
    src1 = {4{32'h3f80_0000}};
    execute_check(128'h5,0,0); // masked-off sNaNs do not raise NV

    // Kill an operation after its first 64-bit phase.
    @(negedge clk);
    ctrl.op = VOP_ADD;
    req_valid = 1;
    @(posedge clk);
    #1 req_valid = 0;
    flush = 1;
    @(posedge clk);
    #1 flush = 0;
    if (rsp_valid) $fatal(1, "flushed request produced a response");

    $display("tb_vcore_alu_pipe PASS");
    $finish;
  end
endmodule
