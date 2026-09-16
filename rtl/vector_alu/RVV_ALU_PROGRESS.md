# RVV ALU 구현 체크리스트

공식 [rv_v opcode 파일](https://raw.githubusercontent.com/riscv/riscv-opcodes/f5befa291a2562f3194921265b7f5ac5681bc8b0/extensions/rv_v)의 OP-V 인코딩에서 설정 3개와 permutation 34개를 제외한 **280개 인코딩**을 추적합니다.
전체 VLEN=128 정수·FP 연산 범위를 표시하며, `profile` 열에 RV32IMFC에서 조건부인 FP64 계열을 따로 기록했습니다.

현재 `decode=yes`: **138/280**, `execute=yes`: **138/280**, TOP 통합 테스트: **9/280**.
완료는 세 항목과 명세 경계 테스트가 모두 채워진 경우에만 판정합니다.

| 연산군 | 인코딩 수 |
|---|---:|
| Carry/borrow | 15 |
| FP convert | 21 |
| FP element | 36 |
| FP multiply/FMA | 32 |
| FP reduction | 6 |
| Fixed point | 26 |
| Integer divide | 8 |
| Integer element | 53 |
| Integer multiply/MAC | 16 |
| Integer/mask reduction | 12 |
| Mask logic | 8 |
| Widen/narrow/extend | 47 |

상세: [RVV_ALU_CHECKLIST.csv](RVV_ALU_CHECKLIST.csv)
