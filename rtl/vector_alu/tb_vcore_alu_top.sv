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
  logic last_vxsat = 0;

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
      last_vxsat <= 0;
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
        last_vxsat <= commit_data.vxsat;
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

    // vf2 uses both halves of a single source register for two m2 beats.
    mem[10] = 128'h10_0f_0e_0d_0c_0b_0a_09_08_07_06_05_04_03_02_01;
    cmd.inst = {6'h12,1'b1,5'd10,5'h06,3'b010,5'd16,7'h57};
    cmd.sew = VSEW_16;
    cmd.vlmul = 3'b001;
    cmd.vl = 16;
    cmd.mask_snapshot = '1;
    cmd.tag = 16'h67;
    send_command();
    await_commits(36);
    if (mem[16] !== {16'd8,16'd7,16'd6,16'd5,16'd4,16'd3,16'd2,16'd1} ||
        mem[17] !== {16'd16,16'd15,16'd14,16'd13,16'd12,16'd11,16'd10,16'd9})
      $fatal(1,"vzext.vf2 m2 source slice mismatch v16=%h v17=%h",mem[16],mem[17]);

    // vf4 sign extends four bytes per beat from one source register.
    mem[11] = 128'hfe_03_82_01_80_7f_ff_00_04_03_02_01_fc_fd_fe_ff;
    cmd.inst = {6'h12,1'b1,5'd11,5'h05,3'b010,5'd20,7'h57};
    cmd.sew = VSEW_32;
    cmd.vlmul = 3'b010;
    cmd.vl = 16;
    cmd.tag = 16'h68;
    send_command();
    await_commits(40);
    if (mem[20] !== {32'hffff_fffc,32'hffff_fffd,32'hffff_fffe,32'hffff_ffff} ||
        mem[21] !== {32'd4,32'd3,32'd2,32'd1} ||
        mem[22] !== {32'hffff_ff80,32'h7f,32'hffff_ffff,32'h0} ||
        mem[23] !== {32'hffff_fffe,32'd3,32'hffff_ff82,32'd1})
      $fatal(1,"vsext.vf4 m4 sign/segment mismatch");

    // vf8 consumes one byte per 64-bit lane and eight m8 destination beats.
    mem[15] = 128'h10_0f_0e_0d_0c_0b_0a_09_08_07_06_05_04_03_02_01;
    cmd.inst = {6'h12,1'b1,5'd15,5'h02,3'b010,5'd16,7'h57};
    cmd.sew = VSEW_64;
    cmd.vlmul = 3'b011;
    cmd.vl = 16;
    cmd.tag = 16'h69;
    send_command();
    await_commits(48);
    for (int i=0; i<8; i++)
      if (mem[16+i] !== {64'(2*i+2),64'(2*i+1)})
        $fatal(1,"vzext.vf8 m8 beat %0d mismatch %h",i,mem[16+i]);

    // A smaller-EEW source can occupy the highest registers of vd's group.
    mem[14] = 128'h10_0f_0e_0d_0c_0b_0a_09_08_07_06_05_04_03_02_01;
    mem[15] = 128'h20_1f_1e_1d_1c_1b_1a_19_18_17_16_15_14_13_12_11;
    cmd.inst = {6'h12,1'b1,5'd14,5'h04,3'b010,5'd8,7'h57};
    cmd.sew = VSEW_32;
    cmd.vl = 32;
    cmd.tag = 16'h6a;
    send_command();
    await_commits(56);
    if (mem[8] !== {32'd4,32'd3,32'd2,32'd1} ||
        mem[15] !== {32'd32,32'd31,32'd30,32'd29})
      $fatal(1,"legal high-end overlap was corrupted");

    // The same source at the low end is a reserved unequal-EEW overlap.
    cmd.inst = {6'h12,1'b1,5'd12,5'h04,3'b010,5'd8,7'h57};
    cmd.tag = 16'h6b;
    send_command();
    await_commits(57);
    if (illegal_count != 2 || write_count != 37)
      $fatal(1,"illegal low-end extension overlap was accepted");

    mem[10] = {64'b0,16'h0001,16'h7fff,16'h8000,16'hffff};
    cmd.inst = {6'h12,1'b1,5'd10,5'h07,3'b010,5'd24,7'h57};
    cmd.sew = VSEW_32;
    cmd.vlmul = 3'b000;
    cmd.vl = 4;
    cmd.tag = 16'h6c;
    send_command();
    await_commits(58);
    if (mem[24] !== {32'd1,32'h7fff,32'hffff_8000,32'hffff_ffff})
      $fatal(1,"vsext.vf2 sign mismatch %h",mem[24]);

    mem[11] = 128'h01_7f_80_ff;
    cmd.inst = {6'h12,1'b1,5'd11,5'h04,3'b010,5'd25,7'h57};
    cmd.tag = 16'h6d;
    send_command();
    await_commits(59);
    if (mem[25] !== {32'd1,32'd127,32'd128,32'd255})
      $fatal(1,"vzext.vf4 zero extension mismatch %h",mem[25]);

    mem[15] = 128'h80_ff;
    cmd.inst = {6'h12,1'b1,5'd15,5'h03,3'b010,5'd26,7'h57};
    cmd.sew = VSEW_64;
    cmd.vl = 2;
    cmd.tag = 16'h6e;
    send_command();
    await_commits(60);
    if (mem[26] !== {64'hffff_ffff_ffff_ff80,64'hffff_ffff_ffff_ffff})
      $fatal(1,"vsext.vf8 sign mismatch %h",mem[26]);

    // Fractional source EMUL cannot overlap a different-EEW destination.
    cmd.inst = {6'h12,1'b1,5'd10,5'h06,3'b010,5'd10,7'h57};
    cmd.sew = VSEW_32;
    cmd.vlmul = 3'b111;
    cmd.vl = 2;
    cmd.tag = 16'h6f;
    send_command();
    await_commits(61);
    if (illegal_count != 3 || write_count != 40)
      $fatal(1,"fractional EMUL overlap was accepted");

    // Widening add doubles destination EMUL: m2 sources, m4 destination.
    mem[2] = 128'h10_0f_0e_0d_0c_0b_0a_09_08_07_06_05_04_03_02_01;
    mem[3] = 128'h20_1f_1e_1d_1c_1b_1a_19_18_17_16_15_14_13_12_11;
    mem[6] = {16{8'd10}};
    mem[7] = {16{8'd20}};
    cmd.inst = {6'h30,1'b1,5'd2,5'd6,3'b010,5'd8,7'h57};
    cmd.sew = VSEW_8;
    cmd.vlmul = 3'b001;
    cmd.vl = 32;
    cmd.tag = 16'h70;
    send_command();
    await_commits(65);
    for (int i=0; i<4; i++)
      for (int j=0; j<8; j++)
        if (mem[8+i][j*16 +: 16] !== 16'(i*8+j+1+(i<2 ? 10 : 20)))
          $fatal(1,"vwaddu.vv m2/m4 beat=%0d lane=%0d data=%h",i,j,mem[8+i]);

    // Signed widening with a scalar sign-extends the SEW=16 scalar first.
    mem[10] = {16'h8000,16'hffff,16'd6,16'd5,16'd4,16'd3,16'd2,16'd1};
    cmd.inst = {6'h31,1'b1,5'd10,5'd3,3'b110,5'd12,7'h57};
    cmd.sew = VSEW_16;
    cmd.vlmul = 3'b000;
    cmd.vl = 8;
    cmd.scalar = 32'hffff_fffe;
    cmd.tag = 16'h71;
    send_command();
    await_commits(67);
    if (mem[12] !== {32'd2,32'd1,32'd0,32'hffff_ffff} ||
        mem[13] !== {32'hffff_7ffe,32'hffff_fffd,32'd4,32'd3})
      $fatal(1,"vwadd.vx signed widening mismatch v12=%h v13=%h",mem[12],mem[13]);

    // .wv reads vs2 at destination EEW and vs1 at source EEW.
    mem[16] = {32'd40,32'd30,32'd20,32'd10};
    mem[17] = {32'd80,32'd70,32'd60,32'd50};
    mem[18] = {16'd8,16'd7,16'd6,16'd5,16'd4,16'd3,16'd2,16'd1};
    cmd.inst = {6'h37,1'b1,5'd16,5'd18,3'b010,5'd16,7'h57};
    cmd.tag = 16'h72;
    send_command();
    await_commits(69);
    if (mem[16] !== {32'd36,32'd27,32'd18,32'd9} ||
        mem[17] !== {32'd72,32'd63,32'd54,32'd45})
      $fatal(1,"vwsub.wv mixed EEW/destructive vd mismatch");

    cmd.inst = {6'h30,1'b1,5'd8,5'd4,3'b010,5'd8,7'h57};
    cmd.sew = VSEW_8;
    cmd.vl = 16;
    cmd.tag = 16'h73;
    send_command();
    await_commits(70);
    if (illegal_count != 4 || write_count != 48)
      $fatal(1,"widen low-end overlap was accepted");

    cmd.inst = {6'h30,1'b1,5'd8,5'd16,3'b010,5'd0,7'h57};
    cmd.vlmul = 3'b011;
    cmd.vl = 128;
    cmd.tag = 16'h74;
    send_command();
    await_commits(71);
    if (illegal_count != 5 || write_count != 48)
      $fatal(1,"widen destination EMUL>8 was accepted");

    // Exercise all 16 widening add/sub OP-MVV/OP-MVX encodings separately.
    mem[2] = {16'd8,16'd7,16'd6,16'd5,16'd4,16'd3,16'd2,16'd1};
    mem[4] = {8{16'd2}};
    mem[8] = {32'd40,32'd30,32'd20,32'd10};
    mem[9] = {32'd80,32'd70,32'd60,32'd50};
    cmd.sew = VSEW_16;
    cmd.vlmul = 3'b000;
    cmd.vl = 8;
    cmd.scalar = 32'd2;
    for (int opcode=32'h30; opcode<=32'h37; opcode++) begin
      for (int form=0; form<2; form++) begin
        mem[20] = '0;
        mem[21] = '0;
        cmd.inst = {6'(opcode),1'b1,
                    (opcode>=32'h34 ? 5'd8 : 5'd2),
                    (form==0 ? 5'd4 : 5'd3),
                    (form==0 ? 3'b010 : 3'b110),5'd20,7'h57};
        cmd.tag = 16'(32'h80 + (opcode-32'h30)*2 + form);
        send_command();
        await_commits(71 + 2*((opcode-32'h30)*2 + form + 1));
        for (int lane_index=0; lane_index<8; lane_index++) begin
          int expected_value;
          expected_value = (opcode>=32'h34) ? 10*(lane_index+1) : lane_index+1;
          expected_value += ((opcode==32'h32) || (opcode==32'h33) ||
                             (opcode==32'h36) || (opcode==32'h37)) ? -2 : 2;
          if (mem[20+lane_index/4][(lane_index%4)*32 +: 32] !==
              32'(expected_value))
            $fatal(1,"widen encoding funct6=%h form=%0d lane=%0d got=%h expected=%h",
                   opcode,form,lane_index,
                   mem[20+lane_index/4][(lane_index%4)*32 +: 32],
                   expected_value);
        end
      end
    end
    if (write_count != 80 || illegal_count != 5)
      $fatal(1,"widen encoding sweep lost writes/raised illegal");

    // m4 narrow sources produce an m8 wide destination, using all 8 beats.
    for (int i=0; i<4; i++) begin
      mem[12+i] = {4{32'd100}};
      for (int j=0; j<4; j++)
        mem[8+i][j*32 +: 32] = 32'(4*i+j+1);
    end
    cmd.inst = {6'h30,1'b1,5'd8,5'd12,3'b010,5'd16,7'h57};
    cmd.sew = VSEW_32;
    cmd.vlmul = 3'b010;
    cmd.vl = 16;
    cmd.tag = 16'h90;
    send_command();
    await_commits(111);
    for (int i=0; i<8; i++)
      if (mem[16+i] !== {64'(2*i+102),64'(2*i+101)})
        $fatal(1,"widen m4/m8 beat %0d mismatch %h",i,mem[16+i]);

    // mf2 source expands into one m1 destination register.
    mem[2] = {16{8'd5}};
    mem[4] = {16{8'd2}};
    cmd.inst = {6'h30,1'b1,5'd2,5'd4,3'b010,5'd24,7'h57};
    cmd.sew = VSEW_8;
    cmd.vlmul = 3'b111;
    cmd.vl = 8;
    cmd.tag = 16'h91;
    send_command();
    await_commits(112);
    if (mem[24] !== {8{16'd7}})
      $fatal(1,"widen fractional LMUL mismatch %h",mem[24]);

    // High-end overlap is legal; its inactive and tail lanes become agnostic.
    mem[24] = '0;
    mem[25] = {16'd8,16'd7,16'd6,16'd5,16'd4,16'd3,16'd2,16'd1};
    mem[4] = {8{16'd2}};
    cmd.inst = {6'h30,1'b0,5'd25,5'd4,3'b010,5'd24,7'h57};
    cmd.sew = VSEW_16;
    cmd.vlmul = 3'b000;
    cmd.vl = 3;
    cmd.mask_snapshot = 128'h5;
    cmd.vta = 0;
    cmd.vma = 0;
    cmd.tag = 16'h92;
    send_command();
    await_commits(114);
    if (mem[24] !== {32'hffff_ffff,32'd5,32'hffff_ffff,32'd3} ||
        mem[25] !== '1 || write_count != 91 || illegal_count != 5)
      $fatal(1,"widen high-end overlap/forced agnostic mismatch %h %h",
             mem[24],mem[25]);

    // Every widening multiply/MAC encoding: signed and unsigned inputs are
    // checked independently against 64-bit scalar reference arithmetic.
    begin : widening_mul_sweep
      int wanted;
      logic [15:0] raw_vs2, raw_vs1;
      longint signed a_value, b_value, expected_value;
      logic vs2_signed, vs1_signed, accumulate;
      wanted = 114;
      mem[2] = {16'd4,16'd2,16'hffff,16'd1,
                16'h7fff,16'h8000,16'd3,16'hfffe};
      mem[4] = {16'd7,16'd6,16'd5,16'h8000,
                16'd4,16'd3,16'hffff,16'd2};
      cmd.sew = VSEW_16;
      cmd.vlmul = 3'b000;
      cmd.vl = 8;
      cmd.scalar = 32'h0000_fffe;
      cmd.mask_snapshot = '1;
      for (int opcode=32'h38; opcode<=32'h3f; opcode++) begin
        for (int form=0; form<2; form++) begin
          if (opcode!=32'h39 && !(opcode==32'h3e && form==0)) begin
            mem[20] = {4{32'd100}};
            mem[21] = {4{32'd100}};
            cmd.inst = {6'(opcode),1'b1,5'd2,
                        (form==0 ? 5'd4 : 5'd3),
                        (form==0 ? 3'b010 : 3'b110),5'd20,7'h57};
            cmd.tag = 16'(32'ha0 + (opcode-32'h38)*2 + form);
            send_command();
            wanted += 2;
            await_commits(wanted);
            vs2_signed = (opcode==32'h3a) || (opcode==32'h3b) ||
                         (opcode==32'h3d) || (opcode==32'h3e);
            vs1_signed = (opcode==32'h3b) || (opcode==32'h3d) ||
                         (opcode==32'h3f);
            accumulate = opcode>=32'h3c;
            for (int lane_index=0; lane_index<8; lane_index++) begin
              raw_vs2 = mem[2][lane_index*16 +: 16];
              raw_vs1 = (form==0) ? mem[4][lane_index*16 +: 16] : 16'hfffe;
              a_value = vs2_signed ? 64'($signed(raw_vs2)) : 64'(raw_vs2);
              b_value = vs1_signed ? 64'($signed(raw_vs1)) : 64'(raw_vs1);
              expected_value = a_value*b_value + (accumulate ? 64'd100 : 64'd0);
              if (mem[20+lane_index/4][(lane_index%4)*32 +: 32] !==
                  32'(expected_value))
                $fatal(1,"widen mul/MAC funct6=%h form=%0d lane=%0d got=%h expected=%h",
                       opcode,form,lane_index,
                       mem[20+lane_index/4][(lane_index%4)*32 +: 32],
                       expected_value);
            end
          end
        end
      end
      if (wanted != 140 || write_count != 117 || illegal_count != 5)
        $fatal(1,"widen mul/MAC encoding sweep incomplete: commits=%0d writes=%0d",
               wanted,write_count);
    end

    // All 12 narrowing shift/clip encodings. One destination register
    // consumes two wide source registers through the single VRF read port.
    begin : narrow_sweep
      int wanted, reads_before;
      logic [31:0] raw_source;
      logic [31:0] shifted_unsigned;
      int signed shifted_signed;
      logic [15:0] expected_value;
      wanted = 140;
      mem[8] = {32'hffff_ffff,32'h0001_ffff,32'h0000_0003,32'h0000_0001};
      mem[9] = {32'h8000_0000,32'h0000_ffff,32'hffff_0000,32'h0002_0000};
      mem[4] = {8{16'd1}};
      cmd.sew = VSEW_16;
      cmd.vlmul = 3'b000;
      cmd.vl = 8;
      cmd.vstart = 0;
      cmd.vxrm = 2'b10; // truncate for a simple independent reference
      cmd.scalar = 32'd1;
      cmd.mask_snapshot = '1;
      cmd.vta = 0;
      cmd.vma = 0;
      for (int opcode=32'h2c; opcode<=32'h2f; opcode++) begin
        for (int form=0; form<3; form++) begin
          mem[20] = '0;
          reads_before = read_count;
          cmd.inst = {6'(opcode),1'b1,5'd8,
                      (form==0 ? 5'd4 : form==1 ? 5'd3 : 5'd1),
                      (form==0 ? 3'b000 : form==1 ? 3'b100 : 3'b011),
                      5'd20,7'h57};
          cmd.tag = 16'(32'hb0 + (opcode-32'h2c)*3 + form);
          send_command();
          wanted++;
          await_commits(wanted);
          if (read_count != reads_before + (form==0 ? 4 : 3))
            $fatal(1,"narrow 1R source read count mismatch opcode=%h form=%0d",opcode,form);
          if (last_vxsat !== (opcode>=32'h2e))
            $fatal(1,"narrow saturation status mismatch opcode=%h form=%0d",opcode,form);
          for (int lane_index=0; lane_index<8; lane_index++) begin
            raw_source = mem[8+lane_index/4][(lane_index%4)*32 +: 32];
            shifted_unsigned = raw_source >> 1;
            shifted_signed = $signed(raw_source) >>> 1;
            case (opcode)
              32'h2c: expected_value = shifted_unsigned[15:0];
              32'h2d: expected_value = 16'(shifted_signed);
              32'h2e: expected_value = (shifted_unsigned > 32'hffff) ?
                                        16'hffff : shifted_unsigned[15:0];
              default: expected_value = (shifted_signed > 32767) ? 16'h7fff :
                                        (shifted_signed < -32768) ? 16'h8000 :
                                        16'(shifted_signed);
            endcase
            if (mem[20][lane_index*16 +: 16] !== expected_value)
              $fatal(1,"narrow opcode=%h form=%0d lane=%0d got=%h expected=%h",
                     opcode,form,lane_index,
                     mem[20][lane_index*16 +: 16],expected_value);
          end
        end
      end
      if (wanted != 152 || write_count != 129 || illegal_count != 5)
        $fatal(1,"narrow encoding sweep incomplete");
    end

    // LMUL=2 maps destination beats v20/v21 to source pairs v8/v9,
    // v10/v11. Fractional LMUL reads only one wide source register.
    for (int i=0; i<4; i++) begin
      mem[8+i] = '0;
      for (int j=0; j<4; j++)
        mem[8+i][j*32 +: 32] = 32'(2*(4*i+j+1));
    end
    cmd.inst = {6'h2c,1'b1,5'd8,5'd3,3'b100,5'd20,7'h57};
    cmd.sew = VSEW_16;
    cmd.vlmul = 3'b001;
    cmd.vl = 16;
    cmd.scalar = 32'd1;
    cmd.tag = 16'hc0;
    send_command();
    await_commits(154);
    for (int i=0; i<16; i++)
      if (mem[20+i/8][(i%8)*16 +: 16] !== 16'(i+1))
        $fatal(1,"narrow m2 source pair/address mismatch lane=%0d",i);

    mem[8] = {32'd8,32'd6,32'd4,32'd2};
    mem[24] = {8{16'h1234}};
    cmd.inst = {6'h2c,1'b1,5'd8,5'd3,3'b100,5'd24,7'h57};
    cmd.vlmul = 3'b111;
    cmd.vl = 4;
    cmd.tag = 16'hc1;
    send_command();
    await_commits(155);
    if (mem[24] !== {{4{16'h1234}},16'd4,16'd3,16'd2,16'd1})
      $fatal(1,"narrow fractional LMUL mismatch %h",mem[24]);

    // Low-end overlap is permitted, with mask and tail forced agnostic.
    mem[8] = {32'd16,32'd14,32'd12,32'd10};
    mem[9] = {32'd24,32'd22,32'd20,32'd18};
    cmd.inst = {6'h2c,1'b0,5'd8,5'd3,3'b100,5'd8,7'h57};
    cmd.vlmul = 3'b000;
    cmd.vl = 3;
    cmd.mask_snapshot = 128'h5;
    cmd.vta = 0;
    cmd.vma = 0;
    cmd.tag = 16'hc2;
    send_command();
    await_commits(156);
    if (mem[8] !== {{5{16'hffff}},16'd7,16'hffff,16'd5})
      $fatal(1,"narrow legal overlap/forced agnostic mismatch %h",mem[8]);

    cmd.inst = {6'h2c,1'b1,5'd8,5'd3,3'b100,5'd9,7'h57};
    cmd.tag = 16'hc3;
    send_command();
    await_commits(157);
    cmd.inst = {6'h2c,1'b1,5'd8,5'd3,3'b100,5'd16,7'h57};
    cmd.vlmul = 3'b011;
    cmd.vl = 128;
    cmd.tag = 16'hc4;
    send_command();
    await_commits(158);
    if (illegal_count != 7 || write_count != 133)
      $fatal(1,"narrow overlap/EMUL legality mismatch illegal=%0d writes=%0d",
             illegal_count,write_count);

    // RNU, RNE, RDN, ROD on a discarded half bit.
    mem[8] = {4{32'd5}};
    mem[9] = {4{32'd5}};
    cmd.inst = {6'h2e,1'b1,5'd8,5'd1,3'b011,5'd20,7'h57};
    cmd.vlmul = 3'b000;
    cmd.vl = 8;
    cmd.mask_snapshot = '1;
    for (int mode=0; mode<4; mode++) begin
      cmd.vxrm = 2'(mode);
      cmd.tag = 16'(32'hc5+mode);
      send_command();
      await_commits(159+mode);
      for (int i=0; i<8; i++)
        if (mem[20][i*16 +: 16] !== 16'((mode==0 || mode==3) ? 3 : 2))
          $fatal(1,"narrow vxrm mode=%0d lane=%0d got=%h",mode,i,
                 mem[20][i*16 +: 16]);
      if (last_vxsat) $fatal(1,"narrow vxrm falsely set vxsat");
    end

    // A saturated lane that is masked off must not set vxsat.
    mem[8] = {32'd0,32'd0,32'd0,32'h0001_ffff};
    mem[9] = '0;
    mem[20] = {8{16'h1234}};
    cmd.inst = {6'h2e,1'b0,5'd8,5'd1,3'b011,5'd20,7'h57};
    cmd.vxrm = 2'b10;
    cmd.mask_snapshot = 128'hfe;
    cmd.vta = 0;
    cmd.vma = 0;
    cmd.tag = 16'hc9;
    send_command();
    await_commits(163);
    if (last_vxsat || mem[20][15:0] !== 16'h1234)
      $fatal(1,"masked saturated lane changed vxsat/data");

    // The same two 64-bit compute stages cover SEW=8 and SEW=32.
    for (int i=0; i<2; i++) begin
      mem[8+i] = '0;
      for (int j=0; j<8; j++)
        mem[8+i][j*16 +: 16] = 16'(2*(8*i+j+1));
    end
    cmd.inst = {6'h2c,1'b1,5'd8,5'd3,3'b100,5'd20,7'h57};
    cmd.sew = VSEW_8;
    cmd.vl = 16;
    cmd.scalar = 32'd1;
    cmd.mask_snapshot = '1;
    cmd.tag = 16'hca;
    send_command();
    await_commits(164);
    for (int i=0; i<16; i++)
      if (mem[20][i*8 +: 8] !== 8'(i+1))
        $fatal(1,"narrow SEW8 mismatch lane=%0d",i);

    mem[8] = {64'h0000_0001_0000_0000,64'hffff_ffff_ffff_fffb};
    mem[9] = {64'd7,64'hffff_fffe_0000_0000};
    cmd.inst = {6'h2f,1'b1,5'd8,5'd1,3'b011,5'd20,7'h57};
    cmd.sew = VSEW_32;
    cmd.vl = 4;
    cmd.vxrm = 2'b10;
    cmd.tag = 16'hcb;
    send_command();
    await_commits(165);
    if (mem[20] !== {32'd3,32'h8000_0000,32'h7fff_ffff,32'hffff_fffd} ||
        !last_vxsat)
      $fatal(1,"narrow SEW32 signed saturation mismatch %h",mem[20]);

    // FP32 min/max reductions use the LMUL sequencer and one element/clock.
    mem[2] = {96'b0,32'h3f80_0000}; // +1.0 seed
    mem[8] = {32'h8000_0000,32'h0000_0000,
              32'hbf80_0000,32'h4000_0000};
    cmd.inst = {6'h05,1'b1,5'd8,5'd2,3'b001,5'd20,7'h57};
    cmd.sew = VSEW_32;
    cmd.vlmul = 3'b000;
    cmd.vl = 4;
    cmd.frm = 3'b000;
    cmd.tag = 16'hcc;
    send_command();
    await_commits(166);
    if (mem[20][31:0] !== 32'hbf80_0000 || last_fflags != 0)
      $fatal(1,"vfredmin numeric reduction mismatch %h flags=%h",mem[20],last_fflags);

    mem[2][31:0] = 32'h8000_0000; // -0.0 seed
    mem[8] = {4{32'h0000_0000}};
    cmd.inst = {6'h07,1'b1,5'd8,5'd2,3'b001,5'd20,7'h57};
    cmd.tag = 16'hcd;
    send_command();
    await_commits(167);
    if (mem[20][31:0] !== 32'h0000_0000 || last_fflags != 0)
      $fatal(1,"vfredmax signed zero mismatch %h",mem[20]);

    mem[2][31:0] = 32'h7fc0_0000; // quiet NaN seed
    mem[8] = {32'h4000_0000,32'h7f80_0001,
              32'h7fc0_0000,32'h3f80_0000};
    cmd.inst = {6'h05,1'b1,5'd8,5'd2,3'b001,5'd20,7'h57};
    cmd.tag = 16'hce;
    send_command();
    await_commits(168);
    if (mem[20][31:0] !== 32'h3f80_0000 || last_fflags != 5'h10)
      $fatal(1,"vfredmin NaN/NV mismatch %h flags=%h",mem[20],last_fflags);

    // Masked signaling NaN must not raise NV.
    mem[2][31:0] = 32'h4000_0000;
    mem[8] = {32'h4000_0000,32'h7f80_0001,
              32'h4000_0000,32'h4000_0000};
    cmd.inst = {6'h07,1'b0,5'd8,5'd2,3'b001,5'd20,7'h57};
    cmd.mask_snapshot = 128'hb;
    cmd.tag = 16'hcf;
    send_command();
    await_commits(169);
    if (mem[20][31:0] !== 32'h4000_0000 || last_fflags != 0)
      $fatal(1,"masked FP signaling NaN raised NV");

    // The second LMUL source beat changes the final reduction result.
    mem[2][31:0] = 32'h42c8_0000; // +100.0
    mem[8] = {4{32'h4000_0000}};
    mem[9] = {{3{32'h3f80_0000}},32'hc040_0000}; // -3.0 in lane 0
    cmd.inst = {6'h05,1'b1,5'd8,5'd2,3'b001,5'd20,7'h57};
    cmd.vlmul = 3'b001;
    cmd.vl = 8;
    cmd.mask_snapshot = '1;
    cmd.tag = 16'hd0;
    send_command();
    await_commits(171);
    if (mem[20][31:0] !== 32'hc040_0000 || last_fflags != 0)
      $fatal(1,"vfredmin LMUL=2 mismatch %h",mem[20]);

    // Reserved frm is rejected for FP instructions, including vl=0.
    cmd.frm = 3'b111;
    cmd.vl = 0;
    cmd.tag = 16'hd1;
    send_command();
    await_commits(172);
    if (illegal_count != 8)
      $fatal(1,"invalid frm accepted for FP reduction");

    // With no active elements, even an sNaN seed is copied unchanged.
    mem[2][31:0] = 32'h7f80_0001;
    mem[8] = {4{32'h3f80_0000}};
    cmd.inst = {6'h05,1'b0,5'd8,5'd2,3'b001,5'd20,7'h57};
    cmd.frm = 3'b000;
    cmd.vlmul = 3'b000;
    cmd.vl = 4;
    cmd.mask_snapshot = '0;
    cmd.tag = 16'hd2;
    send_command();
    await_commits(173);
    if (mem[20][31:0] !== 32'h7f80_0001 || last_fflags != 0)
      $fatal(1,"inactive FP reduction changed sNaN seed/flags");

    // FP32 add/sub/mul and all eight fused forms, each in .vv and .vf
    // where encoded. The same two FMA lanes execute every case.
    begin : fp_arith_sweep
      int wanted;
      logic [31:0] expected_bits;
      wanted = 173;
      mem[8] = {4{32'h4000_0000}};  // 2.0
      mem[4] = {4{32'h4040_0000}};  // 3.0
      cmd.scalar = 32'h4040_0000;
      cmd.sew = VSEW_32;
      cmd.vlmul = 3'b000;
      cmd.vl = 4;
      cmd.mask_snapshot = '1;
      cmd.frm = 3'b000;
      for (int opcode=0; opcode<12; opcode++) begin
        int funct6;
        case (opcode)
          0: funct6=32'h00;
          1: funct6=32'h02;
          2: funct6=32'h27;
          3: funct6=32'h24;
          default: funct6=32'h28+opcode-4;
        endcase
        case (funct6)
          32'h00: expected_bits=32'h40a0_0000; // 2+3=5
          32'h02: expected_bits=32'hbf80_0000; // 2-3=-1
          32'h27: expected_bits=32'h3f80_0000; // 3-2=1
          32'h24: expected_bits=32'h40c0_0000; // 2*3=6
          32'h28: expected_bits=32'h4188_0000; // 3*5+2=17
          32'h29: expected_bits=32'hc188_0000; // -3*5-2=-17
          32'h2a: expected_bits=32'h4150_0000; // 3*5-2=13
          32'h2b: expected_bits=32'hc150_0000; // -3*5+2=-13
          32'h2c: expected_bits=32'h4130_0000; // 3*2+5=11
          32'h2d: expected_bits=32'hc130_0000; // -3*2-5=-11
          32'h2e: expected_bits=32'h3f80_0000; // 3*2-5=1
          default: expected_bits=32'hbf80_0000; // -3*2+5=-1
        endcase
        for (int form=0; form<2; form++) begin
          if (funct6!=32'h27 || form==1) begin
            mem[20] = {4{32'h40a0_0000}}; // 5.0 destructive input
            cmd.inst = {6'(funct6),1'b1,5'd8,
                        (form==0 ? 5'd4 : 5'd3),
                        (form==0 ? 3'b001 : 3'b101),5'd20,7'h57};
            cmd.tag = 16'(32'he0+wanted-173);
            send_command();
            wanted++;
            await_commits(wanted);
            if (last_fflags != 0 || illegal_count != 8)
              $fatal(1,"FP arithmetic flags/illegal funct6=%h form=%0d flags=%h",
                     funct6,form,last_fflags);
            for (int lane=0; lane<4; lane++)
              if (mem[20][lane*32 +: 32] !== expected_bits)
                $fatal(1,"FP arithmetic funct6=%h form=%0d lane=%0d got=%h expected=%h",
                       funct6,form,lane,mem[20][lane*32 +: 32],expected_bits);
          end
        end
      end
      if (wanted != 196) $fatal(1,"FP arithmetic encoding sweep incomplete");
    end

    // A fused result that would become zero if the product were rounded first.
    mem[8] = {4{32'h3f80_0001}}; // 1+2^-23
    mem[4] = {4{32'h3f7f_fffe}}; // 1-2^-23
    mem[20] = {4{32'hbf80_0000}}; // -1
    cmd.inst = {6'h2c,1'b1,5'd8,5'd4,3'b001,5'd20,7'h57};
    cmd.tag = 16'hf8;
    send_command();
    await_commits(197);
    if (mem[20] !== {4{32'ha880_0000}} || last_fflags != 0)
      $fatal(1,"FP FMA lost fused precision %h flags=%h",mem[20],last_fflags);

    // Dynamic frm changes the rounded result and NX flag.
    mem[8] = {4{32'h3f80_0000}};
    mem[4] = {4{32'h3380_0000}}; // half an ulp at 1.0
    cmd.inst = {6'h00,1'b1,5'd8,5'd4,3'b001,5'd20,7'h57};
    for (int mode=0; mode<5; mode++) begin
      cmd.frm = 3'(mode);
      cmd.tag = 16'(32'hf9+mode);
      send_command();
      await_commits(198+mode);
      if (mem[20][31:0] !== ((mode==3 || mode==4) ?
                             32'h3f80_0001 : 32'h3f80_0000) ||
          last_fflags != 5'b00001)
        $fatal(1,"FP frm/NX mismatch mode=%0d data=%h flags=%h",
               mode,mem[20][31:0],last_fflags);
    end

    // Invalid, overflow, underflow, and exact subnormal results.
    cmd.frm = 3'b000;
    cmd.mask_snapshot = '1;
    cmd.inst = {6'h00,1'b1,5'd8,5'd4,3'b001,5'd20,7'h57};
    mem[8] = {4{32'h7f80_0000}}; // +infinity
    mem[4] = {4{32'hff80_0000}}; // -infinity
    cmd.tag = 16'hfe;
    send_command();
    await_commits(203);
    if (mem[20] !== {4{32'h7fc0_0000}} || last_fflags != 5'h10)
      $fatal(1,"FP inf-inf invalid mismatch %h flags=%h",mem[20],last_fflags);

    mem[8] = {4{32'h7f7f_ffff}};
    mem[4] = {4{32'h7f7f_ffff}};
    cmd.tag = 16'hff;
    send_command();
    await_commits(204);
    if (mem[20] !== {4{32'h7f80_0000}} || last_fflags != 5'h05)
      $fatal(1,"FP overflow mismatch %h flags=%h",mem[20],last_fflags);

    mem[8] = {4{32'h0000_0001}}; // smallest subnormal
    mem[4] = {4{32'h3f00_0000}}; // 0.5
    cmd.inst = {6'h24,1'b1,5'd8,5'd4,3'b001,5'd20,7'h57};
    cmd.tag = 16'h100;
    send_command();
    await_commits(205);
    if (mem[20] !== '0 || last_fflags != 5'h03)
      $fatal(1,"FP underflow mismatch %h flags=%h",mem[20],last_fflags);

    mem[8] = {4{32'h0080_0000}}; // smallest normal
    cmd.tag = 16'h101;
    send_command();
    await_commits(206);
    if (mem[20] !== {4{32'h0040_0000}} || last_fflags != 0)
      $fatal(1,"FP exact subnormal mismatch %h flags=%h",mem[20],last_fflags);

    // Masked invalid lanes must not contribute fflags; destination stays old.
    mem[8] = {4{32'h7f80_0000}};
    mem[4] = '0;
    mem[20] = {4{32'h3f80_0000}};
    cmd.inst = {6'h24,1'b0,5'd8,5'd4,3'b001,5'd20,7'h57};
    cmd.mask_snapshot = '0;
    cmd.vma = 0;
    cmd.tag = 16'h102;
    send_command();
    await_commits(207);
    if (mem[20] !== {4{32'h3f80_0000}} || last_fflags != 0)
      $fatal(1,"masked FP invalid lane changed data/flags");

    // Two destination beats consume aligned LMUL=2 source groups.
    mem[8] = {4{32'h4000_0000}};
    mem[9] = {4{32'h4080_0000}};
    mem[4] = {4{32'h4040_0000}};
    mem[5] = {4{32'h40a0_0000}};
    mem[20] = '0;
    mem[21] = '0;
    cmd.inst = {6'h2c,1'b1,5'd8,5'd4,3'b001,5'd20,7'h57};
    cmd.vlmul = 3'b001;
    cmd.vl = 8;
    cmd.mask_snapshot = '1;
    cmd.tag = 16'h103;
    send_command();
    await_commits(209);
    if (mem[20] !== {4{32'h40c0_0000}} || // 2*3=6
        mem[21] !== {4{32'h41a0_0000}} || // 4*5=20
        last_fflags != 0)
      $fatal(1,"FP FMA LMUL=2 mismatch %h %h",mem[20],mem[21]);

    // Multiplication must preserve the sign of an exact zero product.
    mem[8] = {4{32'h8000_0000}};
    mem[4] = {4{32'h4000_0000}};
    cmd.inst = {6'h24,1'b1,5'd8,5'd4,3'b001,5'd20,7'h57};
    cmd.vlmul = 3'b000;
    cmd.vl = 4;
    cmd.tag = 16'h104;
    send_command();
    await_commits(210);
    if (mem[20] !== {4{32'h8000_0000}} || last_fflags != 0)
      $fatal(1,"FP multiply signed zero mismatch %h flags=%h",mem[20],last_fflags);

    // Six FP32/int32 conversion encodings use the same two conversion lanes.
    begin : fp_convert_sweep
      int wanted;
      logic [31:0] source_bits, expected_bits;
      logic [4:0] expected_flags;
      int vs1_code;
      wanted = 210;
      cmd.frm = 3'b000;
      cmd.mask_snapshot = '1;
      for (int mode=0; mode<6; mode++) begin
        case (mode)
          0: begin vs1_code=0; source_bits=32'h4020_0000;
                   expected_bits=32'd2; expected_flags=5'h01; end
          1: begin vs1_code=1; source_bits=32'hc020_0000;
                   expected_bits=32'hffff_fffe; expected_flags=5'h01; end
          2: begin vs1_code=2; source_bits=32'hffff_ffff;
                   expected_bits=32'h4f80_0000; expected_flags=5'h01; end
          3: begin vs1_code=3; source_bits=32'h8000_0000;
                   expected_bits=32'hcf00_0000; expected_flags=5'h00; end
          4: begin vs1_code=6; source_bits=32'h4039_999a;
                   expected_bits=32'd2; expected_flags=5'h01; end
          default: begin vs1_code=7; source_bits=32'hc039_999a;
                   expected_bits=32'hffff_fffe; expected_flags=5'h01; end
        endcase
        mem[8] = {4{source_bits}};
        mem[20] = '0;
        cmd.inst = {6'h12,1'b1,5'd8,5'(vs1_code),3'b001,5'd20,7'h57};
        cmd.tag = 16'(32'h105+mode);
        send_command();
        wanted++;
        await_commits(wanted);
        if (mem[20] !== {4{expected_bits}} || last_fflags != expected_flags)
          $fatal(1,"FP convert mode=%0d got=%h flags=%h expected=%h/%h",
                 mode,mem[20],last_fflags,expected_bits,expected_flags);
      end
      mem[8] = {4{32'h7fc0_0000}}; // NaN -> maximum signed int, NV
      cmd.inst = {6'h12,1'b1,5'd8,5'd1,3'b001,5'd20,7'h57};
      cmd.tag = 16'h10b;
      send_command();
      await_commits(217);
      if (mem[20] !== {4{32'h7fff_ffff}} || last_fflags != 5'h10)
        $fatal(1,"FP convert NaN saturation mismatch %h/%h",mem[20],last_fflags);
      mem[8] = {4{32'hbf80_0000}}; // -1 -> unsigned zero, NV
      cmd.inst = {6'h12,1'b1,5'd8,5'd0,3'b001,5'd20,7'h57};
      cmd.tag = 16'h10c;
      send_command();
      await_commits(218);
      if (mem[20] !== '0 || last_fflags != 5'h10)
        $fatal(1,"FP convert negative unsigned mismatch %h/%h",mem[20],last_fflags);
    end

    // Ordered accumulation is also a legal implementation of unordered sum.
    // Both forms keep the seed across LMUL=2 VRF beats.
    cmd.sew = VSEW_32;
    cmd.vlmul = 3'b001;
    cmd.vl = 8;
    cmd.vstart = 0;
    cmd.mask_snapshot = '1;
    cmd.frm = 3'b000;
    mem[4] = {4{32'h3f80_0000}}; // seed 1
    mem[8] = {4{32'h3f80_0000}}; // four 1s
    mem[9] = {4{32'h4000_0000}}; // four 2s
    for (int mode=0; mode<2; mode++) begin
      mem[20] = '0;
      cmd.inst = {6'(mode==0 ? 1 : 3),1'b1,5'd8,5'd4,3'b001,5'd20,7'h57};
      cmd.tag = 16'(32'h10d+mode);
      send_command();
      await_commits(220+2*mode);
      if (mem[20][31:0] !== 32'h4150_0000 || last_fflags != 0)
        $fatal(1,"FP sum reduction mode=%0d data=%h flags=%h",
               mode,mem[20],last_fflags);
    end

    // No active source elements copies even a signaling-NaN seed verbatim.
    cmd.vlmul = 3'b000;
    cmd.vl = 4;
    cmd.mask_snapshot = '0;
    cmd.inst = {6'h03,1'b0,5'd8,5'd4,3'b001,5'd20,7'h57};
    mem[4][31:0] = 32'h7f80_0001;
    mem[20] = '0;
    cmd.tag = 16'h10f;
    send_command();
    await_commits(223);
    if (mem[20][31:0] !== 32'h7f80_0001 || last_fflags != 0)
      $fatal(1,"inactive FP sum changed seed/flags %h/%h",mem[20],last_fflags);

    // Iterative FP32 divide/reverse-divide/sqrt share one HardFloat engine.
    cmd.mask_snapshot = '1;
    cmd.vl = 4;
    mem[8] = {4{32'h4100_0000}}; // 8.0
    mem[4] = {4{32'h4000_0000}}; // 2.0
    cmd.inst = {6'h20,1'b1,5'd8,5'd4,3'b001,5'd20,7'h57};
    cmd.tag = 16'h110;
    send_command();
    await_commits(224);
    if (mem[20] !== {4{32'h4080_0000}} || last_fflags != 0)
      $fatal(1,"FP divide vv mismatch %h/%h",mem[20],last_fflags);

    cmd.scalar = 32'h4080_0000; // 4.0
    cmd.inst = {6'h20,1'b1,5'd8,5'd3,3'b101,5'd20,7'h57};
    cmd.tag = 16'h111;
    send_command();
    await_commits(225);
    if (mem[20] !== {4{32'h4000_0000}} || last_fflags != 0)
      $fatal(1,"FP divide vf mismatch %h/%h",mem[20],last_fflags);

    cmd.scalar = 32'h4180_0000; // 16.0 / 8.0
    cmd.inst = {6'h21,1'b1,5'd8,5'd3,3'b101,5'd20,7'h57};
    cmd.tag = 16'h112;
    send_command();
    await_commits(226);
    if (mem[20] !== {4{32'h4000_0000}} || last_fflags != 0)
      $fatal(1,"FP reverse divide mismatch %h/%h",mem[20],last_fflags);

    mem[8] = {4{32'h4110_0000}}; // sqrt(9)=3
    cmd.inst = {6'h13,1'b1,5'd8,5'd0,3'b001,5'd20,7'h57};
    cmd.tag = 16'h113;
    send_command();
    await_commits(227);
    if (mem[20] !== {4{32'h4040_0000}} || last_fflags != 0)
      $fatal(1,"FP sqrt mismatch %h/%h",mem[20],last_fflags);

    mem[8] = {4{32'h3f80_0000}};
    cmd.scalar = 32'h0000_0000;
    cmd.inst = {6'h20,1'b1,5'd8,5'd3,3'b101,5'd20,7'h57};
    cmd.tag = 16'h114;
    send_command();
    await_commits(228);
    if (mem[20] !== {4{32'h7f80_0000}} || last_fflags != 5'h08)
      $fatal(1,"FP divide-by-zero mismatch %h/%h",mem[20],last_fflags);

    mem[8] = {4{32'hbf80_0000}};
    cmd.inst = {6'h13,1'b1,5'd8,5'd0,3'b001,5'd20,7'h57};
    cmd.tag = 16'h115;
    send_command();
    await_commits(229);
    if (mem[20] !== {4{32'h7fc0_0000}} || last_fflags != 5'h10)
      $fatal(1,"FP sqrt negative mismatch %h/%h",mem[20],last_fflags);

    mem[20] = {4{32'h3f80_0000}};
    cmd.inst = {6'h20,1'b0,5'd8,5'd3,3'b101,5'd20,7'h57};
    cmd.mask_snapshot = '0;
    cmd.tag = 16'h116;
    send_command();
    await_commits(230);
    if (mem[20] !== {4{32'h3f80_0000}} || last_fflags != 0)
      $fatal(1,"masked FP divide changed data/flags %h/%h",mem[20],last_fflags);

    // Exact RVV 1.0 reciprocal-estimate lookup examples and special cases.
    mem[8] = {32'h7f80_0000,32'h7f76_5432,32'h0071_8abc,32'h3f80_0000};
    cmd.mask_snapshot = '1;
    cmd.inst = {6'h13,1'b1,5'd8,5'd5,3'b001,5'd20,7'h57};
    cmd.tag = 16'h117;
    send_command();
    await_commits(231);
    if (mem[20] !== {32'h0000_0000,32'h0021_4000,
                     32'h7e90_0000,32'h3f7f_0000} || last_fflags != 0)
      $fatal(1,"FP rec7 lookup mismatch %h/%h",mem[20],last_fflags);

    cmd.inst = {6'h13,1'b1,5'd8,5'd4,3'b001,5'd20,7'h57};
    cmd.tag = 16'h118;
    send_command();
    await_commits(232);
    if (mem[20] !== {32'h0000_0000,32'h1f82_0000,
                     32'h5f08_0000,32'h3f7f_0000} || last_fflags != 0)
      $fatal(1,"FP rsqrt7 lookup mismatch %h/%h",mem[20],last_fflags);

    mem[8] = {32'hbf80_0000,32'h7f80_0001,32'h8000_0000,32'h0000_0000};
    cmd.tag = 16'h119;
    send_command();
    await_commits(233);
    if (mem[20] !== {32'h7fc0_0000,32'h7fc0_0000,
                     32'hff80_0000,32'h7f80_0000} || last_fflags != 5'h18)
      $fatal(1,"FP rsqrt7 special mismatch %h/%h",mem[20],last_fflags);

    mem[8] = {4{32'h0000_0001}}; // reciprocal overflows
    cmd.inst = {6'h13,1'b1,5'd8,5'd5,3'b001,5'd20,7'h57};
    cmd.frm = 3'b001; // RTZ selects max finite
    cmd.tag = 16'h11a;
    send_command();
    await_commits(234);
    if (mem[20] !== {4{32'h7f7f_ffff}} || last_fflags != 5'h05)
      $fatal(1,"FP rec7 overflow/round mismatch %h/%h",mem[20],last_fflags);

    // The iterative unit restarts cleanly for the next LMUL destination beat.
    mem[8] = {4{32'h4100_0000}}; // 8 / 4 = 2
    mem[9] = {4{32'h4140_0000}}; // 12 / 4 = 3
    mem[20] = '0;
    mem[21] = '0;
    cmd.scalar = 32'h4080_0000;
    cmd.inst = {6'h20,1'b1,5'd8,5'd3,3'b101,5'd20,7'h57};
    cmd.vlmul = 3'b001;
    cmd.vl = 8;
    cmd.frm = 3'b000;
    cmd.tag = 16'h11b;
    send_command();
    await_commits(236);
    if (mem[20] !== {4{32'h4000_0000}} ||
        mem[21] !== {4{32'h4040_0000}} || last_fflags != 0)
      $fatal(1,"FP divide LMUL=2 mismatch %h %h/%h",
             mem[20],mem[21],last_fflags);

    $display("tb_vcore_alu_top PASS");
    $finish;
  end
endmodule
