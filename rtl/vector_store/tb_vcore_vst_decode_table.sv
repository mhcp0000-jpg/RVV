// Drives every official RVV 1.0 vector-store encoding into vcore_vst_decode
// and checks accept/reject against RVV_LOAD_CHECKLIST.csv.
//
// The point is not that the five in-scope instructions work -- tb_vcore_vst_ref
// proves that. The point is that the other 172 are rejected: an encoding this
// cluster silently mis-executes is far worse than one it refuses, because the
// host has no way to notice.
//
// Vectors come from verify_load_decode_table.py (run generate_load_checklist.py
// first). Group 1 is all 133 encodings unmasked, group 2 is the same 177 with
// vm=0 (which turns vlm.v and the whole-register loads into reserved
// encodings), group 3 is the scalar FP stores that share opcode 0x27, and
// group 4 re-runs every out-of-scope encoding across the whole vtype space
// (4 SEW x 7 LMUL x vm) to catch a reserved field that only slips through at
// one SEW or LMUL.
`timescale 1ns/1ps
module tb_vcore_vst_decode_table;
  import vcore_vst_pkg::*;
  localparam int unsigned MAXROWS = 16384;

  logic [31:0] instructions [0:MAXROWS-1];
  logic [0:0]  expected     [0:MAXROWS-1];
  logic [2:0]  sew_vector   [0:MAXROWS-1];
  logic [2:0]  vlmul_vector [0:MAXROWS-1];
  logic [19:0] vl_vector    [0:MAXROWS-1];
  int unsigned row_count;

  vcore_vst_cmd_t cmd;
  vcore_vst_decoded_t decoded;
  logic cmd_ready, decoded_valid;
  int unsigned fails, accepted, rejected;
  int fd;

  vcore_vst_decode dut (
    .cmd_valid_i(1'b1), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .decoded_valid_o(decoded_valid), .decoded_ready_i(1'b1),
    .decoded_o(decoded)
  );

  initial begin
    for (int i = 0; i < MAXROWS; i++) begin
      instructions[i] = '0;
      expected[i] = 1'b0;
      sew_vector[i] = '0;
      vlmul_vector[i] = '0;
      vl_vector[i] = '0;
    end
    $readmemh("out/vst_decode_inst.hex", instructions);
    $readmemh("out/vst_decode_expected.hex", expected);
    $readmemh("out/vst_decode_sew.hex", sew_vector);
    $readmemh("out/vst_decode_vlmul.hex", vlmul_vector);
    $readmemh("out/vst_decode_vl.hex", vl_vector);
    fd = $fopen("out/vst_decode_count.txt", "r");
    if (fd == 0) $fatal(1, "cannot open out/vst_decode_count.txt");
    void'($fscanf(fd, "%d", row_count));
    $fclose(fd);
    if (row_count == 0 || row_count > MAXROWS)
      $fatal(1, "bad row count %0d", row_count);

    // vtype comes per-probe from the generator, and vs3=v8 is aligned to
    // every EMUL, so an encoding rejected here is rejected on its own merits.
    cmd = '0;
    cmd.vstart = 17'd0;
    cmd.vill   = 1'b0;
    cmd.base   = 32'h0000_0100;
    cmd.stride = 32'h0000_0004;
    cmd.mask_snapshot = '1;

    fails = 0; accepted = 0; rejected = 0;
    for (int i = 0; i < int'(row_count); i++) begin
      cmd.inst  = instructions[i];
      cmd.sew   = sew_vector[i];
      cmd.vlmul = vlmul_vector[i];
      cmd.vl    = 17'(vl_vector[i]);
      #1;
      if (!cmd_ready || !decoded_valid) begin
        $display("FAIL row=%0d inst=%08h: handshake down (ready=%0b valid=%0b)",
                 i, instructions[i], cmd_ready, decoded_valid);
        fails++;
      end else if (decoded.illegal !== !expected[i]) begin
        $display("FAIL row=%0d inst=%08h sew=%0d vlmul=%03b vl=%0d: expected %s, got illegal=%0b op=%0d",
                 i, instructions[i], sew_vector[i], vlmul_vector[i], vl_vector[i],
                 expected[i] ? "accept" : "reject", decoded.illegal,
                 decoded.ctrl.op);
        fails++;
      end else begin
        if (expected[i]) accepted++; else rejected++;
      end
      // An accepted row must also carry a usable beat count.
      if (expected[i] && !decoded.illegal && decoded.beats == 4'd0) begin
        $display("FAIL row=%0d inst=%08h: accepted with beats=0", i, instructions[i]);
        fails++;
      end
      // A rejected row must not leave a live opcode behind.
      if (!expected[i] && decoded.ctrl.op != VSTOP_INVALID) begin
        $display("FAIL row=%0d inst=%08h: rejected but op=%0d, not VSTOP_INVALID",
                 i, instructions[i], decoded.ctrl.op);
        fails++;
      end
    end

    $display("tb_vcore_vst_decode_table: %0d probes, %0d accepted, %0d rejected, %0d failed",
             row_count, accepted, rejected, fails);
    if (fails != 0) $fatal(1, "decode table mismatch");
    $display("tb_vcore_vst_decode_table PASS");
    $finish;
  end
endmodule
