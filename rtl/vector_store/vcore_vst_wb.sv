// Completion stage. A store writes no vector register, so there is no VRF
// write port here at all -- this module only turns a finished beat into the
// TOP commit event and the sequencer's beat acknowledgement.
module vcore_vst_wb (
  input  logic                              clk_i,
  input  logic                              rst_ni,
  input  logic                              flush_i,
  input  logic                              result_valid_i,
  output logic                              result_ready_o,
  input  vcore_vst_pkg::vcore_vst_commit_t  result_i,

  output logic                              commit_valid_o,
  input  logic                              commit_ready_i,
  output vcore_vst_pkg::vcore_vst_commit_t  commit_o,
  output logic                              seq_ack_valid_o,
  input  logic                              seq_ack_ready_i,
  output vcore_vst_pkg::vcore_vst_commit_t  seq_ack_o
);
  import vcore_vst_pkg::*;
  typedef enum logic [0:0] {WB_IDLE, WB_EVENT} state_e;
  state_e state_q;
  vcore_vst_commit_t meta_q;
  logic top_pending_q, seq_pending_q;

  assign result_ready_o  = (state_q == WB_IDLE) && !flush_i;
  assign commit_valid_o  = (state_q == WB_EVENT) && top_pending_q && !flush_i;
  assign seq_ack_valid_o = (state_q == WB_EVENT) && seq_pending_q && !flush_i;
  assign commit_o        = meta_q;
  assign seq_ack_o       = meta_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      state_q <= WB_IDLE; meta_q <= '0;
      top_pending_q <= 1'b0; seq_pending_q <= 1'b0;
    end else begin
      case (state_q)
        WB_IDLE: if (result_valid_i && result_ready_o) begin
          meta_q        <= result_i;
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
