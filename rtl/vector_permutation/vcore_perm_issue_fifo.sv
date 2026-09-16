module vcore_perm_issue_fifo #(
  parameter int unsigned DEPTH = 3,
  localparam int unsigned PTR_W = $clog2(DEPTH),
  localparam int unsigned CNT_W = $clog2(DEPTH+1)
) (
  input  logic                               clk_i,
  input  logic                               rst_ni,
  input  logic                               flush_i,
  input  logic                               in_valid_i,
  output logic                               in_ready_o,
  input  vcore_perm_pkg::vcore_perm_decoded_t in_i,
  output logic                               out_valid_o,
  input  logic                               out_ready_i,
  output vcore_perm_pkg::vcore_perm_decoded_t out_o
);
  import vcore_perm_pkg::*;
  vcore_perm_decoded_t entries_q [DEPTH];
  logic [PTR_W-1:0] read_ptr_q, write_ptr_q;
  logic [CNT_W-1:0] count_q;
  logic push, pop;

  assign in_ready_o = (count_q < CNT_W'(DEPTH)) && !flush_i;
  assign out_valid_o = (count_q != 0) && !flush_i;
  assign out_o = entries_q[read_ptr_q];
  assign push = in_valid_i && in_ready_o;
  assign pop = out_valid_o && out_ready_i;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      read_ptr_q <= '0;
      write_ptr_q <= '0;
      count_q <= '0;
    end else begin
      if (push) begin
        entries_q[write_ptr_q] <= in_i;
        write_ptr_q <= (write_ptr_q == PTR_W'(DEPTH-1)) ? '0 : write_ptr_q + 1'b1;
      end
      if (pop)
        read_ptr_q <= (read_ptr_q == PTR_W'(DEPTH-1)) ? '0 : read_ptr_q + 1'b1;
      case ({push,pop})
        2'b10:   count_q <= count_q + 1'b1;
        2'b01:   count_q <= count_q - 1'b1;
        default: ;
      endcase
    end
  end

  initial begin : p_depth_check
    if (DEPTH < 2) $fatal(1,"Issue FIFO depth must be >= 2");
  end
endmodule
