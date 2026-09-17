// Writeback: same WB_IDLE/WB_WRITE/WB_EVENT flow as vcore_perm_wb, minus
// the scalar destination port (a load never writes a GPR/FPR).
//
// One addition: a beat whose group fetch came back with an error does NOT
// write the VRF. The host is supposed to have checked every address before
// commit (see vcore_vld_pkg), so an error response means the pre-commit
// check and the bus disagree; leaving the destination untouched and raising
// mem_error on the commit event lets the host trap on an architecturally
// clean register file rather than on half-poisoned data.
module vcore_vld_wb #(
  parameter int unsigned VLEN = 128
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,
  input  logic                                flush_i,
  input  logic                                result_valid_i,
  output logic                                result_ready_o,
  input  logic [VLEN-1:0]                     result_i,
  input  vcore_vld_pkg::vcore_vld_rsp_t       result_meta_i,

  output logic                                vrf_write_valid_o,
  input  logic                                vrf_write_ready_i,
  output vcore_vld_pkg::vcore_vrf_write_req_t vrf_write_req_o,
  output logic [VLEN-1:0]                     vrf_write_data_o,

  output logic                                commit_valid_o,
  input  logic                                commit_ready_i,
  output vcore_vld_pkg::vcore_vld_commit_t    commit_o,
  output logic                                seq_ack_valid_o,
  input  logic                                seq_ack_ready_i,
  output vcore_vld_pkg::vcore_vld_commit_t    seq_ack_o
);
  import vcore_vld_pkg::*;
  typedef enum logic [1:0] {WB_IDLE, WB_WRITE, WB_EVENT} state_e;
  state_e state_q;
  logic [VLEN-1:0] data_q;
  vcore_vld_rsp_t meta_q;
  logic top_pending_q, seq_pending_q;
  logic suppress_write;

  assign suppress_write = result_meta_i.illegal_op || result_meta_i.mem_error;

  assign result_ready_o    = (state_q == WB_IDLE) && !flush_i;
  assign vrf_write_valid_o = (state_q == WB_WRITE) && !flush_i;
  assign vrf_write_data_o  = data_q;
  assign vrf_write_req_o.vd_addr = meta_q.vd_addr;
  assign vrf_write_req_o.tag     = meta_q.tag;

  assign commit_valid_o  = (state_q == WB_EVENT) && top_pending_q && !flush_i;
  assign seq_ack_valid_o = (state_q == WB_EVENT) && seq_pending_q && !flush_i;
  assign commit_o.tag        = meta_q.tag;
  assign commit_o.last_beat  = meta_q.last_beat;
  assign commit_o.illegal_op = meta_q.illegal_op;
  assign commit_o.mem_error  = meta_q.mem_error;
  assign seq_ack_o = commit_o;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      state_q       <= WB_IDLE;
      data_q        <= '0;
      meta_q        <= '0;
      top_pending_q <= 1'b0;
      seq_pending_q <= 1'b0;
    end else begin
      case (state_q)
        WB_IDLE: if (result_valid_i && result_ready_o) begin
          data_q <= result_i;
          meta_q <= result_meta_i;
          if (suppress_write) begin
            top_pending_q <= 1'b1;
            seq_pending_q <= 1'b1;
            state_q       <= WB_EVENT;
          end else state_q <= WB_WRITE;
        end
        WB_WRITE: if (vrf_write_valid_o && vrf_write_ready_i) begin
          top_pending_q <= 1'b1;
          seq_pending_q <= 1'b1;
          state_q       <= WB_EVENT;
        end
        WB_EVENT: begin
          if (commit_valid_o && commit_ready_i) top_pending_q <= 1'b0;
          if (seq_ack_valid_o && seq_ack_ready_i) seq_pending_q <= 1'b0;
          if ((!top_pending_q || (commit_valid_o && commit_ready_i)) &&
              (!seq_pending_q || (seq_ack_valid_o && seq_ack_ready_i)))
            state_q <= WB_IDLE;
        end
        default: state_q <= WB_IDLE;
      endcase
    end
  end
endmodule
