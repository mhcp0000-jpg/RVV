// Data engine for the vector store cluster -- the mirror of
// vcore_vld_memreq. Where the load cluster fills the group buffer from
// memory and drains it into the VRF, this one fills it from the VRF and
// drains it into memory.
//
// Per beat it reads one source register (vs3 + beat_index) into the buffer
// at that register's own slice. On the LAST beat, once the whole group is
// resident, it runs the request scan: for every active (element, field) it
// issues one write with that slot's bytes, up to MAX_OUTSTANDING in flight,
// and waits for every acknowledgement before the beat completes. Earlier
// beats complete as soon as their register has landed.
//
// Addressing is identical to the load engine and costs the same two adders:
//
//   acc_q     += stride            once per element
//   elem_addr  = indexed ? base + index[i] : acc_q
//   addr       = elem_addr + (f << log2(EEW/8))
//
// with the data for slot s taken from buffer bytes [s<<log2(EEW/8), +B).
// No multiplier and no divider: element sizes and elements-per-register are
// powers of two, so every scaling is a shift.
//
// What a store does NOT need, and does not have: an old-destination read, a
// tail or mask-agnostic fill, and any policy chain at all. An element that
// is prestart, tail or mask-inactive is simply never requested.
//
// Ordering: RVWMO leaves the element accesses of one store unordered except
// for vsoxei, which is handled the same way the load cluster handles vloxei
// -- the outstanding window is clamped to one request.
//
// Flush: the bus still owes acknowledgements, so VST_DRAIN accepts and
// discards them until inflight_q reaches zero before the engine goes idle.
module vcore_vst_memreq #(
  parameter int unsigned VLEN = 128,
  parameter int unsigned MAX_OUTSTANDING = 8
) (
  input  logic                               clk_i,
  input  logic                               rst_ni,
  input  logic                               flush_i,

  input  logic                               uop_valid_i,
  output logic                               uop_ready_o,
  input  vcore_vst_pkg::vcore_vst_uop_t      uop_i,

  // VRF read port: source data registers, plus index registers when indexed.
  output logic                               vrf_req_valid_o,
  input  logic                               vrf_req_ready_i,
  output vcore_vst_pkg::vcore_vrf_read_req_t vrf_req_o,
  input  logic                               vrf_rsp_valid_i,
  output logic                               vrf_rsp_ready_o,
  input  logic [VLEN-1:0]                    vrf_rsp_data_i,

  // Tagged memory write interface; the response is an ack, not data.
  output logic                               mem_req_valid_o,
  input  logic                               mem_req_ready_i,
  output vcore_vst_pkg::vcore_vst_mem_req_t  mem_req_o,
  input  logic                               mem_rsp_valid_i,
  output logic                               mem_rsp_ready_o,
  input  vcore_vst_pkg::vcore_vst_mem_rsp_t  mem_rsp_i,

  output logic                               done_valid_o,
  input  logic                               done_ready_i,
  output vcore_vst_pkg::vcore_vst_commit_t   done_o,

  output logic                               busy_o
);
  import vcore_vst_pkg::*;

  localparam int unsigned MAX_BYTES  = MAXEMUL*VLEN/8;
  localparam int unsigned BPR        = VLEN/8;
  localparam int unsigned INFLIGHT_W = $clog2(MAX_OUTSTANDING+1);

  typedef enum logic [2:0] {
    VST_IDLE, VST_READ_REQ, VST_READ_RSP, VST_SCAN, VST_DONE, VST_DRAIN
  } state_e;

  state_e state_q;
  logic   idx_pending_q;             // an index-register read is outstanding

  vcore_vst_uop_t uop_q;
  logic [VLEN-1:0]        mask_q;
  logic [MAX_BYTES*8-1:0] byte_q;    // group buffer, byte-addressed by slot
  logic                   mem_err_q;

  logic [16:0] elem_q;               // current element, walks 0 .. evl-1
  logic [3:0]  fld_q;                // current field, 0 .. nf-1
  logic [31:0] acc_q;                // base + elem_q*stride, by accumulation
  logic [16:0] slot_base_q;          // fld_q * slots_per_field, by accumulation
  logic [INFLIGHT_W-1:0] inflight_q;

  logic [VLEN-1:0] idx_data_q;       // the one live index register
  logic [3:0]      idx_reg_have_q;
  logic            idx_valid_q;

  logic        is_indexed;
  int unsigned eew_bytes_c;
  logic [2:0]  eew_log2_c, idx_shift_c;
  logic [16:0] idx_mask_c;
  logic [3:0]  idx_reg_need;
  logic        idx_ready, idx_fetch_want;
  logic [31:0] idx_value, elem_addr;
  logic [16:0] cur_slot;
  logic        scan_busy, cur_active, scan_done, req_fire, rsp_fire, last_field;
  logic [INFLIGHT_W-1:0] credit_limit;

  assign is_indexed   = vst_is_indexed(uop_q.ctrl.op);
  assign eew_bytes_c  = veew_bytes(uop_q.ctrl.eew);
  assign eew_log2_c   = veew_size(uop_q.ctrl.eew);
  assign idx_shift_c  = 3'($clog2(VLEN/8) - int'(veew_size(uop_q.ctrl.idx_eew)));
  assign idx_mask_c   = (17'd1 << idx_shift_c) - 17'd1;
  assign idx_reg_need = 4'(elem_q >> idx_shift_c);
  assign idx_ready    = !is_indexed || (idx_valid_q && (idx_reg_have_q == idx_reg_need));

  always_comb begin
    int unsigned lane;
    lane = int'(17'(elem_q & idx_mask_c));
    idx_value = '0;
    unique case (uop_q.ctrl.idx_eew)
      VEEW_8:  idx_value = 32'(idx_data_q[(lane % (VLEN/8))*8   +: 8]);
      VEEW_16: idx_value = 32'(idx_data_q[(lane % (VLEN/16))*16 +: 16]);
      VEEW_32: idx_value =     idx_data_q[(lane % (VLEN/32))*32 +: 32];
      VEEW_64: idx_value =     idx_data_q[(lane % (VLEN/64))*64 +: 32];
      default: ;
    endcase
  end

  assign elem_addr  = is_indexed ? (uop_q.ctrl.base_addr + idx_value) : acc_q;
  assign cur_slot   = slot_base_q + elem_q;
  assign last_field = (int'(fld_q) + 1 >= int'(uop_q.ctrl.nf));

  assign scan_busy  = (state_q == VST_SCAN) && (elem_q < uop_q.ctrl.evl);
  assign scan_done  = (elem_q >= uop_q.ctrl.evl) && (inflight_q == '0);
  assign cur_active = vst_elem_active(uop_q.ctrl, mask_q, elem_q);
  assign credit_limit = uop_q.ctrl.ordered ? INFLIGHT_W'(1)
                                           : INFLIGHT_W'(MAX_OUTSTANDING);

  assign idx_fetch_want = scan_busy && cur_active && is_indexed && !idx_ready;

  assign mem_req_valid_o = scan_busy && cur_active && idx_ready &&
                           (inflight_q < credit_limit) && !flush_i;
  assign mem_req_o.addr = elem_addr + (32'(fld_q) << eew_log2_c);
  assign mem_req_o.size = eew_log2_c;
  assign mem_req_o.tag  = cur_slot[VST_TAG_W-1:0];

  // Store data: the slot's bytes, right-justified, exactly the placement a
  // load response uses.
  always_comb begin
    mem_req_o.data = '0;
    for (int b = 0; b < 8; b++)
      if (b < int'(eew_bytes_c))
        mem_req_o.data[b*8 +: 8] =
          byte_q[((((int'(32'(cur_slot) << eew_log2_c))) + b) % MAX_BYTES)*8 +: 8];
  end

  assign mem_rsp_ready_o = (inflight_q != '0);
  assign req_fire = mem_req_valid_o && mem_req_ready_i;
  assign rsp_fire = mem_rsp_valid_i && mem_rsp_ready_o;

  assign uop_ready_o = (state_q == VST_IDLE) && !flush_i;

  // The read port serves source registers during VST_READ_* and index
  // registers during the scan, so the address and the response ready are
  // selected by STATE -- not by the pending flag, which is still low on the
  // cycle the index request is issued.
  assign vrf_req_valid_o = (state_q == VST_READ_REQ) ||
                           ((state_q == VST_SCAN) && idx_fetch_want && !idx_pending_q);
  assign vrf_req_o.addr  = (state_q == VST_SCAN)
                         ? 5'(int'(uop_q.ctrl.idx_addr) + int'(idx_reg_need))
                         : uop_q.ctrl.vs3_addr;
  assign vrf_req_o.tag   = uop_q.ctrl.tag;
  assign vrf_rsp_ready_o = (state_q == VST_READ_RSP) ||
                           ((state_q == VST_SCAN) && idx_pending_q);

  assign done_valid_o = (state_q == VST_DONE) && !flush_i;
  assign done_o.tag        = uop_q.ctrl.tag;
  assign done_o.last_beat  = uop_q.ctrl.last_beat;
  assign done_o.illegal_op = (uop_q.ctrl.op == VSTOP_INVALID);
  assign done_o.mem_error  = mem_err_q;
  assign busy_o = (state_q != VST_IDLE) || (inflight_q != '0);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= VST_IDLE; idx_pending_q <= 1'b0;
      uop_q <= '0; mask_q <= '0; byte_q <= '0; mem_err_q <= 1'b0;
      elem_q <= '0; fld_q <= '0; acc_q <= '0; slot_base_q <= '0;
      inflight_q <= '0; idx_data_q <= '0; idx_reg_have_q <= '0; idx_valid_q <= 1'b0;
    end else if (flush_i) begin
      idx_pending_q <= 1'b0; idx_valid_q <= 1'b0;
      elem_q <= '0; fld_q <= '0; slot_base_q <= '0;
      state_q <= ((inflight_q != '0) && !(rsp_fire && (inflight_q == INFLIGHT_W'(1))))
                 ? VST_DRAIN : VST_IDLE;
      if (rsp_fire) inflight_q <= inflight_q - 1'b1;
    end else begin
      case ({req_fire, rsp_fire})
        2'b10:   inflight_q <= inflight_q + 1'b1;
        2'b01:   inflight_q <= inflight_q - 1'b1;
        default: ;
      endcase
      if (rsp_fire && (state_q == VST_SCAN) && mem_rsp_i.error) mem_err_q <= 1'b1;

      case (state_q)
        VST_IDLE: if (uop_valid_i && uop_ready_o) begin
          uop_q  <= uop_i;
          mask_q <= uop_i.mask_snapshot;
          if (uop_i.beat_index == 3'd0) begin
            mem_err_q   <= 1'b0;
            idx_valid_q <= 1'b0;
          end
          elem_q <= '0; fld_q <= '0; slot_base_q <= '0;
          acc_q  <= uop_i.ctrl.base_addr;
          idx_pending_q <= 1'b0;
          state_q <= (uop_i.ctrl.op == VSTOP_INVALID) ? VST_DONE : VST_READ_REQ;
        end

        VST_READ_REQ: if (vrf_req_valid_o && vrf_req_ready_i) state_q <= VST_READ_RSP;

        VST_READ_RSP: if (vrf_rsp_valid_i && vrf_rsp_ready_o) begin
          // This beat's source register lands at its own slice of the buffer.
          byte_q[int'(uop_q.beat_index)*BPR*8 +: VLEN] <= vrf_rsp_data_i;
          // Memory traffic happens once the whole group is resident.
          state_q <= uop_q.ctrl.last_beat ? VST_SCAN : VST_DONE;
        end

        VST_SCAN: begin
          if (idx_fetch_want && !idx_pending_q) begin
            if (vrf_req_valid_o && vrf_req_ready_i) idx_pending_q <= 1'b1;
          end else if (idx_pending_q) begin
            if (vrf_rsp_valid_i && vrf_rsp_ready_o) begin
              idx_data_q     <= vrf_rsp_data_i;
              idx_reg_have_q <= idx_reg_need;
              idx_valid_q    <= 1'b1;
              idx_pending_q  <= 1'b0;
            end
          end else if (scan_busy) begin
            if (!cur_active) begin
              elem_q <= elem_q + 17'd1;
              acc_q  <= acc_q + uop_q.ctrl.stride;
              fld_q  <= '0; slot_base_q <= '0;
            end else if (req_fire) begin
              if (last_field) begin
                elem_q <= elem_q + 17'd1;
                acc_q  <= acc_q + uop_q.ctrl.stride;
                fld_q  <= '0; slot_base_q <= '0;
              end else begin
                fld_q       <= fld_q + 4'd1;
                slot_base_q <= slot_base_q + uop_q.ctrl.slots_per_field;
              end
            end
          end
          if (scan_done && !idx_pending_q) state_q <= VST_DONE;
        end

        VST_DONE: if (done_valid_o && done_ready_i) state_q <= VST_IDLE;

        VST_DRAIN: if (inflight_q == '0) state_q <= VST_IDLE;

        default: state_q <= VST_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk_i)
    if (rst_ni && !flush_i && req_fire)
      assert (inflight_q < credit_limit)
        else $error("vst_memreq: outstanding window overflow");
  always @(posedge clk_i)
    if (rst_ni && !flush_i && (state_q == VST_SCAN) && uop_q.ctrl.ordered)
      assert (inflight_q <= INFLIGHT_W'(1))
        else $error("vst_memreq: ordered indexed store lost its element order");
`endif

endmodule
