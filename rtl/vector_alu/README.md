# Vector ALU 실행 블록

이 디렉터리는 **VLEN=128, RV32IMFC 기반 vector ALU의 진행 중인 RTL**입니다. D 확장은 범위에 넣지 않으므로 FP64 명령은 구현 대상에서 제외합니다. 현재 정수 SEW64를 유지하는 명령 범위는 `Zve64f_Zvl128b`에 해당하며, 단일 문자 `V` 전체를 주장하려면 D/FP64도 필요합니다. 기존 VRF는 외부에 두며, 이 블록은 주소가 붙은 **128비트 단일 읽기 포트와 단일 쓰기 포트(1R1W)** 만 사용합니다. `v0`의 복제본도 외부 TOP이 관리합니다. 공식 인코딩별 구현·검증 현황은 [RVV_ALU_PROGRESS.md](RVV_ALU_PROGRESS.md)와 [RVV_ALU_CHECKLIST.csv](RVV_ALU_CHECKLIST.csv)에 기록합니다.

```text
TOP: inst + scalar + 유효 CSR + v0 스냅샷
  │ ready/valid
  ▼
Decode ──► Issue FIFO (기본 3개) ──► LMUL Sequencer
                                           │ beat/uop
                                           ▼
                              VRF Request (1R 순차 읽기)
                                           │ src2, src1, old vd, mask snapshot
                                           ▼
                              ALU Pipe (일반 연산 64비트 × 2클록;
                                        reduction/divide는 반복 연산)
                                           │ result
                                           ▼
                              WB ──► VRF 1W
                               └──► TOP commit + Sequencer beat 완료
```

## 처리 단위와 지연

- 한 `beat`는 VRF 레지스터 하나인 128비트입니다. `LMUL=2/4/8`은 각각 2/4/8 beat로 펼칩니다. fractional LMUL은 한 beat에서 `vl`과 tail 정책으로 처리합니다.
- 연산 단계는 매 클록 **64비트**, 즉 32비트 데이터 경로 2개 분량을 계산합니다. SEW=32일 때 2개 요소/클록, SEW=16일 때 4개, SEW=8일 때 8개입니다. 두 번째 클록 이후 128비트 결과가 `rsp_valid`로 나옵니다.
- SEW=64는 두 32비트 분량을 결합하는 64비트 연산 경로로 처리합니다. 현재 RTL의 연산자 공유 정도와 합성 면적은 합성 도구 결과로 확인해야 합니다.
- 일반 요소별 연산 단계의 **initiation interval은 2클록**입니다. 정수 reduction은 한 요소/클록, mask reduction은 32비트/클록, 정수 divide/remainder는 radix-2로 한 몫 비트/클록이며 지연이 더 깁니다. 명령 전체의 지연에는 VRF 순차 읽기, WB, backpressure가 추가됩니다. 1R VRF에서 `.vv`는 보통 `vs2 → vs1 → old vd` 순서로 3회 읽습니다.
- 일반 reduction은 source LMUL의 모든 beat를 하나의 누산기에 전달하고, 마지막 beat에서만 `vd[0]`을 씁니다. `vl=0`이면 VRF를 쓰지 않습니다. `vstart!=0`인 reduction은 illegal입니다. mask 논리와 `vcpop.m`/`vfirst.m`은 LMUL과 관계없이 마스크 레지스터 한 개를 읽습니다.
- `vzext.vf2/vf4/vf8`와 `vsext.vf2/vf4/vf8`는 source EEW=`SEW/factor`, source EMUL=`LMUL/factor`로 주소를 계산합니다. 여러 destination beat가 한 source 레지스터를 공유할 수 있으며, 서로 다른 EEW의 source/destination 그룹이 겹치면 source EMUL≥1이고 두 그룹의 최고 번호 레지스터가 같을 때만 허용합니다. source EMUL이 fractional인 overlap은 거부합니다.
- `vwaddu/vwadd/vwsubu/vwsub`의 `.vv/.vx/.wv/.wx`는 source SEW의 두 배를 destination EEW로 사용합니다. 정수 LMUL m1/m2/m4의 destination 그룹은 각각 2/4/8개 레지스터이고, m8은 EMUL 제한으로 거부합니다. `.wv/.wx`의 `vs2`는 이미 넓은 EEW로 읽습니다. 서로 다른 EEW 그룹이 합법적으로 겹치면 해당 명령의 비활성 mask 및 tail 결과는 agnostic으로 처리합니다.
- `vwmulu/vwmulsu/vwmul/vwmaccu/vwmacc/vwmaccus/vwmaccsu`의 13개 형식도 같은 widening beat·VRF 주소 경로를 사용합니다. 명령별 signed/unsigned 조합으로 source를 2×SEW로 확장한 뒤, 기존 정수 multiply/MAC 연산 경로에서 하위 2×SEW 결과를 사용합니다. 현재 정수 곱셈은 RTL의 단일 `multiply_a * multiply_b` 식을 공유하지만, 물리적으로 자원 하나로 합성되는지는 netlist로 확인해야 합니다.
- FP32 `vfadd/vfsub/vfrsub/vfmul` 및 여덟 FMA 계열은 각 32비트 lane의 같은 fused multiply-add 데이터 경로를 사용합니다. `vfadd/vfsub`는 정확한 1.0을 곱하고, `vfmul`은 0을 더합니다. FMA는 중간 곱셈을 반올림하지 않고 최종 결과에서 한 번 반올림하며, 활성 lane의 `fflags`만 beat 결과에 OR합니다. 128비트 beat는 FP32 두 lane씩 두 compute 클록에 처리합니다. 이 경로의 조합 타이밍은 아직 검증하지 않았습니다.
- `vnsrl/vnsra/vnclipu/vnclip`의 `.wv/.wx/.wi`는 source EEW=`2×SEW`, source EMUL=`2×LMUL`입니다. m1/m2/m4는 destination beat마다 VRF에서 넓은 `vs2` 레지스터 두 개를 순차로 읽으며, `.wv`는 추가로 `vs1`, 모든 형식은 old `vd`를 읽습니다. mf2/mf4/mf8은 source가 한 레지스터 안에 들어갑니다. `.wi`의 5비트 shift amount는 zero extension입니다. `vnclip*`는 `vxrm` 반올림 뒤 포화하고 활성 lane의 포화만 `vxsat`에 반영합니다. source/destination EEW가 다른 합법적인 low-end overlap에서는 inactive mask 및 tail을 agnostic으로 처리합니다.
- `vfredmin.vs`와 `vfredmax.vs`는 FP32 요소를 source LMUL 전체에 걸쳐 한 lane씩 누산합니다. NaN, 부호 있는 zero, mask, signaling NaN의 NV 플래그를 처리하고 마지막 beat에서만 `vd[0]`을 씁니다. FP 명령의 `frm`이 예약 값이면 `vl=0`이어도 illegal로 보고합니다.
- FIFO 깊이는 `ISSUE_DEPTH` 파라미터로 정합니다(최소 2). 데이터 폭은 현재 패키지의 mask snapshot과 연결되어 **VLEN=128 고정**이며, 다른 VLEN은 재설계가 필요합니다.

## TOP 입력 계약

`vcore_alu_cmd_t` 한 건을 `cmd_valid_i && cmd_ready_o`에서 받습니다. `inst`는 32비트 원시 OP-V 명령입니다. TOP이 같은 시점에 다음 값을 안정적으로 제공합니다.

| 필드 | 공급 원천 | 의미 |
|---|---|---|
| `inst[31:0]` | instruction | opcode, funct6, funct3, vm, vd, vs1/rs1/imm, vs2 |
| `scalar[31:0]` | TOP의 정수/FP 레지스터 읽기 | `.vx`의 x[rs1] 또는 `.vf`의 raw FP32 f[rs1] 비트. `.vi`는 `inst[19:15]`에서 복호화 |
| `sew[2:0]` | vtype.vsew | 0/1/2/3 = 8/16/32/64 |
| `vlmul[2:0]` | vtype.vlmul | 000/001/010/011 = m1/m2/m4/m8, 111/110/101 = mf2/mf4/mf8 |
| `vxrm[1:0]` | CSR vxrm | fixed point 평균·rounded shift·`vsmul`의 반올림 모드 |
| `frm[2:0]` | CSR frm | FP 산술/FMA 반올림 모드. 비트 조작·비교의 결과에는 영향 없음 |
| `vta`, `vma`, `vill` | vtype | tail, inactive mask 정책 및 illegal vtype |
| `vl[16:0]`, `vstart[16:0]` | CSR | 요소 수 및 재시작 위치 |
| `mask_snapshot[127:0]` | TOP의 v0 복제 FF | **명령 수락 시점의 일관된 v0 값**, bit `i`가 요소 `i`의 마스크 |
| `tag[15:0]` | TOP | 그대로 WB/commit에 전달하는 식별자 |

`v0`는 CSR이 아닙니다. TOP은 VRF의 v0에 대한 모든 writeback을 복제 FF에도 반영하고, v0를 갱신하는 앞선 명령이 남아 있으면 forwarding하거나 이 ALU에 다음 명령을 발행하기 전에 기다려야 합니다. ALU는 마스크를 얻기 위해 VRF의 읽기 포트를 추가 사용하지 않습니다. 한 명령의 모든 LMUL beat는 **동일한** `mask_snapshot`을 사용합니다.

포화 연산의 `vxsat`과 FP의 `fflags[4:0]`은 `commit_o`에서 beat별로 보고하므로 TOP이 sticky CSR에 OR합니다. 현재 FP32 부호·분류·min/max·비교·min/max reduction, add/sub/mul/FMA 계열을 지원합니다. FP32 FMA는 최종 결과에서 정확히 한 번 반올림합니다. TOP이 마지막 beat를 수락하면 architectural `vstart`를 0으로 정리합니다.

## VRF 및 writeback 계약

| 채널 | 핸드셰이크 | 내용 |
|---|---|---|
| 읽기 요청 | `vrf_read_valid_o && vrf_read_ready_i` | `addr`, `tag` 한 개. 응답은 요청 뒤 클록에 도착하고 `rsp_valid/rsp_ready`까지 유지되어야 함 |
| 읽기 응답 | `vrf_read_rsp_valid_i && vrf_read_rsp_ready_o` | 해당 주소의 128비트 데이터. outstanding 읽기는 최대 1개 |
| 쓰기 요청 | `vrf_write_valid_o && vrf_write_ready_i` | `vd_addr`, `tag`, 128비트 데이터 |
| 완료 | `commit_valid_o && commit_ready_i` | beat별 `tag`, `last_beat`, `vxsat`, `fflags`, `illegal_op`; `vcpop.m`/`vfirst.m`은 `scalar_valid`, `scalar_rd`, `scalar_data` 포함 |

일반 벡터 목적지의 기존 128비트 값은 보존 정책 때문에 읽습니다. scalar mask reduction은 VRF 목적지를 읽거나 쓰지 않습니다. 정수 reduction은 마지막 beat에서만 VRF에 씁니다. 비교 명령은 dense mask bit를 `vd` 레지스터의 하위 비트부터 갱신하며 LMUL의 다음 beat도 같은 mask destination 레지스터에 누적 기록합니다.

`flush_i`는 큐·실행 중 beat·보류 결과를 폐기합니다. 이미 VRF write 핸드셰이크가 끝난 beat는 ALU 내부에서 되돌릴 수 없으므로, TOP은 그 시점 이후의 flush에 대해 VRF 복구/재명명 등 별도 회복 기법을 제공해야 합니다.

## 명령 범위와 1GHz 목표

인코딩은 공식 [RISC-V opcode 파일](https://raw.githubusercontent.com/riscv/riscv-opcodes/f5befa291a2562f3194921265b7f5ac5681bc8b0/extensions/rv_v)에 고정했습니다. ALU로 분류한 280개 중 현재 구현 수는 [진행표](RVV_ALU_PROGRESS.md)를 참조하세요. 지원하지 않는 명령/형식, `vill`, 유효하지 않은 `vlmul`/`sew`, `vl>VLMAX`, 예약된 register group alignment는 `illegal_op`로 보고하고 VRF 쓰기를 건너뜁니다. 비교와 mask 논리 목적지는 일반 데이터 그룹과 달리 `vd` 정렬을 요구하지 않습니다.

**1GHz는 설계 목표이며 달성 판정이 아닙니다.** 반복 reduction/divider는 한 클록 조합 연산량을 제한했습니다. 현재 일반 slice에는 64비트 곱셈과 가변 shift/rounding 경로가 있고, FP32 FMA는 조합형 HardFloat 경로이므로 타이밍 위험이 큽니다. 표준셀 라이브러리 기반 합성, 배치·배선, STA 결과가 없습니다. 2클록 결과 요구는 일반 요소 연산에 적용하고, divide/reduction에는 가변 지연을 허용합니다.
타이밍 경계와 필요한 signoff 입력은 [TIMING_1GHZ.md](TIMING_1GHZ.md)에 정리했습니다.

## 파일

- `vcore_alu_pkg.sv`: TOP·VRF·ALU 사이 packed type
- `vcore_alu_decode.sv`: OP-V integer decode 및 legality
- `vcore_alu_issue_fifo.sv`: ready/valid 3-entry 기본 FIFO
- `vcore_alu_sequencer.sv`: LMUL register beat 전개
- `vcore_alu_vrf_request.sv`: 1R VRF 순차 요청 및 scalar broadcast
- `vcore_alu_slice.sv`, `vcore_alu_narrow_slice.sv`, `vcore_alu_pipe.sv`, `vcore_alu_reduce_step.sv`: 일반/축소 요소 연산 및 반복 reduction/divider
- `vcore_alu_fp32_fma.sv`, `vcore_alu_fp32_slice.sv`: FP32 add/sub/mul/FMA 공유 경로. `third_party/hardfloat/`의 라이선스와 출처 참조
- `vcore_alu_wb.sv`, `vcore_alu_top.sv`: 쓰기와 TOP commit, 전체 연결
- `tb_vcore_alu_pipe.sv`, `tb_vcore_alu_top.sv`: 독립 연산 및 1R1W 통합 테스트
- `generate_checklist.py`, `verify_decode_table.py`, `tb_vcore_alu_decode_table.sv`: 공식 인코딩 280개 추적 및 decoder 수락/거부 대조

시뮬레이션에 포함할 때는 **package를 먼저** 컴파일한 뒤 위 RTL, 마지막에 testbench를 컴파일합니다.
