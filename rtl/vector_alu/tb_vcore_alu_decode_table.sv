`timescale 1ns/1ps
module tb_vcore_alu_decode_table;
  import vcore_alu_pkg::*;
  logic [31:0] instructions [0:279];
  logic [0:0] expected [0:279];
  vcore_alu_cmd_t cmd;
  vcore_alu_decoded_t decoded;
  logic cmd_ready, decoded_valid;

  vcore_alu_decode dut (
    .cmd_valid_i(1'b1), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .decoded_valid_o(decoded_valid), .decoded_ready_i(1'b1),
    .decoded_o(decoded)
  );

  initial begin
    $readmemh("out/alu_decode_inst.hex", instructions);
    $readmemh("out/alu_decode_expected.hex", expected);
    cmd = '0;
    cmd.sew = VSEW_32;
    cmd.vlmul = 3'b000;
    cmd.vl = 1;
    cmd.mask_snapshot = '1;
    for (int i=0; i<280; i++) begin
      cmd.inst = instructions[i];
      #1;
      if (!cmd_ready || !decoded_valid || decoded.illegal !== !expected[i])
        $fatal(1,"decode row=%0d inst=%h expected=%b got illegal=%b op=%0d",
               i,instructions[i],expected[i],decoded.illegal,decoded.ctrl.op);
    end
    $display("tb_vcore_alu_decode_table PASS: 280 encodings");
    $finish;
  end
endmodule
