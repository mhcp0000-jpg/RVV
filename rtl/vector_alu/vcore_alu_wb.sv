module vcore_alu_wb #(
  parameter int unsigned VLEN = 128
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,
  input  logic                              flush_i,
  input  logic                              result_valid_i,
  output logic                              result_ready_o,
  input  logic [VLEN-1:0]                   result_i,
  input  vcore_alu_pkg::vcore_alu_rsp_t     result_meta_i,
  output logic                              vrf_write_valid_o,
  input  logic                              vrf_write_ready_i,
  output vcore_alu_pkg::vcore_vrf_write_req_t vrf_write_req_o,
  output logic [VLEN-1:0]                   vrf_write_data_o,
  output logic                              commit_valid_o,
  input  logic                              commit_ready_i,
  output vcore_alu_pkg::vcore_alu_commit_t  commit_o,
  output logic                              seq_ack_valid_o,
  input  logic                              seq_ack_ready_i,
  output vcore_alu_pkg::vcore_alu_commit_t  seq_ack_o
);
  import vcore_alu_pkg::*;
  typedef enum logic [1:0] {WB_IDLE, WB_WRITE, WB_EVENT} state_e;
  state_e state_q;
  logic [VLEN-1:0] data_q;
  vcore_alu_rsp_t meta_q;
  logic top_pending_q, seq_pending_q;

  assign result_ready_o = (state_q == WB_IDLE) && !flush_i;
  assign vrf_write_valid_o = (state_q == WB_WRITE) && !flush_i;
  assign vrf_write_data_o = data_q;
  assign vrf_write_req_o.vd_addr = meta_q.vd_addr;
  assign vrf_write_req_o.tag = meta_q.tag;
  assign commit_valid_o = (state_q == WB_EVENT) && top_pending_q && !flush_i;
  assign seq_ack_valid_o = (state_q == WB_EVENT) && seq_pending_q && !flush_i;
  assign commit_o.tag = meta_q.tag;
  assign commit_o.last_beat = meta_q.last_beat;
  assign commit_o.vxsat = meta_q.vxsat;
  assign commit_o.fflags = meta_q.fflags;
  assign commit_o.scalar_valid = meta_q.scalar_valid;
  assign commit_o.scalar_rd = meta_q.scalar_rd;
  assign commit_o.scalar_data = meta_q.scalar_data;
  assign commit_o.illegal_op = meta_q.illegal_op;
  assign seq_ack_o = commit_o;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      state_q <= WB_IDLE;
      data_q <= '0;
      meta_q <= '0;
      top_pending_q <= 1'b0;
      seq_pending_q <= 1'b0;
    end else begin
      case (state_q)
        WB_IDLE: if (result_valid_i && result_ready_o) begin
          data_q <= result_i;
          meta_q <= result_meta_i;
          if (result_meta_i.illegal_op || !result_meta_i.write_enable) begin
            top_pending_q <= 1'b1;
            seq_pending_q <= 1'b1;
            state_q <= WB_EVENT;
          end else state_q <= WB_WRITE;
        end
        WB_WRITE: if (vrf_write_valid_o && vrf_write_ready_i) begin
          top_pending_q <= 1'b1;
          seq_pending_q <= 1'b1;
          state_q <= WB_EVENT;
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
