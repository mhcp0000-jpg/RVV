"""Emit vectors for a Verilator test of every official ALU encoding row.

Run generate_checklist.py first. The generated hex files go under out/.
"""
from __future__ import annotations

import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKLIST = Path(__file__).with_name("RVV_ALU_CHECKLIST.csv")
OUT = ROOT / "out"


def main() -> None:
    with CHECKLIST.open(newline="", encoding="utf-8-sig") as file:
        rows = list(csv.DictReader(file))
    if len(rows) != 280:
        raise RuntimeError(f"Expected 280 rows, got {len(rows)}")
    OUT.mkdir(exist_ok=True)
    inst_lines = []
    expected_lines = []
    sew_lines = []
    for row in rows:
        funct6 = int(row["funct6"], 0)
        funct3 = int(row["funct3"], 0)
        vm = int(row["vm_constraint"], 0) if row["vm_constraint"] != "variable" else 1
        vs1 = (int(row["vs1_constraint"], 0) if row["vs1_constraint"] != "variable"
               else 3)
        inst = (funct6 << 26) | (vm << 25) | (2 << 20) | (vs1 << 15) | (
            funct3 << 12) | (4 << 7) | 0x57
        inst_lines.append(f"{inst:08x}")
        expected_lines.append("1" if row["decode"] == "yes" else "0")
        sew_lines.append("3" if row["mnemonic"].endswith("vf8") else "2")
    (OUT / "alu_decode_inst.hex").write_text("\n".join(inst_lines) + "\n")
    (OUT / "alu_decode_expected.hex").write_text("\n".join(expected_lines) + "\n")
    (OUT / "alu_decode_sew.hex").write_text("\n".join(sew_lines) + "\n")
    print(f"Generated {len(rows)} official encoding probes")


if __name__ == "__main__":
    main()
