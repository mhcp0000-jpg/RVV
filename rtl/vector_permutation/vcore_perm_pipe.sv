// One-cycle latch around vcore_perm_core. Unlike vcore_alu_pipe there is no
// low/high phase split: permutation crossbars route the full VLEN width in a
// single combinational pass, so accept-and-register is enough.
module vcore_perm_pipe #(
  parameter int unsigned VLEN = 128
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,
  input  logic                              flush_i,
  input  logic                              req_valid_i,
  output logic                              req_ready_o,
  input  vcore_perm_pkg::vcore_perm_ctrl_t  ctrl_i,
  input  logic [31:0]                       scalar_i,
  input  logic [VLEN-1:0]                   src1_i,
  input  logic [VLEN-1:0]                   src2_i,
  input  logic [vcore_perm_pkg::MAXLMUL*VLEN-1:0] src2_group_i,
  input  logic [vcore_perm_pkg::MAXLMUL*VLEN-1:0] src1_idx_group_i,
  input  logic [VLEN-1:0]                   dst_old_i,
  input  logic [VLEN-1:0]                   mask_i,
  output logic                              rsp_valid_o,
  input  logic                              rsp_ready_i,
  output logic [VLEN-1:0]                   result_o,
  output vcore_perm_pkg::vcore_perm_rsp_t   rsp_meta_o
);
  import vcore_perm_pkg::*;

  logic rsp_valid_q;
  logic [VLEN-1:0] rsp_data_q;
  vcore_perm_rsp_t rsp_meta_q;

  logic [VLEN-1:0] core_data;
  logic core_is_scalar, core_illegal;
  logic [31:0] core_scalar_data;

  logic rsp_slot_ready, req_fire;
  assign rsp_slot_ready = !rsp_valid_q || rsp_ready_i;
  assign req_ready_o = rsp_slot_ready && !flush_i;
  assign req_fire = req_valid_i && req_ready_o;
  assign rsp_valid_o = rsp_valid_q;
  assign result_o = rsp_data_q;
  assign rsp_meta_o = rsp_meta_q;

  vcore_perm_core #(.VLEN(VLEN)) u_core (
    .ctrl_i    (ctrl_i),
    .scalar_i  (scalar_i),
    .src1_i    (src1_i),
    .src2_i    (src2_i),
    .src2_group_i (src2_group_i),
    .src1_idx_group_i (src1_idx_group_i),
    .dst_old_i (dst_old_i),
    .mask_i    (mask_i),
    .data_o        (core_data),
    .is_scalar_o   (core_is_scalar),
    .scalar_data_o (core_scalar_data),
    .illegal_o     (core_illegal)
  );

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rsp_valid_q <= 1'b0;
      rsp_data_q  <= '0;
      rsp_meta_q  <= '0;
    end else if (flush_i) begin
      rsp_valid_q <= 1'b0;
    end else begin
      if (rsp_valid_q && rsp_ready_i) rsp_valid_q <= 1'b0;

      if (req_fire) begin
        rsp_valid_q <= 1'b1;
        rsp_data_q  <= core_data;
        rsp_meta_q.tag         <= ctrl_i.tag;
        rsp_meta_q.dest_addr   <= ctrl_i.vd_addr; // same encoding field as scalar rd/fd
        rsp_meta_q.is_scalar   <= core_is_scalar;
        rsp_meta_q.is_fp       <= ctrl_i.is_fp; // decode-time attribute, passed straight through
        rsp_meta_q.scalar_data <= core_scalar_data;
        rsp_meta_q.last_beat   <= ctrl_i.last_beat;
        rsp_meta_q.illegal_op  <= core_illegal;
      end
    end
  end

endmodule
