# RVV Permutation 명령어 구현 체크리스트

기준: RVV 1.0, Vector_Core/outputs/rvv_instruction_20260916 카탈로그의 Permutation 분류 (34개 mnemonic).
검증: Verilator 5.050 (`C:\rv_toolchains\verilator-5.050`) `--lint-only` clean, `tb_vcore_perm_top.sv`로 기능 시뮬레이션.

| # | Mnemonic | 디코드 | 데이터패스 | LMUL>1 | 비고 |
|---|----------|:---:|:---:|:---:|---|
| 1 | vrgather.vv | ✅ | ✅ | ✅ | 그룹버퍼(src2_group) |
| 2 | vrgather.vx | ✅ | ✅ | ✅ | scalar 브로드캐스트 인덱스 |
| 3 | vrgather.vi | ✅ | ✅ | ✅ | uimm5 zero-ext |
| 4 | vrgatherei16.vv | ✅ | ✅ | ✅ | 인덱스(vs1) 독립 그룹버퍼(vpop_ei16_idx_regs), idx_regs>8 illegal 체크 |
| 5 | vslideup.vx | ✅ | ✅ | ✅ | 그룹버퍼, offset 미만은 자기 old vd 보존 |
| 6 | vslideup.vi | ✅ | ✅ | ✅ | uimm5 |
| 7 | vslidedown.vx | ✅ | ✅ | ✅ | 그룹버퍼 |
| 8 | vslidedown.vi | ✅ | ✅ | ✅ | uimm5 |
| 9 | vslide1up.vx | ✅ | ✅ | ✅ | global_index==0에서만 scalar 삽입 |
| 10 | vfslide1up.vf | ✅ | ✅ | ✅ | vslide1up와 동일 datapath |
| 11 | vslide1down.vx | ✅ | ✅ | ✅ | global_index==vl-1에서만 scalar 삽입 |
| 12 | vfslide1down.vf | ✅ | ✅ | ✅ | vslide1down과 동일 |
| 13 | vcompress.vm | ✅ | ✅ | ✅ | vs1(마스크)은 비그룹 고정, vs2는 그룹버퍼, 그룹 전체 기준 popcount |
| 14 | vmerge.vvm | ✅ | ✅ | ✅ | v0 selector, per-beat 독립 (그룹버퍼 불필요) |
| 15 | vmerge.vxm | ✅ | ✅ | ✅ | |
| 16 | vmerge.vim | ✅ | ✅ | ✅ | simm5 sign-ext |
| 17 | vfmerge.vfm | ✅ | ✅ | ✅ | vmerge.vxm과 동일 datapath |
| 18 | vmv.v.v | ✅ | ✅ | ✅ | |
| 19 | vmv.v.x | ✅ | ✅ | ✅ | |
| 20 | vmv.v.i | ✅ | ✅ | ✅ | simm5 sign-ext |
| 21 | vfmv.v.f | ✅ | ✅ | ✅ | vmv.v.x와 동일 |
| 22 | vmv.x.s | ✅ | ✅ | N/A(단일 beat) | **is_fp=0 → GPR 라우팅**, beats=1 강제 |
| 23 | vfmv.f.s | ✅ | ✅ | N/A | **is_fp=1 → FPR 라우팅**, vmv.x.s와 동일 beats=1 |
| 24 | vmv.s.x | ✅ | ✅ | N/A(단일 beat) | vd[0]만 씀, vstart==0 exact 조건, beats=1 강제 |
| 25 | vfmv.s.f | ✅ | ✅ | N/A | vmv.s.x와 동일 |
| 26 | vmv1r.v | ✅ | ✅ | N/A(bypass) | vtype/vl 완전 무시, vd/vs2 정렬 체크(1의 배수=항상 통과) |
| 27 | vmv2r.v | ✅ | ✅ | N/A | vd/vs2 2의 배수 정렬 체크 |
| 28 | vmv4r.v | ✅ | ✅ | N/A | vd/vs2 4의 배수 정렬 체크 |
| 29 | vmv8r.v | ✅ | ✅ | N/A | vd/vs2 8의 배수 정렬 체크 |
| 30 | viota.m | ✅ | ✅ | ✅ | vs2(마스크)는 비그룹 고정, 절대 비트 위치로 prefix popcount, vd는 정상 그룹화 |
| 31 | vid.v | ✅ | ✅ | ✅ | 소스 없음, vd만 정상 그룹화 |
| 32 | vmsbf.m | ✅ | ✅ | N/A(beats=1 강제) | vs2/vd 둘 다 비그룹 마스크 레지스터라 LMUL 무관 단일 beat |
| 33 | vmsof.m | ✅ | ✅ | N/A | 위와 동일 |
| 34 | vmsif.m | ✅ | ✅ | N/A | 위와 동일 |

**34/34 구현 완료.**

---

## 2026-09-17 RVV 1.0 정합성 수정 (11건)

스펙 원문(`riscv-v-spec` v-spec.adoc)과 조항별로 재대조해서 결함 11건을 찾고
전부 고쳤다. **먼저 실패하는 테스트를 넣어 재현을 확인한 뒤 고쳤다** — 수정 전
21개 실패 → 수정 후 0개.

| ID | 결함 | 스펙 근거 | 고친 곳 |
| --- | --- | --- | --- |
| F1 | vcompress가 vl 너머 마스크 비트까지 셈 | 16.5 "the first `vl` elements of vs2" | core: 탐색 루프·total_count 경계를 `ctrl.vl`로 |
| F2 | fractional LMUL에서 VLMAX를 모름 (out-of-range가 0이 아니라 stale) | 16.4 "index ≥ VLMAX → 0", 16.3.2 "VLMAX ≤ i+OFFSET → src=0" | pkg: `ctrl.vlmax` 필드 추가 / decode: 채움 / core: `group_size = vlmax` |
| F3 | viota.m·vmsbf류 vd/vs2 overlap 미검사 | 15.1·15.2 "destination cannot overlap the source register" | decode: overlap case에 항목 추가 (+ masked면 v0도) |
| F4 | vslidedown·vslide1down을 과잉 거부 | 16.3.2·16.3.4에는 overlap 제약이 **없다** | decode: overlap case에서 제거 |
| F5 | vstart≠0에서 illegal 미발생 | 15.1·15.2·16.5 "illegal instruction exception if vstart is non-zero" | pkg: `vpop_requires_vstart_zero()` / decode: 검사 |
| F6 | 마스크된 vslideup의 offset 아래에 agnostic 채움 | 16.3.1 표 "0 ≤ i < max(vstart,OFFSET) Unchanged" | core: 정책 체인에 `slide_up_below_offset` 분기 |
| F7 | 마스크된 viota가 비활성 원소까지 누적 | 15.2 "only the enabled elements contribute to the sum" | core: 스캔에 `(vm \|\| mask[k])` 추가 |
| F7b | vmsbf/vmsof/vmsif가 비활성 소스 비트에서 끊김 | 15.1 "the first **active** source element that is a 1" | core: 동일 |
| F8 | reserved 필드 미검사 (vm, vs2=0) | 16.1 "masked versions are reserved" 외 | decode: vmv.v.*·vmv.s.x·vmv.x.s·vmvNr.v |
| F9 | vstart ≥ vl 인데 tail에 agnostic을 씀 | 5.4 "no elements are updated ... including that no tail elements are updated with agnostic values" | core: 정책 체인 최상단 분기 |
| F10 | vrgather.vx 인덱스를 SEW로 truncate | 16.4 "If XLEN > SEW, the index value is _not_ truncated to SEW bits" | pkg: `ctrl.idx_from_scalar` / core: 원시 scalar 사용 |
| F11 | vmvNr.v가 vstart ≥ evl에서도 씀 | 16.6 "no elements are written if vstart ≥ evl" | decode: `vlmax = evl` / core: 가드 |

### 부수적으로 고친 것
- mask-destination(`vmsbf/vmsof/vmsif`)의 `ret.mbit` 기본값이 **v0 비트**였다.
  정책 체인이 쓰지 않고 통과하면 v0를 그대로 vd에 써 버린다. F5 수정으로
  도달 불가능해지긴 하지만, 기본값을 **이전 vd 비트**로 바꿔 근본을 없앴다.
  같은 김에 "활성 여부"를 `mask_bit`이라는 별도 변수로 분리했다.
- `vpop_ei16_idx_regs`를 `group_regs × n`이 아니라 `ctrl.vlmax` 기준으로 바꿨다
  (fractional LMUL에서 정확해진다). SEW8/LMUL8을 illegal로 거부하는 기존
  동작은 그대로 유지됨을 테스트로 확인했다.
- Verilator 5.020 `-Wall` WIDTHEXPAND 경고 1건 제거 (`GROUP_IDX_SLOTS` localparam).

### 손대지 않은 파일
`vcore_perm_issue_fifo.sv`, `vcore_perm_sequencer.sv`, `vcore_perm_vrf_request.sv`,
`vcore_perm_pipe.sv`, `vcore_perm_wb.sv`, `vcore_perm_top.sv` — 구조에 문제가 없었다.
수정은 pkg(+48줄) / decode(+54) / core(+68) 세 파일에만 들어갔다.

### 기존 테스트 2개의 기댓값을 고쳤다
`vcompress.vm` LMUL2(vl=5)와 LMUL8(vl=32) 두 테스트가 **F1 버그를 기댓값으로
박아 두고** 있었다. vl 너머 마스크 비트까지 세는 결과를 정답으로 적어 둔 것이라,
스펙대로 고쳤다.
- LMUL2/vl=5: 마스크 `10110101` 중 비트 0·2·4만 유효 → `{tail, 5, 3, 1}`
- LMUL8/vl=32: 4칸마다 세운 마스크 중 앞 32개 원소만 → active 32개가 아니라 **8개**

### 검증
```
verilator --lint-only -Wall -Wno-UNUSEDSIGNAL   → clean (exit 0)
tb_vcore_perm_top                               → TOTAL: 56 passed, 0 failed
```
기존 29개 self-check + 신규 27개(F1~F11 회귀 + 미자극이던 vrgather.vi /
vmerge.vvm / vslide1up.vx / vslide1down.vx 기본 자극). 수정 직전 같은 TB로
**21개가 실패**하는 것을 먼저 확인했다.

### 핸드셰이크 backpressure 검증 (추가)

기존 TB의 VRF 모델은 `rd_ready = wr_ready = sc_ready = commit_ready = 1'b1`,
읽기 응답은 **항상 정확히 1 cycle**이었다. 즉 네 포트의 backpressure와 가변
읽기 지연이 전부 미검증 상태였다. TB에 `STRESS` 파라미터를 넣어 두 모드로
돌린다.

| | IDEAL (`-GSTRESS=0`) | STRESS (`-GSTRESS=1`) |
| --- | --- | --- |
| `rd_ready` | 항상 1 | LFSR 랜덤, 읽기 in-flight 중에는 0 (진짜 1R1W) |
| 읽기 응답 지연 | 1 cycle 고정 | 1~4 cycle 랜덤, ready까지 hold |
| `wr_ready` / `sc_ready` / `commit_ready` | 항상 1 | LFSR 랜덤 |
| 결과 | 59 passed, 0 failed | **59 passed, 0 failed** (stall 320 cycle 주입) |

데이터가 맞는 것만으로는 부족해서 프로토콜 규약 자체도 assertion으로 검사한다
(SVA 9개, 두 모드 모두 통과):
- `valid && !ready` 이면 다음 cycle에도 `valid` 유지 — 읽기요청/쓰기/스칼라/commit 4포트
- stall 중 payload 불변 (`$stable`) — 주소·데이터·commit 전부
- 읽기 응답도 ready까지 철회 금지
- 읽기 포트 single-outstanding 위반 없음

**RTL은 한 줄도 고치지 않았다.** `vcore_perm_vrf_request`의 REQ/RSP FSM,
`vcore_perm_pipe`의 `rsp_slot_ready`, `vcore_perm_wb`의 pending 비트 분리가
원래부터 규약대로 쓰여 있었다. 미검증이었을 뿐 틀리지는 않았다.

추가로 issue FIFO를 실제로 채우는 테스트를 넣었다. 기존 `issue()`는 매번
retire까지 기다려서 depth-3 FIFO에 항목이 1개 이상 들어간 적이 없었다.
`issue_nowait()` + `wait_for()`로 3개를 연속으로 밀어 넣어 확인한다.

### 1R1W 포트 경쟁 실측 + 죽은 dst_old 읽기 제거

`tb_vcore_perm_perf.sv`(신규)로 명령어당 VRF read/write 횟수와 cycle을 실측했다.
공유 포트에서 경쟁의 단위는 **원소당 포트 트랜잭션 수**다. 기준선은
`vmerge.vvm`(3-오퍼랜드 마스크 연산, vadd.vv와 같은 구조).

측정 결과 **permutation이 평범한 3-오퍼랜드 연산보다 포트를 덜 쓴다.**
그룹 버퍼 덕분이다 — beat마다 소스를 다시 읽는 순진한 구현은 LMUL=8에서
`8 beat × 8 reg = 64 read`(O(LMUL²))인데, 여기는 명령어당 `8 read`(O(LMUL))다.

진짜 약점은 대역폭이 아니라 두 가지다.
1. **지연**: beat 하나가 완전 직렬이라 읽기 지연이 그대로 노출된다.
   rd_lat 1→4에서 cycle/elem이 2.25→3.75. 단 이건 permutation 고유 문제가
   아니다 — 기준선 vmerge도 2.75→5.00으로 똑같이 무너진다.
2. **버스트성**: preload 8 read가 연속으로 몰린다. 공유 arbiter가 요청 단위
   round-robin이면 preload가 잘려 지연이 늘고, burst를 통째로 내주면 다른
   유닛이 8 cycle 멈춘다. beat마다 읽기를 흩뿌리는 유닛에는 없는 위험이다.

측정 중에 낭비를 하나 찾아서 고쳤다. **모든 beat가 이전 목적지를 읽고 있었다.**
필요한 경우는 prestart 구간 / `vta=0` tail / `vma=0` 비활성 원소 / vslideup의
offset 아래 구간뿐이다. `vstart=0 · vl>0 · unmasked · vta=1`이면 beat의 모든
레인이 덮어써지므로 순수한 낭비다. `vid.v`는 소스가 없는데도 beat당 1 read를
쓰고 있었다.

| LMUL=8 | read 전 → 후 | port/elem | cycle (rd_lat 4) |
| --- | ---: | ---: | ---: |
| vrgather.vv | 24 → **16** | 1.00 → **0.75** | 160 → **120** |
| vcompress.vm | 24 → **16** | 1.00 → **0.75** | 160 → **120** |
| viota.m | 16 → **8** | 0.75 → **0.50** | 120 → **80** |
| vid.v | 8 → **0** | 0.50 → **0.25** | 80 → **40** |
| vslideup.vx | 16 → 16 | 0.75 (유지) | 120 (유지) |
| vmerge.vvm (vm=0) | 24 → 24 | 1.00 (유지) | 160 (유지) |

마지막 두 줄이 안전장치 확인이다 — vslideup은 offset 아래가 undisturbed라
제외했고, 마스크된 vmerge는 비활성 원소 때문에 여전히 읽는다.

구현: `vpop_needs_dst_old(ctrl)` 한 함수에 조건을 모으고,
`vcore_perm_vrf_request`가 DST_REQ/RSP 단계를 건너뛴다 (6개 전이 지점).
IDEAL/STRESS 두 모드 59개 테스트 전부 통과, lint clean.

### 골든 레퍼런스 대조 — 34개 전 명령어 (2026-09-17)

기존 검증은 34개 중 18개에만 자극이 있었고, 그마저 "돌아간다" 수준이었다.
`tb_vcore_perm_ref.sv`(신규 587줄)로 **전 명령어를 독립 참조 모델과 대조**한다.

모델은 RTL과 **다른 표현**으로 썼다. RTL은 1024비트 그룹 버퍼에서 shift/mask로
원소를 뽑지만, 모델은 전역 원소 번호로 인덱싱하는 평평한 배열을 쓴다. RTL을
바꿔 말한 모델이었다면 같이 틀렸을 버그가 이 차이를 못 넘는다.

비교 대상은 **VRF 32개 레지스터 전체 + 스칼라 write**다. 엉뚱한 레지스터에
쓰는 것까지 잡힌다.

| 축 | 범위 |
| --- | --- |
| mnemonic | 34개 전부 |
| SEW | 8 / 16 / 32 / 64 |
| LMUL | 1 / 2 / 4 / 8 / mf2 |
| vl | VLMAX / VLMAX÷2 / 1 / 0 / 랜덤 |
| vstart | 0 / 1 / vl 초과 |
| 정책 | vta·vma·vm 4조합 |
| 스칼라 | 범위 안·밖 인덱스 |

```
REF TOTAL: 3018 cases, 3018 passed, 0 failed   (IDEAL)
REF TOTAL: 3018 cases, 3018 passed, 0 failed   (STRESS: backpressure + 가변 지연)
```

mnemonic당 83~109 케이스 (vmvNr.v는 vtype 무관이라 17~18).

### F12 — vmv.x.s / vfmv.f.s / vmv.s.x / vfmv.s.f 가 LMUL>1에서 거부됨

레퍼런스 대조가 찾아낸 **새 결함**이다. decode의 EMUL 정렬 검사가
`vd % beats == 0`을 이 네 명령어에도 적용했다. `vmv.x.s`의 vd 필드는
**스칼라 rd**라 정렬 개념 자체가 없고, `vmv.s.x`의 vd는 벡터지만 단일
레지스터다.

RVV 1.0 16.1: *"The integer scalar read/write instructions transfer a single
value between a scalar x register and element 0 of a vector register.
**The instructions ignore LMUL and vector register groups.**"*

증상: LMUL=2에서 `vmv.x.s x9, v0` → rd=9가 2의 배수가 아니라서 illegal.
컴파일러가 흔히 내는 코드다.

수정: 정렬 검사 전체를 `vpop_single_beat(op)`인 명령어에서 면제.
vmsbf/vmsof/vmsif는 마스크 오퍼랜드 면제로 이미 빠져 있었고, 이 둘만 남아
있었다.

```systemverilog
-      if (beats > 1) begin
+      if ((beats > 1) && !vpop_single_beat(decoded_o.ctrl.op)) begin
```

### 레퍼런스 모델 자체에서 잡힌 것 (RTL은 정상)

모델을 처음 돌렸을 때 나온 실패 두 종류는 **모델이 틀린 것**이었다. 기록해 둔다.

1. **fractional LMUL의 tail 범위.** 모델이 tail을 VLMAX에서 끊었는데,
   스펙 5.4는 `tail(x) = (vl <= x < max(VLMAX, VLEN/SEW))`이다. mf2/SEW32면
   VLMAX=2지만 레지스터에는 슬롯이 4개 있고, 남는 2개도 tail이다. RTL이 맞았다.
2. **simm5 부호확장.** `vmv.v.i`/`vmerge.vim`의 5비트 즉치는 **부호**
   확장이고, `vrgather.vi`/`vslideup.vi`/`vslidedown.vi`는 **영**확장이다.
   RTL은 둘을 정확히 구분하고 있었다.

### 아직 검증되지 않은 것
- **`flush_i`가 TB에서 상수 0**이다. 모든 모듈에 flush 경로가 구현돼 있지만
  한 번도 동작시켜 보지 않았다. 다음 순위는 여기다.
- SEW 16 / 64, mf4 / mf8
- 미자극 mnemonic 16개

TB에 `issue_full()`을 추가했다 — mask_snapshot / vstart / vma / vm 를 직접
넘길 수 있다. 기존 `issue()`는 그대로 두어 원래 29개 검사는 손대지 않았다.


## 추가로 반영된 스펙 규칙
- 레지스터 overlap illegal-instruction 체크: gather/gatherei16/slide*/compress에서 vd가 vs2(및 해당 시 vs1/인덱스)와 겹치면 illegal (`regs_overlap`)
- vmvNr.v의 vd/vs2 정렬(nreg 배수) 체크
- vs2/vs1/vd가 실제로 그룹화되지 않는 마스크 오퍼랜드(viota의 vs2, vcompress의 vs1, vmsbf류의 vd)는 beats 정렬 체크에서 제외 (아니면 정상 명령어가 illegal로 오탐됨 — 테스트 중 실제로 발견/수정)
- vmv.x.s/vfmv.f.s: `is_fp` 플래그로 GPR/FPR 목적지 구분해서 `scalar_write_req_o.is_fp`로 노출

## 알려진 한계 (의도적으로 범위 밖)
- vrgatherei16의 인덱스 그룹버퍼는 EMUL_index 계산이 SEW=8일 때 급격히 커지는 경우까지 지원하지만(최대 MAXLMUL=8), 그 이상은 decode에서 illegal 처리 — RVV 스펙상으로도 이 조합은 실제로 불법입니다.
- 각 datapath 연산은 완전 combinational 1-beat-per-cycle(1R1W VRF 제약) 구조. 처리량 최적화(prefix-popcount 공유 트리 등)는 하지 않음 — 정확성 우선 스켈레톤.

## 검증 방법 (실제로 Verilator 5.050 돌려서 확인함)
1. **Lint**: `verilator --lint-only -Wall -Wno-UNUSEDSIGNAL --top-module vcore_perm_top vcore_perm_pkg.sv vcore_perm_decode.sv vcore_perm_issue_fifo.sv vcore_perm_sequencer.sv vcore_perm_vrf_request.sv vcore_perm_core.sv vcore_perm_pipe.sv vcore_perm_wb.sv vcore_perm_top.sv` → **clean (exit 0)**
   - 이 과정에서 실제 버그 2개를 발견/수정함: (a) 함수 파라미터 EEW를 variable-width part-select(`+: EEW`)에 쓴 것 — Verilator는 호출부가 리터럴이어도 함수 인자를 상수로 취급 안 함 → shift+mask 기반 `fld_get`/`fld_get_wide`로 교체. (b) `regs_overlap` 호출부 폭 불일치(4bit→32bit) 경고.
2. **시뮬레이션**: `tb_vcore_perm_top.sv`(behavioral 1R1W VRF + scalar sink 포함, `verilator --binary --timing`으로 빌드해 실행) — **29개 self-checking 항목 전부 PASS**, LMUL=1/2 기본 테스트 21개 + **LMUL=8(MAXLMUL) 경계 테스트 8개**:
   - LMUL1/2: vid.v, vrgather.vv(LMUL1), vrgather.vv(LMUL2 교차 레지스터 2케이스), vslideup.vx(LMUL2 교차), vcompress.vm(LMUL2+vta), viota.m(LMUL2, 절대 비트 스캔), vmsbf/vmsof/vmsif.m(LMUL2 CSR인데 단일 beat), vmv.x.s(GPR), vfmv.f.s(FPR, is_fp 구분), vmv.s.x, vmv2r.v.
   - **LMUL8: vrgather.vv (SEW8, 128개 원소 전체를 8개 레지스터에 걸쳐 완전 반전 — dest reg0↔src reg7 식으로 최대 거리 교차), vrgatherei16.vv (SEW32, idx_regs=4 ≠ group_regs=8인 "인덱스가 데이터보다 적은 레지스터" 케이스), vrgatherei16.vv (SEW8, idx_regs=16>MAXLMUL(8) → illegal 정상 거부 확인), vslideup.vx (offset=100, 6개 레지스터 경계를 넘는 교차), vcompress.vm (128개 중 32개 active, 8레지스터 전체+tail), viota.m (단일 마스크 소스 → 8레지스터 목적지, 절대 스캔 128개 전 위치 검증), vmv8r.v (8레지스터 전체 이동)** — 모두 PASS.
   - 이 과정에서 decode.sv의 실제 버그 1개를 추가로 발견/수정함: vs2/vs1/vd 정렬(beats 배수) 체크가 그룹화 안 되는 마스크 오퍼랜드(viota의 vs2, vcompress의 vs1, vmsbf류의 vd)에도 적용돼서 정상 명령어를 illegal로 오탐하는 문제.

**결론: LMUL=1부터 LMUL=8(MAXLMUL, RVV가 지원하는 최댓값)까지 그룹버퍼 기반 로직 전부 실제 시뮬레이션으로 확인됨.**

재현 명령 (PowerShell, Verilator가 `C:\rv_toolchains\verilator-5.050`에 있다고 가정):
```powershell
$env:VERILATOR_ROOT = "C:\rv_toolchains\verilator-5.050"
$env:Path = "C:\rv_toolchains\verilator-5.050\bin;C:\rv_toolchains\w64devkit-2.9.1\w64devkit\bin;" + $env:Path
cd "<repo>\rtl\vector_permutation"
verilator --cc --timing --exe --main --build-jobs 1 -Wno-UNUSEDSIGNAL --top-module tb_vcore_perm_top vcore_perm_pkg.sv vcore_perm_decode.sv vcore_perm_issue_fifo.sv vcore_perm_sequencer.sv vcore_perm_vrf_request.sv vcore_perm_core.sv vcore_perm_pipe.sv vcore_perm_wb.sv vcore_perm_top.sv tb_vcore_perm_top.sv --Mdir obj_dir
mingw32-make.exe -C obj_dir -f Vtb_vcore_perm_top.mk CXX=g++ CC=gcc LINK=g++
.\obj_dir\Vtb_vcore_perm_top.exe
```
(obj_dir는 빌드 산출물이라 커밋하지 않고 지웠습니다 — 필요하면 위 명령으로 재생성)
