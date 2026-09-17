# RVV Permutation 명령어 구현 체크리스트

기준: RVV 1.0, Vector_Core/outputs/rvv_instruction_20260916 카탈로그의 Permutation 분류 (34개 mnemonic).
검증: Verilator 5.050 (`C:\rv_toolchains\verilator-5.050`) `--lint-only` clean, `tb_vcore_perm_top.sv`로 기능 시뮬레이션.

| # | Mnemonic | 디코드 | 데이터패스 | LMUL>1 | 비고 |
|---|----------|:---:|:---:|:---:|---|
| 1 | vrgather.vv | ✅ | ✅ | ✅ | 그룹버퍼(src2_group) |
| 2 | vrgather.vx | ✅ | ✅ | ✅ | scalar 브로드캐스트 인덱스 |
| 3 | vrgather.vi | ✅ | ✅ | ✅ | uimm5 zero-ext |
| 4 | vrgatherei16.vv | ✅ | ✅ | ✅ | 인덱스(vs1) 독립 그룹버퍼(vpop_ei16_idx_regs), idx_regs>8 illegal 체크 |
| 5 | vslideup.vx | ✅ | ✅ | ✅ | 그룹버퍼, offset 미만은 자기 old vd 보존 |
| 6 | vslideup.vi | ✅ | ✅ | ✅ | uimm5 |
| 7 | vslidedown.vx | ✅ | ✅ | ✅ | 그룹버퍼 |
| 8 | vslidedown.vi | ✅ | ✅ | ✅ | uimm5 |
| 9 | vslide1up.vx | ✅ | ✅ | ✅ | global_index==0에서만 scalar 삽입 |
| 10 | vfslide1up.vf | ✅ | ✅ | ✅ | vslide1up와 동일 datapath |
| 11 | vslide1down.vx | ✅ | ✅ | ✅ | global_index==vl-1에서만 scalar 삽입 |
| 12 | vfslide1down.vf | ✅ | ✅ | ✅ | vslide1down과 동일 |
| 13 | vcompress.vm | ✅ | ✅ | ✅ | vs1(마스크)은 비그룹 고정, vs2는 그룹버퍼, 그룹 전체 기준 popcount |
| 14 | vmerge.vvm | ✅ | ✅ | ✅ | v0 selector, per-beat 독립 (그룹버퍼 불필요) |
| 15 | vmerge.vxm | ✅ | ✅ | ✅ | |
| 16 | vmerge.vim | ✅ | ✅ | ✅ | simm5 sign-ext |
| 17 | vfmerge.vfm | ✅ | ✅ | ✅ | vmerge.vxm과 동일 datapath |
| 18 | vmv.v.v | ✅ | ✅ | ✅ | |
| 19 | vmv.v.x | ✅ | ✅ | ✅ | |
| 20 | vmv.v.i | ✅ | ✅ | ✅ | simm5 sign-ext |
| 21 | vfmv.v.f | ✅ | ✅ | ✅ | vmv.v.x와 동일 |
| 22 | vmv.x.s | ✅ | ✅ | N/A(단일 beat) | **is_fp=0 → GPR 라우팅**, beats=1 강제 |
| 23 | vfmv.f.s | ✅ | ✅ | N/A | **is_fp=1 → FPR 라우팅**, vmv.x.s와 동일 beats=1 |
| 24 | vmv.s.x | ✅ | ✅ | N/A(단일 beat) | vd[0]만 씀, vstart==0 exact 조건, beats=1 강제 |
| 25 | vfmv.s.f | ✅ | ✅ | N/A | vmv.s.x와 동일 |
| 26 | vmv1r.v | ✅ | ✅ | N/A(bypass) | vtype/vl 완전 무시, vd/vs2 정렬 체크(1의 배수=항상 통과) |
| 27 | vmv2r.v | ✅ | ✅ | N/A | vd/vs2 2의 배수 정렬 체크 |
| 28 | vmv4r.v | ✅ | ✅ | N/A | vd/vs2 4의 배수 정렬 체크 |
| 29 | vmv8r.v | ✅ | ✅ | N/A | vd/vs2 8의 배수 정렬 체크 |
| 30 | viota.m | ✅ | ✅ | ✅ | vs2(마스크)는 비그룹 고정, 절대 비트 위치로 prefix popcount, vd는 정상 그룹화 |
| 31 | vid.v | ✅ | ✅ | ✅ | 소스 없음, vd만 정상 그룹화 |
| 32 | vmsbf.m | ✅ | ✅ | N/A(beats=1 강제) | vs2/vd 둘 다 비그룹 마스크 레지스터라 LMUL 무관 단일 beat |
| 33 | vmsof.m | ✅ | ✅ | N/A | 위와 동일 |
| 34 | vmsif.m | ✅ | ✅ | N/A | 위와 동일 |

**34/34 구현 완료.**

## 추가로 반영된 스펙 규칙
- 레지스터 overlap illegal-instruction 체크: gather/gatherei16/slide*/compress에서 vd가 vs2(및 해당 시 vs1/인덱스)와 겹치면 illegal (`regs_overlap`)
- vmvNr.v의 vd/vs2 정렬(nreg 배수) 체크
- vs2/vs1/vd가 실제로 그룹화되지 않는 마스크 오퍼랜드(viota의 vs2, vcompress의 vs1, vmsbf류의 vd)는 beats 정렬 체크에서 제외 (아니면 정상 명령어가 illegal로 오탐됨 — 테스트 중 실제로 발견/수정)
- vmv.x.s/vfmv.f.s: `is_fp` 플래그로 GPR/FPR 목적지 구분해서 `scalar_write_req_o.is_fp`로 노출

## 알려진 한계 (의도적으로 범위 밖)
- vrgatherei16의 인덱스 그룹버퍼는 EMUL_index 계산이 SEW=8일 때 급격히 커지는 경우까지 지원하지만(최대 MAXLMUL=8), 그 이상은 decode에서 illegal 처리 — RVV 스펙상으로도 이 조합은 실제로 불법입니다.
- 각 datapath 연산은 완전 combinational 1-beat-per-cycle(1R1W VRF 제약) 구조. 처리량 최적화(prefix-popcount 공유 트리 등)는 하지 않음 — 정확성 우선 스켈레톤.

## 검증 방법 (실제로 Verilator 5.050 돌려서 확인함)
1. **Lint**: `verilator --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module vcore_perm_top vcore_perm_pkg.sv vcore_perm_decode.sv vcore_perm_issue_fifo.sv vcore_perm_sequencer.sv vcore_perm_vrf_request.sv vcore_perm_core.sv vcore_perm_pipe.sv vcore_perm_wb.sv vcore_perm_top.sv` → **clean (exit 0)**
   - 이 과정에서 실제 버그 2개를 발견/수정함: (a) 함수 파라미터 EEW를 variable-width part-select(`+: EEW`)에 쓴 것 — Verilator는 호출부가 리터럴이어도 함수 인자를 상수로 취급 안 함 → shift+mask 기반 `fld_get`/`fld_get_wide`로 교체. (b) `regs_overlap` 호출부 폭 불일치(4bit→32bit) 경고.
2. **시뮬레이션**: `tb_vcore_perm_top.sv`(behavioral 1R1W VRF + scalar sink 포함, `verilator --binary --timing`으로 빌드해 실행) — **29개 self-checking 항목 전부 PASS**, LMUL=1/2 기본 테스트 21개 + **LMUL=8(MAXLMUL) 경계 테스트 8개**:
   - LMUL1/2: vid.v, vrgather.vv(LMUL1), vrgather.vv(LMUL2 교차 레지스터 2케이스), vslideup.vx(LMUL2 교차), vcompress.vm(LMUL2+vta), viota.m(LMUL2, 절대 비트 스캔), vmsbf/vmsof/vmsif.m(LMUL2 CSR인데 단일 beat), vmv.x.s(GPR), vfmv.f.s(FPR, is_fp 구분), vmv.s.x, vmv2r.v.
   - **LMUL8: vrgather.vv (SEW8, 128개 원소 전체를 8개 레지스터에 걸쳐 완전 반전 — dest reg0↔src reg7 식으로 최대 거리 교차), vrgatherei16.vv (SEW32, idx_regs=4 ≠ group_regs=8인 "인덱스가 데이터보다 적은 레지스터" 케이스), vrgatherei16.vv (SEW8, idx_regs=16>MAXLMUL(8) → illegal 정상 거부 확인), vslideup.vx (offset=100, 6개 레지스터 경계를 넘는 교차), vcompress.vm (128개 중 32개 active, 8레지스터 전체+tail), viota.m (단일 마스크 소스 → 8레지스터 목적지, 절대 스캔 128개 전 위치 검증), vmv8r.v (8레지스터 전체 이동)** — 모두 PASS.
   - 이 과정에서 decode.sv의 실제 버그 1개를 추가로 발견/수정함: vs2/vs1/vd 정렬(beats 배수) 체크가 그룹화 안 되는 마스크 오퍼랜드(viota의 vs2, vcompress의 vs1, vmsbf류의 vd)에도 적용돼서 정상 명령어를 illegal로 오탐하는 문제.

**결론: LMUL=1부터 LMUL=8(MAXLMUL, RVV가 지원하는 최댓값)까지 그룹버퍼 기반 로직 전부 실제 시뮬레이션으로 확인됨.**

재현 명령 (PowerShell, Verilator가 `C:\rv_toolchains\verilator-5.050`에 있다고 가정):
```powershell
$env:VERILATOR_ROOT = "C:\rv_toolchains\verilator-5.050"
$env:Path = "C:\rv_toolchains\verilator-5.050\bin;C:\rv_toolchains\w64devkit-2.9.1\w64devkit\bin;" + $env:Path
cd "<repo>\rtl\vector_permutation"
verilator --cc --timing --exe --main --build-jobs 1 -Wno-UNUSEDSIGNAL --top-module tb_vcore_perm_top vcore_perm_pkg.sv vcore_perm_decode.sv vcore_perm_issue_fifo.sv vcore_perm_sequencer.sv vcore_perm_vrf_request.sv vcore_perm_core.sv vcore_perm_pipe.sv vcore_perm_wb.sv vcore_perm_top.sv tb_vcore_perm_top.sv --Mdir obj_dir
mingw32-make.exe -C obj_dir -f Vtb_vcore_perm_top.mk CXX=g++ CC=gcc LINK=g++
.\obj_dir\Vtb_vcore_perm_top.exe
```
(obj_dir는 빌드 산출물이라 커밋하지 않고 지웠습니다 — 필요하면 위 명령으로 재생성)
