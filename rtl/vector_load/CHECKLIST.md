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

## 1. 지원 범위 (결정된 스코프)

지원:
- `vle8.v` / `vle16.v` / `vle32.v` / `vle64.v`  (mop=00, lumop=00000)
- `vlm.v`                                       (mop=00, lumop=01011)

**의도적으로 illegal 처리** (TOP이 다른 곳으로 라우팅해야 함 — 조용히 오동작하지 않도록):
- strided (mop=10), indexed unordered/ordered (mop=01/11)
- whole-register `vl<nf>re<eew>.v` (lumop=01000)
- fault-only-first `vle<eew>ff.v` (lumop=10000)
- segment load (nf≠0), EEW>64 (mew=1)
- `width` = 001/010/011/100 → 이건 같은 opcode를 쓰는 **스칼라 FP 로드**(flh/flw/fld/flq)라서
  절대 이 클러스터가 claim하면 안 됨

## 2. 메모리 인터페이스

```systemverilog
output mem_req_valid_o;  input  mem_req_ready_i;
output vcore_vld_mem_req_t mem_req_o;   // {addr[31:0], size[2:0], tag[6:0]}
input  mem_rsp_valid_i;  output mem_rsp_ready_o;
input  vcore_vld_mem_rsp_t mem_rsp_i;   // {tag[6:0], data[63:0], error}
```

- `size` = log2(bytes), AXI AxSIZE 호환. 응답 데이터는 스칼라 로드처럼 **하위 바이트 정렬**.
- `tag` = **명령어 안에서의 글로벌 element index**. sequencer가 한 번에 명령어 하나만
  처리하므로 별도 할당 로직 없이 in-flight 전체에서 유일함. 응답 순서는 자유(OoO).
- `MAX_OUTSTANDING` 파라미터로 in-flight 창 제한. 요청은 1 element/cycle로 발행.
- `busy_o` = 버스가 아직 데이터를 빚지고 있는 동안 high (fence/flush retire 판단용).
  perm 쪽에서 빠져 있다고 지적됐던 신호를 여기는 처음부터 넣었습니다.

## 3. 핵심 설계 결정

### 3.1 beat 0에서 그룹 전체 fetch (perm의 group buffer와 같은 패턴)
`vcore_perm_vrf_request`가 beat 0에서 vs2 EMUL 그룹 전체를 preload해서 이후 beat이
다시 안 읽게 만든 것과 똑같이, `vcore_vld_memreq`는 beat 0에서 **목적지 EMUL 그룹
전체의 active element**를 요청해 byte buffer(1024b)에 모읍니다.

이유: beat 단위로 나누면 EEW=64일 때 한 beat에 element가 2개뿐이라 MO 창이 2로 묶입니다.
그룹 단위로 하면 창이 명령어 크기(최대 VLMAX=128 요청)까지 열립니다.
이후 beat은 버스 트래픽 0.

### 3.2 active element만 요청 — 최적화가 아니라 **아키텍처 요구사항**
RVV 1.0 §7: loads "only access memory or raise exceptions for **active** elements".
prestart(`i < vstart`), tail(`i >= evl`), mask-inactive 원소는 요청하지 않습니다.
inactive 원소의 주소는 unmapped page를 가리켜도 합법이므로, 여분 요청은
데이터가 맞아도 진짜 버그입니다. → TB의 T1이 **요청 집합 자체**를 검사합니다.

### 3.3 dst_old 읽기와 메모리 요청 동시 진행
둘은 서로 다른 포트를 쓰고 레이턴시는 메모리가 지배하므로 직렬화하면 VRF 레이턴시가
매 beat에 그대로 더해집니다. `vld_needs_dst_old()`로 **읽을 필요 없으면 안 읽습니다**
(perm의 `vpop_needs_dst_old` 확장판):

```
needs_dst_old = !((vm || vma) && vta && vstart==0 && evl!=0)
```
perm 버전과 달리 `vma`까지 봅니다. unmasked거나 mask-agnostic이고 tail-agnostic이고
vstart=0이면 모든 슬롯이 새로 써지므로 이 읽기는 순수 낭비입니다. 로드에서 이건
**클러스터의 유일한 VRF 읽기**라서 효과가 큽니다.

### 3.4 flush — 이 클러스터만 리셋으로 끝낼 수 없음
외부 버스는 응답을 빚고 있고, ready를 내려버리면 버스가 deadlock 합니다.
그래서 flush 시 `VLD_DRAIN`으로 가서 `inflight_q`가 0이 될 때까지 응답을 받아 **버리고**,
그 뒤에야 idle이 됩니다. (T2가 검증)
VRF 읽기 포트는 perm과 같은 가정 — 같은 flush가 VRF 아비터에도 도달한다 — 으로
in-flight 읽기를 그냥 버립니다. 이 비대칭은 의도적이고 코드에 주석으로 박아뒀습니다.

### 3.5 bus error
호스트가 commit 전에 주소를 검사하는 모델(Saturn 방식)이므로 error 응답은
설계 escape입니다. error가 오면 **VRF를 쓰지 않고** commit에 `mem_error`로 올립니다.
반쯤 오염된 레지스터 위에서 trap 하는 것보다 깨끗합니다. (T3이 검증)

## 4. 정책 체인 (`vcore_vld_assemble`)

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

## 5. Decode 합법성 검사

- `EMUL = EEW/SEW × LMUL`을 **유리수**(num/den)로 유지 → fractional LMUL과
  widening/narrowing EEW:SEW 비율이 정확히 합성됨
- `1/8 <= EMUL <= 8` 아니면 reserved
- `emul_regs = ceil(EMUL)` (fractional도 물리 레지스터 1개는 차지)
- `EMUL >= 1`일 때만 vd가 EMUL 배수로 정렬
- `vl <= VLMAX(SEW, LMUL)` — vl은 SEW 공간의 원소 수이므로 EEW가 아니라 SEW로 검사
- §5.3: masked 명령의 목적지는 v0와 겹칠 수 없음 → `vm=0 && vd==v0` reserved
- `vill`, 예약 `width`/`lumop`/`mop`/`mew`/`nf`

## 6. 검증 결과

### `tb_vcore_vld_ref.sv` — golden reference (독립 데이터 표현)
기대 상태를 `exp_vrf[reg][byte]` **바이트 배열**로, 메모리 이미지에서 직접 채웁니다
(DUT는 packed VLEN 레지스터 + packed 그룹 버퍼). 합법성도 raw 명령어 필드에서
**다시 유도**하므로 decode 실수가 자기 자신과 합의할 수 없습니다.
매 케이스 **32개 레지스터 전부** 비교 → 잘못된 목적지에 쓰거나, 건드리면 안 되는
레지스터를 건드리면 실패.

| sweep | 내용 | 케이스 |
|---|---|---|
| 1 | EEW(4) × SEW(4) × LMUL(7, fractional 포함) × vl(5) × policy(4) | 2240 |
| 2 | `vlm.v` × SEW(4) × LMUL(7) × vl(6) | 168 |
| 3 | illegal 인코딩 20종 (segment/mew/strided/indexed/whole-reg/fof/reserved lumop/ FP 로드 width 4종/vlm 변형/vd=v0/vd 미정렬/EMUL 범위/vill/vl>VLMAX) | 20 |
| 4 | 합법 경계 (EMUL=8, EMUL=1/8, unmasked vd=v0, vstart>vl, 미정렬 base) | 5 |

```
REF TOTAL: 2433 cases, 2433 passed, 0 failed   (STRESS=0, ideal)
REF TOTAL: 2433 cases, 2433 passed, 0 failed   (STRESS=1, peak inflight 8)
```
STRESS=1 = 랜덤 ready, 메모리 레이턴시 0~7 랜덤, **응답 순서 무작위(OoO)**,
VRF read/write/commit 랜덤 stall. MAX_OUTSTANDING 1/2/4/8/16/32 전부 통과.

### `tb_vcore_vld_top.sv` — directed (데이터 비교로는 안 잡히는 것들)
```
TOTAL: 15 passed, 0 failed
```
- **T1** 메모리 요청 **집합**이 정확히 active element와 일치
  (masked / prestart / tail / vstart>=vl / vlm.v / illegal 6케이스,
   요청 주소·중복·누락 전부 검사)
- **T2** in-flight 상태에서 flush → 응답 drain, `busy_o` 하강, 이후 정상 동작
- **T3** bus error → VRF 미기록 + commit `mem_error`
- **T4** `busy_o`가 in-flight 구간을 빠짐없이 덮음
- **T5** issue FIFO를 통한 연속 3개 발행
- **T6** MO 효과 (64-element, EEW=8, LMUL=4)

| MAX_OUTSTANDING | LAT=6 | LAT=20 |
|---|---|---|
| 1 | 539 cy | 1435 cy |
| 2 | 284 cy | — |
| 4 | 158 cy | — |
| 8 | **98 cy** | **210 cy** |
| 16 | 98 cy | — |

레이턴시가 길수록 MO 이득이 커짐 (5.5× → 6.8×). 8 이상에서 포화하는 건
요청 발행이 1 element/cycle이고 레이턴시가 그보다 짧아서입니다.

### Lint
`verilator --lint-only -Wall -Wno-UNUSEDSIGNAL` clean (RTL 9개 파일 전부).

## 7. 알려진 한계 / 다음 단계 (주의사항)

1. **요청 coalescing 없음.** unit-stride인데도 element당 요청 1개를 냅니다.
   16바이트 로드 = 1바이트 요청 16개. 실제 구현은 버스 폭 단위로 묶어야 합니다
   (VLEN=128, 64b 버스면 요청 2개로 끝). 지금 구조에서 `memreq`의 스캔 루프만
   바꾸면 되고, tag를 "요청 번호"로 바꾸고 응답을 여러 element에 분배하는 작업이 필요.
2. **비정렬 element 접근**을 메모리 포트가 지원한다고 가정 (base=67 케이스로 테스트).
   지원 안 하는 버스면 호스트가 정렬을 보장하거나 misaligned trap 경로가 필요.
3. **요청 발행이 1 element/cycle.** inactive element를 스킵할 때도 1사이클씩 씁니다.
   mask가 희소하면 스캔 자체가 병목이 될 수 있음 (priority-encoder로 개선 가능).
4. **VRF 읽기 포트의 flush**는 perm과 같은 가정에 의존 (§3.4).
5. 세그먼트/strided/indexed/whole-register/fault-only-first는 스코프 밖 →
   현재는 illegal로 리포트. 특히 **fault-only-first는 pre-commit fault check 모델과
   충돌**하므로(첫 원소 외에는 trap 대신 vl을 줄임) 별도 설계가 필요합니다.
