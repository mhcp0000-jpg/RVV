#!/bin/bash
# -Wno-TIMESCALEMOD: only the testbench carries a `timescale (it needs #1 delays);
# the RTL deliberately does not, same as the other clusters.
set -e
python3 generate_store_checklist.py
python3 verify_store_decode_table.py
verilator --binary --timing -Wall -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  -j 4 -Mdir obj_dectab -o vstdectab \
  vcore_vst_pkg.sv vcore_vst_decode.sv tb_vcore_vst_decode_table.sv \
  --top-module tb_vcore_vst_decode_table > build_dectab.log 2>&1
./obj_dectab/vstdectab
