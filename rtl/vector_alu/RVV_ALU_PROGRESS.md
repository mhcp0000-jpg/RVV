# RVV ALU 구현 체크리스트

공식 [rv_v opcode 파일](https://raw.githubusercontent.com/riscv/riscv-opcodes/f5befa291a2562f3194921265b7f5ac5681bc8b0/extensions/rv_v)의 OP-V 인코딩에서 설정 3개와 permutation 34개를 제외한 **280개 인코딩**을 추적합니다.
전체 인코딩을 참고용으로 표시합니다. 현재 RV32IMFC 목표는 정수 SEW64와 FP32를 지원하는 `Zve64f_Zvl128b` 명령 범위이며, D가 필요한 FP64 인코딩은 대상에서 제외합니다.

현재 `decode=yes`: **245/280**, `execute=yes`: **245/280**, TOP 통합 테스트: **98/280**.
현재 목표 범위: **245/245** 실행 구현, 남은 **0**개. FP64 제외 인코딩은 35개입니다.
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
