"""Emit vectors for a Verilator test of every official vector-store encoding.

Mirrors rtl/vector_load/verify_load_decode_table.py. Expected acceptance is
computed by a Python model of the RVV 1.0 legality rules; it sweeps the whole
encoding space, which no data bench can, and is a coverage instrument rather
than an independent oracle.

Store-specific: no fault-only-first sumop, whole-register is width-000 only,
and there is no v0-overlap or index/source-overlap rule because a store has
no vector destination.
"""
from __future__ import annotations

import csv
from pathlib import Path

CHECKLIST = Path(__file__).with_name("RVV_STORE_CHECKLIST.csv")
OUT = Path(__file__).with_name("out")

VLEN = 128
RS1  = 1
VS3  = 8     # source data register: aligned to EMUL 1/2/4/8 and to NREG
VS2  = 16    # index base: aligned
SEW_BITS  = {0: 8, 1: 16, 2: 32, 3: 64}
LMUL      = {0b000: (1, 1), 0b001: (2, 1), 0b010: (4, 1), 0b011: (8, 1),
             0b111: (1, 2), 0b110: (1, 4), 0b101: (1, 8)}
WIDTH_EEW = {0b000: 8, 0b101: 16, 0b110: 32, 0b111: 64}


def vlmax_of(sew: int, vlmul: int) -> int:
    ln, ld = LMUL[vlmul]
    return (ln * VLEN) // (ld * SEW_BITS[sew])


def legal(nf: int, mew: int, mop: int, vm: int, sumop: int, width: int,
          sew: int, vlmul: int, vl: int) -> bool:
    if mew or width not in WIDTH_EEW:
        return False
    w  = WIDTH_EEW[width]
    sb = SEW_BITS[sew]
    ln, ld = LMUL[vlmul]

    nf_val  = nf + 1
    indexed = mop in (1, 3)
    whole = is_mask = False
    nreg = 1

    if mop == 0:
        if sumop == 0x00:
            pass
        elif sumop == 0x0b:                      # vsm.v
            is_mask = True
            if width != 0 or not vm or nf != 0:
                return False
        elif sumop == 0x08:                      # vs<nreg>r.v
            whole = True
            if not vm or width != 0 or nf not in (0, 1, 3, 7):
                return False
            nreg = {0: 1, 1: 2, 3: 4, 7: 8}[nf]
            nf_val = 1
        else:
            return False                         # no fault-only-first store
    elif mop not in (1, 2, 3):
        return False

    deb = sb if indexed else w
    if indexed:   en, ed = ln, ld
    elif is_mask: en, ed = 1, 1
    else:         en, ed = deb * ln, sb * ld

    if whole:
        regs = nreg
    else:
        if en * 8 < ed or en > ed * 8:
            return False
        regs = -(-en // ed)
    if regs > 8:
        return False

    ien, ied = w * ln, sb * ld
    iregs = max(1, -(-ien // ied))
    if indexed:
        if ien * 8 < ied or ien > ied * 8 or iregs > 8:
            return False
        if ien >= ied and iregs > 1 and (VS2 % iregs):
            return False

    total = nf_val * regs
    if total > 8:
        return False
    if whole:
        if nreg > 1 and (VS3 % nreg):
            return False
    elif en >= ed and regs > 1 and (VS3 % regs):
        return False

    if not whole:
        vlmax = (ln * VLEN) // (ld * sb)
        if vlmax == 0 or vl > vlmax:
            return False
    # No v0-overlap rule and no index/source overlap rule: a store has no
    # vector destination, and vs2/vs3 are both sources.
    return True


def build(nf: int, mew: int, mop: int, vm: int, sumop: int, width: int) -> int:
    return ((nf << 29) | (mew << 28) | (mop << 26) | (vm << 25) |
            (sumop << 20) | (RS1 << 15) | (width << 12) | (VS3 << 7) | 0x27)


def main() -> None:
    with CHECKLIST.open(newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    if len(rows) != 133:
        raise RuntimeError(f"Expected 133 rows, got {len(rows)}")

    inst, exp, names, sews, vlmuls, vls = [], [], [], [], [], []

    def emit(i, ok, label, sew, vlmul, vl):
        inst.append(f"{i:08x}"); exp.append("1" if ok else "0"); names.append(label)
        sews.append(f"{sew:x}"); vlmuls.append(f"{vlmul:x}"); vls.append(f"{vl:05x}")

    for row in rows:
        nf    = int(row["nf"], 0)
        mop   = int(row["mop"], 0)
        width = int(row["width"], 0)
        sumop = VS2 if row["sumop"] == "vs2/rs2" else int(row["sumop"], 0)
        vm_fixed = row["vm_constraint"]
        for sew in sorted(SEW_BITS):
            for vlmul in sorted(LMUL):
                vl = vlmax_of(sew, vlmul)
                for vm in (1, 0):
                    ok = False if (vm_fixed == "1" and vm == 0) else \
                         legal(nf, 0, mop, vm, sumop, width, sew, vlmul, vl)
                    emit(build(nf, 0, mop, vm, sumop, width), ok,
                         f"{row['mnemonic']} vm={vm} sew={SEW_BITS[sew]} "
                         f"vlmul={vlmul:03b}", sew, vlmul, vl)

    reserved = [(0, 1, 0, 1, 0x00, 0b110, "mew=1 (EEW>64)")]
    for su in (0x01, 0x02, 0x09, 0x0a, 0x0c, 0x10, 0x1f):
        # 0x10 is the LOAD's fault-only-first sumop: reserved on a store
        reserved.append((0, 0, 0, 1, su, 0b110, f"reserved sumop={su:05b}"))
    for nm, wv in (("fsh", 0b001), ("fsw", 0b010), ("fsd", 0b011), ("fsq", 0b100)):
        reserved.append((0, 0, 0, 1, 0x00, wv, f"{nm} (scalar FP store)"))
    for bad_nf in (2, 4, 5, 6):
        reserved.append((bad_nf, 0, 0, 1, 0x08, 0b000,
                         f"whole-register nf={bad_nf} reserved"))
    for wv in (0b101, 0b110, 0b111):
        reserved.append((0, 0, 0, 1, 0x08, wv,
                         f"whole-register width={wv:03b} reserved"))
    for (nf, mew, mop, vm, su, width, why) in reserved:
        for sew in sorted(SEW_BITS):
            for vlmul in sorted(LMUL):
                emit(build(nf, mew, mop, vm, su, width), False,
                     f"{why} sew={SEW_BITS[sew]} vlmul={vlmul:03b}",
                     sew, vlmul, vlmax_of(sew, vlmul))

    OUT.mkdir(exist_ok=True)
    (OUT / "vst_decode_inst.hex").write_text("\n".join(inst) + "\n")
    (OUT / "vst_decode_expected.hex").write_text("\n".join(exp) + "\n")
    (OUT / "vst_decode_sew.hex").write_text("\n".join(sews) + "\n")
    (OUT / "vst_decode_vlmul.hex").write_text("\n".join(vlmuls) + "\n")
    (OUT / "vst_decode_vl.hex").write_text("\n".join(vls) + "\n")
    (OUT / "vst_decode_names.txt").write_text("\n".join(names) + "\n")
    (OUT / "vst_decode_count.txt").write_text(f"{len(inst)}\n")
    acc = sum(1 for e in exp if e == "1")
    print(f"Generated {len(inst)} probes ({acc} expected accept, "
          f"{len(inst)-acc} expected reject); vs3=v{VS3}, vs2=v{VS2}")


if __name__ == "__main__":
    main()
