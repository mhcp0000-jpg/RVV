// One integer reduction element per clock. This reuses a single arithmetic
// operator across all SEW modes and every LMUL source-register beat.
module vcore_alu_reduce_step (
  input  logic [127:0]                     source_i,
  input  logic [127:0]                     mask_i,
  input  logic [4:0]                       element_index_i,
  input  logic [63:0]                      accumulator_i,
  input  vcore_alu_pkg::vcore_alu_ctrl_t  ctrl_i,
  output logic [63:0]                      accumulator_o
);
  import vcore_alu_pkg::*;

  logic [63:0] element;
  logic [16:0] global_index;
  logic [63:0] mask_w, acc, ext_element, next_acc;
  logic signed [63:0] signed_acc, signed_element;
  int unsigned result_width, source_width;

  always_comb begin
    source_width = 0;
    element = '0;
    case (ctrl_i.sew)
      VSEW_8: begin
        source_width = 8;
        element = 64'(source_i[int'(element_index_i)*8 +: 8]);
      end
      VSEW_16: begin
        source_width = 16;
        element = 64'(source_i[int'(element_index_i)*16 +: 16]);
      end
      VSEW_32: begin
        source_width = 32;
        element = 64'(source_i[int'(element_index_i)*32 +: 32]);
      end
      VSEW_64: begin
        source_width = 64;
        element = source_i[int'(element_index_i)*64 +: 64];
      end
      default: ;
    endcase
    global_index = ctrl_i.element_base + 17'(element_index_i);
    result_width = vop_is_widen_reduction(ctrl_i.op) ?
                   source_width*2 : source_width;
    mask_w = (result_width == 64) ? 64'hffff_ffff_ffff_ffff :
             (result_width == 0) ? 64'b0 :
             (64'hffff_ffff_ffff_ffff >> (64-result_width));
    acc = accumulator_i & mask_w;
    ext_element = element;
    if (ctrl_i.op == VOP_WREDSUM && source_width != 0)
      ext_element = $unsigned($signed(element << (64-source_width)) >>>
                              (64-source_width));
    ext_element &= mask_w;
    signed_acc = $signed(acc << (64-result_width)) >>> (64-result_width);
    signed_element = $signed(ext_element << (64-result_width)) >>>
                     (64-result_width);
    next_acc = acc;
    case (ctrl_i.op)
      VOP_REDSUM, VOP_WREDSUMU, VOP_WREDSUM: next_acc = acc + ext_element;
      VOP_REDAND:  next_acc = acc & ext_element;
      VOP_REDOR:   next_acc = acc | ext_element;
      VOP_REDXOR:  next_acc = acc ^ ext_element;
      VOP_REDMINU: next_acc = (acc < ext_element) ? acc : ext_element;
      VOP_REDMIN:  next_acc = (signed_acc < signed_element) ? acc : ext_element;
      VOP_REDMAXU: next_acc = (acc > ext_element) ? acc : ext_element;
      VOP_REDMAX:  next_acc = (signed_acc > signed_element) ? acc : ext_element;
      default: ;
    endcase
    accumulator_o = acc;
    if (source_width != 0 && global_index < ctrl_i.vl &&
        (ctrl_i.vm || mask_i[global_index[6:0]]))
      accumulator_o = next_acc & mask_w;
  end
endmodule
