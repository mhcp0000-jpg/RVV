// Two binary32 lanes per 64-bit compute phase. All FP add/sub/mul/FMA
// operations feed the same fused multiply-add implementation per lane.
module vcore_alu_fp32_slice #(
  parameter int unsigned VLEN = 128,
  localparam int unsigned SLICE_W = VLEN/2
) (
  input  logic [SLICE_W-1:0]             src1_i,
  input  logic [SLICE_W-1:0]             src2_i,
  input  logic [SLICE_W-1:0]             old_data_i,
  input  logic [VLEN-1:0]                mask_i,
  input  logic                           high_half_i,
  input  logic                           reduce_mode_i,
  input  logic [31:0]                    reduce_acc_i,
  input  logic [31:0]                    reduce_element_i,
  input  vcore_alu_pkg::vcore_alu_ctrl_t ctrl_i,
  output logic [SLICE_W-1:0]             data_o,
  output logic [4:0]                     fflags_o,
  output logic [31:0]                    reduce_result_o,
  output logic [4:0]                     reduce_flags_o
);
  import vcore_alu_pkg::*;
  logic [31:0] a [2], b [2], c [2], result [2];
  logic [31:0] converted [2];
  logic [31:0] estimated [2];
  logic [1:0] fma_op [2];
  logic [4:0] flags [2];
  logic [4:0] convert_flags [2];
  logic [4:0] estimate_flags [2];
  logic [16:0] global_index [2];

  for (genvar lane=0; lane<2; lane++) begin : g_lane
    always_comb begin
      a[lane] = src1_i[lane*32 +: 32];
      b[lane] = src2_i[lane*32 +: 32];
      c[lane] = old_data_i[lane*32 +: 32];
      fma_op[lane] = 2'b00;
      case (ctrl_i.op)
        VOP_FADD, VOP_FSUB: begin
          a[lane] = 32'h3f80_0000; // exact 1.0
          c[lane] = src1_i[lane*32 +: 32];
          fma_op[lane] = (ctrl_i.op == VOP_FSUB) ? 2'b01 : 2'b00;
        end
        VOP_FRSUB: begin
          a[lane] = 32'h3f80_0000;
          b[lane] = src1_i[lane*32 +: 32];
          c[lane] = src2_i[lane*32 +: 32];
          fma_op[lane] = 2'b01;
        end
        // A product with signed zero must keep its sign. Adding +0 would
        // turn an exact -0 product into +0 under round-to-nearest.
        VOP_FMUL: c[lane] = {(src1_i[lane*32+31] ^ src2_i[lane*32+31]),31'b0};
        VOP_FMADD, VOP_FNMADD, VOP_FMSUB, VOP_FNMSUB: begin
          b[lane] = old_data_i[lane*32 +: 32];
          c[lane] = src2_i[lane*32 +: 32];
        end
        default: ; // accumulator-overwrite FMA
      endcase
      case (ctrl_i.op)
        VOP_FNMADD, VOP_FNMACC: fma_op[lane] = 2'b11;
        VOP_FMSUB, VOP_FMSAC:   fma_op[lane] = 2'b01;
        VOP_FNMSUB, VOP_FNMSAC: fma_op[lane] = 2'b10;
        default: ;
      endcase
      if (lane == 0 && reduce_mode_i) begin
        a[lane] = 32'h3f80_0000;
        b[lane] = reduce_acc_i;
        c[lane] = reduce_element_i;
        fma_op[lane] = 2'b00;
      end
      global_index[lane] = ctrl_i.element_base +
                            17'((high_half_i ? 2 : 0) + lane);
    end
    vcore_alu_fp32_fma u_fma (
      .a_i(a[lane]), .b_i(b[lane]), .c_i(c[lane]),
      .op_i(fma_op[lane]), .frm_i(ctrl_i.frm),
      .result_o(result[lane]), .fflags_o(flags[lane])
    );
    vcore_alu_fp32_convert u_convert (
      .src_i(src2_i[lane*32 +: 32]), .op_i(ctrl_i.op),
      .frm_i(ctrl_i.frm), .result_o(converted[lane]),
      .fflags_o(convert_flags[lane])
    );
    vcore_alu_fp32_estimate u_estimate (
      .src_i(src2_i[lane*32 +: 32]),
      .rsqrt_i(ctrl_i.op == VOP_FRSQRT7), .frm_i(ctrl_i.frm),
      .result_o(estimated[lane]), .fflags_o(estimate_flags[lane])
    );
  end

  assign reduce_result_o = result[0];
  assign reduce_flags_o = flags[0];

  always_comb begin
    data_o = old_data_i;
    fflags_o = '0;
    for (int lane=0; lane<2; lane++) begin
      if (ctrl_i.vstart < ctrl_i.vl &&
          global_index[lane] >= ctrl_i.vstart) begin
        if (global_index[lane] >= ctrl_i.vl) begin
          if (ctrl_i.vta) data_o[lane*32 +: 32] = '1;
        end else if (!ctrl_i.vm && !mask_i[global_index[lane][6:0]]) begin
          if (ctrl_i.vma) data_o[lane*32 +: 32] = '1;
        end else begin
          data_o[lane*32 +: 32] = vop_is_fp_convert(ctrl_i.op) ?
                                    converted[lane] :
                                  vop_is_fp_estimate(ctrl_i.op) ?
                                    estimated[lane] : result[lane];
          fflags_o |= vop_is_fp_convert(ctrl_i.op) ?
                      convert_flags[lane] :
                      vop_is_fp_estimate(ctrl_i.op) ?
                      estimate_flags[lane] : flags[lane];
        end
      end
    end
  end
endmodule
