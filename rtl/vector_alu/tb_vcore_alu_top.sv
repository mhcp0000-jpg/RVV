`timescale 1ns/1ps
module tb_vcore_alu_top;
  import vcore_alu_pkg::*;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, flush = 0;
  logic cmd_valid = 0, cmd_ready;
  vcore_alu_cmd_t cmd = '0;
  logic rd_valid, rd_ready = 1, rd_rsp_valid, rd_rsp_ready;
  vcore_vrf_read_req_t rd_req;
  logic [127:0] rd_rsp_data;
  logic wr_valid, wr_ready = 1;
  vcore_vrf_write_req_t wr_req;
  logic [127:0] wr_data;
  logic commit_valid, commit_ready = 1;
  vcore_alu_commit_t commit_data;

  logic [127:0] mem [0:31];
  int read_count = 0, write_count = 0, commit_count = 0;
  logic last_seen = 0;
  int illegal_count = 0;
  int scalar_count = 0;
  logic [31:0] last_scalar_data = '0;
  logic [4:0] last_scalar_rd = '0;
  logic [4:0] last_fflags = '0;

  vcore_alu_top dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .vrf_read_valid_o(rd_valid), .vrf_read_ready_i(rd_ready),
    .vrf_read_req_o(rd_req), .vrf_read_rsp_valid_i(rd_rsp_valid),
    .vrf_read_rsp_ready_o(rd_rsp_ready), .vrf_read_rsp_data_i(rd_rsp_data),
    .vrf_write_valid_o(wr_valid), .vrf_write_ready_i(wr_ready),
    .vrf_write_req_o(wr_req), .vrf_write_data_o(wr_data),
    .commit_valid_o(commit_valid), .commit_ready_i(commit_ready),
    .commit_o(commit_data)
  );

  // Test VRF model: exactly one addressed read and one whole-register write.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd_rsp_valid <= 0;
      rd_rsp_data <= '0;
      read_count <= 0;
      write_count <= 0;
      commit_count <= 0;
      last_seen <= 0;
      illegal_count <= 0;
      scalar_count <= 0;
      last_scalar_data <= '0;
      last_scalar_rd <= '0;
      last_fflags <= '0;
    end else begin
      if (rd_rsp_valid && rd_rsp_ready) rd_rsp_valid <= 0;
      if (rd_valid && rd_ready) begin
        if (rd_req.addr == 0) $fatal(1,"ALU fetched v0 for mask");
        rd_rsp_data <= mem[rd_req.addr];
        rd_rsp_valid <= 1;
        read_count <= read_count + 1;
      end
      if (wr_valid && wr_ready) begin
        mem[wr_req.vd_addr] <= wr_data;
        write_count <= write_count + 1;
      end
      if (commit_valid && commit_ready) begin
        if (commit_data.illegal_op) illegal_count <= illegal_count + 1;
        if (commit_data.scalar_valid) begin
          scalar_count <= scalar_count + 1;
          last_scalar_data <= commit_data.scalar_data;
          last_scalar_rd <= commit_data.scalar_rd;
        end
        commit_count <= commit_count + 1;
        last_fflags <= commit_data.fflags;
        if (commit_data.last_beat) last_seen <= 1;
      end
    end
  end

  task automatic send_command;
    @(negedge clk);
    cmd_valid = 1;
    while (!cmd_ready) @(negedge clk);
    @(posedge clk);
    #1 cmd_valid = 0;
  endtask

  task automatic await_commits(input int wanted);
    for (int n=0; n<1200; n++) begin
      @(posedge clk);
      #1;
      if (commit_count == wanted) return;
    end
    $fatal(1,"timed out: commits=%0d wanted=%0d",commit_count,wanted);
  endtask

  initial begin
    for (int i=0; i<32; i++) mem[i] = '0;
    mem[2] = {32'd4,32'd3,32'd2,32'd1};
    mem[3] = {32'd8,32'd7,32'd6,32'd5};
    mem[6] = {32'd40,32'd30,32'd20,32'd10};
    mem[7] = {32'd80,32'd70,32'd60,32'd50};
    repeat (2) @(posedge clk);
    #1 rst_n = 1;

    // vadd.vv v4,v2,v6,v0.t; m2 executes two 128-bit register beats.
    // The physical v0 contents are zero; TOP's snapshot is all ones.
    cmd.inst = {6'h00,1'b0,5'd2,5'd6,3'b000,5'd4,7'h57};
    cmd.sew = VSEW_32;
    cmd.vlmul = 3'b001;
    cmd.vl = 8;
    cmd.mask_snapshot = '1;
    cmd.tag = 16'h55;
    send_command();
    await_commits(2);
    if (mem[4] !== {32'd44,32'd33,32'd22,32'd11} ||
        mem[5] !== {32'd88,32'd77,32'd66,32'd55} ||
        read_count != 6 || write_count != 2 || !last_seen)
      $fatal(1,"LMUL/mask/read mismatch v4=%h v5=%h reads=%0d writes=%0d",
             mem[4],mem[5],read_count,write_count);

    // A mask-producing compare may use an unaligned destination register.
    cmd.inst = {6'h18,1'b1,5'd2,5'd2,3'b000,5'd1,7'h57};
    cmd.tag = 16'h56;
    send_command();
    await_commits(4);
    if (mem[1][7:0] !== 8'hff || write_count != 4)
      $fatal(1,"comparison mask mismatch: %h",mem[1]);

    // Reduction uses all LMUL=2 source beats, but writes vd only once.
    mem[9] = 128'd100;
    cmd.inst = {6'h00,1'b1,5'd2,5'd9,3'b010,5'd1,7'h57};
    cmd.tag = 16'h57;
    send_command();
    await_commits(6);
    if (mem[1][31:0] !== 32'd136 || write_count != 5 || illegal_count != 0)
      $fatal(1,"LMUL reduction mismatch result=%h writes=%0d",
             mem[1],write_count);

    // Widening reduction keeps vs1/vd scalar, independent of source LMUL.
    mem[10] = {8{16'd1}};
    mem[11] = {8{16'd2}};
    mem[9] = 128'd1000;
    cmd.inst = {6'h30,1'b1,5'd10,5'd9,3'b000,5'd5,7'h57};
    cmd.sew = VSEW_16;
    cmd.vl = 16;
    cmd.tag = 16'h58;
    send_command();
    await_commits(8);
    if (mem[5][31:0] !== 32'd1024 || write_count != 6)
      $fatal(1,"widen reduction mismatch result=%h writes=%0d",
             mem[5],write_count);

    // vl=0 produces an event and leaves destination unchanged.
    cmd.vl = 0;
    cmd.tag = 16'h59;
    send_command();
    await_commits(10);
    if (write_count != 6 || mem[5][31:0] !== 32'd1024)
      $fatal(1,"zero-VL reduction unexpectedly wrote destination");

    // Any nonzero vstart is reserved for reductions.
    cmd.vl = 16;
    cmd.vstart = 1;
    cmd.tag = 16'h5a;
    send_command();
    await_commits(11);
    if (illegal_count != 1 || write_count != 6)
      $fatal(1,"reduction with vstart != 0 was not rejected");

    // m4: mask bit index continues across all four source registers.
    for (int i=12; i<16; i++) mem[i] = {4{32'd1}};
    mem[9] = 128'd5;
    cmd.inst = {6'h00,1'b0,5'd12,5'd9,3'b010,5'd3,7'h57};
    cmd.vlmul = 3'b010;
    cmd.sew = VSEW_32;
    cmd.vl = 16;
    cmd.vstart = 0;
    cmd.mask_snapshot = 128'haaaa;
    cmd.tag = 16'h5b;
    send_command();
    await_commits(15);
    if (mem[3][31:0] !== 32'd13 || write_count != 7)
      $fatal(1,"m4 masked reduction mismatch result=%h",mem[3]);

    // m8: one final write after eight sequential source beats.
    for (int i=16; i<24; i++) mem[i] = {4{32'd1}};
    mem[9] = 128'd3;
    cmd.inst = {6'h00,1'b1,5'd16,5'd9,3'b010,5'd3,7'h57};
    cmd.vlmul = 3'b011;
    cmd.vl = 32;
    cmd.tag = 16'h5c;
    send_command();
    await_commits(23);
    if (mem[3][31:0] !== 32'd35 || write_count != 8)
      $fatal(1,"m8 reduction mismatch result=%h",mem[3]);

    // Mask reductions read one mask register, regardless of LMUL.
    mem[8] = (128'd1 << 0) | (128'd1 << 2) |
             (128'd1 << 4) | (128'd1 << 33);
    cmd.inst = {6'h10,1'b1,5'd8,5'h10,3'b010,5'd7,7'h57};
    cmd.sew = VSEW_8;
    cmd.vl = 64;
    cmd.tag = 16'h5d;
    send_command();
    await_commits(24);
    if (scalar_count != 1 || last_scalar_data !== 32'd4 ||
        last_scalar_rd != 5'd7 || write_count != 8)
      $fatal(1,"vcpop result mismatch: %d",last_scalar_data);

    cmd.inst = {6'h10,1'b1,5'd8,5'h11,3'b010,5'd7,7'h57};
    cmd.tag = 16'h5e;
    send_command();
    await_commits(25);
    if (scalar_count != 2 || last_scalar_data !== 32'd0)
      $fatal(1,"vfirst result mismatch: %d",last_scalar_data);

    cmd.inst = {6'h10,1'b0,5'd8,5'h10,3'b010,5'd7,7'h57};
    cmd.mask_snapshot = (128'd1 << 2) | (128'd1 << 33);
    cmd.tag = 16'h5f;
    send_command();
    await_commits(26);
    if (scalar_count != 3 || last_scalar_data !== 32'd2)
      $fatal(1,"masked vcpop mismatch: %d",last_scalar_data);

    cmd.vl = 0;
    cmd.tag = 16'h60;
    send_command();
    await_commits(27);
    if (scalar_count != 4 || last_scalar_data !== 32'd0 || write_count != 8)
      $fatal(1,"zero-VL vcpop mismatch: %d",last_scalar_data);

    // vmacc.vx reads old vd and uses the scalar operand across both m2 beats.
    mem[2] = {32'd4,32'd3,32'd2,32'd1};
    mem[3] = {32'd8,32'd7,32'd6,32'd5};
    mem[4] = {4{32'd10}};
    mem[5] = {4{32'd10}};
    cmd.inst = {6'h2d,1'b1,5'd2,5'd3,3'b110,5'd4,7'h57};
    cmd.scalar = 32'd3;
    cmd.sew = VSEW_32;
    cmd.vlmul = 3'b001;
    cmd.vl = 8;
    cmd.tag = 16'h61;
    send_command();
    await_commits(29);
    if (mem[4] !== {32'd22,32'd19,32'd16,32'd13} ||
        mem[5] !== {32'd34,32'd31,32'd28,32'd25} ||
        write_count != 10)
      $fatal(1,"vmacc.vx m2 mismatch v4=%h v5=%h",mem[4],mem[5]);

    // Mask logical instructions use one mask register even at LMUL=2.
    // Their registers have no LMUL alignment requirement.
    mem[3] = 128'hf0;
    mem[5] = 128'haa;
    cmd.inst = {6'h1b,1'b1,5'd3,5'd5,3'b010,5'd1,7'h57};
    cmd.vl = 8;
    cmd.tag = 16'h62;
    send_command();
    await_commits(30);
    if (mem[1] !== {{120{1'b1}},8'h5a} ||
        write_count != 11 || illegal_count != 1)
      $fatal(1,"vmxor.mm mask/tail mismatch: %h",mem[1]);

    // Iterative divider preserves masked-off lanes through the 1R1W path.
    mem[2] = {32'd4,32'd3,32'd2,32'd1};
    mem[24] = {4{32'd10}};
    cmd.inst = {6'h20,1'b0,5'd2,5'd3,3'b110,5'd24,7'h57};
    cmd.scalar = 32'd2;
    cmd.vlmul = 3'b000;
    cmd.vl = 4;
    cmd.vma = 0;
    cmd.mask_snapshot = 128'h5;
    cmd.tag = 16'h63;
    send_command();
    await_commits(31);
    if (mem[24] !== {32'd10,32'd1,32'd10,32'd0} || write_count != 12)
      $fatal(1,"masked vdivu.vx mismatch: %h",mem[24]);

    // .vf receives the raw FP32 register bits in cmd.scalar from TOP.
    mem[2] = {4{32'h3f80_0000}};
    cmd.inst = {6'h08,1'b1,5'd2,5'd3,3'b101,5'd25,7'h57};
    cmd.scalar = 32'h8000_0000;
    cmd.tag = 16'h64;
    send_command();
    await_commits(32);
    if (mem[25] !== {4{32'hbf80_0000}} || write_count != 13)
      $fatal(1,"vfsgnj.vf mismatch: %h",mem[25]);

    mem[2] = {32'h7fc0_0001,32'h7f80_0001,32'h8000_0000,32'h7f80_0000};
    cmd.inst = {6'h13,1'b1,5'd2,5'h10,3'b001,5'd26,7'h57};
    cmd.tag = 16'h65;
    send_command();
    await_commits(33);
    if (mem[26] !== {32'h200,32'h100,32'h008,32'h080} ||
        write_count != 14)
      $fatal(1,"vfclass.v mismatch: %h",mem[26]);

    mem[2] = {32'h7fc0_0001,32'h3f80_0000,32'h8000_0000,32'h4000_0000};
    cmd.inst = {6'h19,1'b1,5'd2,5'd3,3'b101,5'd27,7'h57};
    cmd.scalar = 32'h3f80_0000;
    cmd.tag = 16'h66;
    send_command();
    await_commits(34);
    if (mem[27][3:0] !== 4'b0110 || last_fflags != 5'h10 ||
        write_count != 15)
      $fatal(1,"vmfle.vf mask/invalid mismatch data=%h flags=%h",
             mem[27],last_fflags);

    $display("tb_vcore_alu_top PASS");
    $finish;
  end
endmodule
