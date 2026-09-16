// Shared 64-bit execution slice: two 32-bit ALU resources at VLEN=128.
// The outer pipe selects the low or high half each cycle.
module vcore_alu_slice #(
  parameter int unsigned VLEN = 128,
  localparam int unsigned SLICE_W = VLEN / 2
) (
  input  logic [SLICE_W-1:0]             src1_i,
  input  logic [SLICE_W-1:0]             src2_i,
  input  logic [SLICE_W-1:0]             old_data_i,
  input  logic [VLEN-1:0]                old_mask_dst_i,
  input  logic [VLEN-1:0]                mask_i,
  input  logic                           high_half_i,
  input  vcore_alu_pkg::vcore_alu_ctrl_t ctrl_i,
  output logic [SLICE_W-1:0]             data_o,
  output logic [VLEN-1:0]                mask_dst_o,
  output logic                           vxsat_o
);
  import vcore_alu_pkg::*;

  typedef struct packed {
    logic [63:0] value;
    logic        sat;
  } elem_result_t;

  typedef struct packed {
    logic [63:0] data;
    logic        mask_bit;
    logic        sat;
  } lane_result_t;

  function automatic elem_result_t compute_elem(
    input logic [63:0] a_in,
    input logic [63:0] b_in,
    input int unsigned width,
    input logic [5:0] op
  );
    elem_result_t ret;
    logic [63:0] mask_w, a, b;
    logic signed [63:0] sa, sb;
    logic signed [64:0] signed_sum, signed_min, signed_max;
    logic [64:0] unsigned_sum;
    int unsigned shamt;
    ret = '0;
    mask_w = (width == 64) ? 64'hffff_ffff_ffff_ffff :
             (64'hffff_ffff_ffff_ffff >> (64-width));
    a = a_in & mask_w;
    b = b_in & mask_w;
    sa = $signed(a << (64-width)) >>> (64-width);
    sb = $signed(b << (64-width)) >>> (64-width);
    shamt = int'(b & 64'(width-1));
    signed_min = -(65'sd1 <<< (width-1));
    signed_max =  (65'sd1 <<< (width-1)) - 65'sd1;
    unsigned_sum = {1'b0,a} + {1'b0,b};
    signed_sum = '0;

    case (op)
      VOP_ADD:    ret.value = a + b;
      VOP_SUB:    ret.value = a - b;
      VOP_RSUB:   ret.value = b - a;
      VOP_AND:    ret.value = a & b;
      VOP_OR:     ret.value = a | b;
      VOP_XOR:    ret.value = a ^ b;
      VOP_SLL:    ret.value = a << shamt;
      VOP_SRL:    ret.value = a >> shamt;
      VOP_SRA:    ret.value = $unsigned(sa >>> shamt);
      VOP_MINU:   ret.value = (a < b) ? a : b;
      VOP_MIN:    ret.value = (sa < sb) ? a : b;
      VOP_MAXU:   ret.value = (a > b) ? a : b;
      VOP_MAX:    ret.value = (sa > sb) ? a : b;
      VOP_EQ:     ret.value = 64'(a == b);
      VOP_NE:     ret.value = 64'(a != b);
      VOP_LTU:    ret.value = 64'(a < b);
      VOP_LT:     ret.value = 64'(sa < sb);
      VOP_LEU:    ret.value = 64'(a <= b);
      VOP_LE:     ret.value = 64'(sa <= sb);
      VOP_GTU:    ret.value = 64'(a > b);
      VOP_GT:     ret.value = 64'(sa > sb);
      VOP_SADDU: begin
        ret.sat = unsigned_sum > {1'b0,mask_w};
        ret.value = ret.sat ? mask_w : unsigned_sum[63:0];
      end
      VOP_SADD: begin
        signed_sum = $signed({sa[63],sa}) + $signed({sb[63],sb});
        ret.sat = (signed_sum > signed_max) || (signed_sum < signed_min);
        ret.value = (signed_sum > signed_max) ? signed_max[63:0] :
                    (signed_sum < signed_min) ? signed_min[63:0] :
                    signed_sum[63:0];
      end
      VOP_SSUBU: begin
        ret.sat = a < b;
        ret.value = ret.sat ? 64'b0 : a-b;
      end
      VOP_SSUB: begin
        signed_sum = $signed({sa[63],sa}) - $signed({sb[63],sb});
        ret.sat = (signed_sum > signed_max) || (signed_sum < signed_min);
        ret.value = (signed_sum > signed_max) ? signed_max[63:0] :
                    (signed_sum < signed_min) ? signed_min[63:0] :
                    signed_sum[63:0];
      end
      VOP_COPY_B: ret.value = b;
      default:    ret.value = a;
    endcase
    ret.value &= mask_w;
    return ret;
  endfunction

  function automatic lane_result_t execute_lane(
    input logic [63:0] a,
    input logic [63:0] b,
    input logic [63:0] old_data,
    input logic old_mask,
    input logic mask_bit,
    input logic [16:0] global_index,
    input int unsigned width,
    input vcore_alu_ctrl_t ctrl
  );
    lane_result_t ret;
    elem_result_t calculation;
    logic is_compare;
    ret = '0;
    ret.data = old_data;
    ret.mask_bit = old_mask;
    is_compare = vop_is_compare(ctrl.op);
    calculation = compute_elem(a,b,width,ctrl.op);

    if (ctrl.vstart >= ctrl.vl) begin
      // RVV leaves even tail elements unchanged when the body is empty.
    end else if (global_index < ctrl.vstart) begin
      // Prestart elements are always undisturbed.
    end else if (global_index >= ctrl.vl) begin
      if (is_compare) ret.mask_bit = 1'b1; // mask tails are agnostic
      else if (ctrl.vta) ret.data = '1;
    end else if (!ctrl.vm && !mask_bit && ctrl.op != VOP_MERGE) begin
      if (is_compare) begin
        if (ctrl.vma) ret.mask_bit = 1'b1;
      end else if (ctrl.vma) ret.data = '1;
    end else if (ctrl.op == VOP_MERGE) begin
      ret.data = mask_bit ? b : a;
    end else if (is_compare) begin
      ret.mask_bit = calculation.value[0];
    end else begin
      ret.data = calculation.value;
      ret.sat = calculation.sat;
    end
    return ret;
  endfunction

  always_comb begin : p_execute_slice
    lane_result_t lane;
    logic [16:0] global_index;
    int unsigned local_index;
    data_o = old_data_i;
    mask_dst_o = old_mask_dst_i;
    vxsat_o = 1'b0;
    lane = '0;
    global_index = '0;
    local_index = 0;

    case (ctrl_i.sew)
      VSEW_8: begin
        for (int unsigned i = 0; i < SLICE_W/8; i++) begin
          local_index = (high_half_i ? SLICE_W/8 : 0) + i;
          global_index = ctrl_i.element_base + 17'(local_index);
          lane = execute_lane({56'b0,src2_i[i*8 +: 8]},
                              {56'b0,src1_i[i*8 +: 8]},
                              {56'b0,old_data_i[i*8 +: 8]},
                              old_mask_dst_i[global_index[6:0]],mask_i[global_index[6:0]],
                              global_index,8,ctrl_i);
          data_o[i*8 +: 8] = lane.data[7:0];
          mask_dst_o[global_index[6:0]] = lane.mask_bit;
          vxsat_o |= lane.sat;
        end
      end
      VSEW_16: begin
        for (int unsigned i = 0; i < SLICE_W/16; i++) begin
          local_index = (high_half_i ? SLICE_W/16 : 0) + i;
          global_index = ctrl_i.element_base + 17'(local_index);
          lane = execute_lane({48'b0,src2_i[i*16 +: 16]},
                              {48'b0,src1_i[i*16 +: 16]},
                              {48'b0,old_data_i[i*16 +: 16]},
                              old_mask_dst_i[global_index[6:0]],mask_i[global_index[6:0]],
                              global_index,16,ctrl_i);
          data_o[i*16 +: 16] = lane.data[15:0];
          mask_dst_o[global_index[6:0]] = lane.mask_bit;
          vxsat_o |= lane.sat;
        end
      end
      VSEW_32: begin
        for (int unsigned i = 0; i < SLICE_W/32; i++) begin
          local_index = (high_half_i ? SLICE_W/32 : 0) + i;
          global_index = ctrl_i.element_base + 17'(local_index);
          lane = execute_lane({32'b0,src2_i[i*32 +: 32]},
                              {32'b0,src1_i[i*32 +: 32]},
                              {32'b0,old_data_i[i*32 +: 32]},
                              old_mask_dst_i[global_index[6:0]],mask_i[global_index[6:0]],
                              global_index,32,ctrl_i);
          data_o[i*32 +: 32] = lane.data[31:0];
          mask_dst_o[global_index[6:0]] = lane.mask_bit;
          vxsat_o |= lane.sat;
        end
      end
      VSEW_64: begin
        for (int unsigned i = 0; i < SLICE_W/64; i++) begin
          local_index = (high_half_i ? SLICE_W/64 : 0) + i;
          global_index = ctrl_i.element_base + 17'(local_index);
          lane = execute_lane(src2_i[i*64 +: 64],src1_i[i*64 +: 64],
                              old_data_i[i*64 +: 64],
                              old_mask_dst_i[global_index[6:0]],mask_i[global_index[6:0]],
                              global_index,64,ctrl_i);
          data_o[i*64 +: 64] = lane.data;
          mask_dst_o[global_index[6:0]] = lane.mask_bit;
          vxsat_o |= lane.sat;
        end
      end
      default: begin
        data_o = old_data_i;
        mask_dst_o = old_mask_dst_i;
      end
    endcase
  end

endmodule
