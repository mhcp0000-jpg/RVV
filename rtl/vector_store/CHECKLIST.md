# vcore_vst — 벡터 STORE 클러스터

RVV 1.0 벡터 스토어 **133개 인코딩 전체**를 하나의 데이터패스로 처리하는 클러스터입니다.
로드 클러스터(`rtl/vector_load`)와 같은 구조 — decode → issue FIFO → sequencer →
memreq → wb — 를 따르되, **6단이 아니라 5단**입니다. assemble 단과 결과 래치가 없습니다.
계산하는 것이 없고 벡터 레지스터에 쓰는 것도 없기 때문입니다.

```
cmd ─▶ decode ─▶ issue FIFO ─▶ sequencer ─▶ memreq ─▶ wb ─▶ commit
                                    ▲           │
                                    └─ beat ack ┘
                                                │
                     VRF read port ◀────────────┤  (vs3 그룹 + 인덱스 레지스터)
                     mem write     ◀────────────┘  (태그 있는 out-of-order)
```

> **상태: 133개 인코딩 전부 디코드 + 실행 검증 완료.** 디코더는 인코딩 × vtype
> 공간 전체(7,980 probe)에서, 데이터패스는 golden reference 2,369 케이스 ×
> 6개 설정 = **14,214 케이스런**에서 대조됩니다. 체크리스트의 `execute` 133/133은
> 손으로 적은 값이 아니라 참조 벤치가 실제로 실행한 인코딩 로그에서 생성됩니다(§6).

---

## 1. 로드와 무엇이 같고 무엇이 다른가

같은 것: 주소 규칙, (element, field) → slot 매핑, 레지스터 순서로 놓인 그룹 버퍼,
log2 합법성 산술, 태그 있는 out-of-order 메모리 인터페이스, flush 드레인.

다른 것 6가지 — 이것들이 설계를 결정합니다.

| # | 차이 | 결과 |
|---|---|---|
| 1 | **데이터가 반대로 흐른다.** 그룹 버퍼를 VRF *읽기*가 채우고 메모리 *쓰기*가 비운다 | 스토어는 벡터 레지스터를 최대 8개 읽는다. 로드는 많아야 1개(dst_old). 공유 1R1W VRF에서 **이 클러스터의 지배적 비용**이고 로드와 정반대 프로파일 |
| 2 | **목적지 레지스터가 없다** | tail / prestart / mask-agnostic 정책 체인이 통째로 사라진다. `vta`, `vma`가 ctrl에 없고 dst_old 읽기도 없다. prestart·tail·inactive 원소는 그냥 메모리에 쓰지 않는다 |
| 3 | **응답에 데이터가 없다** — ack + error 비트뿐 | 그래도 모든 ack를 기다린 뒤 retire한다. 호스트가 쓰기 수락을 알아야 하고, flush가 드레인할 대상이 있어야 하기 때문 |
| 4 | **fault-only-first가 없다** | vl을 깎는 경로가 없다. 로드보다 인코딩이 32개 적은 이유(177 → 133) |
| 5 | **§5.3 v0 오버랩 규칙이 적용되지 않는다** | 스토어에는 벡터 목적지가 없다. `vs3 = v0`인 마스크 스토어는 **합법**. 인덱스 세그먼트 스토어의 목적지/인덱스 오버랩 규칙도 없다 (vs2, vs3 둘 다 소스) |
| 6 | **원소 순서가 의미를 가진다** | 한 스토어 안의 원소 접근은 RVWMO상 unordered — `vsoxei` 제외. 두 원소가 **같은 주소**를 노릴 때(stride 0, 중복 인덱스) 결과는 ordered 형태에서만 정의된다. 설계 제약이자 **검증 제약**이다 |

6번이 golden reference를 아직 못 쓴 이유입니다. 참조 모델은 unordered 스토어의
주소 충돌을 예측할 수 없으므로, 스윕 생성기가 **주소 중복을 구조적으로 배제**해야
합니다 (stride ≠ 0, 인덱스 벡터 중복 제거). `vsoxei`만 last-writer가 정의됩니다.

---

## 2. 지원 범위 — 133개 인코딩

| 연산군 | 인코딩 수 | 디코드 |
|---|---:|---:|
| Unit-stride (`vse8/16/32/64.v`) | 4 | 4 |
| Segment unit-stride (`vsseg2..8eN.v`) | 28 | 28 |
| Strided (`vsse8/16/32/64.v`) | 4 | 4 |
| Segment strided (`vssseg2..8eN.v`) | 28 | 28 |
| Indexed unordered (`vsuxeiN.v`) | 4 | 4 |
| Segment indexed unordered (`vsuxseg2..8eiN.v`) | 28 | 28 |
| Indexed ordered (`vsoxeiN.v`) | 4 | 4 |
| Segment indexed ordered (`vsoxseg2..8eiN.v`) | 28 | 28 |
| Mask (`vsm.v`) | 1 | 1 |
| Whole register (`vs1r.v`..`vs8r.v` 중 4종) | 4 | 4 |
| **합계** | **133** | **133** |

인코딩 집합은 공식 `rv_v` opcode 파일에서 뽑고 `nf` 가변 행을 RVV 1.0이 이름을 주는
segment 변형으로 전개해 얻었습니다. 저장소의 명령어 카탈로그 xlsx Store 행과
**양방향 집합 차집합이 모두 공집합**입니다.

로드와 달리 whole-register는 EEW별 4종이 아니라 **레지스터 수별 4종**입니다
(`width`가 000 고정, EEW=8). `vs1r/vs2r/vs4r/vs8r`.

---

## 3. 메모리 인터페이스 계약

```systemverilog
typedef struct packed {
  logic [31:0] addr;   // 바이트 주소, EEW 정렬됨
  logic [2:0]  size;   // log2(바이트 수): 0=1B, 1=2B, 2=4B, 3=8B
  logic [63:0] data;   // LSB 정렬. 상위 바이트는 무효
  logic [6:0]  tag;    // slot 인덱스. 응답이 이걸 그대로 돌려준다
} vcore_vst_mem_req_t;

typedef struct packed {
  logic [6:0] tag;
  logic       error;
} vcore_vst_mem_rsp_t;
```

로드와 같은 규칙입니다:

* **요청 하나 = 원소 하나** (세그먼트는 필드 하나). 클러스터가 합치지 않습니다.
* **태그는 slot 인덱스**, 응답은 **아무 순서로나** 와도 됩니다.
* **active 원소에 대해서만** 요청이 나갑니다 — prestart, tail, mask-inactive 원소는
  버스에 아예 나타나지 않습니다. RVV 1.0 §7의 요구사항입니다.
* `mem_rsp_ready_o`는 미결 요청이 있을 때만 1입니다.
* `ordered`(`vsoxei`, `vsoxseg`)는 크레딧 윈도를 **1로 클램프**합니다 — 별도 로직 없음.

로드와 다른 점: 응답에 페이로드가 없습니다. 클러스터는 ack를 **세기만** 합니다.

---

## 4. 핵심 설계 결정

### 4.1 VRF 읽기 포트 하나로 vs3 그룹과 인덱스를 모두 가져온다

`vcore_vst_memreq`의 상태 기계:

```
VST_IDLE → VST_READ_REQ ⇄ VST_READ_RSP → VST_SCAN → VST_DONE
                                             ↑ (인덱스 필요 시 재진입)
                                          VST_DRAIN  (flush)
```

`VST_READ_REQ`/`VST_READ_RSP`가 `vs3 + beat` 를 beat마다 한 레지스터씩 읽어
`byte_q[beat*VLEN +: VLEN]` 에 넣습니다. `last_beat`에 `VST_SCAN`으로 갑니다.
스캔 중에 인덱스 레지스터가 필요해지면 **같은 포트**를 다시 씁니다:

```systemverilog
assign vrf_req_valid_o = (state_q == VST_READ_REQ) ||
                         ((state_q == VST_SCAN) && idx_fetch_want && !idx_pending_q);
assign vrf_req_o.addr  = (state_q == VST_SCAN)
                       ? 5'(int'(uop_q.ctrl.idx_addr) + int'(idx_reg_need))
                       : uop_q.ctrl.vs3_addr;
assign vrf_rsp_ready_o = (state_q == VST_READ_RSP) ||
                         ((state_q == VST_SCAN) && idx_pending_q);
```

포트 선택과 ready를 **상태**로 뽑는 것이 중요합니다. 초기 구현은 `rd_for_idx_q`
레지스터로 골랐는데, 요청을 내보내는 그 사이클에는 아직 0이라 vs3를 읽었습니다.
ready도 `VST_READ_RSP`에서만 1이라 스캔 중 인덱스 응답이 영영 수락되지 않아
**데드락**이 났습니다. 스모크 테스트가 잡은 실제 버그 2개입니다 (§6).

### 4.2 스토어 데이터는 버퍼에서 바이트 단위로 뽑는다

곱셈기 없이, 시프트와 모듈로 마스크만으로:

```systemverilog
always_comb begin
  mem_req_o.data = '0;
  for (int b = 0; b < 8; b++)
    if (b < int'(eew_bytes_c))
      mem_req_o.data[b*8 +: 8] =
        byte_q[((((int'(32'(cur_slot) << eew_log2_c))) + b) % MAX_BYTES)*8 +: 8];
end
```

`byte_q`는 packed 벡터입니다. unpacked 배열이면 Verilator의 `BLKLOOPINIT`에
걸립니다 (로드에서 이미 겪음).

### 4.3 주소 — 로드와 동일

누산기 하나(`acc += stride`) + 덧셈기 하나. 세그먼트 필드 오프셋은
`fld << eew_log2`. 인덱스 형태는 `base + idx_value`. 곱셈기/나눗셈기 **0개**.

### 4.4 wb 단에 VRF 쓰기 포트가 아예 없다

`vcore_vst_wb.sv`는 commit 핸드셰이크와 error 집계만 합니다. TOP 아비터 입장에서
스토어 클러스터는 **읽기 포트만** 다툽니다 — 대신 세게 다툽니다 (명령어당 최대 8 레지스터).
1R1W VRF에서 permutation 클러스터와 정면으로 부딪히는 지점입니다.

---

## 5. Decode 합법성 — 로드에서 빼는 것

로드와 같은 log2 산술입니다:

```
emul_log2 = log2(EEW/8) − log2(SEW/8) + log2(LMUL)
legal     ⟺ −3 ≤ emul_log2 ≤ 3
regs      = 1 << max(0, emul_log2)
EMUL × NFIELDS ≤ 8  ⟺  레지스터 예산 검사
```

인덱스 스토어는 **데이터 EEW = vtype.vsew**, `width`는 **인덱스** EEW입니다.

스토어에서 **빠지는** 검사 2개:

* §5.3 목적지 v0 오버랩 — 목적지가 없으므로 해당 없음
* 인덱스/목적지 오버랩 — vs2, vs3 둘 다 소스이므로 해당 없음

추가되는 검사: whole-register는 `width == 3'b000`이어야 합니다.

---

## 6. 검증 결과

### `tb_vcore_vst_ref` — golden reference (독립 데이터 표현)

```
STRESS=0  MAX_OUT=8   2369 cases, 2369 passed, 0 failed   (peak inflight 2)
STRESS=1  MAX_OUT=1   2369 cases, 2369 passed, 0 failed   (peak inflight 1)
STRESS=1  MAX_OUT=2   2369 cases, 2369 passed, 0 failed   (peak inflight 2)
STRESS=1  MAX_OUT=4   2369 cases, 2369 passed, 0 failed   (peak inflight 4)
STRESS=1  MAX_OUT=8   2369 cases, 2369 passed, 0 failed   (peak inflight 8)
STRESS=1  MAX_OUT=16  2369 cases, 2369 passed, 0 failed   (peak inflight 8)
                      ─────────────────────────────────
                      14,214 케이스런, 0 실패
MIX: 1,899 실행 · 470 불법 거부 · 24 트랩 · 97 이미지 예측불가
     11,576 메모리 쓰기 · 5,617 VRF 읽기 · flush 15건 드레인/복구
```

참조 모델은 **DUT와 다른 데이터 표현**을 씁니다. 기대 상태는 바이트 이미지
`exp_mem[]`이고 소스는 스펙의 표현 그대로 — 필드 f의 원소 i는 레지스터
`vs3 + f*regs + i/epr` 의 바이트 `(i%epr)*B` — 로 주소를 계산합니다. DUT는 packed
그룹 버퍼와 flat slot 산술을 씁니다. 합법성도 raw 인스트럭션 필드에서 다시
유도합니다. 그래서 slot 산술의 실수가 자기 자신과 일치할 수 없습니다.

**매 케이스마다 메모리 이미지 8,192바이트 전체를 비교합니다.** 잘못된 주소로 나간
요청, 비활성 원소를 쓴 요청, 빠진 요청이 전부 걸립니다.

`STRESS=1`은 랜덤 ready, 랜덤 1~8사이클 지연, 순서 뒤섞인 ack, VRF 읽기 스톨을
겁니다. `MAX_OUT`을 1부터 16까지 훑는 것은 크레딧 윈도와 ordered 클램프가 윈도
크기와 무관하게 성립하는지 보기 위해서입니다.

**스윕 구성**

| # | 내용 | 비고 |
|---|---|---|
| 1 | unit-stride: EEW × SEW × LMUL × vl × (mask, vstart) | 560 |
| 2 | `vsm.v`: SEW × LMUL × vl 경계 (7, 8, 9 비트) | 168 |
| 3 | strided: stride = eb / 3 / 0 / −eb | 448 |
| 4 | indexed unordered·ordered: EEW × SEW × LMUL | 224 |
| 5 | segment unit-stride: nf 2..8 × EEW × LMUL | 168 |
| 6 | segment strided·unordered·ordered: nf 2..8 × EEW × LMUL | 168 |
| 7 | whole-register: nreg 1/2/4/8 × vstart(0, 3, evl 초과) | 12 |
| 8 | 폴트: 원소 0/1/3에서 트랩 + 무폴트 | 32 |
| 9 | 불법 인코딩 20종 | 20 |
| 10 | 합법 경계 8종 (스토어에 **없는** 규칙 포함) | 8 |
| 11 | scan 도중 flush → 드레인 → 복구 | 16 |

### `execute` 열은 주장이 아니라 로그입니다

참조 벤치는 **합법으로 판정되고 끝까지 통과한** 인코딩을 매번
`exec_coverage.txt`에 기록합니다. `generate_store_checklist.py`가 그 로그를 읽어
`execute` 열을 채웁니다. 로그가 없으면 execute는 전부 `no`가 됩니다.

```
covered: 133 of 133   (missing: 없음, unexpected: 없음)
```

### `tb_vcore_vst_decode_table` — 공식 인코딩 대조

```
7980 probes, 4041 accepted, 3939 rejected, 0 failed
```

133개 인코딩 × vtype 전 구간(SEW × LMUL × 정렬)을 공식 opcode 파일에서 생성한
기대값과 대조합니다. 예약 인코딩은 거부되어야 하고 실제로 거부됩니다.

### `tb_vcore_vst_smoke` — directed 9개

```
SMOKE TOTAL: 9 passed, 0 failed (66 writes, peak inflight 6)
```

### 프로토콜 어서션 (참조 벤치 안에서 상시)

* 스톨 중 `mem_req` / `commit` / `vrf_read_req` 안정
* 미결 요청이 없는데 ack가 오지 않을 것
* 미결 쓰기가 있는 동안 `busy_o`는 1
* `req_fire` 시점에 `inflight_q < credit_limit` (윈도 오버플로)
* ordered 스토어는 `req_fire` 시점에 `inflight_q == 0` (원소 순서 유지)
* **last_beat commit 시점에 미결 쓰기 0** — 호스트가 커밋하기 전에 모든 쓰기가
  수락돼 있어야 합니다

### Lint

7개 RTL 모듈 전부 `verilator --lint-only -Wall -Wno-UNUSEDSIGNAL` 클린.

### 검증이 찾아낸 것

| 단계 | 결함 | 고친 내용 |
|---|---|---|
| 스모크 | 스캔 중 인덱스 레지스터 읽기의 `vrf_rsp_ready_o`가 0 → **데드락** (indexed / `vsm.v` / `vs2r.v` 쓰기 0건) | ready를 상태로 뽑음 |
| 스모크 | 읽기 포트 주소 mux를 `rd_for_idx_q`로 선택 → 요청 사이클엔 아직 0이라 인덱스 대신 **vs3를 읽음** | mux를 상태로 뽑고 `idx_pending_q`로 개명 |
| 참조(MAX_OUT=1) | ordered 어서션 `inflight_q <= 1`이 `INFLIGHT_W`가 1일 때 항상 참 (Verilator `CMPCONST`) | `req_fire` 시점 `inflight_q == 0`으로 재표현 |
| 참조(flush) | (벤치 쪽) VRF 포트 모델이 flush에 리셋되지 않아 응답이 고립 | 아래 **TOP 요구사항** 참조 |
| 합성 | `vcore_vst_sequencer`에 `$mul` 1개 + `$div` 1개 (`beat * (VLEN/EEW)`) | `beat << log2(VLEN/EEW)`. **로드 클러스터에도 같은 결함이 있어 같이 고쳤습니다** |

**TOP 요구사항 하나가 여기서 드러났습니다.** 이 클러스터는 flush 시
`vrf_rsp_ready_o`를 내리고, 이미 공중에 떠 있던 VRF 읽기 응답을 수거하지 않습니다.
따라서 **TOP의 VRF 읽기 아비터도 같은 flush로 함께 리셋되어야 합니다.** 그렇지
않으면 그 응답이 영원히 고립되고 다음 명령어가 소스 레지스터를 못 받습니다.
로드 클러스터도 구조가 같습니다.

## 7. 하드웨어 비용

`sv2v` + `yosys 0.33` (`proc; opt -fast`) 기준 generic cell / 플립플롭 비트입니다.
**표준셀 면적이 아니라 RTL 구조 지표**입니다 — 합성 라이브러리·STA 없이는 면적을
주장하지 않습니다.

| 모듈 | cells | 플롭 비트 |
|---|---:|---:|
| `vcore_vst_decode` | 186 | 0 (조합) |
| `vcore_vst_memreq` | 286 | 1,699 |
| `vcore_vst_sequencer` | 49 | 346 |
| `vcore_vst_wb` | 36 | 22 |
| `vcore_vst_issue_fifo` | 35 | 6 + 엔트리 메모리 |
| **합계** | **592** | **2,073** |

곱셈기 `$mul`, 나눗셈기 `$div`, 나머지 `$mod`: **전부 0개**. 주소는 누산기 하나,
슬롯·필드 오프셋은 시프트, 합법성은 log2 산술입니다(§4.3, §5).

같은 방식으로 잰 로드 클러스터와의 비교:

| | LOAD (177개) | STORE (133개) |
|---|---:|---:|
| cells 합계 | 2,687 | **592** |
| 플롭 비트 합계 | 2,549 | 2,073 |
| `$mul` / `$div` / `$mod` | 0 / 0 / 0 | 0 / 0 / 0 |

스토어가 로드의 **22%**인 이유는 한 모듈에 있습니다: `vcore_vld_assemble`이 혼자
1,923 cells입니다. tail / prestart / mask-agnostic 정책을 목적지 바이트마다 고르는
멀티플렉서 밭인데, 스토어에는 목적지가 없어서 그 단이 통째로 존재하지 않습니다(§1의 2번).
그룹 버퍼 1,024비트는 양쪽 다 같습니다.

## 8. 알려진 한계 / 다음 단계 (주의사항)

1. **요청 병합(coalescing)이 없다.** unit-stride 스토어가 원소마다 요청을 하나씩
   냅니다. `vse8.v` vl=16이면 1바이트 쓰기 16개가 나갑니다. 캐시에 붙이기 전에
   해야 합니다 — 로드 CHECKLIST §8 1번과 같은 항목이고, 둘이 같은 병합기를 쓰는
   것이 맞습니다.
2. **TOP의 VRF 읽기 아비터가 flush를 함께 받아야 한다.** §6에서 나온 요구사항입니다.
   이 클러스터는 flush 시 `vrf_rsp_ready_o`를 내리고 공중의 응답을 수거하지
   않으므로, 아비터가 같이 리셋되지 않으면 그 응답이 고립됩니다. 로드도 같습니다.
3. **TOP 통합이 안 됐다.** 읽기 포트 아비터에 스토어를 넣어야 하는데, 스토어는
   명령어당 최대 8 레지스터를 읽습니다(§1의 1번) — permutation과 정면으로 부딪히는
   지점이라 아비터 정책을 정해야 합니다. `VCORE_ARCHITECTURE.html` §1 상태 표와
   §10 6번(Store)도 갱신 대상입니다.
4. **예외 보고가 플래그 하나뿐.** `mem_error`는 집계되지만 어느 원소에서 났는지,
   호스트의 pre-commit fault check(Saturn 방식)에 무엇을 넘겨야 하는지는 정하지
   않았습니다. 로드의 fault-only-first처럼 원소 인덱스를 들고 있어야 할 수도
   있습니다. 참조 벤치의 폴트 스윕도 **플래그만** 검사합니다 — 트랩한 스토어의
   메모리 이미지는 이미 수락된 쓰기가 남아 있어 정의되지 않기 때문입니다.
5. **unordered 중복 주소는 검증할 수 없다 — 원리상.** 참조 벤치 2,369 케이스 중
   97건이 여기 해당해서 이미지 비교를 건너뜁니다(플래그·프로토콜·타임아웃은 여전히
   검사). stride 0, stride < 원소 크기, 중복 인덱스가 그 경우입니다. 아키텍처가
   답을 정의하지 않으므로 이건 구멍이 아니라 경계입니다 — `vsoxei`만 정의되고,
   그쪽은 전부 비교합니다.
6. **`vstart`가 세그먼트 중간을 가리키는 경우가 스펙상 모호하다.** 현재 구현은
   `vstart`를 원소 단위로만 봅니다(필드 중간에서 재개하지 않음). RVV 1.0은 세그먼트
   스토어의 트랩 후 재개를 원소 경계로 규정하므로 맞지만, 호스트가 필드 중간
   `vstart`를 넣으면 어떻게 되는지는 문서화되지 않았습니다.
