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
        if (commit_data.illegal_op) $fatal(1,"unexpected illegal instruction");
        commit_count <= commit_count + 1;
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
    for (int n=0; n<100; n++) begin
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

    $display("tb_vcore_alu_top PASS");
    $finish;
  end
endmodule
