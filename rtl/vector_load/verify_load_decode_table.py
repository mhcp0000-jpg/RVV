"""Emit vectors for a Verilator test of every official vector-load encoding.

Run generate_load_checklist.py first. The generated hex files go under out/
next to this script (the ALU counterpart writes to the repo-level out/; this
one stays local so it works from a bare checkout of the cluster too).

Three groups are emitted:
  1. all 177 official load encodings, unmasked (vm=1)
  2. the same 177 with vm=0, which also probes the encodings that pin vm=1
     (vlm.v and the whole-register loads) and the masked forms of the rest
  3. the four scalar FP loads that share opcode 0x07 (flh/flw/fld/flq),
     which this cluster must never claim
  4. every out-of-scope encoding again across the whole vtype space
     (4 SEW x 7 LMUL x vm in {0,1}). Rejection of an out-of-scope encoding is
     unconditional, so this group needs no legality model of its own -- it
     catches a reserved field that only slips through at one SEW or LMUL.
     Group 1-3 legality for the in-scope five is cross-checked against an
     independent model in tb_vcore_vld_ref sweep 1.
"""
from __future__ import annotations

import csv
from pathlib import Path

CHECKLIST = Path(__file__).with_name("RVV_LOAD_CHECKLIST.csv")
OUT = Path(__file__).with_name("out")

RS1 = 1
VD = 8          # aligned to EMUL 1/2/4/8, and not v0 (masked vd cannot be v0)
IDX_REG = 2     # vs2 / rs2 for the indexed and strided rows
SEW_CODE = 2    # SEW=32 -> every in-scope EEW gives a legal EMUL at LMUL=1

SEW_BITS = {0: 8, 1: 16, 2: 32, 3: 64}
# vlmul encoding -> (numerator, denominator)
LMUL = {0b000: (1, 1), 0b001: (2, 1), 0b010: (4, 1), 0b011: (8, 1),
        0b111: (1, 2), 0b110: (1, 4), 0b101: (1, 8)}
VLEN = 128


def vlmax(sew_code: int, vlmul: int) -> int:
    num, den = LMUL[vlmul]
    return (num * VLEN) // (den * SEW_BITS[sew_code])


def build(nf: int, mew: int, mop: int, vm: int, lumop: int,
          width: int) -> int:
    return ((nf << 29) | (mew << 28) | (mop << 26) | (vm << 25) |
            (lumop << 20) | (RS1 << 15) | (width << 12) | (VD << 7) | 0x07)


def main() -> None:
    with CHECKLIST.open(newline="", encoding="utf-8-sig") as file:
        rows = list(csv.DictReader(file))
    if len(rows) != 177:
        raise RuntimeError(f"Expected 177 rows, got {len(rows)}")

    inst_lines, expected_lines, name_lines = [], [], []
    sew_lines, vlmul_lines, vl_lines = [], [], []

    def emit(inst: int, accept: bool, label: str,
             sew: int = SEW_CODE, vlmul: int = 0b000, vl: int = 4) -> None:
        inst_lines.append(f"{inst:08x}")
        expected_lines.append("1" if accept else "0")
        name_lines.append(label)
        sew_lines.append(f"{sew:x}")
        vlmul_lines.append(f"{vlmul:x}")
        vl_lines.append(f"{vl:05x}")

    for vm_pass in (1, 0):
        for row in rows:
            nf = int(row["nf"], 0)
            mop = int(row["mop"], 0)
            width = int(row["width"], 0)
            lumop = IDX_REG if row["lumop"] == "vs2/rs2" else int(row["lumop"], 0)
            vm_fixed = row["vm_constraint"]
            accept = row["decode"] == "yes"
            if vm_pass == 0:
                # An encoding that pins vm=1 becomes a reserved encoding here.
                if vm_fixed == "1":
                    accept = False
            emit(build(nf, 0, mop, vm_pass, lumop, width), accept,
                 f"{row['mnemonic']} vm={vm_pass}")

    # Scalar FP loads on the same major opcode: flh(001) flw(010) fld(011) flq(100).
    for width, label in ((0x1, "flh"), (0x2, "flw"), (0x3, "fld"), (0x4, "flq")):
        emit(build(0, 0, 0, 1, 0, width), False, f"{label} (scalar FP load)")

    # Group 4: out-of-scope encodings must stay rejected at every SEW/LMUL.
    for row in rows:
        if row["decode"] == "yes":
            continue
        nf = int(row["nf"], 0)
        mop = int(row["mop"], 0)
        width = int(row["width"], 0)
        lumop = IDX_REG if row["lumop"] == "vs2/rs2" else int(row["lumop"], 0)
        for sew in sorted(SEW_BITS):
            for vlmul in sorted(LMUL):
                for vm in (1, 0):
                    emit(build(nf, 0, mop, vm, lumop, width), False,
                         f"{row['mnemonic']} vm={vm} sew={SEW_BITS[sew]} "
                         f"vlmul={vlmul:03b}",
                         sew=sew, vlmul=vlmul, vl=vlmax(sew, vlmul))

    OUT.mkdir(exist_ok=True)
    (OUT / "vld_decode_inst.hex").write_text("\n".join(inst_lines) + "\n")
    (OUT / "vld_decode_expected.hex").write_text("\n".join(expected_lines) + "\n")
    (OUT / "vld_decode_sew.hex").write_text("\n".join(sew_lines) + "\n")
    (OUT / "vld_decode_vlmul.hex").write_text("\n".join(vlmul_lines) + "\n")
    (OUT / "vld_decode_vl.hex").write_text("\n".join(vl_lines) + "\n")
    (OUT / "vld_decode_names.txt").write_text("\n".join(name_lines) + "\n")
    (OUT / "vld_decode_count.txt").write_text(f"{len(inst_lines)}\n")
    accepted = sum(1 for e in expected_lines if e == "1")
    print(f"Generated {len(inst_lines)} probes "
          f"({accepted} expected accept, {len(inst_lines)-accepted} expected reject); "
          f"SEW code {SEW_CODE}, vd=v{VD}")


if __name__ == "__main__":
    main()
