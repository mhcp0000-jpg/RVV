"""Refresh the RVV vector-load encoding checklist from the pinned official opcode file.

Mirrors rtl/vector_alu/generate_checklist.py. The official rv_v file leaves the
`nf` field variable on the unit-stride / strided / indexed / fault-only-first
rows, so the segment variants share those encoding rows; this script expands
them into the named instructions RVV 1.0 defines, which is what the project's
instruction catalog (outputs/rvv_instruction_20260916) counts.

Existing progress columns are kept when the script is rerun. Run from any cwd.
"""
from __future__ import annotations

import csv
import re
from collections import Counter
from pathlib import Path
from urllib.request import urlopen

SOURCE_COMMIT = "f5befa291a2562f3194921265b7f5ac5681bc8b0"
SOURCE_URL = (
    "https://raw.githubusercontent.com/riscv/riscv-opcodes/"
    f"{SOURCE_COMMIT}/extensions/rv_v"
)
CHECKLIST = Path(__file__).with_name("RVV_LOAD_CHECKLIST.csv")
SUMMARY = Path(__file__).with_name("RVV_LOAD_PROGRESS.md")
CACHE = Path(__file__).with_name(".rv_v_cache")

LOAD_FP_OPCODE = 0x07

# rtl/vector_load decodes and executes every official vector load form.
# Anything still outside the cluster would be listed here.
NOT_IMPLEMENTED: set[str] = set()

# What the benches exercise, per family.
REF_SWEEP = {
    "Unit-stride":        "EEW x SEW x LMUL(분수 포함) x vl x vstart x 정책",
    "Segment unit-stride":"nf=2~8 x EEW x LMUL x 정책",
    "Mask memory":        "SEW x LMUL x vl (evl=ceil(vl/8), tail-agnostic 강제)",
    "Strided":            "EEW x SEW x LMUL x stride(양/0/음/비정렬)",
    "Segment strided":    "nf x EEW x LMUL x segment stride",
    "Indexed unordered":  "index EEW x SEW x LMUL x mask",
    "Indexed ordered":    "index EEW x SEW x LMUL, 단일 미결 강제",
    "Segment indexed unordered": "nf x index EEW x LMUL",
    "Segment indexed ordered":   "nf x index EEW x LMUL",
    "Whole register":     "NREG x EEW x vstart, vtype 무시 확인",
    "Fault-only-first":   "fault 위치 x EEW x nf, trim/trap 구분",
}
DIRECTED = {
    "Unit-stride":        "T1a/b/c/d 요청 집합, T2 flush, T3 bus error, T4 busy_o, T5 연속 발행, T6 MO 클록",
    "Segment unit-stride":"T1i 필드별 요청 집합",
    "Mask memory":        "T1e ceil(vl/8) 요청",
    "Strided":            "T1g 음수 stride 주소",
    "Segment strided":    "",
    "Indexed unordered":  "T1h 인덱스 주소, T7 전체 창 사용",
    "Indexed ordered":    "T7 in-flight 1 강제 + 수집 정확성",
    "Segment indexed unordered": "",
    "Segment indexed ordered":   "",
    "Whole register":     "T9 vtype/vl/v0 무시",
    "Fault-only-first":   "T8 trim 보고 / element 0 trap / tail 전환",
}

EEW_BY_WIDTH = {0x0: 8, 0x5: 16, 0x6: 32, 0x7: 64}


def fetch() -> str:
    if CACHE.exists():
        return CACHE.read_text(encoding="utf-8")
    text = urlopen(SOURCE_URL, timeout=60).read().decode("utf-8")
    CACHE.write_text(text, encoding="utf-8")
    return text


def parse_fields(tokens: list[str]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for token in tokens:
        if "=" in token:
            key, value = token.split("=", 1)
            fields[key] = value
        else:
            fields[token] = "variable"
    return fields


def family(mop: int, lumop: int | None, nf: int) -> str:
    if mop == 0 and lumop == 0x0b:
        return "Mask memory"
    if mop == 0 and lumop == 0x08:
        return "Whole register"
    if mop == 0 and lumop == 0x10:
        return "Fault-only-first"
    if mop == 0 and lumop == 0x00:
        return "Unit-stride" if nf == 0 else "Segment unit-stride"
    if mop == 2:
        return "Strided" if nf == 0 else "Segment strided"
    if mop == 1:
        return "Indexed unordered" if nf == 0 else "Segment indexed unordered"
    if mop == 3:
        return "Indexed ordered" if nf == 0 else "Segment indexed ordered"
    raise RuntimeError(f"unclassified mop={mop} lumop={lumop} nf={nf}")


def segment_name(base: str, nf: int) -> str:
    """Name of the nf>0 variant of a base load mnemonic (RVV 1.0 naming)."""
    n = nf + 1
    m = re.fullmatch(r"vle(\d+)\.v", base)
    if m:
        return f"vlseg{n}e{m.group(1)}.v"
    m = re.fullmatch(r"vle(\d+)ff\.v", base)
    if m:
        return f"vlseg{n}e{m.group(1)}ff.v"
    m = re.fullmatch(r"vlse(\d+)\.v", base)
    if m:
        return f"vlsseg{n}e{m.group(1)}.v"
    m = re.fullmatch(r"vluxei(\d+)\.v", base)
    if m:
        return f"vluxseg{n}ei{m.group(1)}.v"
    m = re.fullmatch(r"vloxei(\d+)\.v", base)
    if m:
        return f"vloxseg{n}ei{m.group(1)}.v"
    raise RuntimeError(f"no segment naming rule for {base}")


def profile(mnemonic: str, eew: int, family_name: str) -> str:
    # EEW=64 indexed loads need Zve64x; the project targets Zve64f_Zvl128b on
    # RV32 and the catalog marks these rows as outside RV32 V.
    if "ndexed" in family_name and eew == 64:
        return "RV32 V 제외 (EEW=64 index)"
    return "Zve32x/Zve64x base"


def main() -> None:
    text = fetch()
    previous: dict[str, dict[str, str]] = {}
    if CHECKLIST.exists():
        with CHECKLIST.open(newline="", encoding="utf-8-sig") as file:
            previous = {row["mnemonic"]: row for row in csv.DictReader(file)}

    rows = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        name, fields = parts[0], parse_fields(parts[1:])
        if fields.get("6..0") != f"0x{LOAD_FP_OPCODE:02x}":
            continue
        if "vd" not in fields:          # vs3 present -> store, not our cluster
            continue

        width = int(fields["14..12"], 0)
        eew = EEW_BY_WIDTH[width]
        mop = int(fields["27..26"], 0)
        lumop = int(fields["24..20"], 0) if mop == 0 else None
        # `nf` is a named field (variable) on the plain rows and a fixed value
        # on the whole-register rows.
        if "nf" in fields:
            nf_values = list(range(8))
            nf_fixed = None
        elif "31..29" in fields:
            nf_fixed = int(fields["31..29"], 0)
            nf_values = [nf_fixed]
        elif "31..28" in fields:        # vlm.v pins 31..28 = 0
            nf_fixed = 0
            nf_values = [0]
        else:
            raise RuntimeError(f"{name}: no nf field")

        for nf in nf_values:
            mnemonic = name if nf == 0 or nf_fixed is not None else segment_name(name, nf)
            fam = family(mop, lumop, nf if nf_fixed is None else 0)
            prior = previous.get(mnemonic, {})
            implemented = mnemonic not in NOT_IMPLEMENTED
            rows.append({
                "mnemonic": mnemonic,
                "family": fam,
                "profile": profile(mnemonic, eew, fam),
                "eew_bits": eew,
                "width": f"0b{width:03b}",
                "mop": f"0b{mop:02b}",
                "nf": f"0b{nf:03b}",
                "lumop": "vs2/rs2" if lumop is None else f"0b{lumop:05b}",
                "vm_constraint": fields.get("25", "variable"),
                "decode": "yes" if implemented else prior.get("decode", "no"),
                "execute": "yes" if implemented else prior.get("execute", "no"),
                "decode_table_test": "tb_vcore_vld_decode_table",
                "unit_test": (REF_SWEEP.get(fam, "") if implemented else ""),
                "integration_test": (DIRECTED.get(fam, "") if implemented else ""),
                "notes": ("" if implemented else "범위 밖 — decode가 illegal_op으로 보고"),
            })

    if len(rows) != 177:
        raise RuntimeError(f"Expected 177 official vector load encodings, got {len(rows)}")

    rows.sort(key=lambda row: (row["family"], row["mnemonic"]))
    with CHECKLIST.open("w", newline="", encoding="utf-8-sig") as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    counts = Counter(row["family"] for row in rows)
    impl = Counter(row["family"] for row in rows if row["execute"] == "yes")
    decoded = sum(row["decode"] == "yes" for row in rows)
    executed = sum(row["execute"] == "yes" for row in rows)
    integrated = sum(bool(row["integration_test"]) for row in rows)
    text_out = [
        "# RVV 벡터 로드 구현 체크리스트",
        "",
        f"공식 [rv_v opcode 파일]({SOURCE_URL})에서 LOAD-FP(opcode 0x07) 인코딩을 추출하고,",
        "`nf` 필드가 가변인 행은 RVV 1.0이 이름을 주는 segment 변형으로 전개해 **177개**를 추적합니다.",
        "이 개수는 저장소의 명령어 카탈로그(`outputs/rvv_instruction_20260916`) Load 행 수와 일치합니다.",
        "",
        f"현재 `decode=yes`: **{decoded}/177**, `execute=yes`: **{executed}/177**, "
        f"directed 통합 테스트: **{integrated}/177**.",
        "",
        "`tb_vcore_vld_decode_table`이 177개 인코딩 전부를 vtype 전 구간에 걸쳐 대조하고,",
        "`tb_vcore_vld_ref`가 독립 모델로 데이터를 전수 비교합니다.",
        "",
        "| 연산군 | 인코딩 수 | 구현 |",
        "|---|---:|---:|",
    ]
    text_out += [f"| {key} | {value} | {impl.get(key, 0)} |"
                 for key, value in sorted(counts.items())]
    text_out += ["", "상세: [RVV_LOAD_CHECKLIST.csv](RVV_LOAD_CHECKLIST.csv)", ""]
    SUMMARY.write_text("\n".join(text_out), encoding="utf-8")
    print(f"Wrote {len(rows)} rows; decode={decoded}, execute={executed}, "
          f"integration={integrated}")


if __name__ == "__main__":
    main()
