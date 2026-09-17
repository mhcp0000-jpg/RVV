module vcore_perm_top #(
  parameter int unsigned VLEN = 128,
  parameter int unsigned ISSUE_DEPTH = 3
) (
  input  logic                                    clk_i,
  input  logic                                    rst_ni,
  input  logic                                    flush_i,

  // TOP control supplies instruction, scalar operand and effective vector CSR state.
  input  logic                                    cmd_valid_i,
  output logic                                    cmd_ready_o,
  input  vcore_perm_pkg::vcore_perm_cmd_t         cmd_i,

  // One physical VRF read port; request module reads each source in sequence.
  output logic                                    vrf_read_valid_o,
  input  logic                                    vrf_read_ready_i,
  output vcore_perm_pkg::vcore_vrf_read_req_t     vrf_read_req_o,
  input  logic                                    vrf_read_rsp_valid_i,
  output logic                                    vrf_read_rsp_ready_o,
  input  logic [VLEN-1:0]                         vrf_read_rsp_data_i,

  // Whole-register beat write; mask-destination scans write the mask reg.
  output logic                                    vrf_write_valid_o,
  input  logic                                    vrf_write_ready_i,
  output vcore_perm_pkg::vcore_vrf_write_req_t    vrf_write_req_o,
  output logic [VLEN-1:0]                         vrf_write_data_o,

  // vmv.x.s / vfmv.f.s write a scalar GPR/FPR instead of the VRF;
  // scalar_write_req_o.is_fp tells the caller which regfile to target.
  output logic                                    scalar_write_valid_o,
  input  logic                                    scalar_write_ready_i,
  output vcore_perm_pkg::vcore_scalar_write_req_t scalar_write_req_o,
  output logic [31:0]                             scalar_write_data_o,

  // One event per beat. last_beat marks completion of the instruction.
  output logic                                    commit_valid_o,
  input  logic                                    commit_ready_i,
  output vcore_perm_pkg::vcore_perm_commit_t      commit_o
);
  import vcore_perm_pkg::*;
  logic decode_valid, decode_ready;
  vcore_perm_decoded_t decode_data;
  logic issue_valid, issue_ready;
  vcore_perm_decoded_t issue_data;
  logic uop_valid, uop_ready;
  vcore_perm_uop_t uop_data;
  logic exec_valid, exec_ready;
  vcore_perm_ctrl_t exec_ctrl;
  logic [31:0] exec_scalar;
  logic [VLEN-1:0] exec_src1, exec_src2, exec_dst_old, exec_mask;
  logic [MAXLMUL*VLEN-1:0] exec_src2_group;
  logic [MAXLMUL*VLEN-1:0] exec_src1_idx_group;
  logic result_valid, result_ready;
  logic [VLEN-1:0] result_data;
  vcore_perm_rsp_t result_meta;
  logic seq_ack_valid, seq_ack_ready;
  vcore_perm_commit_t seq_ack_data;

  vcore_perm_decode #(.VLEN(VLEN)) u_decode (
    .cmd_valid_i(cmd_valid_i), .cmd_ready_o(cmd_ready_o), .cmd_i(cmd_i),
    .decoded_valid_o(decode_valid), .decoded_ready_i(decode_ready),
    .decoded_o(decode_data)
  );

  vcore_perm_issue_fifo #(.DEPTH(ISSUE_DEPTH)) u_issue_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .in_valid_i(decode_valid), .in_ready_o(decode_ready), .in_i(decode_data),
    .out_valid_o(issue_valid), .out_ready_i(issue_ready), .out_o(issue_data)
  );

  vcore_perm_sequencer #(.VLEN(VLEN)) u_sequencer (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .decoded_valid_i(issue_valid), .decoded_ready_o(issue_ready),
    .decoded_i(issue_data),
    .uop_valid_o(uop_valid), .uop_ready_i(uop_ready), .uop_o(uop_data),
    .beat_done_valid_i(seq_ack_valid), .beat_done_ready_o(seq_ack_ready),
    .beat_done_i(seq_ack_data)
  );

  vcore_perm_vrf_request #(.VLEN(VLEN)) u_vrf_request (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .uop_valid_i(uop_valid), .uop_ready_o(uop_ready), .uop_i(uop_data),
    .vrf_req_valid_o(vrf_read_valid_o), .vrf_req_ready_i(vrf_read_ready_i),
    .vrf_req_o(vrf_read_req_o),
    .vrf_rsp_valid_i(vrf_read_rsp_valid_i),
    .vrf_rsp_ready_o(vrf_read_rsp_ready_o),
    .vrf_rsp_data_i(vrf_read_rsp_data_i),
    .exec_valid_o(exec_valid), .exec_ready_i(exec_ready),
    .exec_ctrl_o(exec_ctrl), .exec_scalar_o(exec_scalar),
    .exec_src1_o(exec_src1), .exec_src2_o(exec_src2),
    .exec_src2_group_o(exec_src2_group),
    .exec_src1_idx_group_o(exec_src1_idx_group),
    .exec_dst_old_o(exec_dst_old), .exec_mask_o(exec_mask)
  );

  vcore_perm_pipe #(.VLEN(VLEN)) u_execute (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .req_valid_i(exec_valid), .req_ready_o(exec_ready),
    .ctrl_i(exec_ctrl), .scalar_i(exec_scalar),
    .src1_i(exec_src1), .src2_i(exec_src2),
    .src2_group_i(exec_src2_group),
    .src1_idx_group_i(exec_src1_idx_group),
    .dst_old_i(exec_dst_old), .mask_i(exec_mask),
    .rsp_valid_o(result_valid), .rsp_ready_i(result_ready),
    .result_o(result_data), .rsp_meta_o(result_meta)
  );

  vcore_perm_wb #(.VLEN(VLEN)) u_wb (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .result_valid_i(result_valid), .result_ready_o(result_ready),
    .result_i(result_data), .result_meta_i(result_meta),
    .vrf_write_valid_o(vrf_write_valid_o),
    .vrf_write_ready_i(vrf_write_ready_i),
    .vrf_write_req_o(vrf_write_req_o),
    .vrf_write_data_o(vrf_write_data_o),
    .scalar_write_valid_o(scalar_write_valid_o),
    .scalar_write_ready_i(scalar_write_ready_i),
    .scalar_write_req_o(scalar_write_req_o),
    .scalar_write_data_o(scalar_write_data_o),
    .commit_valid_o(commit_valid_o), .commit_ready_i(commit_ready_i),
    .commit_o(commit_o),
    .seq_ack_valid_o(seq_ack_valid), .seq_ack_ready_i(seq_ack_ready),
    .seq_ack_o(seq_ack_data)
  );

endmodule
