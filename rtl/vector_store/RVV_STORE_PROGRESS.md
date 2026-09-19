# RVV 벡터 스토어 구현 체크리스트

공식 [rv_v opcode 파일](https://raw.githubusercontent.com/riscv/riscv-opcodes/f5befa291a2562f3194921265b7f5ac5681bc8b0/extensions/rv_v)에서 STORE-FP(opcode 0x27) 인코딩을 추출하고,
`nf` 필드가 가변인 행은 RVV 1.0이 이름을 주는 segment 변형으로 전개해 **133개**를 추적합니다.
이 개수는 저장소 명령어 카탈로그(`outputs/rvv_instruction_20260916`) Store 행 수와 일치합니다.

현재 `decode=yes`: **133/133**, `execute=yes`: **133/133**.

`decode`는 `tb_vcore_vst_decode_table`이 인코딩 × vtype 전 구간에서 대조합니다.
`execute`는 손으로 적은 값이 아닙니다 — `tb_vcore_vst_ref`가 실제로 실행해서
통과시킨 인코딩을 `exec_coverage.txt`에 기록하고, 이 스크립트가 그 로그를 읽어
채웁니다. 로그가 없으면 execute는 전부 no가 됩니다.

로드와 비교해 **없는 것**: fault-only-first(32개 적음), 그리고 whole-register가
EEW별 4종이 아니라 레지스터 수별 4종입니다(`width`가 000으로 고정).

| 연산군 | 인코딩 수 | 구현 |
|---|---:|---:|
| Indexed ordered | 4 | 4 |
| Indexed unordered | 4 | 4 |
| Mask memory | 1 | 1 |
| Segment indexed ordered | 28 | 28 |
| Segment indexed unordered | 28 | 28 |
| Segment strided | 28 | 28 |
| Segment unit-stride | 28 | 28 |
| Strided | 4 | 4 |
| Unit-stride | 4 | 4 |
| Whole register | 4 | 4 |

상세: [RVV_STORE_CHECKLIST.csv](RVV_STORE_CHECKLIST.csv)
