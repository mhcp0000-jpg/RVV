"""Refresh the RVV ALU encoding checklist from the pinned official opcode file.

Existing progress columns are kept when the script is rerun. Run from any cwd.
"""
from __future__ import annotations

import csv
from collections import Counter
from pathlib import Path
from urllib.request import urlopen

SOURCE_COMMIT = "f5befa291a2562f3194921265b7f5ac5681bc8b0"
SOURCE_URL = (
    "https://raw.githubusercontent.com/riscv/riscv-opcodes/"
    f"{SOURCE_COMMIT}/extensions/rv_v"
)
CHECKLIST = Path(__file__).with_name("RVV_ALU_CHECKLIST.csv")
SUMMARY = Path(__file__).with_name("RVV_ALU_PROGRESS.md")
PERM_PREFIXES = (
    "vrgather", "vrgatherei16", "vslide", "vfslide", "vcompress",
    "vmerge", "vfmerge", "vmv", "vfmv", "viota", "vid", "vmsbf",
    "vmsof", "vmsif",
)

# Baseline present before the full-RVV expansion. A row is only `verified`
# after a top-level instruction test; a unit-level test is insufficient.
LEGACY_FORMS = {
    "vadd": {"vv", "vx", "vi"},
    "vsub": {"vv", "vx"},
    "vrsub": {"vx", "vi"},
    "vminu": {"vv", "vx"}, "vmin": {"vv", "vx"},
    "vmaxu": {"vv", "vx"}, "vmax": {"vv", "vx"},
    "vand": {"vv", "vx", "vi"},
    "vor": {"vv", "vx", "vi"},
    "vxor": {"vv", "vx", "vi"},
    "vmseq": {"vv", "vx", "vi"},
    "vmsne": {"vv", "vx", "vi"},
    "vmsltu": {"vv", "vx"}, "vmslt": {"vv", "vx"},
    "vmsleu": {"vv", "vx", "vi"}, "vmsle": {"vv", "vx", "vi"},
    "vmsgtu": {"vx", "vi"}, "vmsgt": {"vx", "vi"},
    "vsaddu": {"vv", "vx", "vi"},
    "vsadd": {"vv", "vx", "vi"},
    "vssubu": {"vv", "vx"}, "vssub": {"vv", "vx"},
    "vsll": {"vv", "vx", "vi"},
    "vsrl": {"vv", "vx", "vi"},
    "vsra": {"vv", "vx", "vi"},
}
NEW_FORMS = {
    "vadc": {"vvm", "vxm", "vim"},
    "vmadc": {"vvm", "vxm", "vim", "vv", "vx", "vi"},
    "vsbc": {"vvm", "vxm"},
    "vmsbc": {"vvm", "vxm", "vv", "vx"},
    "vaaddu": {"vv", "vx"}, "vaadd": {"vv", "vx"},
    "vasubu": {"vv", "vx"}, "vasub": {"vv", "vx"},
    "vssrl": {"vv", "vx", "vi"},
    "vssra": {"vv", "vx", "vi"},
    "vsmul": {"vv", "vx"},
    "vredsum": {"vs"}, "vredand": {"vs"},
    "vredor": {"vs"}, "vredxor": {"vs"},
    "vredminu": {"vs"}, "vredmin": {"vs"},
    "vredmaxu": {"vs"}, "vredmax": {"vs"},
    "vwredsumu": {"vs"}, "vwredsum": {"vs"},
    "vcpop": {"m"}, "vfirst": {"m"},
    "vmul": {"vv", "vx"}, "vmulhu": {"vv", "vx"},
    "vmulhsu": {"vv", "vx"}, "vmulh": {"vv", "vx"},
    "vmacc": {"vv", "vx"}, "vnmsac": {"vv", "vx"},
    "vmadd": {"vv", "vx"}, "vnmsub": {"vv", "vx"},
    "vdivu": {"vv", "vx"}, "vdiv": {"vv", "vx"},
    "vremu": {"vv", "vx"}, "vrem": {"vv", "vx"},
    "vfsgnj": {"vv", "vf"}, "vfsgnjn": {"vv", "vf"},
    "vfsgnjx": {"vv", "vf"}, "vfclass": {"v"},
    "vfmin": {"vv", "vf"}, "vfmax": {"vv", "vf"},
    "vmfeq": {"vv", "vf"}, "vmfle": {"vv", "vf"},
    "vmflt": {"vv", "vf"}, "vmfne": {"vv", "vf"},
    "vmfgt": {"vf"}, "vmfge": {"vf"},
    "vmandn": {"mm"}, "vmand": {"mm"},
    "vmor": {"mm"}, "vmxor": {"mm"},
    "vmorn": {"mm"}, "vmnand": {"mm"},
    "vmnor": {"mm"}, "vmxnor": {"mm"},
    "vzext": {"vf2", "vf4", "vf8"},
    "vsext": {"vf2", "vf4", "vf8"},
    "vwaddu": {"vv", "vx", "wv", "wx"},
    "vwadd": {"vv", "vx", "wv", "wx"},
    "vwsubu": {"vv", "vx", "wv", "wx"},
    "vwsub": {"vv", "vx", "wv", "wx"},
    "vwmulu": {"vv", "vx"},
    "vwmulsu": {"vv", "vx"},
    "vwmul": {"vv", "vx"},
    "vwmaccu": {"vv", "vx"},
    "vwmacc": {"vv", "vx"},
    "vwmaccus": {"vx"},
    "vwmaccsu": {"vv", "vx"},
    "vnsrl": {"wv", "wx", "wi"},
    "vnsra": {"wv", "wx", "wi"},
    "vnclipu": {"wv", "wx", "wi"},
    "vnclip": {"wv", "wx", "wi"},
    "vfredmin": {"vs"}, "vfredmax": {"vs"},
}


def family(name: str) -> str:
    stem = name.split(".")[0]
    if stem != "vfirst" and stem.startswith(("vf", "vmf")):
        if stem.startswith(("vfcvt", "vfwcvt", "vfncvt")):
            return "FP convert"
        if stem.startswith(("vfred", "vfwred")):
            return "FP reduction"
        if stem.startswith(("vfm", "vfnm", "vfwm", "vfwn")):
            return "FP multiply/FMA"
        return "FP element"
    if stem.startswith(("vred", "vwred", "vcpop", "vfirst")):
        return "Integer/mask reduction"
    if stem.startswith(("vmand", "vmor", "vmxor", "vmnand", "vmnor", "vmxnor")):
        return "Mask logic"
    if stem.startswith(("vwad", "vwsub", "vwmul", "vwmacc", "vzext", "vsext", "vns", "vnclip")):
        return "Widen/narrow/extend"
    if stem.startswith(("vdiv", "vrem")):
        return "Integer divide"
    if stem.startswith(("vmul", "vmacc", "vmadd", "vnms")):
        return "Integer multiply/MAC"
    if stem.startswith(("vsadd", "vssub", "vssrl", "vssra", "vsmul", "vaadd", "vasub")):
        return "Fixed point"
    if stem.startswith(("vadc", "vsbc", "vmadc", "vmsbc")):
        return "Carry/borrow"
    return "Integer element"


def profile(name: str) -> str:
    stem = name.split(".")[0]
    if stem.startswith(("vfw", "vfncvt")):
        return "FP64 feature conditional"
    if stem != "vfirst" and stem.startswith(("vf", "vmf")):
        return "FP32 F extension"
    return "Integer V extension"


def main() -> None:
    previous = {}
    if CHECKLIST.exists():
        with CHECKLIST.open(newline="", encoding="utf-8-sig") as file:
            previous = {row["mnemonic"]: row for row in csv.DictReader(file)}

    source = urlopen(SOURCE_URL, timeout=20).read().decode("utf-8")
    rows = []
    for line in source.splitlines():
        if not line or line.startswith("#") or "6..0=0x57" not in line:
            continue
        parts = line.split()
        name = parts[0]
        if name.startswith("vset") or name.startswith(PERM_PREFIXES):
            continue
        fields = {}
        for token in parts[1:]:
            if "=" in token:
                key, value = token.split("=", 1)
                fields[key] = value
        prior = previous.get(name, {})
        base, _, suffix = name.partition(".")
        implemented = (suffix in LEGACY_FORMS.get(base, set()) or
                       suffix in NEW_FORMS.get(base, set()))
        row = {
            "mnemonic": name,
            "family": family(name),
            "profile": profile(name),
            "funct6": fields.get("31..26", ""),
            "funct3": fields.get("14..12", ""),
            "vm_constraint": fields.get("25", "variable"),
            "vs1_constraint": fields.get("19..15", "variable"),
            "decode": "yes" if implemented else prior.get("decode", "no"),
            "execute": "yes" if implemented else prior.get("execute", "no"),
            "integration_test": prior.get("integration_test") or (
                "tb_vcore_alu_top" if name in {
                    "vadd.vv", "vmseq.vv", "vredsum.vs", "vwredsumu.vs",
                    "vcpop.m", "vfirst.m", "vmacc.vx", "vmxor.mm",
                    "vdivu.vx", "vfsgnj.vf", "vfclass.v", "vmfle.vf",
                    "vzext.vf2", "vzext.vf4", "vzext.vf8",
                    "vsext.vf2", "vsext.vf4", "vsext.vf8",
                    "vwaddu.vv", "vwadd.vx", "vwsub.wv",
                    "vfredmin.vs", "vfredmax.vs"
                } or (base in {"vwaddu", "vwadd", "vwsubu", "vwsub"} and
                      suffix in {"vv", "vx", "wv", "wx"}) or
                    (base in {"vwmulu", "vwmulsu", "vwmul", "vwmaccu",
                              "vwmacc", "vwmaccus", "vwmaccsu"} and
                     suffix in NEW_FORMS[base]) or
                    (base in {"vnsrl", "vnsra", "vnclipu", "vnclip"} and
                     suffix in NEW_FORMS[base]) else ""
            ),
            "spec_corner_test": prior.get("spec_corner_test") or (
                "m2/m4/m8, masked, vl=0, vstart!=0"
                if name == "vredsum.vs" else
                "m2, vl=0, vstart!=0" if name == "vwredsumu.vs" else
                "masked, vl=0" if name == "vcpop.m" else
                "first-set index" if name == "vfirst.m" else
                "m2, destructive vd" if name == "vmacc.vx" else
                "m2, unaligned mask registers, tail bits" if name == "vmxor.mm" else
                "m2, NaN/zero, mask and fflags" if name in {
                    "vfredmin.vs", "vfredmax.vs"} else
                "masked lanes, divide by 2" if name == "vdivu.vx" else
                "scalar FP32 sign bits" if name == "vfsgnj.vf" else
                "zero, infinity, sNaN, qNaN" if name == "vfclass.v" else
                "NaN invalid flag and mask result" if name == "vmfle.vf" else
                "m2, shared source register across beats" if name == "vzext.vf2" else
                "byte zero extension" if name == "vzext.vf4" else
                "signed halfword lanes; fractional overlap rejection" if name == "vsext.vf2" else
                "m4, signed byte lanes" if name == "vsext.vf4" else
                "signed byte lanes at SEW=64" if name == "vsext.vf8" else
                "m8, source EMUL=1; overlap boundary" if name == "vzext.vf8" else
                "m2 source, m4 destination" if name == "vwaddu.vv" else
                "signed scalar widened; negative lanes" if name == "vwadd.vx" else
                "wide vs2, narrow vs1; destructive vd" if name == "vwsub.wv" else
                "m1 all lanes, OP-MVV/OP-MVX sweep" if base in {
                    "vwaddu", "vwadd", "vwsubu", "vwsub"} else
                "m1 all lanes; signed/unsigned corners; MAC old vd" if base in {
                    "vwmulu", "vwmulsu", "vwmul", "vwmaccu", "vwmacc",
                    "vwmaccus", "vwmaccsu"} else
                "1R wide source pair, m2/mf2, overlap, vxrm, masked vxsat" if base in {
                    "vnsrl", "vnsra", "vnclipu", "vnclip"} else ""
            ),
            "notes": prior.get("notes", ""),
        }
        rows.append(row)

    if len(rows) != 280:
        raise RuntimeError(f"Expected 280 official ALU encodings, got {len(rows)}")
    rows.sort(key=lambda row: (row["family"], row["mnemonic"]))
    with CHECKLIST.open("w", newline="", encoding="utf-8-sig") as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)

    counts = Counter(row["family"] for row in rows)
    decoded = sum(row["decode"] == "yes" for row in rows)
    executed = sum(row["execute"] == "yes" for row in rows)
    integrated = sum(bool(row["integration_test"]) for row in rows)
    target_rows = [row for row in rows if row["profile"] != "FP64 feature conditional"]
    target_done = sum(row["execute"] == "yes" for row in target_rows)
    text = [
        "# RVV ALU 구현 체크리스트",
        "",
        f"공식 [rv_v opcode 파일]({SOURCE_URL})의 OP-V 인코딩에서 설정 3개와 permutation 34개를 제외한 **280개 인코딩**을 추적합니다.",
        "전체 인코딩을 참고용으로 표시합니다. 현재 RV32IMFC 목표는 정수 SEW64와 FP32를 지원하는 `Zve64f_Zvl128b` 명령 범위이며, D가 필요한 FP64 인코딩은 대상에서 제외합니다.",
        "",
        f"현재 `decode=yes`: **{decoded}/280**, `execute=yes`: **{executed}/280**, TOP 통합 테스트: **{integrated}/280**.",
        f"현재 목표 범위: **{target_done}/{len(target_rows)}** 실행 구현, 남은 **{len(target_rows)-target_done}**개. FP64 제외 인코딩은 {len(rows)-len(target_rows)}개입니다.",
        "완료는 세 항목과 명세 경계 테스트가 모두 채워진 경우에만 판정합니다.",
        "",
        "| 연산군 | 인코딩 수 |",
        "|---|---:|",
    ]
    text += [f"| {key} | {value} |" for key, value in sorted(counts.items())]
    text += ["", "상세: [RVV_ALU_CHECKLIST.csv](RVV_ALU_CHECKLIST.csv)", ""]
    SUMMARY.write_text("\n".join(text), encoding="utf-8")
    print(f"Wrote {len(rows)} rows; decode={decoded}, execute={executed}, integration={integrated}")


if __name__ == "__main__":
    main()
