#!/bin/bash

if [ ! -z ${XILINX_VIVADO} ]; then
  source ${XILINX_VIVADO}/settings64.sh
  alias gmake=make
else
  echo "WARNING: No Vivado found, expect errors..."
fi

$@
