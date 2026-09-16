// rvv_perm_decode.sv
// RV32 OP-V(0x57) 명령어 워드 -> rvv_perm_dec_t. Permutation 클래스가 아니면 PERM_ILLEGAL.
// funct3/funct6/vm/vs1 조합은 riscv-opcodes 기준 실측값(build_rvv_catalog.mjs 산출물)을 그대로 사용.
// 조합 논리 1단(comb) + skid 없이 valid/ready만 통과시키는 얇은 stage.
module rvv_perm_decode
  import rvv_perm_pkg::*;
(
  input  logic         clk,
  input  logic         rst_n,

  input  logic         valid_i,
  output logic         ready_o,
  input  logic [31:0]  instr_i,

  output logic         valid_o,
  input  logic         ready_i,
  output rvv_perm_dec_t dec_o
);

  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [5:0] funct6;
  logic       vm;
  logic [4:0] vd_f, vs1_f, vs2_f;

  assign opcode = instr_i[6:0];
  assign funct3 = instr_i[14:12];
  assign funct6 = instr_i[31:26];
  assign vm     = instr_i[25];
  assign vd_f   = instr_i[11:7];
  assign vs1_f  = instr_i[19:15];
  assign vs2_f  = instr_i[24:20];

  rvv_perm_op_e   op;
  rvv_op2_src_e   op2_src;
  logic [63:0]    imm_ext;
  logic [2:0]     nreg_grp;

  always_comb begin
    op       = PERM_ILLEGAL;
    op2_src  = OP2_NONE;
    imm_ext  = '0;
    nreg_grp = 3'd1;

    if (opcode == 7'h57) begin
      unique casez ({funct6, funct3})
        // vrgather / vrgatherei16 : funct6=0x0C / 0x0E(vv only)
        {6'h0c, 3'b000}: begin op = PERM_VRGATHER_VV;      op2_src = OP2_VEC;    end
        {6'h0c, 3'b100}: begin op = PERM_VRGATHER_VX;      op2_src = OP2_SCALAR; end
        {6'h0c, 3'b011}: begin op = PERM_VRGATHER_VI;      op2_src = OP2_IMM; imm_ext = {59'd0, vs1_f}; end // uimm5, zero-ext
        {6'h0e, 3'b000}: begin op = PERM_VRGATHEREI16_VV;  op2_src = OP2_VEC;    end

        // vslideup(0x0e)/vslidedown(0x0f), vslide1up/down 포함
        {6'h0e, 3'b100}: begin op = PERM_VSLIDEUP;    op2_src = OP2_SCALAR; end
        {6'h0e, 3'b011}: begin op = PERM_VSLIDEUP;    op2_src = OP2_IMM; imm_ext = {59'd0, vs1_f}; end // uimm5
        {6'h0e, 3'b110}: begin op = PERM_VSLIDE1UP;   op2_src = OP2_SCALAR; end
        {6'h0e, 3'b101}: begin op = PERM_VSLIDE1UP;   op2_src = OP2_SCALAR; end // vfslide1up.vf, 데이터패스는 동일

        {6'h0f, 3'b100}: begin op = PERM_VSLIDEDOWN;  op2_src = OP2_SCALAR; end
        {6'h0f, 3'b011}: begin op = PERM_VSLIDEDOWN;  op2_src = OP2_IMM; imm_ext = {59'd0, vs1_f}; end
        {6'h0f, 3'b110}: begin op = PERM_VSLIDE1DOWN; op2_src = OP2_SCALAR; end
        {6'h0f, 3'b101}: begin op = PERM_VSLIDE1DOWN; op2_src = OP2_SCALAR; end // vfslide1down.vf

        // 0x17: vm=1 -> vmv.v.*(funct3=010이면 대신 vcompress) / vm=0 -> vmerge.*m
        {6'h17, 3'b010}: begin op = PERM_VCOMPRESS;   op2_src = OP2_VEC; end
        {6'h17, 3'b000}: begin
          if (vm) begin op = PERM_VMV_V_V;   op2_src = OP2_VEC;    end
          else    begin op = PERM_VMERGE_VVM; op2_src = OP2_VEC;   end
        end
        {6'h17, 3'b100}: begin
          if (vm) begin op = PERM_VMV_V_X;   op2_src = OP2_SCALAR; end
          else    begin op = PERM_VMERGE_VXM; op2_src = OP2_SCALAR; end
        end
        {6'h17, 3'b101}: begin
          if (vm) begin op = PERM_VMV_V_X;   op2_src = OP2_SCALAR; end // vfmv.v.f, 동일 데이터패스
          else    begin op = PERM_VMERGE_VXM; op2_src = OP2_SCALAR; end // vfmerge.vfm
        end
        {6'h17, 3'b011}: begin
          if (vm) begin op = PERM_VMV_V_I;   op2_src = OP2_IMM; imm_ext = {{59{vs1_f[4]}}, vs1_f}; end // simm5
          else    begin op = PERM_VMERGE_VIM; op2_src = OP2_IMM; imm_ext = {{59{vs1_f[4]}}, vs1_f}; end
        end

        // 0x10: 스칼라 추출/삽입. vs1 필드로 vmv.x.s/vfmv.f.s(=0) 대 vcpop.m/vfirst.m(=0x10/0x11)을 구분
        {6'h10, 3'b010}: if (vs1_f == 5'h00) begin op = PERM_VMV_X_S; op2_src = OP2_NONE; end
        {6'h10, 3'b001}: if (vs1_f == 5'h00) begin op = PERM_VFMV_F_S; op2_src = OP2_NONE; end
        {6'h10, 3'b110}: begin op = PERM_VMV_S_X;  op2_src = OP2_SCALAR; end // vs1=rs1(가변), vs2 고정 0
        {6'h10, 3'b101}: begin op = PERM_VFMV_S_F; op2_src = OP2_SCALAR; end

        // 0x27 + OPIVI: whole-register move. vs1 필드가 nreg-1 인코딩(0/1/3/7)
        {6'h27, 3'b011}: begin
          op = PERM_VMVNR; op2_src = OP2_NONE;
          unique case (vs1_f)
            5'd0: nreg_grp = 3'd1;
            5'd1: nreg_grp = 3'd2;
            5'd3: nreg_grp = 3'd4;
            5'd7: nreg_grp = 3'd8;
            default: op = PERM_ILLEGAL;
          endcase
        end

        // 0x14 + OPMVV: viota/vid/vmsbf/vmsof/vmsif. vs1 필드로 구분
        {6'h14, 3'b010}: begin
          op2_src = OP2_NONE;
          unique case (vs1_f)
            5'h11: op = PERM_VID;
            5'h10: op = PERM_VIOTA;
            5'h01: op = PERM_VMSBF;
            5'h02: op = PERM_VMSOF;
            5'h03: op = PERM_VMSIF;
            default: op = PERM_ILLEGAL;
          endcase
        end

        default: op = PERM_ILLEGAL;
      endcase
    end
  end

  // 피연산자 필요 여부 : 1R1W VRF read-request 단의 유일한 판단 근거
  logic need_vs2, need_vs1, need_v0, need_vd_old;
  always_comb begin
    need_vs2 = 1'b0; need_vs1 = 1'b0; need_v0 = 1'b0; need_vd_old = 1'b0;
    unique case (op)
      PERM_VRGATHER_VV:     begin need_vs2=1; need_vs1=1; need_v0=1; need_vd_old=1; end
      PERM_VRGATHER_VX,
      PERM_VRGATHER_VI:     begin need_vs2=1;              need_v0=1; need_vd_old=1; end
      PERM_VRGATHEREI16_VV: begin need_vs2=1; need_vs1=1; need_v0=1; need_vd_old=1; end
      PERM_VSLIDEUP,
      PERM_VSLIDEDOWN,
      PERM_VSLIDE1UP,
      PERM_VSLIDE1DOWN:     begin need_vs2=1;              need_v0=1; need_vd_old=1; end
      PERM_VCOMPRESS:       begin need_vs2=1; need_vs1=1;             need_vd_old=1; end
      PERM_VMERGE_VVM:      begin need_vs2=1; need_vs1=1; need_v0=1; need_vd_old=1; end
      PERM_VMERGE_VXM,
      PERM_VMERGE_VIM:      begin need_vs2=1;             need_v0=1; need_vd_old=1; end
      PERM_VMV_V_V:         begin              need_vs1=1;            need_vd_old=1; end
      PERM_VMV_V_X,
      PERM_VMV_V_I:         begin                                     need_vd_old=1; end
      PERM_VMV_X_S,
      PERM_VFMV_F_S:        begin need_vs2=1;                                        end
      PERM_VMV_S_X,
      PERM_VFMV_S_F:        begin                                     need_vd_old=1; end
      PERM_VMVNR:           begin need_vs2=1;                                        end
      PERM_VIOTA:           begin need_vs2=1;             need_v0=1; need_vd_old=1; end
      PERM_VID:             begin                          need_v0=1; need_vd_old=1; end
      PERM_VMSBF, PERM_VMSOF, PERM_VMSIF:
                            begin need_vs2=1;             need_v0=1; need_vd_old=1; end
      default: ;
    endcase
  end

  assign dec_o.op          = op;
  assign dec_o.vm          = vm;
  assign dec_o.op2_src     = op2_src;
  assign dec_o.imm_ext     = imm_ext;
  assign dec_o.nreg_grp    = nreg_grp;
  assign dec_o.vd_addr     = vd_f;
  assign dec_o.vs1_addr    = vs1_f;
  assign dec_o.vs2_addr    = vs2_f;
  assign dec_o.need_vs2    = need_vs2;
  assign dec_o.need_vs1    = need_vs1;
  assign dec_o.need_v0     = need_v0;
  assign dec_o.need_vd_old = need_vd_old;

  // 조합 로직만 있는 통과형 stage -> valid/ready 그대로 전달
  assign valid_o = valid_i;
  assign ready_o = ready_i;

endmodule
