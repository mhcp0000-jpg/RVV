// Port-pressure profiler for vcore_perm_top.
//
// The question this answers: on a shared 1R1W VRF, how much of the port does
// one permutation instruction consume, and how does that compare with an
// ordinary three-operand vector op? Counts are per instruction: VRF read
// requests accepted, VRF writes accepted, and end-to-end cycles from command
// acceptance to the last_beat commit.
//
// RD_LAT models the VRF's own read latency (extra cycles beyond the minimum
// one). Sweeping it shows how much of the cost is the port and how much is
// this cluster's fully-serialized operand fetch.
module tb_vcore_perm_perf #(
  parameter int unsigned RD_LAT = 0
);
  import vcore_perm_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic cmd_valid, cmd_ready;          vcore_perm_cmd_t cmd;
  logic rd_valid, rd_ready;            vcore_vrf_read_req_t rd_req;
  logic rd_rsp_valid, rd_rsp_ready;    logic [127:0] rd_rsp_data;
  logic wr_valid, wr_ready;            vcore_vrf_write_req_t wr_req;
  logic [127:0] wr_data;
  logic sc_valid, sc_ready;            vcore_scalar_write_req_t sc_req;
  logic [31:0] sc_data;
  logic commit_valid, commit_ready;    vcore_perm_commit_t commit;

  vcore_perm_top #(.VLEN(128)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0),
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .vrf_read_valid_o(rd_valid), .vrf_read_ready_i(rd_ready), .vrf_read_req_o(rd_req),
    .vrf_read_rsp_valid_i(rd_rsp_valid), .vrf_read_rsp_ready_o(rd_rsp_ready),
    .vrf_read_rsp_data_i(rd_rsp_data),
    .vrf_write_valid_o(wr_valid), .vrf_write_ready_i(wr_ready),
    .vrf_write_req_o(wr_req), .vrf_write_data_o(wr_data),
    .scalar_write_valid_o(sc_valid), .scalar_write_ready_i(sc_ready),
    .scalar_write_req_o(sc_req), .scalar_write_data_o(sc_data),
    .commit_valid_o(commit_valid), .commit_ready_i(commit_ready), .commit_o(commit)
  );

  logic [127:0] vrf [0:31];
  logic [127:0] rd_data_q;
  logic         rd_busy_q;
  int unsigned  rd_delay_q;

  assign rd_ready = !rd_busy_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rd_busy_q <= 1'b0; rd_delay_q <= 0; rd_data_q <= '0; end
    else if (!rd_busy_q) begin
      if (rd_valid && rd_ready) begin
        rd_busy_q <= 1'b1; rd_data_q <= vrf[rd_req.addr]; rd_delay_q <= RD_LAT;
      end
    end else if (rd_delay_q != 0) rd_delay_q <= rd_delay_q - 1;
    else if (rd_rsp_valid && rd_rsp_ready) rd_busy_q <= 1'b0;
  end
  assign rd_rsp_valid = rd_busy_q && (rd_delay_q == 0);
  assign rd_rsp_data  = rd_data_q;

  assign wr_ready = 1'b1;
  always_ff @(posedge clk) if (wr_valid && wr_ready) vrf[wr_req.vd_addr] <= wr_data;
  assign sc_ready = 1'b1;
  assign commit_ready = 1'b1;

  int unsigned n_rd, n_wr, n_cyc;
  bit measuring;
  always_ff @(posedge clk) if (rst_n && measuring) begin
    n_cyc <= n_cyc + 1;
    if (rd_valid && rd_ready) n_rd <= n_rd + 1;
    if (wr_valid && wr_ready) n_wr <= n_wr + 1;
  end

  function automatic logic [31:0] mkinst(
    input logic [5:0] f6, input logic vm, input logic [4:0] vs2,
    input logic [4:0] vs1, input logic [2:0] f3, input logic [4:0] vd);
    mkinst = {f6, vm, vs2, vs1, f3, vd, 7'h57};
  endfunction

  task automatic profile(input string name, input logic [31:0] inst,
                         input logic [2:0] vlmul, input int unsigned vl,
                         input int unsigned elems);
    real per_elem;
    cmd = '0;
    cmd.inst = inst; cmd.scalar = 32'd1; cmd.sew = VSEW_32; cmd.vlmul = vlmul;
    cmd.vta = 1'b1; cmd.vma = 1'b1; cmd.vl = 17'(vl); cmd.mask_snapshot = {128{1'b1}};
    cmd.tag = 16'h1;
    n_rd = 0; n_wr = 0; n_cyc = 0;
    cmd_valid = 1'b1;
    @(posedge clk);
    while (!cmd_ready) @(posedge clk);
    cmd_valid = 1'b0;
    measuring = 1'b1;
    forever begin
      @(posedge clk);
      if (commit_valid && commit_ready && commit.last_beat) begin
        if (commit.illegal_op) $display("  !! %s flagged illegal", name);
        break;
      end
    end
    measuring = 1'b0;
    per_elem = real'(n_rd + n_wr) / real'(elems);
    $display("| %-18s | %4d | %5d | %4d | %5d | %8.2f | %8.2f |",
             name, elems, n_cyc, n_rd, n_wr, real'(n_cyc)/real'(elems), per_elem);
  endtask

  localparam logic [2:0] L1 = 3'b000, L2 = 3'b001, L4 = 3'b010, L8 = 3'b011;

  initial begin
    for (int r = 0; r < 32; r++) vrf[r] = {4{32'(r)}};
    vrf[24] = {128{1'b1}};
    rst_n = 0; cmd_valid = 0; measuring = 0;
    repeat (3) @(posedge clk); rst_n = 1; @(posedge clk);

    $display("");
    $display("### VRF read latency = %0d extra cycle(s)  (SEW=32, VLEN=128)", RD_LAT);
    $display("| instruction        | elem | cycle | rd  | wr    | cyc/elem | port/elem |");
    $display("|--------------------|-----:|------:|----:|------:|---------:|----------:|");

    // three-operand reference: same shape as a masked vadd.vv
    profile("vmerge.vvm  LMUL1", mkinst(6'h17,1'b0,5'd0,5'd16,3'b000,5'd8), L1,  4,  4);
    profile("vmerge.vvm  LMUL4", mkinst(6'h17,1'b0,5'd0,5'd16,3'b000,5'd8), L4, 16, 16);
    profile("vmerge.vvm  LMUL8", mkinst(6'h17,1'b0,5'd0,5'd16,3'b000,5'd8), L8, 32, 32);

    profile("vid.v       LMUL8", mkinst(6'h14,1'b1,5'd0,5'h11,3'b010,5'd8), L8, 32, 32);

    profile("vrgather.vv LMUL1", mkinst(6'h0c,1'b1,5'd0,5'd16,3'b000,5'd8), L1,  4,  4);
    profile("vrgather.vv LMUL2", mkinst(6'h0c,1'b1,5'd0,5'd16,3'b000,5'd8), L2,  8,  8);
    profile("vrgather.vv LMUL4", mkinst(6'h0c,1'b1,5'd0,5'd16,3'b000,5'd8), L4, 16, 16);
    profile("vrgather.vv LMUL8", mkinst(6'h0c,1'b1,5'd0,5'd16,3'b000,5'd8), L8, 32, 32);

    profile("vslideup.vx LMUL1", mkinst(6'h0e,1'b1,5'd0,5'd0,3'b100,5'd8),  L1,  4,  4);
    profile("vslideup.vx LMUL8", mkinst(6'h0e,1'b1,5'd0,5'd0,3'b100,5'd8),  L8, 32, 32);

    profile("vcompress   LMUL8", mkinst(6'h17,1'b1,5'd0,5'd24,3'b010,5'd8), L8, 32, 32);
    profile("viota.m     LMUL8", mkinst(6'h14,1'b1,5'd24,5'h10,3'b010,5'd8),L8, 32, 32);

    $display("");
    $finish;
  end

  initial begin #2000000; $fatal(1,"perf tb timeout"); end
endmodule
