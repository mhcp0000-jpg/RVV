#!/bin/bash
set -e
verilator --binary --timing -Wall -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
  --assert -j 4 -Mdir obj_smoke -o vstsmoke \
  $(cat filelist.f) tb_vcore_vst_smoke.sv \
  --top-module tb_vcore_vst_smoke > build_smoke.log 2>&1
./obj_smoke/vstsmoke
