#!/bin/bash
# Golden-reference sweep. $1 = STRESS (0 clean, 1 random), $2 = MAX_OUTSTANDING.
set -e
S=${1:-0}
M=${2:-8}
D=obj_ref_${S}_${M}
verilator --binary --timing --assert -Wall -Wno-UNUSEDSIGNAL -Wno-TIMESCALEMOD \
  -j 0 -O2 --Mdir $D -o vstref \
  -GSTRESS=$S -GMAX_OUT=$M \
  -f filelist.f tb_vcore_vst_ref.sv --top-module tb_vcore_vst_ref
./$D/vstref
