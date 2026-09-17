// Multiple-outstanding memory request engine for the vector load cluster.
// This is the module that replaces vcore_perm_vrf_request: where the
// permutation cluster staged its operands out of the VRF, a load stages
// them out of memory.
//
// Structure deliberately mirrors the permutation cluster's group buffer.
// vcore_perm_vrf_request preloads the WHOLE vs2 EMUL group on beat 0 so that
// later beats never re-read it; here beat 0 fetches every active element of
// the whole destination EMUL group into byte_q, and later beats just slice
// it. That is what makes the outstanding window the size of the instruction
// (up to VLMAX = 128 element requests) instead of the size of one beat --
// at EEW=64 a single beat only holds 2 elements, which would cap MO at 2.
//
// Concurrency: the destination-old VRF read and the memory requests run at
// the same time. They contend for nothing (different ports) and the memory
// side dominates the latency, so serialising them would only add VRF
// latency to every beat.
//
// Requests are issued for ACTIVE elements only (RVV 1.0 7: loads "only
// access memory or raise exceptions for active elements"). Prestart, tail
// and mask-inactive elements are skipped one index per cycle without
// touching the bus -- an inactive element may legitimately address an
// unmapped page, so this is architectural, not an optimisation.
//
// Flush: the memory bus is external, so unlike every other module in this
// cluster this one cannot simply reset. Outstanding requests still owe a
// response, and dropping their ready would deadlock the bus. On flush the
// engine therefore enters VLD_DRAIN, keeps accepting and discarding
// responses until inflight_q reaches zero, and only then becomes idle. The
// VRF read port is assumed to be flushed coherently with this cluster (the
// same assumption vcore_perm_vrf_request makes), so an in-flight dst_old
// read is simply abandoned.
module vcore_vld_memreq #(
  parameter int unsigned VLEN = 128,
  // Peak number of element requests allowed in flight on the memory bus.
  parameter int unsigned MAX_OUTSTANDING = 8
) (
  input  logic                               clk_i,
  input  logic                               rst_ni,
  input  logic                               flush_i,

  input  logic                               uop_valid_i,
  output logic                               uop_ready_o,
  input  vcore_vld_pkg::vcore_vld_uop_t      uop_i,

  // Old destination register read -- the cluster's only VRF read.
  output logic                               vrf_req_valid_o,
  input  logic                               vrf_req_ready_i,
  output vcore_vld_pkg::vcore_vrf_read_req_t vrf_req_o,
  input  logic                               vrf_rsp_valid_i,
  output logic                               vrf_rsp_ready_o,
  input  logic [VLEN-1:0]                    vrf_rsp_data_i,

  // Tagged, out-of-order external memory interface.
  output logic                               mem_req_valid_o,
  input  logic                               mem_req_ready_i,
  output vcore_vld_pkg::vcore_vld_mem_req_t  mem_req_o,
  input  logic                               mem_rsp_valid_i,
  output logic                               mem_rsp_ready_o,
  input  vcore_vld_pkg::vcore_vld_mem_rsp_t  mem_rsp_i,

  output logic                               exec_valid_o,
  input  logic                               exec_ready_i,
  output vcore_vld_pkg::vcore_vld_ctrl_t     exec_ctrl_o,
  output logic [vcore_vld_pkg::MAXEMUL*VLEN-1:0] exec_data_group_o,
  output logic [VLEN-1:0]                    exec_dst_old_o,
  output logic [VLEN-1:0]                    exec_mask_o,
  output logic                               exec_mem_error_o,

  // Observability: high whenever a request may still be owed a response.
  output logic                               busy_o
);
  import vcore_vld_pkg::*;

  localparam int unsigned MAX_BYTES  = MAXEMUL*VLEN/8;
  localparam int unsigned INFLIGHT_W = $clog2(MAX_OUTSTANDING+1);

  typedef enum logic [1:0] {VLD_IDLE, VLD_RUN, VLD_EXEC, VLD_DRAIN} state_e;
  typedef enum logic [1:0] {DST_DONE, DST_REQ, DST_RSP} dst_state_e;

  state_e     state_q;
  dst_state_e dst_state_q;
  vcore_vld_uop_t uop_q;
  logic [VLEN-1:0] mask_q, dst_old_q;
  // Group buffer, byte-addressed: element e of width B bytes owns bytes
  // [e*B, e*B+B) of the destination EMUL group. Kept as one packed vector
  // (rather than an unpacked byte array) so it can be reset and forwarded
  // in one assignment.
  logic [MAX_BYTES*8-1:0] byte_q;
  logic       mem_err_q;
  logic       mem_active_q;      // this beat owns the group fetch (beat 0)
  logic [16:0] req_idx_q;        // next global element index to consider
  logic [INFLIGHT_W-1:0] inflight_q;

  logic scan_busy, cur_active, mem_done, req_fire, rsp_fire;
  logic collect_rsp;
  logic [16:0] next_idx;
  int unsigned eew_bytes_c;

  assign eew_bytes_c = veew_bytes(uop_q.ctrl.eew);

  // ---- handshakes -----------------------------------------------------
  assign uop_ready_o = (state_q == VLD_IDLE) && !flush_i;

  assign scan_busy  = (state_q == VLD_RUN) && mem_active_q &&
                      (req_idx_q < uop_q.ctrl.evl);
  assign cur_active = vld_elem_active(uop_q.ctrl, mask_q, req_idx_q);

  assign mem_req_valid_o = scan_busy && cur_active &&
                           (inflight_q < INFLIGHT_W'(MAX_OUTSTANDING)) && !flush_i;
  assign mem_req_o.addr = uop_q.ctrl.base_addr +
                          32'(int'(req_idx_q) * int'(eew_bytes_c));
  assign mem_req_o.size = veew_size(uop_q.ctrl.eew);
  assign mem_req_o.tag  = req_idx_q[VLD_TAG_W-1:0];

  // Responses are accepted whenever anything can still be in flight,
  // including while draining a flushed instruction -- see header.
  assign mem_rsp_ready_o = (inflight_q != '0);

  assign req_fire = mem_req_valid_o && mem_req_ready_i;
  assign rsp_fire = mem_rsp_valid_i && mem_rsp_ready_o;

  assign vrf_req_valid_o = (state_q == VLD_RUN) && (dst_state_q == DST_REQ) && !flush_i;
  assign vrf_req_o.addr  = uop_q.ctrl.vd_addr;
  assign vrf_req_o.tag   = uop_q.ctrl.tag;
  assign vrf_rsp_ready_o = (state_q == VLD_RUN) && (dst_state_q == DST_RSP) && !flush_i;

  // Registered-state-only completion test: the last response drops
  // inflight_q to zero, and the transition is taken the cycle after.
  assign mem_done = !mem_active_q ||
                    ((req_idx_q >= uop_q.ctrl.evl) && (inflight_q == '0));

  assign exec_valid_o     = (state_q == VLD_EXEC) && !flush_i;
  assign exec_ctrl_o      = uop_q.ctrl;
  assign exec_dst_old_o   = dst_old_q;
  assign exec_mask_o      = mask_q;
  assign exec_mem_error_o = mem_err_q;
  assign busy_o           = (state_q != VLD_IDLE) || (inflight_q != '0);

  assign exec_data_group_o = byte_q;

  // Skip-ahead: an inactive index costs one cycle and no bus traffic.
  assign next_idx = req_idx_q + 17'd1;

  // ---- start-of-beat decode ------------------------------------------
  // vld_needs_dst_old already returns 0 for VLDOP_INVALID, so an illegal
  // instruction touches neither port and goes straight to the writeback
  // path, exactly as in the permutation cluster.
  logic start_dst, start_mem, start_exec;
  assign start_dst  = vld_needs_dst_old(uop_i.ctrl);
  assign start_mem  = (uop_i.ctrl.op != VLDOP_INVALID) && (uop_i.beat_index == 3'd0);
  assign start_exec = !start_dst && !start_mem;

  // Only a response landing while this beat still owns the group fetch may
  // write the buffer; a response arriving during VLD_DRAIN belongs to a
  // flushed instruction and is discarded.
  assign collect_rsp = rsp_fire && (state_q == VLD_RUN);

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q      <= VLD_IDLE;
      dst_state_q  <= DST_DONE;
      uop_q        <= '0;
      mask_q       <= '0;
      dst_old_q    <= '0;
      mem_err_q    <= 1'b0;
      mem_active_q <= 1'b0;
      req_idx_q    <= '0;
      inflight_q   <= '0;
      byte_q       <= '0;
    end else if (flush_i) begin
      // Keep inflight_q: those responses are still owed.
      dst_state_q  <= DST_DONE;
      mem_active_q <= 1'b0;
      req_idx_q    <= '0;
      // A response arriving on the flush cycle still counts as drained.
      state_q <= ((inflight_q != '0) && !(rsp_fire && (inflight_q == INFLIGHT_W'(1))))
                 ? VLD_DRAIN : VLD_IDLE;
      if (rsp_fire) inflight_q <= inflight_q - 1'b1;
    end else begin
      // ---- outstanding-window accounting -----------------------------
      // One place only, so a simultaneous request/response pair cannot be
      // double-counted by two separate branches.
      case ({req_fire, rsp_fire})
        2'b10:   inflight_q <= inflight_q + 1'b1;
        2'b01:   inflight_q <= inflight_q - 1'b1;
        default: ; // 00 idle, 11 one in one out
      endcase

      // ---- response collection ---------------------------------------
      if (collect_rsp) begin
        mem_err_q <= mem_err_q | mem_rsp_i.error;
        // Right-justified return, byte-addressed into the group buffer:
        // element e of width B bytes owns bytes [e*B, e*B+B).
        for (int b = 0; b < 8; b++)
          if (b < int'(eew_bytes_c))
            byte_q[(((int'(mem_rsp_i.tag)*int'(eew_bytes_c)) + b) % MAX_BYTES)*8 +: 8]
              <= mem_rsp_i.data[b*8 +: 8];
      end

      case (state_q)
        VLD_IDLE: if (uop_valid_i && uop_ready_o) begin
          uop_q     <= uop_i;
          mask_q    <= uop_i.mask_snapshot;
          req_idx_q <= uop_i.ctrl.vstart;
          if (uop_i.beat_index == 3'd0) mem_err_q <= 1'b0;
          mem_active_q <= start_mem;
          dst_state_q  <= start_dst ? DST_REQ : DST_DONE;
          state_q      <= start_exec ? VLD_EXEC : VLD_RUN;
        end

        VLD_RUN: begin
          // dst_old read -- runs concurrently with the request scan below
          case (dst_state_q)
            DST_REQ: if (vrf_req_valid_o && vrf_req_ready_i) dst_state_q <= DST_RSP;
            DST_RSP: if (vrf_rsp_valid_i && vrf_rsp_ready_o) begin
              dst_old_q   <= vrf_rsp_data_i;
              dst_state_q <= DST_DONE;
            end
            default: ;
          endcase

          // request scan: one element index per cycle, bus traffic only for
          // active elements
          if (scan_busy && (!cur_active || req_fire)) req_idx_q <= next_idx;

          if ((dst_state_q == DST_DONE) && mem_done) state_q <= VLD_EXEC;
        end

        VLD_EXEC: if (exec_valid_o && exec_ready_i) begin
          mem_active_q <= 1'b0;
          state_q      <= VLD_IDLE;
        end

        VLD_DRAIN: if (inflight_q == '0) state_q <= VLD_IDLE;

        default: state_q <= VLD_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // The tag space is the instruction's element index space, so a response
  // can never name a slot the group buffer does not own.
  always @(posedge clk_i)
    if (rst_ni && collect_rsp)
      assert (int'(mem_rsp_i.tag)*int'(eew_bytes_c) + int'(eew_bytes_c) <= MAX_BYTES)
        else $error("vld_memreq: response tag %0d out of group buffer range", mem_rsp_i.tag);
  // The window must never be pushed past its cap: a request may only fire
  // when a credit is free.
  always @(posedge clk_i)
    if (rst_ni && !flush_i && req_fire)
      assert (inflight_q != INFLIGHT_W'(MAX_OUTSTANDING))
        else $error("vld_memreq: outstanding window overflow");
`endif

endmodule
