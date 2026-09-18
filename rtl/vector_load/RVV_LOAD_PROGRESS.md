# RVV 벡터 로드 구현 체크리스트

공식 [rv_v opcode 파일](https://raw.githubusercontent.com/riscv/riscv-opcodes/f5befa291a2562f3194921265b7f5ac5681bc8b0/extensions/rv_v)에서 LOAD-FP(opcode 0x07) 인코딩을 추출하고,
`nf` 필드가 가변인 행은 RVV 1.0이 이름을 주는 segment 변형으로 전개해 **177개**를 추적합니다.
이 개수는 저장소의 명령어 카탈로그(`outputs/rvv_instruction_20260916`) Load 행 수와 일치합니다.

현재 `decode=yes`: **5/177**, `execute=yes`: **5/177**, directed 통합 테스트: **5/177**.

나머지는 미구현이 아니라 **범위 밖**이며, decode가 `illegal_op`으로 보고해 TOP이
다른 곳으로 라우팅하거나 trap을 걸 수 있게 합니다. 조용히 오동작하지 않는 것이
`tb_vcore_vld_decode_table`이 177개 전수로 확인하는 내용입니다.

| 연산군 | 인코딩 수 | 구현 |
|---|---:|---:|
| Fault-only-first | 32 | 0 |
| Indexed ordered | 4 | 0 |
| Indexed unordered | 4 | 0 |
| Mask memory | 1 | 1 |
| Segment indexed ordered | 28 | 0 |
| Segment indexed unordered | 28 | 0 |
| Segment strided | 28 | 0 |
| Segment unit-stride | 28 | 0 |
| Strided | 4 | 0 |
| Unit-stride | 4 | 4 |
| Whole register | 16 | 0 |

상세: [RVV_LOAD_CHECKLIST.csv](RVV_LOAD_CHECKLIST.csv)
