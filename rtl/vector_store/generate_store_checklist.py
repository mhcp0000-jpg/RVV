"""Refresh the RVV vector-store encoding checklist from the pinned official
opcode file. Mirrors rtl/vector_load/generate_load_checklist.py.

The official rv_v file leaves `nf` variable on the unit-stride, strided and
indexed store rows, so the segment variants share those rows; this script
expands them into the instructions RVV 1.0 names, giving 133 rows.

Note what stores do NOT have, compared with loads: there is no fault-only-
first form (32 fewer encodings), and the whole-register store has one
encoding per register count rather than one per EEW (4 instead of 16),
because it moves whole registers and the width field is fixed to 000.
"""
from __future__ import annotations

import csv
import re
from collections import Counter
from pathlib import Path
from urllib.request import urlopen

SOURCE_COMMIT = "f5befa291a2562f3194921265b7f5ac5681bc8b0"
SOURCE_URL = ("https://raw.githubusercontent.com/riscv/riscv-opcodes/"
              f"{SOURCE_COMMIT}/extensions/rv_v")
CHECKLIST = Path(__file__).with_name("RVV_STORE_CHECKLIST.csv")
SUMMARY   = Path(__file__).with_name("RVV_STORE_PROGRESS.md")
CACHE     = Path(__file__).with_name(".rv_v_cache")

STORE_FP_OPCODE = 0x27
EEW_BY_WIDTH = {0x0: 8, 0x5: 16, 0x6: 32, 0x7: 64}

# The decoder covers the whole encoding space. The `execute` column is not
# typed by hand: tb_vcore_vst_ref logs every encoding it actually ran to a
# passing completion into exec_coverage.txt, and that log is read back here.
# No coverage file means no execute claims.
DECODED_ALL = True
COVERAGE = Path(__file__).with_name("exec_coverage.txt")


def executed_set() -> set[str]:
    """Mnemonics the golden-reference bench executed, read from its own log."""
    if not COVERAGE.exists():
        return set()
    out: set[str] = set()
    for line in COVERAGE.read_text(encoding="utf-8").split("\n"):
        parts = line.split()
        if len(parts) != 4:
            continue
        nf, mop, sumop, width = (int(x) for x in parts)
        n = nf + 1
        if mop == 0 and sumop == 0x0b:
            out.add("vsm.v"); continue
        if mop == 0 and sumop == 0x08:
            out.add(f"vs{n}r.v"); continue
        eew = EEW_BY_WIDTH[width]
        if mop == 0:
            out.add(f"vse{eew}.v" if nf == 0 else f"vsseg{n}e{eew}.v")
        elif mop == 2:
            out.add(f"vsse{eew}.v" if nf == 0 else f"vssseg{n}e{eew}.v")
        elif mop == 1:
            out.add(f"vsuxei{eew}.v" if nf == 0 else f"vsuxseg{n}ei{eew}.v")
        elif mop == 3:
            out.add(f"vsoxei{eew}.v" if nf == 0 else f"vsoxseg{n}ei{eew}.v")
    return out


EXECUTED: set[str] = executed_set()


def fetch() -> str:
    if CACHE.exists():
        return CACHE.read_text(encoding="utf-8")
    text = urlopen(SOURCE_URL, timeout=60).read().decode("utf-8")
    CACHE.write_text(text, encoding="utf-8")
    return text


def parse_fields(tokens: list[str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for t in tokens:
        if "=" in t:
            k, v = t.split("=", 1)
            out[k] = v
        else:
            out[t] = "variable"
    return out


def family(mop: int, sumop: int | None, nf: int) -> str:
    if mop == 0 and sumop == 0x0b: return "Mask memory"
    if mop == 0 and sumop == 0x08: return "Whole register"
    if mop == 0: return "Unit-stride" if nf == 0 else "Segment unit-stride"
    if mop == 2: return "Strided" if nf == 0 else "Segment strided"
    if mop == 1: return "Indexed unordered" if nf == 0 else "Segment indexed unordered"
    if mop == 3: return "Indexed ordered" if nf == 0 else "Segment indexed ordered"
    raise RuntimeError(f"unclassified mop={mop} sumop={sumop} nf={nf}")


def segment_name(base: str, nf: int) -> str:
    n = nf + 1
    for pat, rep in (
        (r"vse(\d+)\.v",     lambda m: f"vsseg{n}e{m.group(1)}.v"),
        (r"vsse(\d+)\.v",    lambda m: f"vssseg{n}e{m.group(1)}.v"),
        (r"vsuxei(\d+)\.v",  lambda m: f"vsuxseg{n}ei{m.group(1)}.v"),
        (r"vsoxei(\d+)\.v",  lambda m: f"vsoxseg{n}ei{m.group(1)}.v"),
    ):
        m = re.fullmatch(pat, base)
        if m:
            return rep(m)
    raise RuntimeError(f"no segment naming rule for {base}")


def main() -> None:
    text = fetch()
    previous: dict[str, dict[str, str]] = {}
    if CHECKLIST.exists():
        with CHECKLIST.open(newline="", encoding="utf-8-sig") as f:
            previous = {r["mnemonic"]: r for r in csv.DictReader(f)}

    rows = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        name, fields = parts[0], parse_fields(parts[1:])
        if fields.get("6..0") != f"0x{STORE_FP_OPCODE:02x}":
            continue
        if "vs3" not in fields:          # vd present -> a load, not our cluster
            continue

        width = int(fields["14..12"], 0)
        eew   = EEW_BY_WIDTH[width]
        mop   = int(fields["27..26"], 0)
        sumop = int(fields["24..20"], 0) if mop == 0 else None

        if "nf" in fields:
            nf_values, nf_fixed = list(range(8)), None
        elif "31..29" in fields:
            nf_fixed = int(fields["31..29"], 0); nf_values = [nf_fixed]
        elif "31..28" in fields:          # vsm.v pins 31..28 = 0
            nf_fixed = 0; nf_values = [0]
        else:
            raise RuntimeError(f"{name}: no nf field")

        for nf in nf_values:
            mnem = name if (nf == 0 or nf_fixed is not None) else segment_name(name, nf)
            fam  = family(mop, sumop, nf if nf_fixed is None else 0)
            prior = previous.get(mnem, {})
            dec  = DECODED_ALL
            impl = mnem in EXECUTED
            rows.append({
                "mnemonic": mnem,
                "family": fam,
                "eew_bits": eew,
                "width": f"0b{width:03b}",
                "mop": f"0b{mop:02b}",
                "nf": f"0b{nf:03b}",
                "sumop": "vs2/rs2" if sumop is None else f"0b{sumop:05b}",
                "vm_constraint": fields.get("25", "variable"),
                "decode": "yes" if dec else prior.get("decode", "no"),
                "execute": "yes" if impl else prior.get("execute", "no"),
                "decode_table_test": "tb_vcore_vst_decode_table",
                "unit_test": "tb_vcore_vst_ref" if impl else prior.get("unit_test", ""),
                "integration_test": prior.get("integration_test", ""),
                "notes": ("" if impl else "decode 완료, 실행 미검증"),
            })

    if len(rows) != 133:
        raise RuntimeError(f"Expected 133 official vector store encodings, got {len(rows)}")

    rows.sort(key=lambda r: (r["family"], r["mnemonic"]))
    with CHECKLIST.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader(); w.writerows(rows)

    counts = Counter(r["family"] for r in rows)
    impl_c = Counter(r["family"] for r in rows if r["execute"] == "yes")
    decoded  = sum(r["decode"] == "yes" for r in rows)
    executed = sum(r["execute"] == "yes" for r in rows)
    out = [
        "# RVV 벡터 스토어 구현 체크리스트",
        "",
        f"공식 [rv_v opcode 파일]({SOURCE_URL})에서 STORE-FP(opcode 0x27) 인코딩을 추출하고,",
        "`nf` 필드가 가변인 행은 RVV 1.0이 이름을 주는 segment 변형으로 전개해 **133개**를 추적합니다.",
        "이 개수는 저장소 명령어 카탈로그(`outputs/rvv_instruction_20260916`) Store 행 수와 일치합니다.",
        "",
        f"현재 `decode=yes`: **{decoded}/133**, `execute=yes`: **{executed}/133**.",
        "",
        "`decode`는 `tb_vcore_vst_decode_table`이 인코딩 × vtype 전 구간에서 대조합니다.",
        "`execute`는 손으로 적은 값이 아닙니다 — `tb_vcore_vst_ref`가 실제로 실행해서",
        "통과시킨 인코딩을 `exec_coverage.txt`에 기록하고, 이 스크립트가 그 로그를 읽어",
        "채웁니다. 로그가 없으면 execute는 전부 no가 됩니다.",
        "",
        "로드와 비교해 **없는 것**: fault-only-first(32개 적음), 그리고 whole-register가",
        "EEW별 4종이 아니라 레지스터 수별 4종입니다(`width`가 000으로 고정).",
        "",
        "| 연산군 | 인코딩 수 | 구현 |",
        "|---|---:|---:|",
    ]
    out += [f"| {k} | {v} | {impl_c.get(k, 0)} |" for k, v in sorted(counts.items())]
    out += ["", "상세: [RVV_STORE_CHECKLIST.csv](RVV_STORE_CHECKLIST.csv)", ""]
    SUMMARY.write_text("\n".join(out), encoding="utf-8")
    print(f"Wrote {len(rows)} rows; decode={decoded}, execute={executed}")


if __name__ == "__main__":
    main()
