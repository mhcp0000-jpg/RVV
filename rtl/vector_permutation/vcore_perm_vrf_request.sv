// Converts one permutation micro-op into serial reads on a 1R1W VRF.
// v0 never goes through this port: TOP supplies a coherent mask_snapshot
// alongside the command (see vcore_perm_pkg), so only vs2/vs1/vd are staged
// here, mirroring vcore_alu_vrf_request's SRC2->SRC1->DST ordering -- with
// two additions:
//  - gather/slide/compress (vpop_needs_group_buf) can reach any register of
//    vs2's EMUL group, not just this beat's own vs2 register, so on the
//    first beat of such an instruction this module first preloads the whole
//    group (up to MAXLMUL registers) into vs2_group_q.
//  - vrgatherei16 additionally needs its EEW=16 index operand (vs1) as its
//    own group (vpop_vs1_needs_group_buf), sized independently via
//    vpop_ei16_idx_regs since EMUL_index can differ from the data EMUL.
// Later beats of the same instruction reuse whichever buffers were already
// loaded instead of re-reading them.
module vcore_perm_vrf_request #(
  parameter int unsigned VLEN = 128
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,
  input  logic                                flush_i,
  input  logic                                uop_valid_i,
  output logic                                uop_ready_o,
  input  vcore_perm_pkg::vcore_perm_uop_t     uop_i,
  output logic                                vrf_req_valid_o,
  input  logic                                vrf_req_ready_i,
  output vcore_perm_pkg::vcore_vrf_read_req_t vrf_req_o,
  input  logic                                vrf_rsp_valid_i,
  output logic                                vrf_rsp_ready_o,
  input  logic [VLEN-1:0]                     vrf_rsp_data_i,
  output logic                                exec_valid_o,
  input  logic                                exec_ready_i,
  output vcore_perm_pkg::vcore_perm_ctrl_t    exec_ctrl_o,
  output logic [31:0]                         exec_scalar_o,
  output logic [VLEN-1:0]                     exec_src1_o,
  output logic [VLEN-1:0]                     exec_src2_o,
  output logic [vcore_perm_pkg::MAXLMUL*VLEN-1:0] exec_src2_group_o,
  output logic [vcore_perm_pkg::MAXLMUL*VLEN-1:0] exec_src1_idx_group_o,
  output logic [VLEN-1:0]                     exec_dst_old_o,
  output logic [VLEN-1:0]                     exec_mask_o
);
  import vcore_perm_pkg::*;
  typedef enum logic [3:0] {
    VRF_IDLE,
    VRF_PRELOAD_VS2_REQ, VRF_PRELOAD_VS2_RSP,
    VRF_PRELOAD_VS1_REQ, VRF_PRELOAD_VS1_RSP,
    VRF_SRC2_REQ, VRF_SRC2_RSP,
    VRF_SRC1_REQ, VRF_SRC1_RSP,
    VRF_DST_REQ, VRF_DST_RSP, VRF_EXEC
  } state_e;
  state_e state_q;
  vcore_perm_uop_t uop_q;
  logic [VLEN-1:0] src1_q, src2_q, dst_old_q, mask_q;
  logic [MAXLMUL*VLEN-1:0] vs2_group_q, vs1_idx_group_q;
  logic [3:0] preload_idx_q;

  function automatic logic [VLEN-1:0] broadcast_scalar(
    input logic [31:0] scalar,
    input logic [2:0] sew
  );
    logic [VLEN-1:0] value;
    value = '0;
    case (sew)
      VSEW_8:  for (int i=0;i<VLEN/8;i++)
                 value[i*8 +: 8] = scalar[7:0];
      VSEW_16: for (int i=0;i<VLEN/16;i++)
                 value[i*16 +: 16] = scalar[15:0];
      VSEW_32: for (int i=0;i<VLEN/32;i++)
                 value[i*32 +: 32] = scalar;
      VSEW_64: for (int i=0;i<VLEN/64;i++)
                 value[i*64 +: 64] = {{32{scalar[31]}},scalar};
      default: ;
    endcase
    return value;
  endfunction

  assign uop_ready_o = (state_q == VRF_IDLE) && !flush_i;
  assign vrf_req_valid_o = ((state_q == VRF_PRELOAD_VS2_REQ) ||
                            (state_q == VRF_PRELOAD_VS1_REQ) ||
                            (state_q == VRF_SRC2_REQ) ||
                            (state_q == VRF_SRC1_REQ) ||
                            (state_q == VRF_DST_REQ)) && !flush_i;
  assign vrf_rsp_ready_o = ((state_q == VRF_PRELOAD_VS2_RSP) ||
                            (state_q == VRF_PRELOAD_VS1_RSP) ||
                            (state_q == VRF_SRC2_RSP) ||
                            (state_q == VRF_SRC1_RSP) ||
                            (state_q == VRF_DST_RSP)) && !flush_i;
  assign exec_valid_o = (state_q == VRF_EXEC) && !flush_i;
  assign exec_ctrl_o  = uop_q.ctrl;
  assign exec_scalar_o = uop_q.scalar;
  assign exec_src1_o  = (uop_q.form == VSRC_VV) ? src1_q :
                        broadcast_scalar(uop_q.scalar,uop_q.ctrl.sew);
  assign exec_src2_o  = src2_q;
  assign exec_src2_group_o = vs2_group_q;
  assign exec_src1_idx_group_o = vs1_idx_group_q;
  assign exec_dst_old_o = dst_old_q;
  assign exec_mask_o  = mask_q;

  always_comb begin
    vrf_req_o = '0;
    vrf_req_o.tag = uop_q.ctrl.tag;
    case (state_q)
      VRF_PRELOAD_VS2_REQ: vrf_req_o.addr = 5'(int'(uop_q.vs2_base_addr) + int'(preload_idx_q));
      VRF_PRELOAD_VS1_REQ: vrf_req_o.addr = 5'(int'(uop_q.vs1_addr) + int'(preload_idx_q));
      VRF_SRC2_REQ:        vrf_req_o.addr = uop_q.vs2_addr;
      VRF_SRC1_REQ:        vrf_req_o.addr = uop_q.vs1_addr;
      VRF_DST_REQ:         vrf_req_o.addr = uop_q.vd_addr;
      default:             vrf_req_o.addr = '0;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      state_q <= VRF_IDLE;
      uop_q <= '0;
      src1_q <= '0;
      src2_q <= '0;
      dst_old_q <= '0;
      mask_q <= '0;
      vs2_group_q <= '0;
      vs1_idx_group_q <= '0;
      preload_idx_q <= '0;
    end else begin
      case (state_q)
        VRF_IDLE: if (uop_valid_i && uop_ready_o) begin
          uop_q <= uop_i;
          mask_q <= uop_i.mask_snapshot;
          if (uop_i.ctrl.op == VPOP_INVALID) state_q <= VRF_EXEC;
          else if (vpop_needs_group_buf(uop_i.ctrl.op) && uop_i.beat_index == 3'd0) begin
            preload_idx_q <= '0;
            state_q <= VRF_PRELOAD_VS2_REQ;
          end else if (vpop_needs_group_buf(uop_i.ctrl.op)) begin
            // later beat of the same instruction: group buffer(s) already valid
            state_q <= vpop_vs1_needs_group_buf(uop_i.ctrl.op) ? VRF_DST_REQ :
                       (uop_i.read_vs1 ? VRF_SRC1_REQ : VRF_DST_REQ);
          end else if (uop_i.read_vs2) state_q <= VRF_SRC2_REQ;
          else if (uop_i.read_vs1) state_q <= VRF_SRC1_REQ;
          else state_q <= VRF_DST_REQ;
        end
        VRF_PRELOAD_VS2_REQ: if (vrf_req_valid_o && vrf_req_ready_i)
          state_q <= VRF_PRELOAD_VS2_RSP;
        VRF_PRELOAD_VS2_RSP: if (vrf_rsp_valid_i && vrf_rsp_ready_o) begin
          vs2_group_q[int'(preload_idx_q)*VLEN +: VLEN] <= vrf_rsp_data_i;
          if (int'(preload_idx_q) + 1 == int'(uop_q.ctrl.group_regs)) begin
            if (vpop_vs1_needs_group_buf(uop_q.ctrl.op)) begin
              preload_idx_q <= '0;
              state_q <= VRF_PRELOAD_VS1_REQ;
            end else state_q <= uop_q.read_vs1 ? VRF_SRC1_REQ : VRF_DST_REQ;
          end else begin
            preload_idx_q <= preload_idx_q + 1'b1;
            state_q <= VRF_PRELOAD_VS2_REQ;
          end
        end
        VRF_PRELOAD_VS1_REQ: if (vrf_req_valid_o && vrf_req_ready_i)
          state_q <= VRF_PRELOAD_VS1_RSP;
        VRF_PRELOAD_VS1_RSP: if (vrf_rsp_valid_i && vrf_rsp_ready_o) begin
          vs1_idx_group_q[int'(preload_idx_q)*VLEN +: VLEN] <= vrf_rsp_data_i;
          if (int'(preload_idx_q) + 1 == vpop_ei16_idx_regs(uop_q.ctrl, VLEN))
            state_q <= VRF_DST_REQ; // index comes entirely from the buffer now
          else begin
            preload_idx_q <= preload_idx_q + 1'b1;
            state_q <= VRF_PRELOAD_VS1_REQ;
          end
        end
        VRF_SRC2_REQ: if (vrf_req_valid_o && vrf_req_ready_i)
          state_q <= VRF_SRC2_RSP;
        VRF_SRC2_RSP: if (vrf_rsp_valid_i && vrf_rsp_ready_o) begin
          src2_q <= vrf_rsp_data_i;
          if (uop_q.read_vs1) state_q <= VRF_SRC1_REQ;
          else state_q <= VRF_DST_REQ;
        end
        VRF_SRC1_REQ: if (vrf_req_valid_o && vrf_req_ready_i)
          state_q <= VRF_SRC1_RSP;
        VRF_SRC1_RSP: if (vrf_rsp_valid_i && vrf_rsp_ready_o) begin
          src1_q <= vrf_rsp_data_i;
          state_q <= VRF_DST_REQ;
        end
        VRF_DST_REQ: if (vrf_req_valid_o && vrf_req_ready_i)
          state_q <= VRF_DST_RSP;
        VRF_DST_RSP: if (vrf_rsp_valid_i && vrf_rsp_ready_o) begin
          dst_old_q <= vrf_rsp_data_i;
          state_q <= VRF_EXEC;
        end
        VRF_EXEC: if (exec_valid_o && exec_ready_i)
          state_q <= VRF_IDLE;
        default: state_q <= VRF_IDLE;
      endcase
    end
  end
endmodule
