// Multiple-outstanding memory request engine for the vector load cluster.
// This is the module that replaces vcore_perm_vrf_request: where the
// permutation cluster stages its operands out of the VRF, a load stages them
// out of memory.
//
// It covers every RVV 1.0 vector load form from one datapath. What the forms
// actually have in common is the destination side: element i of field f
// always belongs in destination slot f*slots_per_field + i, and the group
// buffer is kept in destination-register order, so beat b slices out bytes
// [b*VLEN/8, (b+1)*VLEN/8) no matter which form produced them. Only the
// ADDRESS differs, and that costs two adders:
//
//   acc_q      += stride     once per element   (unit / strided / mask /
//                                                whole-register; `stride` is
//                                                fixed at decode except for
//                                                the strided forms)
//   elem_addr   = indexed ? base + index[i] : acc_q
//   addr        = elem_addr + f*EEW/8          (segment field offset)
//
// There is no multiplier and no divider anywhere: the scan walks elements
// from 0 and steps the accumulator every element, issuing requests only for
// the active ones, so a non-zero vstart costs cycles on a restart instead of
// a 17x32 multiply in the address path. The field offset, the buffer byte
// address and the index-register number are all shifts, because element
// sizes and elements-per-register are powers of two.
//
// Index operands do not get a group buffer either. The scan consumes index
// elements in order, so only the ONE index register covering the current
// element has to be live: idx_data_q is 128 bits and is refetched when the
// scan crosses a register boundary, instead of the 1024-bit index group the
// permutation cluster needs for vrgatherei16 (which can address its group
// randomly and has no such luxury).
//
// Ordered indexed loads (vloxei) must perform their element accesses in
// element order. That is achieved by clamping the outstanding window to one
// request, which costs a mux on the credit comparison and nothing else.
//
// Fault-only-first: an error response on an element after index 0 is
// architectural, not a bug -- it trims vl instead of trapping. The engine
// records the lowest erroring element, and the assemble stage then sees a
// smaller evl, which turns the elements at and above it into tail.
//
// Flush: the memory bus is external, so unlike every other module in this
// cluster this one cannot simply reset. Outstanding requests still owe a
// response and dropping their ready would deadlock the bus, so the engine
// enters VLD_DRAIN, keeps accepting and discarding responses until
// inflight_q reaches zero, and only then becomes idle.
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

  // Old destination register, and the index vector for indexed forms.
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
  output logic                               exec_vl_trimmed_o,
  output logic [16:0]                        exec_new_vl_o,

  // High whenever a request may still be owed a response.
  output logic                               busy_o
);
  import vcore_vld_pkg::*;

  localparam int unsigned MAX_BYTES  = MAXEMUL*VLEN/8;
  localparam int unsigned INFLIGHT_W = $clog2(MAX_OUTSTANDING+1);

  typedef enum logic [1:0] {VLD_IDLE, VLD_RUN, VLD_EXEC, VLD_DRAIN} state_e;
  typedef enum logic [1:0] {VRD_IDLE, VRD_REQ, VRD_RSP} vrd_state_e;

  state_e     state_q;
  vrd_state_e vrd_state_q;
  logic       vrd_for_idx_q;   // 0 = old destination, 1 = index register
  logic       dst_done_q;

  vcore_vld_uop_t uop_q;
  logic [VLEN-1:0] mask_q, dst_old_q;
  // Group buffer, byte-addressed: destination slot s of width B bytes owns
  // bytes [s*B, s*B+B). One packed vector so it resets in one assignment.
  logic [MAX_BYTES*8-1:0] byte_q;

  logic        mem_err_q;       // non-fof error, or a fof error on element 0
  logic        trim_valid_q;    // fault-only-first reduced vl
  logic [16:0] trim_vl_q;
  logic        mem_active_q;    // this beat owns the group fetch (beat 0)

  logic [16:0] elem_q;          // current element index, walks 0 .. evl-1
  logic [3:0]  fld_q;           // current field, 0 .. nf-1
  logic [31:0] acc_q;           // base + elem_q*stride, kept by accumulation
  logic [16:0] slot_base_q;     // fld_q * slots_per_field, kept by accumulation
  logic [INFLIGHT_W-1:0] inflight_q;

  // index operand: exactly one live register
  logic [VLEN-1:0] idx_data_q;
  logic [3:0]      idx_reg_have_q;
  logic            idx_valid_q;

  // ---- decoded shorthands --------------------------------------------
  logic        is_indexed;
  int unsigned eew_bytes_c;
  // log2 of the element size in bytes, and of the index elements per
  // register. Both counts are powers of two, so every "multiply by the
  // element size" and "divide by the elements per register" in the address
  // and buffer paths is a shift by one of these -- no multiplier or divider
  // is synthesised anywhere in this module.
  logic [2:0]  eew_log2_c, idx_shift_c;
  logic [16:0] idx_mask_c, slots_mask_c;
  logic [3:0]  idx_reg_need;
  logic        idx_ready;
  logic [31:0] idx_value, elem_addr;
  logic [16:0] cur_slot;
  logic        scan_busy, cur_active, mem_done, req_fire, rsp_fire, collect_rsp;
  logic        last_field;
  logic [INFLIGHT_W-1:0] credit_limit;

  assign is_indexed    = vld_is_indexed(uop_q.ctrl.op);
  assign eew_bytes_c   = veew_bytes(uop_q.ctrl.eew);
  assign eew_log2_c    = veew_size(uop_q.ctrl.eew);       // 0..3
  // Index elements per register is VLEN/idx_bits -- 16/8/4/2 at VLEN=128 --
  // so the register number is the element index shifted right by 4/3/2/1.
  assign idx_shift_c   = 3'($clog2(VLEN/8) - int'(veew_size(uop_q.ctrl.idx_eew)));
  assign idx_mask_c    = (17'd1 << idx_shift_c) - 17'd1;
  assign slots_mask_c  = uop_q.ctrl.slots_per_field - 17'd1;
  assign idx_reg_need  = 4'(elem_q >> idx_shift_c);
  assign idx_ready     = !is_indexed || (idx_valid_q && (idx_reg_have_q == idx_reg_need));

  // Index element, zero-extended (or truncated) to the 32-bit address width.
  // RVV 1.0 7.8.2: index values are unsigned.
  always_comb begin
    int unsigned lane;
    lane = int'(17'(elem_q & idx_mask_c));
    idx_value = '0;
    unique case (uop_q.ctrl.idx_eew)
      VEEW_8:  idx_value = 32'(idx_data_q[(lane % (VLEN/8))*8   +: 8]);
      VEEW_16: idx_value = 32'(idx_data_q[(lane % (VLEN/16))*16 +: 16]);
      VEEW_32: idx_value =     idx_data_q[(lane % (VLEN/32))*32 +: 32];
      VEEW_64: idx_value =     idx_data_q[(lane % (VLEN/64))*64 +: 32]; // low XLEN bits
      default: ;
    endcase
  end

  assign elem_addr = is_indexed ? (uop_q.ctrl.base_addr + idx_value) : acc_q;
  assign cur_slot  = slot_base_q + elem_q;
  assign last_field = (int'(fld_q) + 1 >= int'(uop_q.ctrl.nf));

  // ---- handshakes -----------------------------------------------------
  assign uop_ready_o = (state_q == VLD_IDLE) && !flush_i;

  assign scan_busy  = (state_q == VLD_RUN) && mem_active_q &&
                      (elem_q < uop_q.ctrl.evl);
  assign cur_active = vld_elem_active(uop_q.ctrl, mask_q, elem_q);

  // Ordered indexed loads must hit memory in element order, so their window
  // collapses to a single request.
  assign credit_limit = uop_q.ctrl.ordered ? INFLIGHT_W'(1)
                                           : INFLIGHT_W'(MAX_OUTSTANDING);

  assign mem_req_valid_o = scan_busy && cur_active && idx_ready &&
                           (inflight_q < credit_limit) && !flush_i;
  assign mem_req_o.addr = elem_addr + (32'(fld_q) << eew_log2_c);
  assign mem_req_o.size = veew_size(uop_q.ctrl.eew);
  assign mem_req_o.tag  = cur_slot[VLD_TAG_W-1:0];

  // Responses are accepted whenever anything can still be in flight,
  // including while draining a flushed instruction.
  assign mem_rsp_ready_o = (inflight_q != '0);

  assign req_fire = mem_req_valid_o && mem_req_ready_i;
  assign rsp_fire = mem_rsp_valid_i && mem_rsp_ready_o;
  assign collect_rsp = rsp_fire && (state_q == VLD_RUN);

  // The one VRF read port serves the old destination first, then index
  // registers as the scan crosses them.
  logic idx_fetch_want;
  assign idx_fetch_want = scan_busy && cur_active && is_indexed && !idx_ready;

  assign vrf_req_valid_o = (state_q == VLD_RUN) && (vrd_state_q == VRD_REQ) && !flush_i;
  assign vrf_req_o.addr  = vrd_for_idx_q
                         ? 5'(int'(uop_q.ctrl.idx_addr) + int'(idx_reg_need))
                         : uop_q.ctrl.vd_addr;
  assign vrf_req_o.tag   = uop_q.ctrl.tag;
  assign vrf_rsp_ready_o = (state_q == VLD_RUN) && (vrd_state_q == VRD_RSP) && !flush_i;

  // Registered-state-only completion test.
  assign mem_done = !mem_active_q ||
                    ((elem_q >= uop_q.ctrl.evl) && (inflight_q == '0));

  assign exec_valid_o      = (state_q == VLD_EXEC) && !flush_i;
  assign exec_data_group_o = byte_q;
  assign exec_dst_old_o    = dst_old_q;
  assign exec_mask_o       = mask_q;
  assign exec_mem_error_o  = mem_err_q;
  assign exec_vl_trimmed_o = trim_valid_q;
  assign exec_new_vl_o     = trim_vl_q;
  assign busy_o            = (state_q != VLD_IDLE) || (inflight_q != '0);

  // A fault-only-first trim turns body elements into tail, so the assemble
  // stage sees the reduced evl rather than a special case of its own.
  always_comb begin
    exec_ctrl_o = uop_q.ctrl;
    if (trim_valid_q) exec_ctrl_o.evl = trim_vl_q;
  end

  // ---- start-of-beat decode ------------------------------------------
  logic start_dst, start_mem, start_exec;
  assign start_dst  = vld_needs_dst_old(uop_i.ctrl);
  assign start_mem  = (uop_i.ctrl.op != VLDOP_INVALID) && (uop_i.beat_index == 3'd0);
  assign start_exec = !start_dst && !start_mem;

  // Element index that a returning response belongs to (fault-only-first).
  logic [16:0] rsp_elem;
  assign rsp_elem = 17'(mem_rsp_i.tag) & slots_mask_c;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q        <= VLD_IDLE;
      vrd_state_q    <= VRD_IDLE;
      vrd_for_idx_q  <= 1'b0;
      dst_done_q     <= 1'b1;
      uop_q          <= '0;
      mask_q         <= '0;
      dst_old_q      <= '0;
      byte_q         <= '0;
      mem_err_q      <= 1'b0;
      trim_valid_q   <= 1'b0;
      trim_vl_q      <= '0;
      mem_active_q   <= 1'b0;
      elem_q         <= '0;
      fld_q          <= '0;
      acc_q          <= '0;
      slot_base_q    <= '0;
      inflight_q     <= '0;
      idx_data_q     <= '0;
      idx_reg_have_q <= '0;
      idx_valid_q    <= 1'b0;
    end else if (flush_i) begin
      // Keep inflight_q: those responses are still owed.
      vrd_state_q  <= VRD_IDLE;
      dst_done_q   <= 1'b1;
      mem_active_q <= 1'b0;
      elem_q       <= '0;
      fld_q        <= '0;
      slot_base_q  <= '0;
      idx_valid_q  <= 1'b0;
      state_q <= ((inflight_q != '0) && !(rsp_fire && (inflight_q == INFLIGHT_W'(1))))
                 ? VLD_DRAIN : VLD_IDLE;
      if (rsp_fire) inflight_q <= inflight_q - 1'b1;
    end else begin
      // ---- outstanding-window accounting -----------------------------
      case ({req_fire, rsp_fire})
        2'b10:   inflight_q <= inflight_q + 1'b1;
        2'b01:   inflight_q <= inflight_q - 1'b1;
        default: ; // 00 idle, 11 one in one out
      endcase

      // ---- response collection ---------------------------------------
      if (collect_rsp) begin
        if (mem_rsp_i.error) begin
          if (uop_q.ctrl.op == VLDOP_FOF) begin
            // RVV 1.0 7.7: only element 0 may raise an exception; a fault on
            // any later element reduces vl instead.
            if (rsp_elem == 17'd0) mem_err_q <= 1'b1;
            else if (!trim_valid_q || (rsp_elem < trim_vl_q)) begin
              trim_valid_q <= 1'b1;
              trim_vl_q    <= rsp_elem;
            end
          end else mem_err_q <= 1'b1;
        end
        // Right-justified return, byte-addressed into the group buffer.
        for (int b = 0; b < 8; b++)
          if (b < int'(eew_bytes_c))
            byte_q[(((int'(32'(mem_rsp_i.tag) << eew_log2_c)) + b) % MAX_BYTES)*8 +: 8]
              <= mem_rsp_i.data[b*8 +: 8];
      end

      case (state_q)
        VLD_IDLE: if (uop_valid_i && uop_ready_o) begin
          uop_q       <= uop_i;
          mask_q      <= uop_i.mask_snapshot;
          elem_q      <= '0;
          fld_q       <= '0;
          slot_base_q <= '0;
          acc_q       <= uop_i.ctrl.base_addr;
          idx_valid_q <= 1'b0;
          if (uop_i.beat_index == 3'd0) begin
            mem_err_q    <= 1'b0;
            trim_valid_q <= 1'b0;
            trim_vl_q    <= '0;
          end
          mem_active_q <= start_mem;
          dst_done_q   <= !start_dst;
          if (start_dst) begin
            vrd_for_idx_q <= 1'b0;
            vrd_state_q   <= VRD_REQ;
          end else vrd_state_q <= VRD_IDLE;
          state_q <= start_exec ? VLD_EXEC : VLD_RUN;
        end

        VLD_RUN: begin
          // ---- VRF read track: old destination first, then index regs ---
          case (vrd_state_q)
            VRD_IDLE: if (dst_done_q && idx_fetch_want) begin
              vrd_for_idx_q <= 1'b1;
              vrd_state_q   <= VRD_REQ;
            end
            VRD_REQ: if (vrf_req_valid_o && vrf_req_ready_i) vrd_state_q <= VRD_RSP;
            VRD_RSP: if (vrf_rsp_valid_i && vrf_rsp_ready_o) begin
              if (vrd_for_idx_q) begin
                idx_data_q     <= vrf_rsp_data_i;
                idx_reg_have_q <= idx_reg_need;
                idx_valid_q    <= 1'b1;
              end else begin
                dst_old_q  <= vrf_rsp_data_i;
                dst_done_q <= 1'b1;
              end
              vrd_state_q <= VRD_IDLE;
            end
            default: vrd_state_q <= VRD_IDLE;
          endcase

          // ---- request scan: one element-field per cycle ---------------
          if (scan_busy) begin
            if (!cur_active) begin
              // Inactive or prestart: no bus traffic, but the address
              // accumulator still has to step past this element.
              elem_q <= elem_q + 17'd1;
              acc_q  <= acc_q + uop_q.ctrl.stride;
              fld_q  <= '0;
              slot_base_q <= '0;
            end else if (req_fire) begin
              if (last_field) begin
                elem_q      <= elem_q + 17'd1;
                acc_q       <= acc_q + uop_q.ctrl.stride;
                fld_q       <= '0;
                slot_base_q <= '0;
              end else begin
                fld_q       <= fld_q + 4'd1;
                slot_base_q <= slot_base_q + uop_q.ctrl.slots_per_field;
              end
            end
          end

          if (dst_done_q && mem_done && (vrd_state_q == VRD_IDLE))
            state_q <= VLD_EXEC;
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
  // The tag space is the destination slot space, so a response can never
  // name a slot the group buffer does not own.
  always @(posedge clk_i)
    if (rst_ni && collect_rsp)
      assert (int'(32'(mem_rsp_i.tag) << eew_log2_c) + int'(eew_bytes_c) <= MAX_BYTES)
        else $error("vld_memreq: response tag %0d out of group buffer range", mem_rsp_i.tag);
  // The window must never be pushed past its cap.
  always @(posedge clk_i)
    if (rst_ni && !flush_i && req_fire)
      assert (inflight_q < credit_limit)
        else $error("vld_memreq: outstanding window overflow");
  // Ordered indexed loads may never have two requests in flight.
  always @(posedge clk_i)
    if (rst_ni && !flush_i && (state_q == VLD_RUN) && uop_q.ctrl.ordered)
      assert (inflight_q <= INFLIGHT_W'(1))
        else $error("vld_memreq: ordered indexed load lost its element order");
`endif

endmodule
