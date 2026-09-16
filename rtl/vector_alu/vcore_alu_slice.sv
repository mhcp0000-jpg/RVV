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

  function automatic logic [63:0] round_shift(
    input logic signed [127:0] value,
    input int unsigned amount,
    input logic [1:0] vxrm,
    input logic signed_mode
  );
    logic [127:0] shifted;
    logic guard_bit, lower_nonzero, any_discarded, increment;
    shifted = signed_mode ? $unsigned(value >>> amount) :
                            ($unsigned(value) >> amount);
    guard_bit = 0;
    lower_nonzero = 0;
    any_discarded = 0;
    increment = 0;
    if (amount != 0) begin
      guard_bit = value[amount-1];
      lower_nonzero = (value & ((128'd1 << (amount-1))-1)) != 0;
      any_discarded = (value & ((128'd1 << amount)-1)) != 0;
      case (vxrm)
        2'b00: increment = guard_bit; // rnu
        2'b01: increment = guard_bit && (lower_nonzero || shifted[0]); // rne
        2'b10: increment = 0; // rdn
        2'b11: increment = any_discarded && !shifted[0]; // rod
      endcase
    end
    return shifted[63:0] + 64'(increment);
  endfunction

  function automatic elem_result_t compute_elem(
    input logic [63:0] a_in,
    input logic [63:0] b_in,
    input logic [63:0] old_in,
    input int unsigned width,
    input logic [7:0] op,
    input logic carry_bit,
    input logic [1:0] vxrm
  );
    elem_result_t ret;
    logic [63:0] mask_w, a, b, old_value;
    logic signed [63:0] sa, sb;
    logic signed [64:0] signed_sum, signed_min, signed_max;
    logic [64:0] unsigned_sum;
    logic signed [127:0] round_input, product_s, product_su;
    logic [127:0] product_u;
    int unsigned shamt;
    ret = '0;
    mask_w = (width == 64) ? 64'hffff_ffff_ffff_ffff :
             (64'hffff_ffff_ffff_ffff >> (64-width));
    a = a_in & mask_w;
    b = b_in & mask_w;
    old_value = old_in & mask_w;
    sa = $signed(a << (64-width)) >>> (64-width);
    sb = $signed(b << (64-width)) >>> (64-width);
    shamt = int'(b & 64'(width-1));
    signed_min = -(65'sd1 <<< (width-1));
    signed_max =  (65'sd1 <<< (width-1)) - 65'sd1;
    unsigned_sum = {1'b0,a} + {1'b0,b};
    signed_sum = '0;
    round_input = '0;
    product_s = '0;
    product_su = '0;
    product_u = '0;

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
      VOP_ADC:    ret.value = a + b + 64'(carry_bit);
      VOP_MADC:   ret.value = 64'(({1'b0,a} + {1'b0,b} + 65'(carry_bit)) >> width);
      VOP_SBC:    ret.value = a - b - 64'(carry_bit);
      VOP_MSBC:   ret.value = 64'({1'b0,a} < ({1'b0,b} + 65'(carry_bit)));
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
      VOP_AADDU, VOP_ASUBU: begin
        unsigned_sum = (op == VOP_AADDU) ?
                       {1'b0,a} + {1'b0,b} : {1'b0,a} - {1'b0,b};
        round_input = {63'b0,unsigned_sum};
        ret.value = round_shift(round_input,1,vxrm,1'b0);
      end
      VOP_AADD, VOP_ASUB: begin
        signed_sum = (op == VOP_AADD) ?
                     $signed({sa[63],sa}) + $signed({sb[63],sb}) :
                     $signed({sa[63],sa}) - $signed({sb[63],sb});
        round_input = {{63{signed_sum[64]}},signed_sum};
        ret.value = round_shift(round_input,1,vxrm,1'b1);
      end
      VOP_SSRL: begin
        round_input = {64'b0,a};
        ret.value = round_shift(round_input,shamt,vxrm,1'b0);
      end
      VOP_SSRA: begin
        round_input = {{64{sa[63]}},sa};
        ret.value = round_shift(round_input,shamt,vxrm,1'b1);
      end
      VOP_SMUL: begin
        product_s = sa * sb;
        ret.sat = (a == (64'd1 << (width-1))) &&
                  (b == (64'd1 << (width-1)));
        ret.value = ret.sat ? signed_max[63:0] :
                    round_shift(product_s,width-1,vxrm,1'b1);
      end
      VOP_MUL, VOP_MULHU, VOP_MULHSU, VOP_MULH,
      VOP_MADD, VOP_NMSUB, VOP_MACC, VOP_NMSAC: begin
        product_u = 128'(a) * 128'(b);
        product_s = sa * sb;
        product_su = sa * $signed({1'b0,b});
        case (op)
          VOP_MUL:    ret.value = product_u[63:0];
          VOP_MULHU:  ret.value = 64'(product_u >> width);
          VOP_MULHSU: ret.value = 64'(product_su >>> width);
          VOP_MULH:   ret.value = 64'(product_s >>> width);
          VOP_MACC:   ret.value = old_value + product_u[63:0];
          VOP_NMSAC:  ret.value = old_value - product_u[63:0];
          VOP_MADD: begin
            product_u = 128'(old_value) * 128'(b);
            ret.value = a + product_u[63:0];
          end
          VOP_NMSUB: begin
            product_u = 128'(old_value) * 128'(b);
            ret.value = a - product_u[63:0];
          end
          default: ;
        endcase
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
    calculation = compute_elem(a,b,old_data,width,ctrl.op,
                               !ctrl.vm && mask_bit,ctrl.vxrm);

    if (ctrl.vstart >= ctrl.vl) begin
      // RVV leaves even tail elements unchanged when the body is empty.
    end else if (global_index < ctrl.vstart) begin
      // Prestart elements are always undisturbed.
    end else if (global_index >= ctrl.vl) begin
      if (is_compare) ret.mask_bit = 1'b1; // mask tails are agnostic
      else if (ctrl.vta) ret.data = '1;
    end else if (!ctrl.vm && !mask_bit && ctrl.op != VOP_MERGE &&
                 !vop_uses_carry(ctrl.op)) begin
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

    if (vop_is_mask_logic(ctrl_i.op)) begin
      for (int unsigned bit_index = 0; bit_index < SLICE_W; bit_index++) begin
        global_index = 17'((high_half_i ? SLICE_W : 0) + bit_index);
        if (ctrl_i.vstart < ctrl_i.vl &&
            global_index >= ctrl_i.vstart && global_index < ctrl_i.vl) begin
          case (ctrl_i.op)
            VOP_MANDN: data_o[bit_index] = src2_i[bit_index] & ~src1_i[bit_index];
            VOP_MAND:  data_o[bit_index] = src2_i[bit_index] & src1_i[bit_index];
            VOP_MOR:   data_o[bit_index] = src2_i[bit_index] | src1_i[bit_index];
            VOP_MXOR:  data_o[bit_index] = src2_i[bit_index] ^ src1_i[bit_index];
            VOP_MORN:  data_o[bit_index] = src2_i[bit_index] | ~src1_i[bit_index];
            VOP_MNAND: data_o[bit_index] = ~(src2_i[bit_index] & src1_i[bit_index]);
            VOP_MNOR:  data_o[bit_index] = ~(src2_i[bit_index] | src1_i[bit_index]);
            VOP_MXNOR: data_o[bit_index] = ~(src2_i[bit_index] ^ src1_i[bit_index]);
            default: ;
          endcase
        end else if (ctrl_i.vstart < ctrl_i.vl && global_index >= ctrl_i.vl) begin
          // Mask destination tail bits are agnostic; all ones is legal.
          data_o[bit_index] = 1'b1;
        end
      end
    end else case (ctrl_i.sew)
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
