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
    input logic expected_illegal
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
        rsp_meta.illegal_op !== expected_illegal)
      $fatal(1, "pipe mismatch: got=%h expected=%h sat=%b illegal=%b",
             result, expected, rsp_meta.vxsat, rsp_meta.illegal_op);
    @(posedge clk);
    #1;
    if (rsp_valid) $fatal(1, "response did not retire");
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
