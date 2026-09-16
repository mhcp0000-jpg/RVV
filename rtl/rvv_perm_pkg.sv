// rvv_perm_pkg.sv
// RVV Permutation Unit 전용 타입 정의.
// VLEN 자체는 각 모듈의 parameter로 전달됨(추후 상위 PKG에서 override).
// 여기 정의된 타입은 VLEN 폭에 의존하지 않는 control/CSR 필드만 포함한다.
package rvv_perm_pkg;

  // ---------------------------------------------------------------------
  // vtype / CSR
  // ---------------------------------------------------------------------
  typedef enum logic [1:0] {
    SEW8  = 2'd0,
    SEW16 = 2'd1,
    SEW32 = 2'd2,
    SEW64 = 2'd3
  } rvv_sew_e;

  // vlmul 인코딩은 RVV 스펙 그대로: 000=1,001=2,010=4,011=8,101=1/2,110=1/4,111=1/8
  typedef struct packed {
    logic       vill;
    logic       vma;
    logic       vta;
    logic [2:0] vlmul;
    rvv_sew_e   vsew;
  } rvv_vtype_t;

  // vl/vstart는 global(레지스터 그룹 전체) 기준 element count.
  // VLEN=128, SEW=8, LMUL=8 조합에서 VLMAX=128이므로 8bit면 충분(0..128).
  typedef struct packed {
    logic [7:0]  vl;
    logic [7:0]  vstart;
    rvv_vtype_t  vtype;
  } rvv_csr_t;

  // ---------------------------------------------------------------------
  // Permutation micro-op
  // ---------------------------------------------------------------------
  typedef enum logic [4:0] {
    PERM_VRGATHER_VV, PERM_VRGATHER_VX, PERM_VRGATHER_VI, PERM_VRGATHEREI16_VV,
    PERM_VSLIDEUP,     PERM_VSLIDEDOWN,
    PERM_VSLIDE1UP,    PERM_VSLIDE1DOWN,
    PERM_VCOMPRESS,
    PERM_VMERGE_VVM,   PERM_VMERGE_VXM,   PERM_VMERGE_VIM,
    PERM_VMV_V_V,      PERM_VMV_V_X,      PERM_VMV_V_I,
    PERM_VMV_X_S,      PERM_VMV_S_X,
    PERM_VFMV_F_S,     PERM_VFMV_S_F,
    PERM_VMVNR,
    PERM_VIOTA,        PERM_VID,
    PERM_VMSBF,        PERM_VMSOF,        PERM_VMSIF,
    PERM_ILLEGAL
  } rvv_perm_op_e;

  // exec가 두번째 피연산자를 어디서 가져와야 하는지 (decode가 이미 해석 완료)
  typedef enum logic [1:0] { OP2_VEC, OP2_SCALAR, OP2_IMM, OP2_NONE } rvv_op2_src_e;

  // decode 출력: 명령어 1개에 대한 정적 제어 정보.
  // need_* 플래그가 VRF read-request 단계의 유일한 근거가 된다 (1R1W이므로 최소 read만 순차 발행).
  typedef struct packed {
    rvv_perm_op_e   op;
    logic           vm;          // 원본 vm 비트 (predicate 사용 여부는 op별로 별도 해석)
    rvv_op2_src_e   op2_src;
    logic [63:0]    imm_ext;     // simm5/uimm5을 op 규칙에 맞게 이미 부호/제로 확장한 값
    logic [2:0]     nreg_grp;    // whole-register move count: 1/2/4/8 (log2 아님, 실제 개수)
    logic [4:0]     vd_addr, vs1_addr, vs2_addr;
    logic           need_vs2, need_vs1, need_v0, need_vd_old;
  } rvv_perm_dec_t;

  // sequencer 출력: EMUL 그룹 내 한 레지스터에 대한 pass 하나.
  typedef struct packed {
    rvv_perm_dec_t dec;
    rvv_csr_t      csr;          // 명령어가 sequencer에 들어올 때 스냅샷 (진행 중 vsetvli 변경으로부터 격리)
    logic [3:0]    reg_idx;      // 그룹 내 몇 번째 레지스터인지 (0-base)
    logic [3:0]    reg_cnt;      // 그룹 총 레지스터 수 (EMUL 또는 nreg_grp)
    logic          last_reg;     // reg_idx == reg_cnt-1
    logic [7:0]    elem_offset;  // reg_idx * (VLEN/SEW), vl/vstart를 이 레지스터 기준으로 국소화하는 데 사용
  } rvv_perm_seq_t;

endpackage
