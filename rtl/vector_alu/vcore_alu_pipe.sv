module vcore_alu_pipe #(
  parameter int unsigned VLEN = 128,
  localparam int unsigned SLICE_W = VLEN / 2
) (
  input  logic                           clk_i,
  input  logic                           rst_ni,
  input  logic                           flush_i,
  input  logic                           req_valid_i,
  output logic                           req_ready_o,
  input  vcore_alu_pkg::vcore_alu_ctrl_t ctrl_i,
  input  logic [VLEN-1:0]                src1_i,
  input  logic [VLEN-1:0]                src2_i,
  input  logic [VLEN-1:0]                dst_old_i,
  input  logic [VLEN-1:0]                mask_i,
  output logic                           rsp_valid_o,
  input  logic                           rsp_ready_i,
  output logic [VLEN-1:0]                result_o,
  output vcore_alu_pkg::vcore_alu_rsp_t  rsp_meta_o
);
  import vcore_alu_pkg::*;

  typedef enum logic {PHASE_LOW, PHASE_HIGH} phase_e;
  phase_e phase_q;
  logic rsp_valid_q;
  logic [VLEN-1:0] rsp_data_q;
  vcore_alu_rsp_t rsp_meta_q;

  vcore_alu_ctrl_t ctrl_q;
  logic [SLICE_W-1:0] src1_high_q, src2_high_q;
  logic [VLEN-1:0] dst_old_q, mask_q;
  logic [SLICE_W-1:0] low_data_q;
  logic [VLEN-1:0] low_mask_dst_q;
  logic low_vxsat_q;
  logic illegal_q;

  logic [SLICE_W-1:0] slice_src1, slice_src2, slice_old;
  logic [VLEN-1:0] slice_old_mask, slice_mask;
  vcore_alu_ctrl_t slice_ctrl;
  logic [SLICE_W-1:0] slice_data;
  logic [VLEN-1:0] slice_mask_dst;
  logic slice_vxsat;
  logic rsp_slot_ready;
  logic req_fire, finish_fire;

  assign rsp_slot_ready = !rsp_valid_q || rsp_ready_i;
  assign req_ready_o = (phase_q == PHASE_LOW) && rsp_slot_ready && !flush_i;
  assign req_fire = req_valid_i && req_ready_o;
  assign finish_fire = (phase_q == PHASE_HIGH) && rsp_slot_ready && !flush_i;
  assign rsp_valid_o = rsp_valid_q;
  assign result_o = rsp_data_q;
  assign rsp_meta_o = rsp_meta_q;

  always_comb begin
    if (phase_q == PHASE_LOW) begin
      slice_src1 = src1_i[SLICE_W-1:0];
      slice_src2 = src2_i[SLICE_W-1:0];
      slice_old = dst_old_i[SLICE_W-1:0];
      slice_old_mask = dst_old_i;
      slice_mask = mask_i;
      slice_ctrl = ctrl_i;
    end else begin
      slice_src1 = src1_high_q;
      slice_src2 = src2_high_q;
      slice_old = dst_old_q[VLEN-1:SLICE_W];
      slice_old_mask = low_mask_dst_q;
      slice_mask = mask_q;
      slice_ctrl = ctrl_q;
    end
  end

  vcore_alu_slice #(.VLEN(VLEN)) u_slice (
    .src1_i        (slice_src1),
    .src2_i        (slice_src2),
    .old_data_i    (slice_old),
    .old_mask_dst_i(slice_old_mask),
    .mask_i        (slice_mask),
    .high_half_i   (phase_q == PHASE_HIGH),
    .ctrl_i        (slice_ctrl),
    .data_o        (slice_data),
    .mask_dst_o    (slice_mask_dst),
    .vxsat_o       (slice_vxsat)
  );

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      phase_q <= PHASE_LOW;
      rsp_valid_q <= 1'b0;
      rsp_data_q <= '0;
      rsp_meta_q <= '0;
      ctrl_q <= '0;
      src1_high_q <= '0;
      src2_high_q <= '0;
      dst_old_q <= '0;
      mask_q <= '0;
      low_data_q <= '0;
      low_mask_dst_q <= '0;
      low_vxsat_q <= 1'b0;
      illegal_q <= 1'b0;
    end else if (flush_i) begin
      phase_q <= PHASE_LOW;
      rsp_valid_q <= 1'b0;
    end else begin
      if (rsp_valid_q && rsp_ready_i) rsp_valid_q <= 1'b0;

      if (req_fire) begin
        ctrl_q <= ctrl_i;
        src1_high_q <= src1_i[VLEN-1:SLICE_W];
        src2_high_q <= src2_i[VLEN-1:SLICE_W];
        dst_old_q <= dst_old_i;
        mask_q <= mask_i;
        low_data_q <= slice_data;
        low_mask_dst_q <= slice_mask_dst;
        low_vxsat_q <= slice_vxsat;
        illegal_q <= !vop_supported(ctrl_i.op) || !vsew_supported(ctrl_i.sew);
        phase_q <= PHASE_HIGH;
      end

      if (finish_fire) begin
        rsp_valid_q <= 1'b1;
        rsp_data_q <= illegal_q ? dst_old_q :
                      vop_is_compare(ctrl_q.op) ? slice_mask_dst :
                      {slice_data,low_data_q};
        rsp_meta_q.tag <= ctrl_q.tag;
        rsp_meta_q.vd_addr <= ctrl_q.vd_addr;
        rsp_meta_q.last_beat <= ctrl_q.last_beat;
        rsp_meta_q.vxsat <= illegal_q ? 1'b0 : (low_vxsat_q | slice_vxsat);
        rsp_meta_q.illegal_op <= illegal_q;
        phase_q <= PHASE_LOW;
      end
    end
  end

  initial begin : p_parameter_checks
    if (VLEN != VCORE_VLEN)
      $fatal(1,"This ALU package and v0 snapshot require VLEN=128");
  end

endmodule
