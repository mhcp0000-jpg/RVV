// Vector STORE cluster.
//
//   cmd -> decode -> issue FIFO -> sequencer -> memreq -> wb
//                                      ^                   |
//                                      +---- beat ack -----+
//
// Five stages, not the load cluster's six: a store has no assemble step and
// no result latch, because nothing is computed and nothing is written back
// to a vector register. The data goes from the VRF read port straight into
// the group buffer and out to memory.
//
// Scope: every RVV 1.0 vector store -- unit-stride, strided, indexed
// (unordered and ordered), whole-register, the mask store, and the segment
// form of each. 133 encodings.
//
// Note there is no VRF WRITE port on this module. For the TOP arbiter that
// means the store cluster only ever contends for the read port -- but it
// contends hard, reading up to 8 registers per instruction where a load
// reads at most one.
module vcore_vst_top #(
  parameter int unsigned VLEN = 128,
  parameter int unsigned ISSUE_DEPTH = 3,
  parameter int unsigned MAX_OUTSTANDING = 8
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,
  input  logic                                flush_i,

  input  logic                                cmd_valid_i,
  output logic                                cmd_ready_o,
  input  vcore_vst_pkg::vcore_vst_cmd_t       cmd_i,

  // VRF read port (1R1W VRF, shared with the other clusters): source data
  // registers, plus index registers for the indexed forms.
  output logic                                vrf_read_valid_o,
  input  logic                                vrf_read_ready_i,
  output vcore_vst_pkg::vcore_vrf_read_req_t  vrf_read_req_o,
  input  logic                                vrf_read_rsp_valid_i,
  output logic                                vrf_read_rsp_ready_o,
  input  logic [VLEN-1:0]                     vrf_read_rsp_data_i,

  // Tagged memory write interface; responses are acknowledgements.
  output logic                                mem_req_valid_o,
  input  logic                                mem_req_ready_i,
  output vcore_vst_pkg::vcore_vst_mem_req_t   mem_req_o,
  input  logic                                mem_rsp_valid_i,
  output logic                                mem_rsp_ready_o,
  input  vcore_vst_pkg::vcore_vst_mem_rsp_t   mem_rsp_i,

  output logic                                commit_valid_o,
  input  logic                                commit_ready_i,
  output vcore_vst_pkg::vcore_vst_commit_t    commit_o,

  output logic                                busy_o
);
  import vcore_vst_pkg::*;
  logic decode_valid, decode_ready;
  vcore_vst_decoded_t decode_data;
  logic issue_valid, issue_ready;
  vcore_vst_decoded_t issue_data;
  logic uop_valid, uop_ready;
  vcore_vst_uop_t uop_data;
  logic done_valid, done_ready;
  vcore_vst_commit_t done_data;
  logic seq_ack_valid, seq_ack_ready;
  vcore_vst_commit_t seq_ack_data;

  vcore_vst_decode #(.VLEN(VLEN)) u_decode (
    .cmd_valid_i(cmd_valid_i), .cmd_ready_o(cmd_ready_o), .cmd_i(cmd_i),
    .decoded_valid_o(decode_valid), .decoded_ready_i(decode_ready),
    .decoded_o(decode_data)
  );

  vcore_vst_issue_fifo #(.DEPTH(ISSUE_DEPTH)) u_issue_fifo (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .in_valid_i(decode_valid), .in_ready_o(decode_ready), .in_i(decode_data),
    .out_valid_o(issue_valid), .out_ready_i(issue_ready), .out_o(issue_data)
  );

  vcore_vst_sequencer #(.VLEN(VLEN)) u_sequencer (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .decoded_valid_i(issue_valid), .decoded_ready_o(issue_ready),
    .decoded_i(issue_data),
    .uop_valid_o(uop_valid), .uop_ready_i(uop_ready), .uop_o(uop_data),
    .beat_done_valid_i(seq_ack_valid), .beat_done_ready_o(seq_ack_ready),
    .beat_done_i(seq_ack_data)
  );

  vcore_vst_memreq #(.VLEN(VLEN), .MAX_OUTSTANDING(MAX_OUTSTANDING)) u_memreq (
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
    .done_valid_o(done_valid), .done_ready_i(done_ready), .done_o(done_data),
    .busy_o(busy_o)
  );

  vcore_vst_wb u_wb (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .result_valid_i(done_valid), .result_ready_o(done_ready), .result_i(done_data),
    .commit_valid_o(commit_valid_o), .commit_ready_i(commit_ready_i),
    .commit_o(commit_o),
    .seq_ack_valid_o(seq_ack_valid), .seq_ack_ready_i(seq_ack_ready),
    .seq_ack_o(seq_ack_data)
  );

endmodule
