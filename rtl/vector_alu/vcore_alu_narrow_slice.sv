// One 64-bit destination half per clock. Its wide source occupies 128 bits.
module vcore_alu_narrow_slice #(
  parameter int unsigned VLEN = 128,
  localparam int unsigned SLICE_W = VLEN/2
) (
  input  logic [VLEN-1:0]                wide_src_i,
  input  logic [SLICE_W-1:0]             shift_src_i,
  input  logic [SLICE_W-1:0]             old_data_i,
  input  logic [VLEN-1:0]                mask_i,
  input  logic                           high_half_i,
  input  vcore_alu_pkg::vcore_alu_ctrl_t ctrl_i,
  output logic [SLICE_W-1:0]             data_o,
  output logic                           vxsat_o
);
  import vcore_alu_pkg::*;

  typedef struct packed {
    logic [63:0] value;
    logic        sat;
  } narrow_result_t;

  function automatic narrow_result_t calculate(
    input logic [63:0] raw_source,
    input logic [63:0] raw_amount,
    input int unsigned width,
    input logic [7:0] op,
    input logic [1:0] vxrm
  );
    narrow_result_t result;
    logic [63:0] wide_mask, dest_mask, source_u, shifted_u;
    logic signed [63:0] source_s, shifted_s;
    logic [64:0] rounded_u;
    logic signed [64:0] rounded_s, signed_min, signed_max;
    logic guard_bit, lower_nonzero, discarded, increment, shifted_lsb;
    int unsigned wide_width, amount;
    result = '0;
    wide_width = 2*width;
    wide_mask = (wide_width == 64) ? '1 : ('1 >> (64-wide_width));
    dest_mask = '1 >> (64-width);
    source_u = raw_source & wide_mask;
    source_s = $signed(source_u << (64-wide_width)) >>> (64-wide_width);
    amount = int'(raw_amount & 64'(wide_width-1));
    shifted_u = source_u >> amount;
    shifted_s = source_s >>> amount;
    result.value = (op == VOP_NSRL || op == VOP_NCLIPU) ?
                   shifted_u : $unsigned(shifted_s);
    if (op == VOP_NCLIPU || op == VOP_NCLIP) begin
      guard_bit = 0;
      lower_nonzero = 0;
      discarded = 0;
      increment = 0;
      shifted_lsb = result.value[0];
      if (amount != 0) begin
        guard_bit = source_u[amount-1];
        lower_nonzero = (source_u & ((64'd1 << (amount-1))-1)) != 0;
        discarded = (source_u & ((64'd1 << amount)-1)) != 0;
        case (vxrm)
          2'b00: increment = guard_bit;
          2'b01: increment = guard_bit && (lower_nonzero || shifted_lsb);
          2'b10: increment = 0;
          2'b11: increment = discarded && !shifted_lsb;
          default: ;
        endcase
      end
      if (op == VOP_NCLIPU) begin
        rounded_u = {1'b0,shifted_u} + 65'(increment);
        result.sat = rounded_u > {1'b0,dest_mask};
        result.value = result.sat ? dest_mask : rounded_u[63:0];
      end else begin
        rounded_s = $signed({shifted_s[63],shifted_s}) +
                    $signed(65'(increment));
        signed_min = -(65'sd1 <<< (width-1));
        signed_max = (65'sd1 <<< (width-1)) - 65'sd1;
        result.sat = (rounded_s < signed_min) || (rounded_s > signed_max);
        result.value = (rounded_s < signed_min) ? signed_min[63:0] :
                       (rounded_s > signed_max) ? signed_max[63:0] :
                       rounded_s[63:0];
      end
    end
    result.value &= dest_mask;
    return result;
  endfunction

  always_comb begin : p_narrow
    narrow_result_t lane;
    logic [16:0] global_index;
    logic [63:0] wide_source, shift_amount;
    int unsigned local_index;
    data_o = old_data_i;
    vxsat_o = 1'b0;
    lane = '0;
    global_index = '0;
    wide_source = '0;
    shift_amount = '0;
    local_index = 0;
    case (ctrl_i.sew)
      VSEW_8: for (int i=0; i<SLICE_W/8; i++) begin
        local_index = (high_half_i ? SLICE_W/8 : 0) + i;
        global_index = ctrl_i.element_base + 17'(local_index);
        wide_source = 64'(wide_src_i[i*16 +: 16]);
        shift_amount = 64'(shift_src_i[i*8 +: 8]);
        lane = calculate(wide_source,shift_amount,8,ctrl_i.op,ctrl_i.vxrm);
        if (ctrl_i.vstart < ctrl_i.vl && global_index >= ctrl_i.vstart) begin
          if (global_index >= ctrl_i.vl) begin
            if (ctrl_i.vta) data_o[i*8 +: 8] = '1;
          end else if (!ctrl_i.vm && !mask_i[global_index[6:0]]) begin
            if (ctrl_i.vma) data_o[i*8 +: 8] = '1;
          end else begin
            data_o[i*8 +: 8] = lane.value[7:0];
            vxsat_o |= lane.sat;
          end
        end
      end
      VSEW_16: for (int i=0; i<SLICE_W/16; i++) begin
        local_index = (high_half_i ? SLICE_W/16 : 0) + i;
        global_index = ctrl_i.element_base + 17'(local_index);
        wide_source = 64'(wide_src_i[i*32 +: 32]);
        shift_amount = 64'(shift_src_i[i*16 +: 16]);
        lane = calculate(wide_source,shift_amount,16,ctrl_i.op,ctrl_i.vxrm);
        if (ctrl_i.vstart < ctrl_i.vl && global_index >= ctrl_i.vstart) begin
          if (global_index >= ctrl_i.vl) begin
            if (ctrl_i.vta) data_o[i*16 +: 16] = '1;
          end else if (!ctrl_i.vm && !mask_i[global_index[6:0]]) begin
            if (ctrl_i.vma) data_o[i*16 +: 16] = '1;
          end else begin
            data_o[i*16 +: 16] = lane.value[15:0];
            vxsat_o |= lane.sat;
          end
        end
      end
      VSEW_32: for (int i=0; i<SLICE_W/32; i++) begin
        local_index = (high_half_i ? SLICE_W/32 : 0) + i;
        global_index = ctrl_i.element_base + 17'(local_index);
        wide_source = wide_src_i[i*64 +: 64];
        shift_amount = 64'(shift_src_i[i*32 +: 32]);
        lane = calculate(wide_source,shift_amount,32,ctrl_i.op,ctrl_i.vxrm);
        if (ctrl_i.vstart < ctrl_i.vl && global_index >= ctrl_i.vstart) begin
          if (global_index >= ctrl_i.vl) begin
            if (ctrl_i.vta) data_o[i*32 +: 32] = '1;
          end else if (!ctrl_i.vm && !mask_i[global_index[6:0]]) begin
            if (ctrl_i.vma) data_o[i*32 +: 32] = '1;
          end else begin
            data_o[i*32 +: 32] = lane.value[31:0];
            vxsat_o |= lane.sat;
          end
        end
      end
      default: ;
    endcase
  end
endmodule
