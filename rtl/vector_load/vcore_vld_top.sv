// Vector unit-stride LOAD cluster.
//
//   cmd -> decode -> issue FIFO -> sequencer -> memreq -> pipe -> wb
//                                      ^                           |
//                                      +------ beat ack -----------+
//
// Same six-stage skeleton as vcore_perm_top. The one structural difference
// is where the operands come from: the permutation cluster's
// vcore_perm_vrf_request stages vs1/vs2/vd out of the VRF, while
// vcore_vld_memreq stages the loaded elements out of an external, tagged,
// out-of-order memory interface with up to MAX_OUTSTANDING element requests
// in flight, and reads only the old destination register from the VRF (and
// only when some slot can survive unwritten -- see vld_needs_dst_old).
//
// Request issue happens in the execute stage of the pipeline, not at decode:
// the sequencer hands a beat to vcore_vld_memreq, which fires memory
// requests for that instruction's active elements and waits for every
// response before the assemble stage runs. Beat 0 fetches the whole
// destination EMUL group, so later beats need no bus traffic at all.
module vcore_vld_top #(
  parameter int unsigned VLEN = 128,
  parameter int unsigned ISSUE_DEPTH = 3,
  parameter int unsigned MAX_OUTSTANDING = 8
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,
  input  logic                                flush_i,

  input  logic                                cmd_valid_i,
  output logic                                cmd_ready_o,
  input  vcore_vld_pkg::vcore_vld_cmd_t       cmd_i,

  // Old-destination read port (1R1W VRF, shared with the other clusters).
  output logic                                vrf_read_valid_o,
  input  logic                                vrf_read_ready_i,
  output vcore_vld_pkg::vcore_vrf_read_req_t  vrf_read_req_o,
  input  logic                                vrf_read_rsp_valid_i,
  output logic                                vrf_read_rsp_ready_o,
  input  logic [VLEN-1:0]                     vrf_read_rsp_data_i,

  // Whole-register beat write.
  output logic                                vrf_write_valid_o,
  input  logic                                vrf_write_ready_i,
  output vcore_vld_pkg::vcore_vrf_write_req_t vrf_write_req_o,
  output logic [VLEN-1:0]                     vrf_write_data_o,

  // External memory interface: one request per element, responses may come
  // back in any order and are matched by tag.
  output logic                                mem_req_valid_o,
  input  logic                                mem_req_ready_i,
  output vcore_vld_pkg::vcore_vld_mem_req_t   mem_req_o,
  input  logic                                mem_rsp_valid_i,
  output logic                                mem_rsp_ready_o,
  input  vcore_vld_pkg::vcore_vld_mem_rsp_t   mem_rsp_i,

  // One event per beat; last_beat marks completion of the instruction.
  output logic                                commit_valid_o,
  input  logic                                commit_ready_i,
  output vcore_vld_pkg::vcore_vld_commit_t    commit_o,

  // High while any element request may still be owed a response, so the
  // host can tell the cluster is not quiescent (e.g. before a fence, or
  // before retiring a flush).
  output logic                                busy_o
);
  import vcore_vld_pkg::*;
  logic decode_valid, decode_ready;
  vcore_vld_decoded_t decode_data;
  logic issue_valid, issue_ready;
  vcore_vld_decoded_t issue_data;
  logic uop_valid, uop_ready;
  vcore_vld_uop_t uop_data;
  logic exec_valid, exec_ready;
  vcore_vld_ctrl_t exec_ctrl;
  logic [MAXEMUL*VLEN-1:0] exec_data_group;
  logic [VLEN-1:0] exec_dst_old, exec_mask;
  logic exec_mem_error;
  logic result_valid, result_ready;
  logic [VLEN-1:0] result_data;
  vcore_vld_rsp_t result_meta;
  logic seq_ack_valid, seq_ack_ready;
  vcore_vld_commit_t seq_ack_data;

  vcore_vld_decode #(.VLEN(VLEN)) u_decode (
    .cmd_valid_i(cmd_valid_i), .cmd_ready_o(cmd_ready_o), .cmd_i(cmd_i),
    .decoded_valid_o(decode_valid), .decoded_ready_i(decode_ready),
    .decoded_o(decode_data)
  );

  vcore_vld_issue_fifo #(.DEPTH(ISSUE_DEPTH)) u_issue_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .in_valid_i(decode_valid), .in_ready_o(decode_ready), .in_i(decode_data),
    .out_valid_o(issue_valid), .out_ready_i(issue_ready), .out_o(issue_data)
  );

  vcore_vld_sequencer #(.VLEN(VLEN)) u_sequencer (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .decoded_valid_i(issue_valid), .decoded_ready_o(issue_ready),
    .decoded_i(issue_data),
    .uop_valid_o(uop_valid), .uop_ready_i(uop_ready), .uop_o(uop_data),
    .beat_done_valid_i(seq_ack_valid), .beat_done_ready_o(seq_ack_ready),
    .beat_done_i(seq_ack_data)
  );

  vcore_vld_memreq #(.VLEN(VLEN), .MAX_OUTSTANDING(MAX_OUTSTANDING)) u_memreq (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .uop_valid_i(uop_valid), .uop_ready_o(uop_ready), .uop_i(uop_data),
    .vrf_req_valid_o(vrf_read_valid_o), .vrf_req_ready_i(vrf_read_ready_i),
    .vrf_req_o(vrf_read_req_o),
    .vrf_rsp_valid_i(vrf_read_rsp_valid_i),
    .vrf_rsp_ready_o(vrf_read_rsp_ready_o),
    .vrf_rsp_data_i(vrf_read_rsp_data_i),
    .mem_req_valid_o(mem_req_valid_o), .mem_req_ready_i(mem_req_ready_i),
    .mem_req_o(mem_req_o),
    .mem_rsp_valid_i(mem_rsp_valid_i), .mem_rsp_ready_o(mem_rsp_ready_o),
    .mem_rsp_i(mem_rsp_i),
    .exec_valid_o(exec_valid), .exec_ready_i(exec_ready),
    .exec_ctrl_o(exec_ctrl),
    .exec_data_group_o(exec_data_group),
    .exec_dst_old_o(exec_dst_old), .exec_mask_o(exec_mask),
    .exec_mem_error_o(exec_mem_error),
    .busy_o(busy_o)
  );

  vcore_vld_pipe #(.VLEN(VLEN)) u_execute (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .req_valid_i(exec_valid), .req_ready_o(exec_ready),
    .ctrl_i(exec_ctrl),
    .data_group_i(exec_data_group),
    .dst_old_i(exec_dst_old), .mask_i(exec_mask),
    .mem_error_i(exec_mem_error),
    .rsp_valid_o(result_valid), .rsp_ready_i(result_ready),
    .result_o(result_data), .rsp_meta_o(result_meta)
  );

  vcore_vld_wb #(.VLEN(VLEN)) u_wb (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .result_valid_i(result_valid), .result_ready_o(result_ready),
    .result_i(result_data), .result_meta_i(result_meta),
    .vrf_write_valid_o(vrf_write_valid_o),
    .vrf_write_ready_i(vrf_write_ready_i),
    .vrf_write_req_o(vrf_write_req_o),
    .vrf_write_data_o(vrf_write_data_o),
    .commit_valid_o(commit_valid_o), .commit_ready_i(commit_ready_i),
    .commit_o(commit_o),
    .seq_ack_valid_o(seq_ack_valid), .seq_ack_ready_i(seq_ack_ready),
    .seq_ack_o(seq_ack_data)
  );

endmodule
