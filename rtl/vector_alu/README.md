# Vector ALU 실행 블록

이 디렉터리는 **VLEN=128, RV32 기반 RVV 정수 ALU의 구현 초안**입니다. 기존 VRF는 외부에 두며, 이 블록은 주소가 붙은 **128비트 단일 읽기 포트와 단일 쓰기 포트(1R1W)** 만 사용합니다. `v0`의 복제본도 외부 TOP이 관리합니다.

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
                              ALU Pipe (64비트 × 2클록)
                                           │ result
                                           ▼
                              WB ──► VRF 1W
                               └──► TOP commit + Sequencer beat 완료
```

## 처리 단위와 지연

- 한 `beat`는 VRF 레지스터 하나인 128비트입니다. `LMUL=2/4/8`은 각각 2/4/8 beat로 펼칩니다. fractional LMUL은 한 beat에서 `vl`과 tail 정책으로 처리합니다.
- 연산 단계는 매 클록 **64비트**, 즉 32비트 데이터 경로 2개 분량을 계산합니다. SEW=32일 때 2개 요소/클록, SEW=16일 때 4개, SEW=8일 때 8개입니다. 두 번째 클록 이후 128비트 결과가 `rsp_valid`로 나옵니다.
- SEW=64는 두 32비트 분량을 결합하는 64비트 연산 경로로 처리합니다. 현재 RTL의 연산자 공유 정도와 합성 면적은 합성 도구 결과로 확인해야 합니다.
- 연산 단계의 **initiation interval은 2클록**입니다. 명령 전체의 지연에는 VRF 순차 읽기, WB, backpressure가 추가됩니다. 1R VRF에서 `.vv`는 보통 `vs2 → vs1 → old vd` 순서로 3회 읽습니다.
- FIFO 깊이는 `ISSUE_DEPTH` 파라미터로 정합니다(최소 2). 데이터 폭은 현재 패키지의 mask snapshot과 연결되어 **VLEN=128 고정**이며, 다른 VLEN은 재설계가 필요합니다.

## TOP 입력 계약

`vcore_alu_cmd_t` 한 건을 `cmd_valid_i && cmd_ready_o`에서 받습니다. `inst`는 32비트 원시 OP-V 명령입니다. TOP이 같은 시점에 다음 값을 안정적으로 제공합니다.

| 필드 | 공급 원천 | 의미 |
|---|---|---|
| `inst[31:0]` | instruction | opcode, funct6, funct3, vm, vd, vs1/rs1/imm, vs2 |
| `scalar[31:0]` | 정수 레지스터 읽기 | `.vx`의 x[rs1]. `.vi`는 `inst[19:15]`에서 복호화 |
| `sew[2:0]` | vtype.vsew | 0/1/2/3 = 8/16/32/64 |
| `vlmul[2:0]` | vtype.vlmul | 000/001/010/011 = m1/m2/m4/m8, 111/110/101 = mf2/mf4/mf8 |
| `vta`, `vma`, `vill` | vtype | tail, inactive mask 정책 및 illegal vtype |
| `vl[16:0]`, `vstart[16:0]` | CSR | 요소 수 및 재시작 위치 |
| `mask_snapshot[127:0]` | TOP의 v0 복제 FF | **명령 수락 시점의 일관된 v0 값**, bit `i`가 요소 `i`의 마스크 |
| `tag[15:0]` | TOP | 그대로 WB/commit에 전달하는 식별자 |

`v0`는 CSR이 아닙니다. TOP은 VRF의 v0에 대한 모든 writeback을 복제 FF에도 반영하고, v0를 갱신하는 앞선 명령이 남아 있으면 forwarding하거나 이 ALU에 다음 명령을 발행하기 전에 기다려야 합니다. ALU는 마스크를 얻기 위해 VRF의 읽기 포트를 추가 사용하지 않습니다. 한 명령의 모든 LMUL beat는 **동일한** `mask_snapshot`을 사용합니다.

`vxrm`은 현재 지원 연산에서 쓰지 않습니다. 포화 연산의 `vxsat`은 `commit_o.vxsat`에서 beat별 펄스로 보고하므로 TOP이 sticky CSR에 OR합니다. TOP이 마지막 beat를 수락하면 architectural `vstart`를 0으로 정리합니다.

## VRF 및 writeback 계약

| 채널 | 핸드셰이크 | 내용 |
|---|---|---|
| 읽기 요청 | `vrf_read_valid_o && vrf_read_ready_i` | `addr`, `tag` 한 개. 응답은 요청 뒤 클록에 도착하고 `rsp_valid/rsp_ready`까지 유지되어야 함 |
| 읽기 응답 | `vrf_read_rsp_valid_i && vrf_read_rsp_ready_o` | 해당 주소의 128비트 데이터. outstanding 읽기는 최대 1개 |
| 쓰기 요청 | `vrf_write_valid_o && vrf_write_ready_i` | `vd_addr`, `tag`, 128비트 데이터 |
| 완료 | `commit_valid_o && commit_ready_i` | beat별 `tag`, `last_beat`, `vxsat`, `illegal_op` |

목적 레지스터의 기존 128비트 값은 항상 읽습니다. `vta=0`, `vma=0`, prestart 요소, mask destination의 수정하지 않는 비트를 보존하기 위해서입니다. 비교 명령은 dense mask bit를 `vd` 레지스터의 하위 비트부터 갱신하며 LMUL의 다음 beat도 같은 mask destination 레지스터에 누적 기록합니다.

`flush_i`는 큐·실행 중 beat·보류 결과를 폐기합니다. 이미 VRF write 핸드셰이크가 끝난 beat는 ALU 내부에서 되돌릴 수 없으므로, TOP은 그 시점 이후의 flush에 대해 VRF 복구/재명명 등 별도 회복 기법을 제공해야 합니다.

## 현재 디코드 범위

OP-V (`opcode=0x57`) 정수 `.vv`, `.vx`, `.vi` 형식 중 다음을 처리합니다. `funct3=000/100/011`은 각각 `.vv/.vx/.vi`입니다. `funct6`는 [RISC-V 공식 opcode 표](https://github.com/riscv/riscv-opcodes/blob/master/extensions/rv_v)를 따릅니다.

| funct6 | 연산 | 제한 |
|---|---|---|
| `00`, `02`, `03` | add, sub, rsub | sub에 `.vi` 없음, rsub에 `.vv` 없음 |
| `04`–`07` | unsigned/signed min/max | `.vi` 없음 |
| `09`–`0b` | and/or/xor | `.vv/.vx/.vi` |
| `17` | merge, vmv.v.v/x/i | `vm`과 `vs2=0` 구분 |
| `18`–`1f` | eq/ne/ltu/lt/leu/le/gtu/gt 비교 | 각 형식의 예약 encoding은 illegal |
| `20`–`23` | unsigned/signed saturating add/sub | sub에 `.vi` 없음 |
| `25`, `28`, `29` | sll/srl/sra | `.vv/.vx/.vi` |

지원하지 않는 명령/형식, `vill`, 유효하지 않은 `vlmul`/`sew`, `vl>VLMAX`, 예약된 register group alignment는 `illegal_op`로 보고하고 VRF 쓰기를 건너뜁니다. 마스크 목적지 비교는 일반 데이터 그룹과 달리 `vd` 정렬을 요구하지 않습니다. 마스크를 쓰는 일반 데이터 연산에서 `vd`가 v0와 겹치는 인코딩은 예약된 인코딩으로 처리합니다.

이 블록만으로 전체 RVV가 구현되지는 않습니다. widening/narrowing, multiply/divide, fixed-point rounding, FP vector, reduction, permutation, load/store 및 mask 논리 등은 별도 실행 블록이 필요합니다.

## 파일

- `vcore_alu_pkg.sv`: TOP·VRF·ALU 사이 packed type
- `vcore_alu_decode.sv`: OP-V integer decode 및 legality
- `vcore_alu_issue_fifo.sv`: ready/valid 3-entry 기본 FIFO
- `vcore_alu_sequencer.sv`: LMUL register beat 전개
- `vcore_alu_vrf_request.sv`: 1R VRF 순차 요청 및 scalar broadcast
- `vcore_alu_slice.sv`, `vcore_alu_pipe.sv`: 64비트/클록 연산과 2클록 결과 생성
- `vcore_alu_wb.sv`, `vcore_alu_top.sv`: 쓰기와 TOP commit, 전체 연결
- `tb_vcore_alu_pipe.sv`, `tb_vcore_alu_top.sv`: 독립 연산 및 1R1W 통합 테스트

시뮬레이션에 포함할 때는 **package를 먼저** 컴파일한 뒤 위 RTL, 마지막에 testbench를 컴파일합니다.
