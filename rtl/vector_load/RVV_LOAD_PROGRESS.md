# RVV 벡터 로드 구현 체크리스트

공식 [rv_v opcode 파일](https://raw.githubusercontent.com/riscv/riscv-opcodes/f5befa291a2562f3194921265b7f5ac5681bc8b0/extensions/rv_v)에서 LOAD-FP(opcode 0x07) 인코딩을 추출하고,
`nf` 필드가 가변인 행은 RVV 1.0이 이름을 주는 segment 변형으로 전개해 **177개**를 추적합니다.
이 개수는 저장소의 명령어 카탈로그(`outputs/rvv_instruction_20260916`) Load 행 수와 일치합니다.

현재 `decode=yes`: **177/177**, `execute=yes`: **177/177**, directed 통합 테스트: **93/177**.

`tb_vcore_vld_decode_table`이 177개 인코딩 전부를 vtype 전 구간에 걸쳐 대조하고,
`tb_vcore_vld_ref`가 독립 모델로 데이터를 전수 비교합니다.

| 연산군 | 인코딩 수 | 구현 |
|---|---:|---:|
| Fault-only-first | 32 | 32 |
| Indexed ordered | 4 | 4 |
| Indexed unordered | 4 | 4 |
| Mask memory | 1 | 1 |
| Segment indexed ordered | 28 | 28 |
| Segment indexed unordered | 28 | 28 |
| Segment strided | 28 | 28 |
| Segment unit-stride | 28 | 28 |
| Strided | 4 | 4 |
| Unit-stride | 4 | 4 |
| Whole register | 16 | 16 |

상세: [RVV_LOAD_CHECKLIST.csv](RVV_LOAD_CHECKLIST.csv)
