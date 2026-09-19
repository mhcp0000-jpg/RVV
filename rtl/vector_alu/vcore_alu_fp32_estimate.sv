// RVV 1.0 binary32 reciprocal and reciprocal-square-root estimates.
// The result carries seven significand bits and uses the architectural lookup
// tables.  This path is combinational and independent of frm except for the
// vfrec7 overflow choice required by the specification.
module vcore_alu_fp32_estimate (
  input  logic [31:0] src_i,
  input  logic        rsqrt_i,
  input  logic [2:0]  frm_i,
  output logic [31:0] result_o,
  output logic [4:0]  fflags_o
);
  `include "vcore_alu_fp32_estimate_lut.svh"

  logic sign;
  logic [7:0] exponent;
  logic [22:0] fraction, normalized_fraction;
  logic [22:0] result_fraction;
  logic [6:0] lookup_index, lookup_value;
  integer signed normalized_exponent, result_exponent;

  always_comb begin
    sign = src_i[31];
    exponent = src_i[30:23];
    fraction = src_i[22:0];
    normalized_exponent = int'(exponent);
    normalized_fraction = fraction;
    result_exponent = 0;
    result_fraction = '0;
    lookup_index = '0;
    lookup_value = '0;
    result_o = '0;
    fflags_o = '0;

    // Normalize subnormal inputs. The extra shift removes the restored
    // leading one and leaves the 23 fraction bits used by the tables.
    if (exponent == 0 && fraction != 0) begin
      for (int bit_index=0; bit_index<23; bit_index++) begin
        if (!normalized_fraction[22]) begin
          normalized_fraction = normalized_fraction << 1;
          normalized_exponent = normalized_exponent - 1;
        end
      end
      normalized_fraction = normalized_fraction << 1;
    end

    if (exponent == 8'hff && fraction != 0) begin
      result_o = 32'h7fc0_0000;
      if (!fraction[22]) fflags_o[4] = 1'b1;
    end else if (rsqrt_i) begin
      if (exponent == 0 && fraction == 0) begin
        result_o = {sign,8'hff,23'b0};
        fflags_o[3] = 1'b1;
      end else if (sign) begin
        result_o = 32'h7fc0_0000;
        fflags_o[4] = 1'b1;
      end else if (exponent == 8'hff) begin
        result_o = 32'b0;
      end else begin
        lookup_index = {normalized_exponent[0],normalized_fraction[22:17]};
        lookup_value = VFRSQRT7_LUT[lookup_index];
        result_exponent = (380-normalized_exponent)/2;
        result_o = {1'b0,8'(result_exponent),lookup_value,16'b0};
      end
    end else begin
      if (exponent == 8'hff) begin
        result_o = {sign,31'b0};
      end else if (exponent == 0 && fraction == 0) begin
        result_o = {sign,8'hff,23'b0};
        fflags_o[3] = 1'b1;
      end else if (normalized_exponent < -1) begin
        // Tiny subnormals overflow. Rounding selects infinity or the greatest
        // finite value according to sign and the architectural frm encoding.
        if ((frm_i == 3'b001) ||
            (frm_i == 3'b010 && !sign) ||
            (frm_i == 3'b011 && sign))
          result_o = {sign,8'hfe,23'h7f_ffff};
        else
          result_o = {sign,8'hff,23'b0};
        fflags_o = 5'b00101;
      end else begin
        lookup_index = normalized_fraction[22:16];
        lookup_value = VFREC7_LUT[lookup_index];
        result_exponent = 253-normalized_exponent;
        result_fraction = {lookup_value,16'b0};
        if (result_exponent == 0 || result_exponent == -1) begin
          result_fraction = (result_fraction >> 1) | 23'h40_0000;
          if (result_exponent == -1)
            result_fraction = result_fraction >> 1;
          result_exponent = 0;
        end
        result_o = {sign,8'(result_exponent),result_fraction};
      end
    end
  end
endmodule
