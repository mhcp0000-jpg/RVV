// Smoke test for the store cluster frame. Not a full verification bench --
// that is the golden-reference sweep still to be written. This one proves
// the frame stands: each addressing form produces the right bytes in memory,
// inactive elements are never written, and the instruction retires.
//
// The expected memory image is built here from the spec's own formulation --
// element i of field f comes from register vs3 + f*regs + i/elems_per_reg at
// byte (i%elems_per_reg)*B -- rather than from the DUT's flat slot
// arithmetic.
`timescale 1ns/1ps
module tb_vcore_vst_smoke;
  import vcore_vst_pkg::*;

  localparam int unsigned VLEN  = 128;
  localparam int unsigned BPR   = VLEN/8;
  localparam int unsigned MEMSZ = 8192;
  localparam int unsigned MAXQ  = 64;
  parameter  int unsigned MAX_OUT = 8;
  parameter  int unsigned LAT     = 4;

  logic clk, rst_n, flush;
  logic cmd_valid, cmd_ready;
  vcore_vst_cmd_t cmd;
  logic vrf_rd_valid, vrf_rd_ready, vrf_rd_rsp_valid, vrf_rd_rsp_ready;
  vcore_vrf_read_req_t vrf_rd_req;
  logic [VLEN-1:0] vrf_rd_rsp_data;
  logic mem_req_valid, mem_req_ready, mem_rsp_valid, mem_rsp_ready;
  vcore_vst_mem_req_t mem_req;
  vcore_vst_mem_rsp_t mem_rsp;
  logic commit_valid, commit_ready;
  vcore_vst_commit_t commit;
  logic busy;

  vcore_vst_top #(.VLEN(VLEN), .MAX_OUTSTANDING(MAX_OUT)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready), .cmd_i(cmd),
    .vrf_read_valid_o(vrf_rd_valid), .vrf_read_ready_i(vrf_rd_ready),
    .vrf_read_req_o(vrf_rd_req),
    .vrf_read_rsp_valid_i(vrf_rd_rsp_valid), .vrf_read_rsp_ready_o(vrf_rd_rsp_ready),
    .vrf_read_rsp_data_i(vrf_rd_rsp_data),
    .mem_req_valid_o(mem_req_valid), .mem_req_ready_i(mem_req_ready), .mem_req_o(mem_req),
    .mem_rsp_valid_i(mem_rsp_valid), .mem_rsp_ready_o(mem_rsp_ready), .mem_rsp_i(mem_rsp),
    .commit_valid_o(commit_valid), .commit_ready_i(commit_ready), .commit_o(commit),
    .busy_o(busy)
  );

  initial clk = 0;
  /* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
  /* verilator lint_on BLKSEQ */

  logic [VLEN-1:0] vrf [32];
  logic [7:0]      mem [MEMSZ];
  logic [7:0]      exp_mem [MEMSZ];
  // `mem` is written by the memory model's clocked process, so the test
  // program must never write it directly -- a variable with both a clocked
  // and a procedural driver loses its clocked updates under Verilator.
  // Seeding therefore goes through this request line.
  logic        seed_req;
  int unsigned seed_salt;

  // VRF read model, one outstanding
  logic rd_busy_q; logic [4:0] rd_addr_q;
  assign vrf_rd_ready     = !rd_busy_q;
  assign vrf_rd_rsp_valid = rd_busy_q;
  assign vrf_rd_rsp_data  = vrf[rd_addr_q];
  always @(posedge clk) begin
    if (!rst_n || flush) rd_busy_q <= 1'b0;
    else if (!rd_busy_q) begin
      if (vrf_rd_valid && vrf_rd_ready) begin rd_busy_q <= 1'b1; rd_addr_q <= vrf_rd_req.addr; end
    end else if (vrf_rd_rsp_valid && vrf_rd_rsp_ready) rd_busy_q <= 1'b0;
  end

  // memory model: applies the write, acks by tag, out of order
  logic                 q_valid [MAXQ];
  logic [VST_TAG_W-1:0] q_tag   [MAXQ];
  int unsigned          q_wait  [MAXQ];
  int unsigned          q_rot_q, rsp_sel, inflight_model, peak_inflight;
  int unsigned          writes_seen;

  assign mem_req_ready = 1'b1;
  always_comb begin
    rsp_sel = MAXQ;
    for (int j = 0; j < MAXQ; j++) begin
      int s = (int'(q_rot_q) + j) % MAXQ;
      if ((rsp_sel == MAXQ) && q_valid[s] && (q_wait[s] == 0)) rsp_sel = s;
    end
  end
  assign mem_rsp_valid = (rsp_sel != MAXQ);
  assign mem_rsp.tag   = (rsp_sel != MAXQ) ? q_tag[rsp_sel] : '0;
  assign mem_rsp.error = 1'b0;

  always @(posedge clk) begin
    if (seed_req) begin
      /* verilator lint_off BLKSEQ */
      for (int a = 0; a < MEMSZ; a++) mem[a] = 8'((a*3) ^ (int'(seed_salt)*11));
      /* verilator lint_on BLKSEQ */
    end else if (!rst_n) begin
      for (int s = 0; s < MAXQ; s++) begin q_valid[s] <= 1'b0; q_wait[s] <= 0; end
      q_rot_q <= 0; inflight_model <= 0; peak_inflight <= 0; writes_seen <= 0;
    end else begin
      for (int s = 0; s < MAXQ; s++) if (q_valid[s] && (q_wait[s] != 0)) q_wait[s] <= q_wait[s] - 1;
      if (mem_req_valid && mem_req_ready) begin
        int free_s = MAXQ;
        for (int s = MAXQ-1; s >= 0; s--) if (!q_valid[s]) free_s = s;
        if (free_s == MAXQ) $fatal(1, "memory model: out of slots");
        // the write lands when the request is accepted
        for (int b = 0; b < 8; b++)
          if (b < (1 << mem_req.size))
            mem[(int'(mem_req.addr) + b) % MEMSZ] <= mem_req.data[b*8 +: 8];
        q_valid[free_s] <= 1'b1;
        q_tag  [free_s] <= mem_req.tag;
        q_wait [free_s] <= LAT;
        writes_seen    <= writes_seen + 1;
        inflight_model <= inflight_model + 1 - ((mem_rsp_valid && mem_rsp_ready) ? 1 : 0);
        if (inflight_model + 1 > peak_inflight) peak_inflight <= inflight_model + 1;
      end else if (mem_rsp_valid && mem_rsp_ready) inflight_model <= inflight_model - 1;
      if (mem_rsp_valid && mem_rsp_ready) begin
        q_valid[rsp_sel] <= 1'b0;
        q_rot_q <= (rsp_sel + 1) % MAXQ;
      end
    end
  end

  logic saw_last_q, saw_illegal_q, clr_flags;
  assign commit_ready = 1'b1;
  always @(posedge clk) begin
    if (!rst_n || clr_flags) begin saw_last_q <= 0; saw_illegal_q <= 0; end
    else if (commit_valid && commit_ready) begin
      if (commit.illegal_op) saw_illegal_q <= 1'b1;
      if (commit.last_beat || commit.illegal_op) saw_last_q <= 1'b1;
    end
  end

  int unsigned pass_cnt, fail_cnt;
  task automatic chk(input string name, input logic ok);
    begin
      if (ok) begin pass_cnt++; $display("PASS %s", name); end
      else    begin fail_cnt++; $display("FAIL %s", name); end
    end
  endtask

  function automatic logic [31:0] mk(
    input logic [2:0] width, input logic vmb, input logic [4:0] vs3,
    input logic [4:0] sumop, input logic [2:0] nf = 3'b000, input logic [1:0] mop = 2'b00
  );
    return {nf, 1'b0, mop, vmb, sumop, 5'd1, width, vs3, 7'h27};
  endfunction

  task automatic seed(input int unsigned salt);
    begin
      for (int r = 0; r < 32; r++)
        for (int b = 0; b < BPR; b++)
          vrf[r][b*8 +: 8] = 8'(((r*41) ^ (b*67) ^ (int'(salt)*19)) + 7);
      // exp_mem has only this one driver, so it may be written here; `mem`
      // must go through the clocked seeding path.
      for (int a = 0; a < MEMSZ; a++) exp_mem[a] = 8'((a*3) ^ (int'(salt)*11));
      @(negedge clk);
      seed_salt = salt;
      seed_req  = 1'b1;
      @(negedge clk);
      seed_req  = 1'b0;
      @(negedge clk);
    end
  endtask

  // Apply the architectural effect of a store to exp_mem, using the spec's
  // own register/byte formulation.
  task automatic expect_store(
    input int unsigned vs3, input int unsigned nf, input int unsigned eb,
    input int unsigned regs, input int unsigned epr,
    input int unsigned evl, input int unsigned vstart,
    input logic vmb, input logic [VLEN-1:0] mask,
    input logic [31:0] base, input logic [31:0] stride,
    input logic indexed, input int unsigned idx_base, input int unsigned idx_bits
  );
    logic [31:0] ea, a;
    int unsigned sreg, sbyte, per_reg, r, lane;
    logic [31:0] ival;
    begin
      ea = base;
      for (int i = 0; i < int'(regs*epr); i++) begin
        if (indexed) begin
          per_reg = VLEN / idx_bits; r = idx_base + (i / per_reg); lane = i % per_reg;
          case (idx_bits)
            8:  ival = 32'(vrf[r % 32][lane*8  +: 8]);
            16: ival = 32'(vrf[r % 32][lane*16 +: 16]);
            32: ival =     vrf[r % 32][lane*32 +: 32];
            default: ival = vrf[r % 32][lane*64 +: 32];
          endcase
          a = base + ival;
        end else a = ea;
        if ((i >= int'(vstart)) && (i < int'(evl)) && (vmb || mask[i]))
          for (int f = 0; f < int'(nf); f++) begin
            sreg  = vs3 + f*regs + (i / epr);
            sbyte = (i % epr)*eb;
            for (int b = 0; b < int'(eb); b++)
              exp_mem[(int'(a) + f*int'(eb) + b) % MEMSZ] = vrf[sreg % 32][(sbyte + b)*8 +: 8];
          end
        ea = ea + stride;
      end
    end
  endtask

  function automatic logic mem_matches();
    for (int a = 0; a < MEMSZ; a++) if (mem[a] !== exp_mem[a]) begin
      $display("  mem mismatch at %0d: got %02h exp %02h", a, mem[a], exp_mem[a]);
      return 1'b0;
    end
    return 1'b1;
  endfunction

  task automatic run(input vcore_vst_cmd_t c);
    begin
      @(negedge clk); clr_flags = 1'b1; @(negedge clk); clr_flags = 1'b0;
      cmd = c; cmd_valid = 1'b1;
      do @(negedge clk); while (!cmd_ready);
      cmd_valid = 1'b0;
      for (int t = 0; t < 20000; t++) begin
        if (saw_last_q) break;
        @(negedge clk);
      end
      repeat (4) @(negedge clk);
    end
  endtask

  vcore_vst_cmd_t c;
  initial begin
    pass_cnt = 0; fail_cnt = 0; clr_flags = 0; seed_req = 0; seed_salt = 0;
    cmd_valid = 0; cmd = '0; flush = 0; rst_n = 0;
    seed(1);
    repeat (6) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);

    // 1. vse32.v, unmasked, LMUL=1
    seed(2);
    c = '0; c.inst = mk(3'b110, 1'b1, 5'd8, 5'b00000);
    c.base = 32'd1024; c.sew = 3'd2; c.vlmul = 3'b000; c.vl = 17'd4;
    c.mask_snapshot = '1; c.tag = 16'h1;
    expect_store(8, 1, 4, 1, 4, 4, 0, 1'b1, c.mask_snapshot, c.base, 32'd4, 0, 0, 32);
    run(c);
    chk("vse32.v unmasked", saw_last_q && !saw_illegal_q && mem_matches());

    // 2. vse32.v masked -- inactive elements must not be written
    seed(3);
    vrf[0] = 128'h0000_0000_0000_0000_0000_0000_0000_0005;  // elements 0 and 2
    c = '0; c.inst = mk(3'b110, 1'b0, 5'd8, 5'b00000);
    c.base = 32'd1024; c.sew = 3'd2; c.vlmul = 3'b000; c.vl = 17'd4;
    c.mask_snapshot = vrf[0]; c.tag = 16'h2;
    expect_store(8, 1, 4, 1, 4, 4, 0, 1'b0, c.mask_snapshot, c.base, 32'd4, 0, 0, 32);
    run(c);
    chk("vse32.v masked writes only active elements", mem_matches());

    // 3. vse32.v with vstart -- prestart must not be written
    seed(4);
    c = '0; c.inst = mk(3'b110, 1'b1, 5'd8, 5'b00000);
    c.base = 32'd1024; c.sew = 3'd2; c.vlmul = 3'b001; c.vl = 17'd8; c.vstart = 17'd3;
    c.mask_snapshot = '1; c.tag = 16'h3;
    expect_store(8, 1, 4, 2, 4, 8, 3, 1'b1, c.mask_snapshot, c.base, 32'd4, 0, 0, 32);
    run(c);
    chk("vse32.v vstart skips prestart, LMUL=2 spans two registers", mem_matches());

    // 4. vsse32.v strided, negative stride
    seed(5);
    c = '0; c.inst = mk(3'b110, 1'b1, 5'd8, 5'd2, 3'b000, 2'b10);
    c.base = 32'd4096; c.stride = -32'd12;
    c.sew = 3'd2; c.vlmul = 3'b000; c.vl = 17'd4;
    c.mask_snapshot = '1; c.tag = 16'h4;
    expect_store(8, 1, 4, 1, 4, 4, 0, 1'b1, c.mask_snapshot, c.base, c.stride, 0, 0, 32);
    run(c);
    chk("vsse32.v negative stride", mem_matches());

    // 5. vsseg3e32.v -- three fields interleaved
    seed(6);
    c = '0; c.inst = mk(3'b110, 1'b1, 5'd8, 5'b00000, 3'd2);
    c.base = 32'd2048; c.sew = 3'd2; c.vlmul = 3'b000; c.vl = 17'd4;
    c.mask_snapshot = '1; c.tag = 16'h5;
    expect_store(8, 3, 4, 1, 4, 4, 0, 1'b1, c.mask_snapshot, c.base, 32'd12, 0, 0, 32);
    run(c);
    chk("vsseg3e32.v interleaves three fields", mem_matches());

    // 6. vsuxei32.v -- indexed, addresses from the index vector
    seed(7);
    for (int i = 0; i < 4; i++) vrf[16][i*32 +: 32] = 32'((i*53 + 11) % 512);
    c = '0; c.inst = mk(3'b110, 1'b1, 5'd8, 5'd16, 3'b000, 2'b01);
    c.base = 32'd3072; c.sew = 3'd2; c.vlmul = 3'b000; c.vl = 17'd4;
    c.mask_snapshot = '1; c.tag = 16'h6;
    expect_store(8, 1, 4, 1, 4, 4, 0, 1'b1, c.mask_snapshot, c.base, 32'd0, 1, 16, 32);
    run(c);
    chk("vsuxei32.v gathers addresses from the index vector", mem_matches());

    // 7. vsm.v -- ceil(vl/8) bytes
    seed(8);
    c = '0; c.inst = mk(3'b000, 1'b1, 5'd12, 5'b01011);
    c.base = 32'd5120; c.sew = 3'd0; c.vlmul = 3'b001; c.vl = 17'd17;
    c.mask_snapshot = '1; c.tag = 16'h7;
    expect_store(12, 1, 1, 1, 16, 3, 0, 1'b1, c.mask_snapshot, c.base, 32'd1, 0, 0, 8);
    run(c);
    chk("vsm.v stores ceil(vl/8) bytes", mem_matches());

    // 8. vs2r.v -- two whole registers, vtype ignored
    seed(9);
    c = '0; c.inst = mk(3'b000, 1'b1, 5'd8, 5'b01000, 3'd1);
    c.base = 32'd6144; c.sew = 3'd3; c.vlmul = 3'b101; c.vl = 17'd1;
    c.mask_snapshot = '0; c.tag = 16'h8;
    expect_store(8, 1, 1, 2, 16, 32, 0, 1'b1, '1, c.base, 32'd1, 0, 0, 8);
    run(c);
    chk("vs2r.v stores two whole registers regardless of vtype", mem_matches());

    // 9. a reserved encoding writes nothing
    seed(10);
    c = '0; c.inst = mk(3'b110, 1'b1, 5'd8, 5'b00001);   // reserved sumop
    c.base = 32'd1024; c.sew = 3'd2; c.vlmul = 3'b000; c.vl = 17'd4;
    c.mask_snapshot = '1; c.tag = 16'h9;
    run(c);
    chk("reserved sumop: illegal_op and no memory traffic",
        saw_illegal_q && mem_matches());

    $display("SMOKE TOTAL: %0d passed, %0d failed (%0d writes, peak inflight %0d)",
             pass_cnt, fail_cnt, writes_seen, peak_inflight);
    if (fail_cnt != 0) $fatal(1, "store smoke test failures");
    $finish;
  end

  initial begin #20_000_000; $fatal(1, "global timeout"); end
endmodule
