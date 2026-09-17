#!/bin/bash
# $1 = STRESS (0|1)
set -e
S=${1:-0}
verilator --binary --timing -Wall -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
  --assert -j 4 -Mdir obj_ref${S}_${2:-8} -o vldref${S}_${2:-8} \
  -GSTRESS=$S -GMAX_OUT=${2:-8} \
  vcore_vld_pkg.sv vcore_vld_decode.sv vcore_vld_issue_fifo.sv \
  vcore_vld_sequencer.sv vcore_vld_memreq.sv vcore_vld_assemble.sv \
  vcore_vld_pipe.sv vcore_vld_wb.sv vcore_vld_top.sv tb_vcore_vld_ref.sv \
  --top-module tb_vcore_vld_ref > build_ref${S}_${2:-8}.log 2>&1
./obj_ref${S}_${2:-8}/vldref${S}_${2:-8}
