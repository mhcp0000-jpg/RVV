module vcore_perm_sequencer #(
  parameter int unsigned VLEN = 128
) (
  input  logic                               clk_i,
  input  logic                               rst_ni,
  input  logic                               flush_i,
  input  logic                               decoded_valid_i,
  output logic                               decoded_ready_o,
  input  vcore_perm_pkg::vcore_perm_decoded_t decoded_i,
  output logic                               uop_valid_o,
  input  logic                               uop_ready_i,
  output vcore_perm_pkg::vcore_perm_uop_t    uop_o,
  input  logic                               beat_done_valid_i,
  output logic                               beat_done_ready_o,
  input  vcore_perm_pkg::vcore_perm_commit_t beat_done_i
);
  import vcore_perm_pkg::*;
  typedef enum logic [1:0] {SEQ_IDLE, SEQ_SEND, SEQ_WAIT_WB} state_e;
  state_e state_q;
  vcore_perm_decoded_t decoded_q;
  logic [2:0] beat_index_q;
  logic [3:0] total_beats_q;
  int unsigned elements_per_beat;
  logic mask_dest;

  assign decoded_ready_o = (state_q == SEQ_IDLE) && !flush_i;
  assign uop_valid_o = (state_q == SEQ_SEND) && !flush_i;
  assign beat_done_ready_o = (state_q == SEQ_WAIT_WB) && !flush_i;

  always_comb begin
    case (decoded_q.ctrl.sew)
      VSEW_8:  elements_per_beat = VLEN/8;
      VSEW_16: elements_per_beat = VLEN/16;
      VSEW_32: elements_per_beat = VLEN/32;
      VSEW_64: elements_per_beat = VLEN/64;
      default: elements_per_beat = 0;
    endcase
    // mask-producing scans (vmsbf/vmsof/vmsif) target one physical register
    // regardless of beat, exactly like ALU's compare-into-mask destinations.
    mask_dest = vpop_is_mask_dest(decoded_q.ctrl.op);

    uop_o = '0;
    uop_o.ctrl = decoded_q.ctrl;
    uop_o.ctrl.element_base = 17'(int'(beat_index_q) * elements_per_beat);
    uop_o.ctrl.last_beat = (int'(beat_index_q)+1 == int'(total_beats_q));
    uop_o.ctrl.vd_addr = mask_dest ? decoded_q.vd :
                              5'(int'(decoded_q.vd) + int'(beat_index_q));
    uop_o.form = decoded_q.form;
    uop_o.scalar = decoded_q.scalar;
    uop_o.mask_snapshot = decoded_q.mask_snapshot;
    uop_o.vd_addr  = uop_o.ctrl.vd_addr;
    uop_o.vs1_addr = 5'(int'(decoded_q.vs1) + int'(beat_index_q));
    uop_o.vs2_addr = 5'(int'(decoded_q.vs2) + int'(beat_index_q));

    // vs1 is only a real vector register on VSRC_VV encodings (vrgather.vv,
    // vrgatherei16.vv, vcompress.vm's mask-select, vmerge.vvm, vmv.v.v).
    uop_o.read_vs1 = (decoded_q.form == VSRC_VV) &&
                     (decoded_q.ctrl.op != VPOP_INVALID);
    // vmv.v.*, vid.v and vmv.s.x/vfmv.s.f have no vs2 operand at all.
    uop_o.read_vs2 = (decoded_q.ctrl.op != VPOP_VMV_V) &&
                     (decoded_q.ctrl.op != VPOP_VID) &&
                     (decoded_q.ctrl.op != VPOP_VMV_S_X) &&
                     (decoded_q.ctrl.op != VPOP_INVALID);
    uop_o.beat_index = beat_index_q;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      state_q <= SEQ_IDLE;
      decoded_q <= '0;
      beat_index_q <= '0;
      total_beats_q <= '0;
    end else begin
      case (state_q)
        SEQ_IDLE: if (decoded_valid_i && decoded_ready_o) begin
          decoded_q <= decoded_i;
          total_beats_q <= decoded_i.illegal ? 4'd1 : decoded_i.beats;
          beat_index_q <= '0;
          state_q <= SEQ_SEND;
        end
        SEQ_SEND: if (uop_valid_o && uop_ready_i)
          state_q <= SEQ_WAIT_WB;
        SEQ_WAIT_WB: if (beat_done_valid_i && beat_done_ready_o) begin
          if (beat_done_i.last_beat || beat_done_i.illegal_op)
            state_q <= SEQ_IDLE;
          else begin
            beat_index_q <= beat_index_q + 1'b1;
            state_q <= SEQ_SEND;
          end
        end
        default: state_q <= SEQ_IDLE;
      endcase
    end
  end
endmodule
