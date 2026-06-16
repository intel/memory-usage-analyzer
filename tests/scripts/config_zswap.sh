#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Configure zswap

COMPRESSOR=${1:-lz4}
setup_zswap(){
    compressor=$1
    echo 0  > /sys/module/zswap/parameters/enabled
    echo 90 > /sys/module/zswap/parameters/accept_threshold_percent
    echo 35 > /sys/module/zswap/parameters/max_pool_percent
    echo ${COMPRESSOR} > /sys/module/zswap/parameters/compressor
    echo 1  > /sys/module/zswap/parameters/enabled
}
status_zswap(){
    grep -H . /sys/module/zswap/parameters/accept_threshold_percent
    grep -H . /sys/module/zswap/parameters/max_pool_percent
    grep -H . /sys/module/zswap/parameters/compressor
    grep -H . /sys/module/zswap/parameters/enabled
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
