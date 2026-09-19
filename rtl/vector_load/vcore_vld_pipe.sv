// One-cycle latch around vcore_vld_assemble, identical in shape to
// vcore_perm_pipe: accept-and-register, one result slot.
module vcore_vld_pipe #(
  parameter int unsigned VLEN = 128
) (
  input  logic                              clk_i,
  input  logic                              rst_ni,
  input  logic                              flush_i,
  input  logic                              req_valid_i,
  output logic                              req_ready_o,
  input  vcore_vld_pkg::vcore_vld_ctrl_t    ctrl_i,
  input  logic [vcore_vld_pkg::MAXEMUL*VLEN-1:0] data_group_i,
  input  logic [VLEN-1:0]                   dst_old_i,
  input  logic [VLEN-1:0]                   mask_i,
  input  logic                              mem_error_i,
  input  logic                              vl_trimmed_i,
  input  logic [16:0]                       new_vl_i,
  output logic                              rsp_valid_o,
  input  logic                              rsp_ready_i,
  output logic [VLEN-1:0]                   result_o,
  output vcore_vld_pkg::vcore_vld_rsp_t     rsp_meta_o
);
  import vcore_vld_pkg::*;

  logic rsp_valid_q;
  logic [VLEN-1:0] rsp_data_q;
  vcore_vld_rsp_t rsp_meta_q;

  logic [VLEN-1:0] core_data;
  logic core_illegal;
  logic rsp_slot_ready, req_fire;

  assign rsp_slot_ready = !rsp_valid_q || rsp_ready_i;
  assign req_ready_o    = rsp_slot_ready && !flush_i;
  assign req_fire       = req_valid_i && req_ready_o;
  assign rsp_valid_o    = rsp_valid_q;
  assign result_o       = rsp_data_q;
  assign rsp_meta_o     = rsp_meta_q;

  vcore_vld_assemble #(.VLEN(VLEN)) u_assemble (
    .ctrl_i       (ctrl_i),
    .data_group_i (data_group_i),
    .dst_old_i    (dst_old_i),
    .mask_i       (mask_i),
    .data_o       (core_data),
    .illegal_o    (core_illegal)
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
        rsp_meta_q.tag        <= ctrl_i.tag;
        rsp_meta_q.vd_addr    <= ctrl_i.vd_addr;
        rsp_meta_q.last_beat  <= ctrl_i.last_beat;
        rsp_meta_q.illegal_op <= core_illegal;
        rsp_meta_q.mem_error  <= mem_error_i;
        rsp_meta_q.vl_trimmed <= vl_trimmed_i;
        rsp_meta_q.new_vl     <= new_vl_i;
      end
    end
  end
endmodule
