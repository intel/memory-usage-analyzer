#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Configure zswap

COMPRESSOR=${1:-lz4}
status_zswap(){
    grep -H . /sys/module/zswap/parameters/accept_threshold_percent
    grep -H . /sys/module/zswap/parameters/max_pool_percent
    grep -H . /sys/module/zswap/parameters/compressor
    grep -H . /sys/module/zswap/parameters/zpool
    grep -H . /sys/module/zswap/parameters/enabled
}

update_sysfs() {
    local file="$1"
    local value="$2"

    if [[ -e "$file" ]]; then
    if ! echo "$value" > "$file" 2>/dev/null; then
      echo "WARNING: unable to write '$value' to $file (permission denied or read-only)" >&2
    fi
  else
    echo "INFO: optional knob not available: $file"
    fi
}

setup_zswap(){
    compressor=$1
    update_sysfs /sys/module/zswap/parameters/enabled 0
    update_sysfs /sys/module/zswap/parameters/accept_threshold_percent 90
    update_sysfs /sys/module/zswap/parameters/max_pool_percent 35
    update_sysfs /sys/module/zswap/parameters/compressor $compressor
    update_sysfs /sys/module/zswap/parameters/zpool zsmalloc
    update_sysfs /sys/module/zswap/parameters/enabled 1
}

while getopts "c:h:" opt; do
  case $opt in
    c)
      COMPRESSOR=$OPTARG
      ;;
    h)
      echo "Usage: $0 [-c <comp_algorithm>] [-s <size_in_GB>]"
      echo "       -c - compression algorithm (default: lzo)"
      echo "       -h - help"
      echo ""
      echo "Examples:"
      echo "  $0 -c zstd            # configure zswap compressor as zstd"
      echo ""
      echo "Available compression algorithms:"
      echo "  lzo, lz4, zstd, deflate-iaa-dynamic, deflate-iaa"
      exit
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

setup_zswap ${COMPRESSOR}
status_zswap
