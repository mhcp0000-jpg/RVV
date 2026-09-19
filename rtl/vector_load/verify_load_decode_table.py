"""Emit vectors for a Verilator test of every official vector-load encoding.

Run generate_load_checklist.py first. The generated hex files go under out/.

Now that the cluster implements all 177 encodings, "is this in scope" is no
longer the question; "does the decoder accept exactly the architecturally
legal (encoding, vtype) pairs" is. So the expected answer is computed here by
a model of the RVV 1.0 legality rules written in Python, against the
SystemVerilog decoder.

That Python model and the decoder were written by the same hand, so it is a
coverage instrument, not an independent oracle: it sweeps the whole encoding
space, which the data benches cannot. The independent check on legality is
tb_vcore_vld_ref, whose model is written separately in SystemVerilog and
compares actual register contents.

Groups emitted:
  1. all 177 encodings x 4 SEW x 7 LMUL x vm in {0,1}
  2. reserved and foreign encodings over the same vtypes -- always rejected
"""
from __future__ import annotations

import csv
from pathlib import Path

CHECKLIST = Path(__file__).with_name("RVV_LOAD_CHECKLIST.csv")
OUT = Path(__file__).with_name("out")

VLEN    = 128
RS1     = 1
VD      = 8      # aligned to EMUL 1/2/4/8 and to NREG, and not v0
VS2     = 16     # index base: aligned, and clear of the destination group
SEW_BITS = {0: 8, 1: 16, 2: 32, 3: 64}
LMUL     = {0b000: (1, 1), 0b001: (2, 1), 0b010: (4, 1), 0b011: (8, 1),
            0b111: (1, 2), 0b110: (1, 4), 0b101: (1, 8)}
WIDTH_EEW = {0b000: 8, 0b101: 16, 0b110: 32, 0b111: 64}


def vlmax_of(sew: int, vlmul: int) -> int:
    ln, ld = LMUL[vlmul]
    return (ln * VLEN) // (ld * SEW_BITS[sew])


def legal(nf: int, mew: int, mop: int, vm: int, lumop: int, width: int,
          sew: int, vlmul: int, vl: int) -> bool:
    """RVV 1.0 legality for a vector load at this vtype, with vd=VD, vs2=VS2."""
    if mew:
        return False
    if width not in WIDTH_EEW:
        return False
    w  = WIDTH_EEW[width]
    sb = SEW_BITS[sew]
    ln, ld = LMUL[vlmul]

    nf_val  = nf + 1
    indexed = mop in (1, 3)
    whole = is_mask = False
    nreg = 1

    if mop == 0:
        if lumop == 0x00 or lumop == 0x10:      # unit-stride, fault-only-first
            pass
        elif lumop == 0x0b:                     # vlm.v
            is_mask = True
            if width != 0 or not vm or nf != 0:
                return False
        elif lumop == 0x08:                     # whole register
            whole = True
            if not vm or nf not in (0, 1, 3, 7):
                return False
            nreg = {0: 1, 1: 2, 3: 4, 7: 8}[nf]
            nf_val = 1
        else:
            return False
    elif mop not in (1, 2, 3):
        return False

    # An indexed load takes its data width from vtype and uses `width` for
    # the index; every other form takes its data width from `width`.
    deb = sb if indexed else w

    if indexed:   en, ed = ln, ld
    elif is_mask: en, ed = 1, 1
    else:         en, ed = deb * ln, sb * ld

    if whole:
        regs = nreg
    else:
        if en * 8 < ed or en > ed * 8:          # 1/8 <= EMUL <= 8
            return False
        regs = -(-en // ed)
    if regs > 8:
        return False

    ien, ied = w * ln, sb * ld
    iregs = max(1, -(-ien // ied))
    if indexed:
        if ien * 8 < ied or ien > ied * 8:
            return False
        if iregs > 8:
            return False
        if ien >= ied and iregs > 1 and (VS2 % iregs):
            return False

    total = nf_val * regs
    if total > 8:                                # register budget
        return False
    if not whole and en * nf_val > ed * 8:       # EMUL * NFIELDS <= 8
        return False
    if whole:
        if nreg > 1 and (VD % nreg):
            return False
    elif en >= ed and regs > 1 and (VD % regs):
        return False

    if not whole:
        vlmax = (ln * VLEN) // (ld * sb)
        if vlmax == 0 or vl > vlmax:
            return False
    if not vm and not is_mask and not whole and VD == 0:
        return False
    if indexed and nf_val > 1:
        if VD < VS2 + iregs and VS2 < VD + total:
            return False
    return True


def build(nf: int, mew: int, mop: int, vm: int, lumop: int, width: int) -> int:
    return ((nf << 29) | (mew << 28) | (mop << 26) | (vm << 25) |
            (lumop << 20) | (RS1 << 15) | (width << 12) | (VD << 7) | 0x07)


def main() -> None:
    with CHECKLIST.open(newline="", encoding="utf-8-sig") as file:
        rows = list(csv.DictReader(file))
    if len(rows) != 177:
        raise RuntimeError(f"Expected 177 rows, got {len(rows)}")

    inst_lines, expected_lines, name_lines = [], [], []
    sew_lines, vlmul_lines, vl_lines = [], [], []

    def emit(inst, accept, label, sew, vlmul, vl):
        inst_lines.append(f"{inst:08x}")
        expected_lines.append("1" if accept else "0")
        name_lines.append(label)
        sew_lines.append(f"{sew:x}")
        vlmul_lines.append(f"{vlmul:x}")
        vl_lines.append(f"{vl:05x}")

    # ---- group 1: every official encoding over the whole vtype space ----
    for row in rows:
        nf    = int(row["nf"], 0)
        mop   = int(row["mop"], 0)
        width = int(row["width"], 0)
        lumop = VS2 if row["lumop"] == "vs2/rs2" else int(row["lumop"], 0)
        vm_fixed = row["vm_constraint"]
        for sew in sorted(SEW_BITS):
            for vlmul in sorted(LMUL):
                vl = vlmax_of(sew, vlmul)
                for vm in (1, 0):
                    if vm_fixed == "1" and vm == 0:
                        ok = False          # encoding pins vm=1 -> reserved
                    else:
                        ok = legal(nf, 0, mop, vm, lumop, width, sew, vlmul, vl)
                    emit(build(nf, 0, mop, vm, lumop, width), ok,
                         f"{row['mnemonic']} vm={vm} sew={SEW_BITS[sew]} "
                         f"vlmul={vlmul:03b}", sew, vlmul, vl)

    # ---- group 2: reserved and foreign encodings -------------------------
    reserved = []
    reserved.append((0, 1, 0, 1, 0x00, 0b110, "mew=1 (EEW>64)"))
    for lu in (0x01, 0x02, 0x09, 0x0a, 0x0c, 0x1f):
        reserved.append((0, 0, 0, 1, lu, 0b110, f"reserved lumop={lu:05b}"))
    for wname, wv in (("flh", 0b001), ("flw", 0b010), ("fld", 0b011), ("flq", 0b100)):
        reserved.append((0, 0, 0, 1, 0x00, wv, f"{wname} (scalar FP load)"))
    for bad_nf in (1, 2, 4, 5, 6):   # whole-register nf must encode 1/2/4/8 regs
        if bad_nf in (1, 3, 7):
            continue
        reserved.append((bad_nf, 0, 0, 1, 0x08, 0b110,
                         f"whole-register nf={bad_nf} reserved"))
    for (nf, mew, mop, vm, lumop, width, why) in reserved:
        for sew in sorted(SEW_BITS):
            for vlmul in sorted(LMUL):
                vl = vlmax_of(sew, vlmul)
                emit(build(nf, mew, mop, vm, lumop, width), False,
                     f"{why} sew={SEW_BITS[sew]} vlmul={vlmul:03b}", sew, vlmul, vl)

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
          f"vd=v{VD}, vs2=v{VS2}")


if __name__ == "__main__":
    main()
