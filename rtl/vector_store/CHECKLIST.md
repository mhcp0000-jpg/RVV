# vcore_vst — 벡터 STORE 클러스터 (프레임)

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

> **상태: 프레임입니다.** 디코더는 인코딩 × vtype 공간 전체에서 검증되었고
> (7,980 probe) 데이터패스는 9개 directed 스모크를 통과합니다. 그러나
> **golden reference 스윕이 아직 없습니다** — 체크리스트의 `execute`는 0/133입니다.
> 로드 클러스터가 3,398 케이스 참조 모델로 검증된 것과 대비됩니다.

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

### `tb_vcore_vst_decode_table` — 공식 인코딩 대조

```
7980 probes, 4041 accepted, 3939 rejected, 0 failed
PASS
```

133개 인코딩 × vtype 전 구간(SEW × LMUL × 정렬)을 공식 opcode 파일에서 생성한
기대값과 대조합니다. 예약 인코딩은 거부되어야 하고 실제로 거부됩니다.

### `tb_vcore_vst_smoke` — directed 9개

```
PASS vse32.v unmasked
PASS vse32.v masked writes only active elements
PASS vse32.v vstart skips prestart, LMUL=2 spans two registers
PASS vsse32.v negative stride
PASS vsseg3e32.v interleaves three fields
PASS vsuxei32.v gathers addresses from the index vector
PASS vsm.v stores ceil(vl/8) bytes
PASS vs2r.v stores two whole registers regardless of vtype
PASS reserved sumop: illegal_op and no memory traffic
SMOKE TOTAL: 9 passed, 0 failed (66 writes, peak inflight 6)
```

기대값은 flat slot 산술이 아니라 **스펙의 레지스터/바이트 표현**으로 따로 만듭니다
(`expect_store()`), RTL과 같은 실수를 반복하지 않기 위해서입니다.

**이 스모크가 실제 RTL 버그 2개를 잡았습니다** (§4.1):

1. `vrf_rsp_ready_o`가 `VST_READ_RSP`에서만 1 → 스캔 중 인덱스 레지스터 읽기가
   영영 수락되지 않아 **데드락**. indexed / `vsm.v` / `vs2r.v` 케이스가 쓰기 0건.
2. `vrf_req_o.addr` 멀티플렉서를 `rd_for_idx_q`로 골랐는데 요청 사이클엔 아직 0 →
   인덱스 레지스터 대신 **vs3를 읽음**.

둘 다 상태로 멀티플렉싱하도록 고치고 `rd_for_idx_q` → `idx_pending_q`로 이름을
바꿨습니다.

### Lint

7개 RTL 모듈 전부 `verilator --lint-only -Wall -Wno-UNUSEDSIGNAL` 클린.

---

## 7. 알려진 한계 / 다음 단계

1. **golden reference 스윕이 없다 — 가장 큰 구멍.** `tb_vcore_vst_ref.sv`가 있어야
   `execute`가 0/133 → 133/133이 됩니다. 생성기는 unordered 형태에서 **주소 중복을
   배제**해야 합니다 (§1의 6번): stride ≠ 0, 인덱스 벡터 중복 제거. `vsoxei`만
   last-writer 의미가 정의되므로 중복 주소를 허용할 수 있습니다.
2. **요청 병합(coalescing)이 없다.** unit-stride 스토어가 원소마다 요청을 하나씩
   냅니다. 캐시에 붙이기 전에 해야 합니다 — 로드 CHECKLIST §8과 같은 항목입니다.
3. **합성 면적 수치가 없다.** 로드는 sv2v + yosys로 셀/플롭을 셌습니다. 스토어도
   같은 방식으로 재야 TOP 예산이 나옵니다.
4. **TOP 통합이 안 됐다.** VRF 읽기 포트 아비터에 스토어를 넣고,
   `VCORE_ARCHITECTURE.html` §1 상태 표와 §10 6번(Store)을 갱신해야 합니다.
5. **flush 드레인이 스모크에 없다.** `VST_DRAIN` 경로는 lint만 통과했습니다.
   미결 ack가 남은 채 flush가 들어오는 케이스를 directed로 짜야 합니다.
6. **예외 보고 경로가 프레임 수준.** error 비트는 집계되지만 호스트의 pre-commit
   fault check(Saturn 방식)와 어떻게 맞물리는지는 로드처럼 문서화되지 않았습니다.
