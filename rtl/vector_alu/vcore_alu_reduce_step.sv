// One reduction element per clock across all LMUL source-register beats.
module vcore_alu_reduce_step (
  input  logic [127:0]                     source_i,
  input  logic [127:0]                     mask_i,
  input  logic [4:0]                       element_index_i,
  input  logic [63:0]                      accumulator_i,
  input  vcore_alu_pkg::vcore_alu_ctrl_t  ctrl_i,
  output logic [63:0]                      accumulator_o,
  output logic                             invalid_o
);
  import vcore_alu_pkg::*;

  logic [63:0] element;
  logic [16:0] global_index;
  logic [63:0] mask_w, acc, ext_element, next_acc;
  logic signed [63:0] signed_acc, signed_element;
  logic fp_acc_nan, fp_elem_nan, fp_acc_snan, fp_elem_snan;
  logic fp_less, active;
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
    fp_acc_nan = (acc[30:23] == 8'hff) && (acc[22:0] != 0);
    fp_elem_nan = (ext_element[30:23] == 8'hff) &&
                  (ext_element[22:0] != 0);
    fp_acc_snan = fp_acc_nan && !acc[22];
    fp_elem_snan = fp_elem_nan && !ext_element[22];
    fp_less = 1'b0;
    if (acc[30:0] != 0 || ext_element[30:0] != 0) begin
      if (acc[31] != ext_element[31]) fp_less = acc[31];
      else if (acc[31]) fp_less = acc[30:0] > ext_element[30:0];
      else fp_less = acc[30:0] < ext_element[30:0];
    end
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
      VOP_FREDMIN, VOP_FREDMAX: begin
        if (fp_acc_nan && fp_elem_nan) next_acc = 64'h7fc0_0000;
        else if (fp_acc_nan) next_acc = ext_element;
        else if (fp_elem_nan) next_acc = acc;
        else if (acc[30:0] == 0 && ext_element[30:0] == 0)
          next_acc = (ctrl_i.op == VOP_FREDMIN) ?
                     64'({acc[31] | ext_element[31],31'b0}) :
                     64'({acc[31] & ext_element[31],31'b0});
        else if (ctrl_i.op == VOP_FREDMIN)
          next_acc = fp_less ? acc : ext_element;
        else next_acc = fp_less ? ext_element : acc;
      end
      default: ;
    endcase
    accumulator_o = acc;
    active = (source_width != 0) && (global_index < ctrl_i.vl) &&
             (ctrl_i.vm || mask_i[global_index[6:0]]);
    invalid_o = active &&
                (ctrl_i.op == VOP_FREDMIN || ctrl_i.op == VOP_FREDMAX) &&
                (fp_acc_snan || fp_elem_snan);
    if (active)
      accumulator_o = next_acc & mask_w;
  end
endmodule
