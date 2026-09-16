# 1GHz 목표와 타이밍 검증 기준

목표 클록 주기는 **1.000ns**입니다. 이 수치는 RTL 시뮬레이션 통과와 별개이며,
표준셀 라이브러리·배치·배선·클록 트리 조건을 정한 후 STA로 판정해야 합니다.
현재 저장소에는 대상 공정/라이브러리, SDC, 합성/STA 결과가 없습니다.

## 현재 클록 경계

| 연산 | 클록당 작업 | 결과 지연 | 현재 타이밍 위험 |
|---|---|---|---|
| 일반 정수 | 128비트 beat의 하위/상위 64비트를 각각 계산 | 2 compute 클록 + VRF/WB | SEW64의 64비트 곱셈, 가변 shift/rounding, mask 선택 mux |
| 정수 reduction | 한 요소를 64비트 누산기에 적용 | source 요소 수에 비례 | 동적 요소 선택 + 64비트 add/compare |
| mask reduction | 32비트 mask를 scan/popcount | 4 compute 클록 | 32비트 활성화, popcount, first-bit 선택 |
| 정수 divide/remainder | radix-2로 몫 1비트 | 활성 요소당 SEW+준비 클록 | 65비트 compare/subtract + mux |
| FP FMA | 아직 미구현 | 미정 | 2클록 달성 가능 여부도 미검증 |

연산기의 **2 compute 클록**과 명령의 전체 지연은 다릅니다. 1R1W VRF에서
`.vv`는 source 두 개와 old `vd`를 순차로 읽습니다. LMUL>1일 때 beat도
WB 후 다음 beat로 넘어가므로, 명령 전체가 2클록 안에 끝나지 않습니다.

## 합성 전 수정이 필요한 경로

1. `vcore_alu_slice.sv`의 SEW64 `*`와 `vsmul`은 한 클록에 전체 곱셈과
   반올림/포화 선택이 이어집니다. 이 경로는 1GHz를 보장할 수 없습니다.
   32×32 partial product를 클록 경계로 나누거나 전용 multiplier macro를
   사용하고, 필요 시 compute 지연을 늘려야 합니다.
2. `vcore_alu_reduce_step.sv`의 동적 part-select 뒤에 누산 연산이 있습니다.
   요소 선택을 별도 레지스터에 넣거나 adder 구성을 바꾸는 결정은 STA의
   실제 경로 보고서에 따라 합니다.
3. `vcore_alu_pipe.sv`의 divider에는 65비트 compare/subtract가 있습니다.
   1ns를 넘으면 radix-2 step을 둘 이상의 클록으로 분할해야 합니다.
4. FP32 FMA는 fused rounding과 `fflags`까지 포함하여 설계해야 합니다.
   2클록은 목표일 뿐이며, 독립 add/mul을 연결해 두 번 반올림하는 구현은
   RVV의 fused 명령을 만족하지 않습니다.

## 사인오프에 필요한 입력과 산출물

- 공정/표준셀 `.lib`, 전압/온도 corner, wire/parasitic 모델, multiplier/FPU
  macro 사용 여부
- `create_clock -period 1.000`과 input/output delay, uncertainty를 포함한 SDC
- 합성 후 면적과 worst path, 배치·배선 후 setup/hold WNS/TNS 및 경로별 보고서
- 모든 SEW/LMUL, mask, backpressure, flush에 대한 기능 회귀와 명세 대조

이 자료가 준비되기 전에는 **1GHz 달성**이라고 표시하지 않습니다.
