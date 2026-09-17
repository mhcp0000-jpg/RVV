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

  typedef enum logic [2:0] {
    PHASE_LOW, PHASE_HIGH, PHASE_REDUCE, PHASE_MASK_REDUCE,
    PHASE_DIV_PREP, PHASE_DIV_STEP
  } phase_e;
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
  logic [4:0] low_fflags_q;
  logic illegal_q;
  logic [63:0] reduction_acc_q, reduction_next;
  logic [VLEN-1:0] reduction_src_q;
  logic [4:0] reduction_index_q, reduction_elements;
  logic [1:0] mask_chunk_q;
  logic [31:0] scalar_acc_q, mask_active_word, scalar_next;
  logic [5:0] mask_popcount, mask_first_bit;
  logic mask_first_found;
  logic [VLEN-1:0] div_src1_q, div_src2_q, div_result_q;
  logic [4:0] div_index_q, div_elements;
  logic [6:0] div_count_q;
  logic [63:0] div_numerator_q, div_denominator_q, div_quotient_q;
  logic [64:0] div_remainder_q;
  logic div_neg_quotient_q, div_neg_remainder_q;
  logic [63:0] div_a, div_b, div_mask_width, div_element_result;
  logic [63:0] div_special_result;
  logic signed [63:0] div_signed_a, div_signed_b;
  logic [16:0] div_global_index;
  logic [64:0] div_trial, div_remainder_next;
  logic [63:0] div_quotient_next;
  logic div_quotient_bit;
  int unsigned div_width;

  logic [SLICE_W-1:0] slice_src1, slice_src2, slice_old;
  logic [VLEN-1:0] extension_data;
  logic [VLEN-1:0] slice_old_mask, slice_mask;
  vcore_alu_ctrl_t slice_ctrl;
  logic [SLICE_W-1:0] slice_data;
  logic [VLEN-1:0] slice_mask_dst;
  logic slice_vxsat;
  logic [4:0] slice_fflags;
  logic rsp_slot_ready;
  logic req_fire, finish_fire;

  function automatic logic [63:0] reduction_seed(
    input logic [VLEN-1:0] seed_data,
    input vcore_alu_ctrl_t seed_ctrl
  );
    case (seed_ctrl.sew)
      VSEW_8:  return vop_is_widen_reduction(seed_ctrl.op) ?
                     64'(seed_data[15:0]) : 64'(seed_data[7:0]);
      VSEW_16: return vop_is_widen_reduction(seed_ctrl.op) ?
                     64'(seed_data[31:0]) : 64'(seed_data[15:0]);
      VSEW_32: return vop_is_widen_reduction(seed_ctrl.op) ?
                     seed_data[63:0] : 64'(seed_data[31:0]);
      VSEW_64: return seed_data[63:0];
      default: return '0;
    endcase
  endfunction

  // One source register contains several destination beats when source
  // EMUL is smaller than destination LMUL. The sequencer selects its VRF
  // address; this mux selects the relevant sub-register and widens its lanes.
  function automatic logic [VLEN-1:0] expand_extension(
    input logic [VLEN-1:0] source,
    input vcore_alu_ctrl_t ext_ctrl
  );
    logic [VLEN-1:0] expanded, aligned;
    int unsigned factor, dest_width, source_width, shift_bits;
    logic sign_mode;
    expanded = '0;
    dest_width = 8 << ext_ctrl.sew;
    factor = int'(vop_extension_factor(ext_ctrl.op));
    source_width = dest_width/factor;
    sign_mode = vop_extension_signed(ext_ctrl.op);
    shift_bits = (int'(ext_ctrl.element_base)*source_width) % VLEN;
    aligned = source >> shift_bits;
    case (dest_width)
      16: for (int i=0; i<VLEN/16; i++)
        expanded[i*16 +: 16] = sign_mode ?
          16'($signed(aligned[i*8 +: 8])) : 16'(aligned[i*8 +: 8]);
      32: for (int i=0; i<VLEN/32; i++) begin
        if (source_width == 8)
          expanded[i*32 +: 32] = sign_mode ?
            32'($signed(aligned[i*8 +: 8])) : 32'(aligned[i*8 +: 8]);
        else
          expanded[i*32 +: 32] = sign_mode ?
            32'($signed(aligned[i*16 +: 16])) : 32'(aligned[i*16 +: 16]);
      end
      64: for (int i=0; i<VLEN/64; i++) begin
        case (source_width)
          8: expanded[i*64 +: 64] = sign_mode ?
               64'($signed(aligned[i*8 +: 8])) : 64'(aligned[i*8 +: 8]);
          16: expanded[i*64 +: 64] = sign_mode ?
                64'($signed(aligned[i*16 +: 16])) : 64'(aligned[i*16 +: 16]);
          default: expanded[i*64 +: 64] = sign_mode ?
                64'($signed(aligned[i*32 +: 32])) : 64'(aligned[i*32 +: 32]);
        endcase
      end
      default: ;
    endcase
    return expanded;
  endfunction

  function automatic logic [VLEN-1:0] reduction_result(
    input logic [VLEN-1:0] old_data,
    input logic [63:0] reduced,
    input vcore_alu_ctrl_t reduced_ctrl
  );
    logic [VLEN-1:0] merged;
    merged = old_data;
    case (reduced_ctrl.sew)
      VSEW_8:  if (vop_is_widen_reduction(reduced_ctrl.op))
                 merged[15:0] = reduced[15:0];
               else merged[7:0] = reduced[7:0];
      VSEW_16: if (vop_is_widen_reduction(reduced_ctrl.op))
                 merged[31:0] = reduced[31:0];
               else merged[15:0] = reduced[15:0];
      VSEW_32: if (vop_is_widen_reduction(reduced_ctrl.op))
                 merged[63:0] = reduced;
               else merged[31:0] = reduced[31:0];
      VSEW_64: merged[63:0] = reduced;
      default: ;
    endcase
    return merged;
  endfunction

  assign rsp_slot_ready = !rsp_valid_q || rsp_ready_i;
  assign req_ready_o = (phase_q == PHASE_LOW) && rsp_slot_ready && !flush_i;
  assign req_fire = req_valid_i && req_ready_o;
  assign finish_fire = (phase_q == PHASE_HIGH) && rsp_slot_ready && !flush_i;
  assign rsp_valid_o = rsp_valid_q;
  assign result_o = rsp_data_q;
  assign rsp_meta_o = rsp_meta_q;
  assign extension_data = vop_is_extension(ctrl_i.op) ?
                          expand_extension(src2_i,ctrl_i) : src2_i;

  always_comb begin
    if (phase_q == PHASE_LOW) begin
      slice_src1 = src1_i[SLICE_W-1:0];
      slice_src2 = extension_data[SLICE_W-1:0];
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
    .vxsat_o       (slice_vxsat),
    .fflags_o      (slice_fflags)
  );

  always_comb begin
    case (ctrl_q.sew)
      VSEW_8: reduction_elements = 5'd16;
      VSEW_16: reduction_elements = 5'd8;
      VSEW_32: reduction_elements = 5'd4;
      VSEW_64: reduction_elements = 5'd2;
      default: reduction_elements = 5'd1;
    endcase
  end
  vcore_alu_reduce_step u_reduce_step (
    .source_i(reduction_src_q), .mask_i(mask_q),
    .element_index_i(reduction_index_q),
    .accumulator_i(reduction_acc_q), .ctrl_i(ctrl_q),
    .accumulator_o(reduction_next)
  );

  // Radix-2 restoring division: one quotient bit and one 65-bit subtract
  // per cycle. The variable source mux is only used in PHASE_DIV_PREP.
  always_comb begin
    div_width = 0;
    div_elements = '0;
    div_a = '0;
    div_b = '0;
    case (ctrl_q.sew)
      VSEW_8: begin
        div_width = 8;
        div_elements = 5'd16;
        div_a = 64'(div_src2_q[int'(div_index_q)*8 +: 8]);
        div_b = 64'(div_src1_q[int'(div_index_q)*8 +: 8]);
      end
      VSEW_16: begin
        div_width = 16;
        div_elements = 5'd8;
        div_a = 64'(div_src2_q[int'(div_index_q)*16 +: 16]);
        div_b = 64'(div_src1_q[int'(div_index_q)*16 +: 16]);
      end
      VSEW_32: begin
        div_width = 32;
        div_elements = 5'd4;
        div_a = 64'(div_src2_q[int'(div_index_q)*32 +: 32]);
        div_b = 64'(div_src1_q[int'(div_index_q)*32 +: 32]);
      end
      VSEW_64: begin
        div_width = 64;
        div_elements = 5'd2;
        div_a = div_src2_q[int'(div_index_q)*64 +: 64];
        div_b = div_src1_q[int'(div_index_q)*64 +: 64];
      end
      default: ;
    endcase
    div_mask_width = (div_width == 0) ? 64'b0 :
                     (64'hffff_ffff_ffff_ffff >> (64-div_width));
    div_signed_a = $signed(div_a << (64-div_width)) >>> (64-div_width);
    div_signed_b = $signed(div_b << (64-div_width)) >>> (64-div_width);
    div_global_index = ctrl_q.element_base + 17'(div_index_q);
    div_trial = {div_remainder_q[63:0],div_numerator_q[63]};
    div_quotient_bit = div_trial >= {1'b0,div_denominator_q};
    div_remainder_next = div_quotient_bit ?
                         div_trial - {1'b0,div_denominator_q} : div_trial;
    div_quotient_next = (div_quotient_q << 1) | 64'(div_quotient_bit);
    div_element_result = (ctrl_q.op == VOP_REM || ctrl_q.op == VOP_REMU) ?
                         div_remainder_next[63:0] : div_quotient_next;
    if ((ctrl_q.op == VOP_REM || ctrl_q.op == VOP_REMU) ?
        div_neg_remainder_q : div_neg_quotient_q)
      div_element_result = 64'b0 - div_element_result;
    div_element_result &= div_mask_width;
    if (div_b == 0)
      div_special_result = (ctrl_q.op == VOP_DIV || ctrl_q.op == VOP_DIVU) ?
                           div_mask_width : div_a;
    else
      div_special_result = (ctrl_q.op == VOP_DIV) ? div_a : 64'b0;
  end

  always_comb begin
    mask_active_word = '0;
    mask_popcount = '0;
    mask_first_bit = '0;
    mask_first_found = 1'b0;
    scalar_next = scalar_acc_q;
    for (int unsigned bit_index=0; bit_index<32; bit_index++) begin
      if (((int'(mask_chunk_q)*32 + bit_index) < int'(ctrl_q.vl)) &&
          reduction_src_q[int'(mask_chunk_q)*32 + bit_index] &&
          (ctrl_q.vm || mask_q[int'(mask_chunk_q)*32 + bit_index]))
        mask_active_word[bit_index] = 1'b1;
    end
    mask_popcount = 6'($countones(mask_active_word));
    for (int bit_index=31; bit_index>=0; bit_index--)
      if (mask_active_word[bit_index]) begin
        mask_first_found = 1'b1;
        mask_first_bit = 6'(bit_index);
      end
    if (ctrl_q.op == VOP_CPOP)
      scalar_next = scalar_acc_q + 32'(mask_popcount);
    else if (scalar_acc_q == 32'hffff_ffff && mask_first_found)
      scalar_next = 32'(mask_chunk_q)*32 + 32'(mask_first_bit);
  end

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
      low_fflags_q <= '0;
      illegal_q <= 1'b0;
      reduction_acc_q <= '0;
      reduction_src_q <= '0;
      reduction_index_q <= '0;
      mask_chunk_q <= '0;
      scalar_acc_q <= '0;
      div_src1_q <= '0;
      div_src2_q <= '0;
      div_result_q <= '0;
      div_index_q <= '0;
      div_count_q <= '0;
      div_numerator_q <= '0;
      div_denominator_q <= '0;
      div_quotient_q <= '0;
      div_remainder_q <= '0;
      div_neg_quotient_q <= 1'b0;
      div_neg_remainder_q <= 1'b0;
    end else if (flush_i) begin
      phase_q <= PHASE_LOW;
      rsp_valid_q <= 1'b0;
      reduction_acc_q <= '0;
      reduction_index_q <= '0;
      mask_chunk_q <= '0;
      div_index_q <= '0;
    end else begin
      if (rsp_valid_q && rsp_ready_i) rsp_valid_q <= 1'b0;

      if (req_fire) begin
        ctrl_q <= ctrl_i;
        src1_high_q <= src1_i[VLEN-1:SLICE_W];
        src2_high_q <= extension_data[VLEN-1:SLICE_W];
        dst_old_q <= dst_old_i;
        mask_q <= mask_i;
        if (!vop_is_reduction(ctrl_i.op)) begin
          low_data_q <= slice_data;
          low_mask_dst_q <= slice_mask_dst;
          low_vxsat_q <= slice_vxsat;
          low_fflags_q <= slice_fflags;
        end
        illegal_q <= !vop_supported(ctrl_i.op) || !vsew_supported(ctrl_i.sew);
        if (vop_is_reduction(ctrl_i.op)) begin
          reduction_src_q <= src2_i;
          reduction_index_q <= '0;
          if (ctrl_i.first_beat)
            reduction_acc_q <= reduction_seed(src1_i,ctrl_i);
          phase_q <= PHASE_REDUCE;
        end else if (vop_is_scalar_mask_reduce(ctrl_i.op)) begin
          reduction_src_q <= src2_i;
          mask_chunk_q <= '0;
          scalar_acc_q <= (ctrl_i.op == VOP_FIRST) ? 32'hffff_ffff : 32'd0;
          phase_q <= PHASE_MASK_REDUCE;
        end else if (vop_is_divide(ctrl_i.op)) begin
          div_src1_q <= src1_i;
          div_src2_q <= src2_i;
          div_result_q <= dst_old_i;
          div_index_q <= '0;
          phase_q <= PHASE_DIV_PREP;
        end else phase_q <= PHASE_HIGH;
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
        rsp_meta_q.fflags <= illegal_q ? 5'b0 : (low_fflags_q | slice_fflags);
        rsp_meta_q.write_enable <= !illegal_q;
        rsp_meta_q.scalar_valid <= 1'b0;
        rsp_meta_q.scalar_rd <= '0;
        rsp_meta_q.scalar_data <= '0;
        rsp_meta_q.illegal_op <= illegal_q;
        phase_q <= PHASE_LOW;
      end

      if (phase_q == PHASE_REDUCE) begin
        if (reduction_index_q + 5'd1 < reduction_elements) begin
          reduction_acc_q <= reduction_next;
          reduction_index_q <= reduction_index_q + 5'd1;
        end else if (rsp_slot_ready) begin
          reduction_acc_q <= reduction_next;
          rsp_valid_q <= 1'b1;
          rsp_data_q <= reduction_result(dst_old_q,reduction_next,ctrl_q);
          rsp_meta_q.tag <= ctrl_q.tag;
          rsp_meta_q.vd_addr <= ctrl_q.vd_addr;
          rsp_meta_q.last_beat <= ctrl_q.last_beat;
          rsp_meta_q.vxsat <= 1'b0;
          rsp_meta_q.fflags <= '0;
          rsp_meta_q.write_enable <= ctrl_q.last_beat && (ctrl_q.vl != 0);
          rsp_meta_q.scalar_valid <= 1'b0;
          rsp_meta_q.scalar_rd <= '0;
          rsp_meta_q.scalar_data <= '0;
          rsp_meta_q.illegal_op <= 1'b0;
          phase_q <= PHASE_LOW;
        end
      end

      if (phase_q == PHASE_MASK_REDUCE) begin
        if (mask_chunk_q != 2'd3) begin
          scalar_acc_q <= scalar_next;
          mask_chunk_q <= mask_chunk_q + 2'd1;
        end else if (rsp_slot_ready) begin
          scalar_acc_q <= scalar_next;
          rsp_valid_q <= 1'b1;
          rsp_data_q <= '0;
          rsp_meta_q.tag <= ctrl_q.tag;
          rsp_meta_q.vd_addr <= ctrl_q.vd_addr;
          rsp_meta_q.last_beat <= 1'b1;
          rsp_meta_q.vxsat <= 1'b0;
          rsp_meta_q.fflags <= '0;
          rsp_meta_q.write_enable <= 1'b0;
          rsp_meta_q.scalar_valid <= 1'b1;
          rsp_meta_q.scalar_rd <= ctrl_q.vd_addr;
          rsp_meta_q.scalar_data <= scalar_next;
          rsp_meta_q.illegal_op <= 1'b0;
          phase_q <= PHASE_LOW;
        end
      end

      if (phase_q == PHASE_DIV_PREP) begin
        if (div_index_q == div_elements) begin
          if (rsp_slot_ready) begin
            rsp_valid_q <= 1'b1;
            rsp_data_q <= div_result_q;
            rsp_meta_q.tag <= ctrl_q.tag;
            rsp_meta_q.vd_addr <= ctrl_q.vd_addr;
            rsp_meta_q.last_beat <= ctrl_q.last_beat;
            rsp_meta_q.vxsat <= 1'b0;
            rsp_meta_q.fflags <= '0;
            rsp_meta_q.write_enable <= 1'b1;
            rsp_meta_q.scalar_valid <= 1'b0;
            rsp_meta_q.scalar_rd <= '0;
            rsp_meta_q.scalar_data <= '0;
            rsp_meta_q.illegal_op <= 1'b0;
            phase_q <= PHASE_LOW;
          end
        end else if (ctrl_q.vstart >= ctrl_q.vl ||
                     div_global_index < ctrl_q.vstart) begin
          div_index_q <= div_index_q + 5'd1;
        end else if (div_global_index >= ctrl_q.vl ||
                     (!ctrl_q.vm && !mask_q[div_global_index[6:0]])) begin
          if ((div_global_index >= ctrl_q.vl && ctrl_q.vta) ||
              (div_global_index < ctrl_q.vl && ctrl_q.vma)) begin
            case (ctrl_q.sew)
              VSEW_8: div_result_q[int'(div_index_q)*8 +: 8] <= '1;
              VSEW_16: div_result_q[int'(div_index_q)*16 +: 16] <= '1;
              VSEW_32: div_result_q[int'(div_index_q)*32 +: 32] <= '1;
              VSEW_64: div_result_q[int'(div_index_q)*64 +: 64] <= '1;
              default: ;
            endcase
          end
          div_index_q <= div_index_q + 5'd1;
        end else if (div_b == 0 ||
                     ((ctrl_q.op == VOP_DIV || ctrl_q.op == VOP_REM) &&
                      div_a == (64'd1 << (div_width-1)) &&
                      div_b == div_mask_width)) begin
          // RISC-V M semantics: all-one quotient on divide-by-zero;
          // dividend remainder on divide-by-zero; min/-1 overflow.
          case (ctrl_q.sew)
            VSEW_8: div_result_q[int'(div_index_q)*8 +: 8] <= div_special_result[7:0];
            VSEW_16: div_result_q[int'(div_index_q)*16 +: 16] <= div_special_result[15:0];
            VSEW_32: div_result_q[int'(div_index_q)*32 +: 32] <= div_special_result[31:0];
            VSEW_64: div_result_q[int'(div_index_q)*64 +: 64] <= div_special_result;
            default: ;
          endcase
          div_index_q <= div_index_q + 5'd1;
        end else begin
          div_numerator_q <= (((ctrl_q.op == VOP_DIV || ctrl_q.op == VOP_REM) &&
                               div_signed_a[63]) ?
                              64'b0 - $unsigned(div_signed_a) : div_a) <<
                             (64-div_width);
          div_denominator_q <= ((ctrl_q.op == VOP_DIV || ctrl_q.op == VOP_REM) &&
                                div_signed_b[63]) ?
                               64'b0 - $unsigned(div_signed_b) : div_b;
          div_neg_quotient_q <= (ctrl_q.op == VOP_DIV) &&
                                (div_signed_a[63] ^ div_signed_b[63]);
          div_neg_remainder_q <= (ctrl_q.op == VOP_REM) && div_signed_a[63];
          div_quotient_q <= '0;
          div_remainder_q <= '0;
          div_count_q <= 7'(div_width);
          phase_q <= PHASE_DIV_STEP;
        end
      end

      if (phase_q == PHASE_DIV_STEP) begin
        div_numerator_q <= div_numerator_q << 1;
        div_quotient_q <= div_quotient_next;
        div_remainder_q <= div_remainder_next;
        if (div_count_q == 7'd1) begin
          case (ctrl_q.sew)
            VSEW_8: div_result_q[int'(div_index_q)*8 +: 8] <= div_element_result[7:0];
            VSEW_16: div_result_q[int'(div_index_q)*16 +: 16] <= div_element_result[15:0];
            VSEW_32: div_result_q[int'(div_index_q)*32 +: 32] <= div_element_result[31:0];
            VSEW_64: div_result_q[int'(div_index_q)*64 +: 64] <= div_element_result;
            default: ;
          endcase
          div_index_q <= div_index_q + 5'd1;
          phase_q <= PHASE_DIV_PREP;
        end else div_count_q <= div_count_q - 7'd1;
      end
    end
  end

  initial begin : p_parameter_checks
    if (VLEN != VCORE_VLEN)
      $fatal(1,"This ALU package and v0 snapshot require VLEN=128");
  end

endmodule
