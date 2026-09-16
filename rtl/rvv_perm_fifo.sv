// rvv_perm_fifo.sv
// 범용 ready/valid 동기 FIFO. Sequencer의 명령어 큐로 사용.
module rvv_perm_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 4          // 2의 거듭제곱 권장
)(
  input  logic             clk,
  input  logic             rst_n,

  input  logic             wr_valid_i,
  output logic             wr_ready_o,
  input  logic [WIDTH-1:0] wr_data_i,

  output logic             rd_valid_o,
  input  logic             rd_ready_i,
  output logic [WIDTH-1:0] rd_data_o
);

  localparam int PTR_W = $clog2(DEPTH);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [PTR_W-1:0] wr_ptr_q, rd_ptr_q;
  logic [PTR_W:0]   cnt_q;

  logic full, empty;
  assign full  = (cnt_q == DEPTH);
  assign empty = (cnt_q == 0);

  assign wr_ready_o = ~full;
  assign rd_valid_o = ~empty;
  assign rd_data_o  = mem[rd_ptr_q];

  logic wr_fire, rd_fire;
  assign wr_fire = wr_valid_i & wr_ready_o;
  assign rd_fire = rd_valid_o & rd_ready_i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr_q <= '0;
      rd_ptr_q <= '0;
      cnt_q    <= '0;
    end else begin
      if (wr_fire) begin
        mem[wr_ptr_q] <= wr_data_i;
        wr_ptr_q      <= wr_ptr_q + 1'b1;
      end
      if (rd_fire) rd_ptr_q <= rd_ptr_q + 1'b1;

      case ({wr_fire, rd_fire})
        2'b10:   cnt_q <= cnt_q + 1'b1;
        2'b01:   cnt_q <= cnt_q - 1'b1;
        default: cnt_q <= cnt_q;
      endcase
    end
  end

endmodule
