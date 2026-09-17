#!/bin/bash
# $1 = MAX_OUTSTANDING, $2 = memory latency
set -e
M=${1:-8}; L=${2:-6}
verilator --binary --timing -Wall -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
  --assert -j 4 -Mdir obj_dir_${M}_${L} -o vldtb_${M}_${L} \
  -GMAX_OUT=$M -GLAT=$L \
  vcore_vld_pkg.sv vcore_vld_decode.sv vcore_vld_issue_fifo.sv \
  vcore_vld_sequencer.sv vcore_vld_memreq.sv vcore_vld_assemble.sv \
  vcore_vld_pipe.sv vcore_vld_wb.sv vcore_vld_top.sv tb_vcore_vld_top.sv \
  --top-module tb_vcore_vld_top > build_${M}_${L}.log 2>&1
./obj_dir_${M}_${L}/vldtb_${M}_${L}
