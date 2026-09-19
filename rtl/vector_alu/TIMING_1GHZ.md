# 1GHz 목표와 타이밍 검증 기준

목표 클록 주기는 **1.000ns**입니다. 이 수치는 RTL 시뮬레이션 통과와 별개이며,
표준셀 라이브러리·배치·배선·클록 트리 조건을 정한 후 STA로 판정해야 합니다.
현재 저장소에는 대상 공정/라이브러리, SDC, 합성/STA 결과가 없습니다.

## 현재 클록 경계

| 연산 | 클록당 작업 | 결과 지연 | 현재 타이밍 위험 |
|---|---|---|---|
| 일반 정수 | 128비트 beat의 하위/상위 64비트를 각각 계산 | 2 compute 클록 + VRF/WB | SEW64의 64비트 곱셈, 가변 shift/rounding, mask 선택 mux |
| 정수 reduction | 한 요소를 64비트 누산기에 적용 | source 요소 수에 비례 | 동적 요소 선택 + 64비트 add/compare |
| FP32 min/max reduction | 한 FP32 요소를 seed/누산 값과 비교 | source 요소 수에 비례 | 동적 선택 + NaN/zero 판정 + 비교 |
| FP32 sum reduction | 공유 FMA 경로에서 한 FP32 요소를 순서대로 누산 | 활성 source 요소 수에 비례 | 누산 feedback의 recode·가산·정규화·반올림 조합 경로 |
| mask reduction | 32비트 mask를 scan/popcount | 4 compute 클록 | 32비트 활성화, popcount, first-bit 선택 |
| 정수 divide/remainder | radix-2로 몫 1비트 | 활성 요소당 SEW+준비 클록 | 65비트 compare/subtract + mux |
| 정수 확장 `vzext/vsext` | source sub-register 선택 후 64비트씩 확장 | 2 compute 클록 + VRF/WB | 입력의 128비트 정렬 mux와 lane sign-extension mux |
| widening add/sub | narrow source를 2배 EEW로 확장해 64비트씩 add/sub | 2 compute 클록/beat + VRF/WB | 입력 정렬·확장 mux와 SEW64 adder |
| widening multiply/MAC | narrow source 두 개를 확장해 공통 곱셈 경로에서 계산 | 2 compute 클록/beat + VRF/WB | source 정렬·확장 mux, 64비트 곱셈, 누산 add |
| narrowing shift/clip | wide source 128비트를 한 클록에 좁은 destination 64비트로 계산 | 2 compute 클록/beat + VRF/WB | wide 가변 shift, `vxrm` 반올림, 포화 compare/mux |
| FP32 add/sub/mul/FMA | 공유 fused multiply-add 경로에서 FP32 두 lane/클록 | 2 compute 클록/beat + VRF/WB | 입력 recode, 가수 곱셈·가산·정규화·최종 1회 반올림과 fflags가 한 compute 클록의 조합 경로. 1ns 미검증 |
| FP32/int32 convert | 방향별 변환 경로에서 두 lane/클록 | 2 compute 클록/beat + VRF/WB | leading-zero/정렬·반올림·포화 선택의 조합 경로. 1ns 미검증 |
| FP32 `vfrec7/vfrsqrt7` | 정규화와 128-entry LUT, 두 lane/클록 | 2 compute 클록/beat + VRF/WB | subnormal leading-zero 정규화와 LUT/mux. 1ns 미검증 |
| FP32 divide/sqrt | 한 iterative HardFloat 엔진에 활성 요소를 순차 발행 | 요소별 가변 지연 + VRF/WB | 반복 단계의 significand subtract/shift와 최종 반올림. 처리율은 두-lane 일반 경로보다 낮음 |

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
4. FP32 add/sub/mul/FMA는 같은 HardFloat fused 데이터 경로를 사용합니다.
   기능 시뮬레이션에서 단일 반올림과 대표 `fflags`를 확인했지만, recode부터
   fused 연산과 IEEE 변환까지 조합형이므로 1ns를 보장하지 못합니다. 실제
   타이밍이 초과되면 HardFloat 내부를 파이프라인으로 분할하거나 FP compute
   지연을 늘려야 하며, 이때 ready/valid와 beat 지연 계약도 수정해야 합니다.
   정수 MAC 곱셈식과 FP 가수 곱셈기의 물리적 공유는 가정하지 않습니다.
5. 확장 연산은 source EMUL에 따라 한 128비트 소스의 일부를 선택합니다.
   현재 조합 경로의 정렬 shift가 1ns에 들어오는지 확인하고, 실패하면
   VRF 응답 뒤 정렬 레지스터를 추가하거나 소스 선택을 고정 mux로 바꿉니다.
6. widening add/sub는 narrow source 정렬과 부호 확장 뒤에 64비트
   add/sub가 이어집니다. 1ns를 넘으면 정렬 결과를 별도 레지스터에 저장해
   연산 클록을 분리하고 결과 지연을 재정의해야 합니다.
7. multiply/MAC는 signed·unsigned·mixed 결과 선택을 하나의 곱셈식으로
   합쳤습니다. 이 RTL 변화만으로 물리적으로 곱셈기 하나로 공유되었거나
   1ns에 들어온다고 판정할 수 없으며, 합성 netlist와 STA로 확인합니다.
8. narrowing clip은 64비트 가변 shift, 반올림, 포화 비교가 한 compute
   클록에 이어집니다. 1ns를 넘으면 이 경로를 분할하고 compute 지연을
   재정의해야 합니다. 1R VRF의 추가 source read도 전체 명령 지연에 포함합니다.
9. FP32 변환과 estimate는 일반 두-lane 경로에 들어갑니다. 특히 subnormal
   normalize의 leading-zero/shift가 1ns를 넘는지 확인하고, 실패하면 입력
   정규화와 결과 선택 사이에 클록 경계를 추가합니다.
10. FP32 divide/sqrt는 반복형이라 전체 지연은 2클록 대상이 아닙니다. 반복
    엔진 내부의 한 단계가 1ns를 만족하는지 별도 STA하고, LMUL 명령의 낮은
    처리율이 시스템 요구를 만족하는지도 성능 모델로 확인합니다.

## 사인오프에 필요한 입력과 산출물

- 공정/표준셀 `.lib`, 전압/온도 corner, wire/parasitic 모델, multiplier/FPU
  macro 사용 여부
- `create_clock -period 1.000`과 input/output delay, uncertainty를 포함한 SDC
- 합성 후 면적과 worst path, 배치·배선 후 setup/hold WNS/TNS 및 경로별 보고서
- 모든 SEW/LMUL, mask, backpressure, flush에 대한 기능 회귀와 명세 대조

이 자료가 준비되기 전에는 **1GHz 달성**이라고 표시하지 않습니다.
