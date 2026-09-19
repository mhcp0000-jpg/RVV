# vcore_vld — 벡터 unit-stride LOAD 클러스터

Permutation 클러스터(`vector_permutation/`)와 **같은 6단 골격**을 그대로 쓰고,
오퍼랜드를 VRF가 아니라 **외부 메모리**에서 가져오도록 바꾼 유닛입니다.

```
cmd ─► decode ─► issue_fifo ─► sequencer ─► memreq ─► pipe ─► wb ─► VRF write
                                   ▲                                  │
                                   └──────── beat ack ────────────────┘
                                             │
                                   memreq ◄──┴──► 외부 mem if (tag, OoO, MO)
```

| perm 모듈 | vld 모듈 | 차이 |
|---|---|---|
| `vcore_perm_decode` | `vcore_vld_decode` | OP-V(0x57) → LOAD-FP(0x07), EMUL=EEW/SEW×LMUL |
| `vcore_perm_issue_fifo` | `vcore_vld_issue_fifo` | 동일 |
| `vcore_perm_sequencer` | `vcore_vld_sequencer` | 동일(beat = 목적지 레지스터 1개) |
| `vcore_perm_vrf_request` | **`vcore_vld_memreq`** | VRF 스테이징 → **MO 메모리 요청 엔진** |
| `vcore_perm_core` | `vcore_vld_assemble` | 크로스바 없음, 정책 체인만 |
| `vcore_perm_pipe` | `vcore_vld_pipe` | 동일 |
| `vcore_perm_wb` | `vcore_vld_wb` | scalar 포트 없음, `mem_error` 추가 |

## 1. 지원 범위

공식 `rv_v` opcode 파일 기준 벡터 로드 인코딩 **177개 전부**를 구현합니다.

| 연산군 | 인코딩 | 형태 |
|---|---:|---|
| Unit-stride | 4 | `vle8/16/32/64.v` |
| Mask memory | 1 | `vlm.v` |
| Strided | 4 | `vlse8/16/32/64.v` |
| Indexed unordered | 4 | `vluxei8/16/32/64.v` |
| Indexed ordered | 4 | `vloxei8/16/32/64.v` |
| Fault-only-first | 32 | `vle*ff.v` + segment |
| Whole register | 16 | `vl{1,2,4,8}re{8,16,32,64}.v` |
| Segment unit-stride | 28 | `vlseg{2..8}e*.v` |
| Segment strided | 28 | `vlsseg{2..8}e*.v` |
| Segment indexed unordered | 28 | `vluxseg{2..8}ei*.v` |
| Segment indexed ordered | 28 | `vloxseg{2..8}ei*.v` |
| **합계** | **177** | |

`mew=1`(EEW>64), 예약 `lumop`, whole-register의 예약 `nf`, 그리고 같은 opcode를 쓰는
스칼라 FP 로드(`flh`/`flw`/`fld`/`flq`, width 001/010/011/100)는 `illegal_op`으로
보고합니다. 그 거부가 vtype 전 구간에서 유지되는지는 §6.5가 10,332 probe로 확인합니다.

## 2. 메모리 인터페이스

```systemverilog
output mem_req_valid_o;  input  mem_req_ready_i;
output vcore_vld_mem_req_t mem_req_o;   // {addr[31:0], size[2:0], tag[6:0]}
input  mem_rsp_valid_i;  output mem_rsp_ready_o;
input  vcore_vld_mem_rsp_t mem_rsp_i;   // {tag[6:0], data[63:0], error}
```

- `size` = log2(bytes), AXI AxSIZE 호환. 응답 데이터는 스칼라 로드처럼 **하위 바이트 정렬**.
- 요청 단위는 **element-field 하나**입니다. 비-segment면 필드가 1개이므로 원소 하나와 같습니다.
- `tag` = **목적지 슬롯 인덱스** `f*slots_per_field + i`. sequencer가 한 번에 명령어
  하나만 처리하므로 별도 할당 로직 없이 in-flight 전체에서 유일함. 응답 순서는 자유(OoO).
- `cmd`에 `stride`(= `x[rs2]`, strided 형식) 필드가 있고, indexed 형식은 인덱스 벡터를
  VRF 읽기 포트로 가져옵니다(§3.3).
- commit에 `vl_trimmed` / `new_vl`이 있습니다 — fault-only-first가 줄인 `vl`을 호스트가
  CSR에 되돌려 써야 합니다(§3.5).
- `MAX_OUTSTANDING` 파라미터로 in-flight 창 제한. 요청은 1 element/cycle로 발행.
- `busy_o` = 버스가 아직 데이터를 빚지고 있는 동안 high (fence/flush retire 판단용).
  perm 쪽에서 빠져 있다고 지적됐던 신호를 여기는 처음부터 넣었습니다.

## 3. 핵심 설계 결정 — 왜 177개가 한 데이터패스에 들어가는가

클러스터를 형식별로 늘리지 않았습니다. 모든 벡터 로드는 결국 **(원소 i, 필드 f) 쌍을
방문해서 주소 하나와 목적지 슬롯 하나에 대응시키는 것**이고, 형식 사이에서 실제로
달라지는 건 주소뿐입니다.

### 3.1 목적지 쪽은 애초에 공짜였다

원소 i, 필드 f는 **항상** 목적지 슬롯 `f*slots_per_field + i`에 들어갑니다. 그룹 버퍼는
이미 목적지 레지스터 순서로 놓여 있으므로, beat b는 어떤 형식이 채웠든
`[b*VLEN/8, (b+1)*VLEN/8)` 바이트를 잘라내면 됩니다. 그리고 스펙이
`EMUL × NFIELDS ≤ 8`을 요구하므로 **segment를 넣어도 버퍼가 커지지 않습니다** —
1024비트가 이미 정확히 맞는 크기였습니다. 목적지 레지스터 주소도 `vd + beat_index`로
그대로입니다(필드 그룹들이 연속이므로).

### 3.2 주소는 누산기 하나 + 덧셈기 하나

```
acc_q     += stride            원소마다 1회  (unit / mask / whole-reg는 stride가
                                              decode에서 고정, strided는 x[rs2])
elem_addr  = indexed ? base + index[i] : acc_q
addr       = elem_addr + (f << log2(EEW/8))   segment 필드 오프셋
```

**곱셈기도 나눗셈기도 없습니다.** 스캔이 원소 0부터 걸으면서 매 원소 누산기를
진행시키므로, `vstart`가 0이 아닌 재시작은 곱셈기 대신 사이클로 지불합니다.
필드 오프셋·버퍼 바이트 주소·인덱스 레지스터 번호는 전부 시프트입니다(원소 크기와
레지스터당 원소 수가 2의 거듭제곱이므로).

### 3.3 인덱스는 그룹 버퍼가 아니라 레지스터 하나

스캔이 인덱스 원소를 **순서대로** 소비하므로, 현재 원소를 덮는 인덱스 레지스터
**하나만** 살아 있으면 됩니다. `idx_data_q`는 128비트이고 스캔이 레지스터 경계를
넘을 때 다시 읽습니다 — permutation의 `vrgatherei16`이 인덱스를 무작위로 참조해서
1024비트 그룹 버퍼가 필요한 것과 대조적입니다. **896비트 절약.**

### 3.4 ordered indexed는 크레딧 클램프 하나

`vloxei`는 원소 순서 접근을 보장해야 합니다. 미결 창을 1로 조이면 됩니다 —
크레딧 비교의 mux 하나가 전부이고, 메모리 쪽 계약은 건드리지 않습니다.
(`vluxei`는 unordered라 전체 창을 그대로 씁니다. T7이 둘 다 확인합니다.)

### 3.5 fault-only-first는 evl을 깎는다

원소 0 이후의 fault는 버그가 아니라 아키텍처 동작입니다. 엔진은 **에러가 난 가장 낮은
원소**를 기록하고, assemble이 줄어든 `evl`을 보게 하면 그 위 원소들이 자동으로 tail이
됩니다 — 정책 체인에 특수 분기가 필요 없습니다. 비용은 17비트 레지스터 하나와 비교기,
commit의 `vl_trimmed`/`new_vl` 필드입니다. 원소 0에서의 에러는 진짜 trap입니다.

### 3.6 beat 0에서 그룹 전체 fetch (perm의 group buffer와 같은 패턴)

beat 단위로 요청하면 EEW=64일 때 한 beat에 원소가 2개뿐이라 MO 창이 2로 묶입니다.
beat 0에서 목적지 그룹 전체를 요청하면 창이 명령어 크기(최대 128 요청)까지 열리고,
이후 beat은 버스 트래픽이 0입니다.

### 3.7 active element만 요청 — 아키텍처 요구사항

RVV 1.0 §7: loads "only access memory or raise exceptions for **active** elements".
prestart·tail·mask-inactive 원소는 요청하지 않습니다. inactive 원소의 주소는 unmapped
page를 가리켜도 합법이므로, 여분 요청은 데이터가 맞아도 진짜 버그입니다.

### 3.8 flush — 이 클러스터만 리셋으로 끝낼 수 없음

외부 버스가 응답을 빚고 있고 ready를 내리면 deadlock 합니다. `VLD_DRAIN`에서
`inflight_q`가 0이 될 때까지 응답을 받아 버린 뒤에야 idle이 됩니다.

### 3.9 dst_old 읽기 생략

`vld_needs_dst_old()`: unmasked(또는 mask-agnostic)이고 tail-agnostic이고 `vstart=0`이면
모든 슬롯이 새로 써지므로 읽지 않습니다. 로드에서 이건 클러스터의 **유일한 VRF 읽기**라
효과가 큽니다. fault-only-first는 항상 읽습니다(trim이 body를 tail로 바꾸므로).

## 4. 정책 체인 (`vcore_vld_assemble`)

정책은 **슬롯이 아니라 원소 인덱스**로 정합니다. segment 로드에서는 모든 필드가 같은
prestart/body/tail 구분을 보므로, 원소 인덱스는 슬롯에서 필드 번호를 마스크로 떼어낸
값입니다 — `slots_per_field`가 항상 2의 거듭제곱이라 그 마스크는 공짜입니다.


perm과 같은 순서, 로드가 만들 수 있는 3가지 경우로 축약:

| 조건 | 결과 |
|---|---|
| `vstart >= evl` | 아무것도 갱신 안 함 (§5.4, vl=0 포함) |
| `slot < vstart` | prestart → undisturbed |
| `slot >= evl` | tail → `vta ? all-ones : undisturbed` |
| `vm=0 && v0[i]=0` | inactive → `vma ? all-ones : undisturbed` |
| 그 외 | 메모리에서 가져온 값 |

- tail 범위는 §5.4의 `max(VLMAX, VLEN/SEW)` 규칙 그대로 — fractional EMUL이면
  레지스터 1개 안에서 VLMAX 위쪽 슬롯도 tail이므로 agnostic fill 대상입니다.
  (`ctrl.dst_slots = emul_regs * VLEN/EEW`)
- `vlm.v`: EEW=8, EMUL=1, `evl = ceil(vl/8)`, vstart는 **바이트 단위**,
  tail은 **vtype.vta와 무관하게 항상 agnostic** (§7.4). decode에서 vta/vm을 1로 강제.

## 5. Decode 합법성 검사 — log2 표현

EMUL을 **유리수(num/den)가 아니라 log2 지수**로 들고 갑니다. 합법성 규칙이 건드리는
모든 값(LMUL, EEW/SEW, EMUL, VLMAX, 레지스터당 원소 수, 필드당 슬롯 수)이 2의
거듭제곱이기 때문입니다.

```
emul_log2 = log2(EEW/8) - log2(SEW/8) + log2(LMUL)
```

덧셈 하나가 분수 LMUL과 widening/narrowing EEW:SEW 비율을 정확히 합성합니다. 이후는
전부 시프트나 마스크로 떨어집니다:

| 규칙 | log2 형태 |
|---|---|
| `1/8 <= EMUL <= 8` | `-3 <= emul_log2 <= 3` |
| `regs = ceil(EMUL)` | `1 << max(0, emul_log2)` |
| vd 정렬 | `vd & (regs-1)` |
| `nf * regs <= 8` | `nf << regs_log2 <= 8` |
| `EMUL * NFIELDS <= 8` | 위 검사에 **흡수됨** (EMUL≥1이면 같은 식, 분수면 자동 성립) |
| `VLMAX` | `(VLEN/8 >> sew_log2) << lmul_log2` |
| `slots_per_field` | `1 << (regs_log2 + 4 - eew_log2)` |
| `evl` (vlm.v) | `(vl+7) >> 3` |
| stride (unit/segment) | `nf << eew_log2` |

같은 규칙을 유리수로 쓰면 합성에서 **나눗셈기 4개와 곱셈기 8개**가 나옵니다. log2
형태는 0개입니다(§7). 두 형태가 등가라는 것은 인코딩 대조표가 확인합니다 — 기대값을
만드는 Python 모델은 여전히 유리수 산술로 되어 있고, 10,332개 (인코딩, vtype) 쌍에서
양쪽이 일치합니다.

인덱스 오퍼랜드는 자기 EMUL을 가집니다(`iemul_log2 = log2(index EEW/8) - log2(SEW/8)
+ log2(LMUL)`). indexed 로드의 **데이터** EEW는 `width`가 아니라 `vtype.vsew`이고,
`width`는 인덱스 폭을 준다는 점이 다른 모든 형식과 다릅니다.

## 6. 검증 결과

세 벤치가 서로 다른 것을 봅니다.

### `tb_vcore_vld_ref.sv` — golden reference (독립 데이터 표현)

기대 상태를 `exp_vrf[reg][byte]` **바이트 배열**로 메모리 이미지에서 채우고, 목적지를
**스펙이 서술하는 방식**(필드 f는 `vd + f*regs_per_field` 그룹, 원소 i는 레지스터
`i/elems_per_reg`의 바이트 `(i%elems_per_reg)*B`)으로 주소 계산합니다 — DUT의 평탄한
슬롯 산술과 다른 경로라, 슬롯 산술이 틀리면 자기 자신과 합의할 수 없습니다.
합법성도 raw 명령어 필드에서 다시 유도합니다. 매 케이스 **32개 레지스터 전부** 비교.

| sweep | 내용 | 케이스 |
|---|---|---:|
| 1 | unit-stride: EEW(4) × SEW(4) × LMUL(7, 분수 포함) × vl(5) × 정책(4) | 2,240 |
| 2 | `vlm.v`: SEW(4) × LMUL(7) × vl(6) | 168 |
| 3 | strided: EEW × SEW × LMUL × stride(양/비정렬/**0**/**음수**) | 448 |
| 4 | indexed: index EEW × SEW × LMUL × unordered/ordered, 마스크 섞음 | 448 |
| 5 | segment unit-stride: nf=2~8 × EEW × LMUL × 정책 | 168 |
| 6 | segment strided + segment indexed: nf{2,3,8} × EEW × LMUL | 48 |
| 7 | whole-register: NREG{1,2,4,8} × EEW × vstart, **vtype 일부러 불일치** | 32 |
| 8 | fault-only-first: fault 위치{0,1,2,5,없음} × EEW × nf{1,3} | 40 |
| 9 | illegal 인코딩 22종 | 22 |
| 10 | 합법 경계 8종 | 8 |

```
REF TOTAL: 3398 cases, 3398 passed, 0 failed
REF MIX  : 2679 executed, 719 rejected as illegal, 16 vl-trimmed, 8 trapped
```

`REF MIX`는 sweep이 공허하지 않다는 확인입니다 — 2,679개가 실제로 실행되고, 719개는
그 vtype에서 진짜로 불법이며, fof 40케이스 중 16개가 trim, 8개가 trap입니다(원소 0
fault = 4 EEW × 2 nf). ideal과 stress(랜덤 ready, 레이턴시 0~7 랜덤, **응답 순서
무작위**, VRF/commit 랜덤 stall) 양쪽에서 동일.

### `tb_vcore_vld_top.sv` — directed (데이터 비교로는 안 잡히는 것들)

```
TOTAL: 26 passed, 0 failed
```

- **T1** 메모리 요청 **집합**이 정확히 active element와 일치 — 9케이스:
  masked unit-stride / prestart / tail / `vstart>=vl` / `vlm.v` / 예약 인코딩 /
  **strided 음수 stride 주소** / **indexed 인덱스 벡터 주소** / **segment 필드별 주소**
- **T2** in-flight 상태 flush → drain, `busy_o` 하강, 이후 정상 동작
- **T3** bus error → VRF 미기록 + `mem_error`
- **T4** `busy_o`가 in-flight 구간을 빠짐없이 덮음
- **T5** issue FIFO 연속 3개 발행
- **T6** MO 효과 (64-element, EEW=8, LMUL=4)
- **T7** **ordered indexed는 in-flight가 절대 2가 되지 않음** + 수집 결과 정확,
  unordered는 전체 창 사용
- **T8** **fault-only-first**: trim 보고(`new_vl=2`), trap 아님, trim 아래는 로드되고
  위는 tail로 전환, **원소 0 fault는 trim이 아니라 trap**
- **T9** **whole-register가 vtype·vl·v0를 전부 무시** (일부러 불일치시킨 vtype,
  `vl=1`, all-zero 마스크로 4개 레지스터 전부 로드)

| MAX_OUTSTANDING | LAT=6 | LAT=20 |
|---|---|---|
| 1 | 539 cy | 1435 cy |
| 8 | **98 cy** | **210 cy** |

### Lint
`verilator --lint-only -Wall -Wno-UNUSEDSIGNAL` clean (RTL 9개 파일 전부).

### 전체 회귀 요약

| 테스트 | 케이스 | 결과 |
|---|---:|---|
| `tb_vcore_vld_ref` (ideal) | 3,398 | 전부 통과 |
| `tb_vcore_vld_ref` (stress) | 3,398 | 전부 통과 |
| `tb_vcore_vld_top` (directed) | 26 | 전부 통과 |
| `tb_vcore_vld_decode_table` | 10,332 | 전부 통과 |

## 6.5 공식 인코딩 체크리스트 (`tb_vcore_vld_decode_table`)

ALU 쪽 `generate_checklist.py` / `verify_decode_table.py` /
`tb_vcore_alu_decode_table.sv`와 같은 장치입니다.

| 파일 | 역할 |
|---|---|
| `generate_load_checklist.py` | 고정 커밋(`f5befa2`)의 공식 `rv_v`에서 LOAD-FP(0x07) 인코딩 추출, `nf` 가변 행을 segment 변형으로 전개 → **177개**. CSV + PROGRESS.md 생성 |
| `verify_load_decode_table.py` | 각 행 × vtype에서 기대 accept/reject를 **RVV 합법성 규칙의 Python 모델**로 계산 |
| `tb_vcore_vld_decode_table.sv` | 전부 `vcore_vld_decode`에 넣고 `illegal` 출력을 대조 |
| `dectab.sh` | 위 셋을 순서대로 실행 |

**177은 교차 검증된 숫자입니다** — 공식 opcode 파일에서 유도한 니모닉 집합이 저장소
명령어 카탈로그(`outputs/rvv_instruction_20260916`)의 Load 행 177개와 정확히 일치
(양쪽 차집합 모두 공집합).

검사 그룹 2개, 총 **10,332 probe**:

1. 177개 인코딩 × SEW(4) × LMUL(7) × `vm`(2) = 9,912.
   기대값은 Python 합법성 모델이 계산합니다. `vlm.v`와 whole-register는 인코딩이
   `vm=1`을 고정하므로 `vm=0` pass에서 예약 인코딩이 됩니다.
2. 예약·외부 인코딩(`mew=1`, 예약 lumop 6종, 스칼라 FP 로드 4종, whole-register 예약
   `nf` 3종) × 같은 vtype 공간 = 420. 전부 거부.

```
tb_vcore_vld_decode_table: 10332 probes, 5353 accepted, 4979 rejected, 0 failed
```

각 probe는 세 가지를 같이 봅니다: `illegal`이 기대와 일치, accept된 행은 `beats != 0`,
reject된 행은 `ctrl.op`가 `VLDOP_INVALID`로 남아 죽은 opcode를 흘리지 않음.

**역할 분담.** 이 표의 Python 모델은 디코더와 같은 손으로 썼으므로 독립 oracle이
아니라 **커버리지 도구**입니다 — 데이터 벤치가 못 훑는 인코딩 공간 전체를 훑습니다.
합법성에 대한 독립 검증은 `tb_vcore_vld_ref`가 따로 쓴 SystemVerilog 모델로 실제
레지스터 내용을 비교하며 수행합니다. 덧붙여, 이 표는 §5의 log2 재작성이 원래 유리수
형태와 등가임을 10,332쌍에서 확인하는 역할도 합니다.

## 7. 하드웨어 비용

`sv2v` + `yosys 0.33` (`proc; opt -fast`) 기준 generic cell 수입니다. **표준셀 면적이
아니라 RTL 구조 지표**입니다 — 합성 라이브러리·STA 없이는 면적을 주장하지 않습니다.
비교 대상은 같은 저장소의 이전 버전(unit-stride + `vlm.v`, 5개 인코딩)입니다.

| | 이전 (5개) | 현재 (177개) | 차이 |
|---|---:|---:|---|
| `vcore_vld_decode` cells | 103 | 201 | +98 |
| &nbsp;&nbsp;나눗셈기 `$div` | 3 | **0** | −3 |
| &nbsp;&nbsp;나머지 `$mod` | 1 | **0** | −1 |
| &nbsp;&nbsp;곱셈기 `$mul` | 3 | **0** | −3 |
| `vcore_vld_memreq` cells | 278 | 407 | +129 |
| &nbsp;&nbsp;곱셈기 `$mul` | 2 | **0** | −2 |
| &nbsp;&nbsp;나눗셈기 `$div` | 0 | 0 | — |
| `vcore_vld_memreq` 플립플롭 | 1,577 b | 1,850 b | **+273 b (+17%)** |

**인코딩 커버리지는 35배가 됐는데 곱셈기와 나눗셈기는 오히려 전부 사라졌습니다.**
이전 버전이 주소·버퍼 경로에 곱셈기 2개, 합법성 검사에 나눗셈기 3개/나머지 1개/곱셈기
3개를 갖고 있었고, 지금은 0개입니다(§3.2, §5).

> **정정 (스토어 클러스터 작업 중 발견).** 위 표는 `decode`와 `memreq`만 잰
> 것이었습니다. `vcore_vld_sequencer`에 곱셈기 1개와 나눗셈기 1개가 남아
> 있었습니다 — `beat_index * (VLEN / EEW)`. `VLEN/EEW`는 항상 2의 거듭제곱이므로
> `beat_index << log2(VLEN/EEW)`로 바꿨습니다. 스토어 시퀀서에도 같은 결함이
> 있었고 함께 고쳤습니다. 지금은 **클러스터 전체에 `$mul`/`$div`/`$mod` 0개**입니다.

클러스터 전체를 같은 방식으로 다시 잰 값입니다.

| 모듈 | cells | 플롭 비트 |
|---|---:|---:|
| `vcore_vld_decode` | 201 | 0 (조합) |
| `vcore_vld_memreq` | 406 | 1,850 |
| `vcore_vld_sequencer` | 49 | 348 |
| `vcore_vld_assemble` | 1,923 | 0 (조합) |
| `vcore_vld_pipe` | 23 | 171 |
| `vcore_vld_wb` | 50 | 174 |
| `vcore_vld_issue_fifo` | 35 | 6 + 엔트리 메모리 |
| **합계** | **2,687** | **2,549** |

`vcore_vld_assemble`이 1,923 cells로 클러스터의 72%입니다. tail / prestart /
mask-agnostic 정책을 목적지 바이트마다 고르는 멀티플렉서 밭인데, 스토어 클러스터는
목적지가 없어 이 단이 아예 없습니다 — 그래서 스토어 전체가 592 cells입니다.

추가된 플립플롭 273비트의 내역:

| 레지스터 | 비트 | 용도 |
|---|---:|---|
| `idx_data_q` | 128 | 살아 있는 인덱스 레지스터 1개 (그룹 버퍼 대신, §3.3) |
| `uop_q.ctrl` 확장 | 67 | nf / stride / idx_eew / ordered / slots_per_field 등 |
| `acc_q` | 32 | 주소 누산기 (곱셈기 대신, §3.2) |
| `slot_base_q`, `trim_vl_q` | 34 | 필드 슬롯 오프셋 누산, fof trim 값 |
| `fld_q`, `idx_reg_have_q` | 8 | 필드 카운터, 현재 인덱스 레지스터 번호 |
| 플래그 4개 | 4 | `idx_valid_q`, `trim_valid_q`, `vrd_for_idx_q`, `dst_done_q` |

**1024비트 그룹 버퍼는 그대로입니다.** 이 클러스터에서 가장 큰 저장소인데,
segment를 넣어도 커지지 않았습니다 — 스펙의 `EMUL × NFIELDS <= 8` 덕분에 목적지
그룹이 8개 레지스터를 넘지 않고, 버퍼는 이미 정확히 그 크기였습니다(§3.1).

## 8. 알려진 한계 / 다음 단계 (주의사항)

1. **요청 coalescing이 없습니다.** unit-stride인데도 element-field당 요청 1개를 냅니다 —
   16바이트 로드가 1바이트 요청 16개. 64비트 버스라면 요청 2개로 끝날 일이므로,
   캐시에 붙이기 전에 반드시 해야 합니다. `memreq`의 스캔 루프와 태그 의미(슬롯 →
   요청 번호)를 바꾸고 응답을 여러 슬롯에 분배하는 작업입니다. segment와 indexed는
   주소가 흩어지므로 coalescing 대상이 아니고, unit-stride/strided(작은 stride)가
   대상입니다.
2. **요청 발행이 1 element-field/클록.** inactive 원소를 건너뛸 때도 1사이클씩 쓰고,
   segment는 필드당 1사이클입니다. mask가 희소하거나 nf가 크면 스캔이 병목입니다
   (priority encoder / 필드 병렬 발행으로 개선 가능).
3. **ordered indexed(`vloxei`)는 미결 1개로 직렬화**됩니다. 메모리 쪽이 순서를
   보장해 준다면 이 클램프를 풀 수 있지만, 그건 버스 계약 변경입니다.
4. **fault-only-first는 메모리가 trap 대신 `error` 응답을 준다고 가정**합니다.
   RVV는 fof에서 첫 원소 외의 접근이 trap하지 않기를 요구하므로 이게 맞는 계약이지만,
   붙이는 메모리 시스템이 그렇게 동작하는지 확인해야 합니다.
5. **비정렬 원소 접근**을 메모리 포트가 지원한다고 가정 (`base=67`, stride=3 케이스로
   테스트). 못 하면 호스트가 정렬을 보장하거나 misaligned trap 경로가 필요합니다.
6. **VRF 읽기 포트의 flush**는 perm과 같은 가정(같은 flush가 VRF 아비터에도 도달)에
   의존합니다. 메모리 쪽만 `VLD_DRAIN`으로 제대로 처리합니다.
7. **VLEN=128 고정** — `mask_snapshot` 폭이 패키지에 박혀 있습니다.
8. **Store는 통째로 없습니다** (133개 인코딩). Load와 대칭이지만 VRF 읽기가 늘고
   메모리 쓰기 순서 제약이 생깁니다.
