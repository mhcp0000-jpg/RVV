#!/bin/bash
set -e
# -Wno-TIMESCALEMOD: only the testbench carries a `timescale (it needs #1 delays);
# the RTL deliberately does not, same as the other two clusters.
python3 generate_load_checklist.py
python3 verify_load_decode_table.py
verilator --binary --timing -Wall -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  -j 4 -Mdir obj_dectab -o vlddectab \
  vcore_vld_pkg.sv vcore_vld_decode.sv tb_vcore_vld_decode_table.sv \
  --top-module tb_vcore_vld_decode_table > build_dectab.log 2>&1
./obj_dectab/vlddectab
