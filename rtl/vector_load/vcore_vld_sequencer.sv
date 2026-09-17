// One destination register per beat, beat_index walking the EMUL group,
// identical handshake shape to vcore_perm_sequencer: SEND one uop, wait for
// its writeback acknowledgement, advance.
//
// Unlike the permutation cluster, none of the load operands come from the
// VRF, so a beat's uop carries no source register addresses at all -- only
// the destination register and the global element window this beat covers.
module vcore_vld_sequencer #(
  parameter int unsigned VLEN = 128
) (
  input  logic                               clk_i,
  input  logic                               rst_ni,
  input  logic                               flush_i,
  input  logic                               decoded_valid_i,
  output logic                               decoded_ready_o,
  input  vcore_vld_pkg::vcore_vld_decoded_t  decoded_i,
  output logic                               uop_valid_o,
  input  logic                               uop_ready_i,
  output vcore_vld_pkg::vcore_vld_uop_t      uop_o,
  input  logic                               beat_done_valid_i,
  output logic                               beat_done_ready_o,
  input  vcore_vld_pkg::vcore_vld_commit_t   beat_done_i
);
  import vcore_vld_pkg::*;
  typedef enum logic [1:0] {SEQ_IDLE, SEQ_SEND, SEQ_WAIT_WB} state_e;
  state_e state_q;
  vcore_vld_decoded_t decoded_q;
  logic [2:0] beat_index_q;
  logic [3:0] total_beats_q;
  int unsigned elements_per_beat;

  assign decoded_ready_o  = (state_q == SEQ_IDLE)    && !flush_i;
  assign uop_valid_o      = (state_q == SEQ_SEND)    && !flush_i;
  assign beat_done_ready_o= (state_q == SEQ_WAIT_WB) && !flush_i;

  always_comb begin
    // Slots per destination register are set by EEW, not by vtype.vsew.
    elements_per_beat = (veew_bits(decoded_q.ctrl.eew) == 0) ? 0
                      : (VLEN / veew_bits(decoded_q.ctrl.eew));

    uop_o = '0;
    uop_o.ctrl = decoded_q.ctrl;
    uop_o.ctrl.element_base = 17'(int'(beat_index_q) * elements_per_beat);
    uop_o.ctrl.last_beat    = (int'(beat_index_q)+1 == int'(total_beats_q));
    uop_o.ctrl.vd_addr      = 5'(int'(decoded_q.vd) + int'(beat_index_q));
    uop_o.vd_addr           = uop_o.ctrl.vd_addr;
    uop_o.mask_snapshot     = decoded_q.mask_snapshot;
    uop_o.beat_index        = beat_index_q;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      state_q       <= SEQ_IDLE;
      decoded_q     <= '0;
      beat_index_q  <= '0;
      total_beats_q <= '0;
    end else begin
      case (state_q)
        SEQ_IDLE: if (decoded_valid_i && decoded_ready_o) begin
          decoded_q     <= decoded_i;
          total_beats_q <= decoded_i.illegal ? 4'd1 : decoded_i.beats;
          beat_index_q  <= '0;
          state_q       <= SEQ_SEND;
        end
        SEQ_SEND: if (uop_valid_o && uop_ready_i)
          state_q <= SEQ_WAIT_WB;
        SEQ_WAIT_WB: if (beat_done_valid_i && beat_done_ready_o) begin
          if (beat_done_i.last_beat || beat_done_i.illegal_op)
            state_q <= SEQ_IDLE;
          else begin
            beat_index_q <= beat_index_q + 1'b1;
            state_q      <= SEQ_SEND;
          end
        end
        default: state_q <= SEQ_IDLE;
      endcase
    end
  end
endmodule
