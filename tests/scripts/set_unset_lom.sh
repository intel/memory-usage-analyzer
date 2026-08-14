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
    output=$(${SCRIPT_DIR}/bhs-power-mode.sh --status 2>&1)
    if echo "$output" | grep "EFFICIENCY_LATENCY_CTRL_RATIO: 0 MHz" >/dev/null 2>&1; then
        echo "LOM already enabled, skipping."
    else
        echo "Setting LOM. This may take a few seconds..."
        ${SCRIPT_DIR}/bhs-power-mode.sh --latency-optimized-mode 2>&1 | grep -v "Warning:" | grep EFFICIENCY_LATENCY_CTRL_RATIO
    fi
elif [ "$mode" == "unset" ] ; then
    output=$(${SCRIPT_DIR}/bhs-power-mode.sh --status 2>&1)
    if echo "$output" | grep "EFFICIENCY_LATENCY_CTRL_RATIO: 0 MHz" >/dev/null 2>&1; then
        echo "Resetting LOM. This may take a few seconds..."
        ${SCRIPT_DIR}/bhs-power-mode.sh --default 2>&1 | grep EFFICIENCY_LATENCY_CTRL_RATIO
    else
        echo "LOM already disabled, skipping."
    fi
elif [ "$mode" == "status" ] ; then
    echo "Querying LOM status..."
    output=$(${SCRIPT_DIR}/bhs-power-mode.sh --status 2>&1)
    echo "$output" | grep -E "EFFICIENCY_LATENCY_CTRL_RATIO|Socket|Die|Type"
    if echo "$output" | grep "EFFICIENCY_LATENCY_CTRL_RATIO: 0 MHz" >/dev/null 2>&1; then
        echo ""
        echo "LOM: ENABLED (latency-optimized mode)"
    else
        echo ""
        echo "LOM: DISABLED (default mode)"
    fi
else 
    echo "Incorrect mode... Usage: bash set_unset_lom.sh <set / unset / status>"
fi

