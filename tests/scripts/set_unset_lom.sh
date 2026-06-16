#!/bin/bash 
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Configure LOM
SCRIPT_DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
mode=$1

if ! command -v pcm-tpmi >/dev/null 2>&1 ; then
  echo "PCM Tool Not Found... Installing.. "
  source ${SCRIPT_DIR}/build_pcm.sh
fi

if [ "$mode" = "set" ] ; then 
    echo "Setting LOM. This may take a few seconds..."
    ${SCRIPT_DIR}/bhs-power-mode.sh --latency-optimized-mode 2>&1 | grep -v "Warning:" | grep EFFICIENCY_LATENCY_CTRL_RATIO
elif [ "$mode" == "unset" ] ; then 
    echo "Resetting LOM. This may take a few seconds..."
    ${SCRIPT_DIR}/bhs-power-mode.sh --default 2>&1 | grep EFFICIENCY_LATENCY_CTRL_RATIO
else 
    echo "Incorrect mode... Usage: bash set_unset_lom.sh <set / unset>"
fi

