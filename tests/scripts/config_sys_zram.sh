#!/bin/bash 
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Configure zram as a swap device for memcached testing

VM_PAGE_CLUSTER=3
VM_RECLAIM_BATCHSIZE=1
CORE_FREQUENCY=3200
LOM_SET="set"
ZRAM_COMP_ALGORITHM="lzo"
ZRAM_DISK_SIZE=""
ZRAM_MEM_LIMIT=""
MODE="swap"
MTHP=""

# Process inputs
while getopts "c:f:r:h:l:m:p:s:t:" opt; do
  case $opt in
    c)
      ZRAM_COMP_ALGORITHM=$OPTARG
      ;;
    f)
      CORE_FREQUENCY=$OPTARG
      ;;
    l)
      # Limit in GB
      ZRAM_MEM_LIMIT=$(($OPTARG))
      ;;
    m)
      # mode fs or swap       
      MODE=$OPTARG
      ;;
    p)
      VM_PAGE_CLUSTER=$OPTARG
      ;;
    r)
      VM_RECLAIM_BATCHSIZE=$OPTARG
      ;;
    s)
      # Size in GB
      ZRAM_DISK_SIZE=$(($OPTARG))
      ;;
    t)
      # mTHP sizes, comma-separated
      MTHP=$OPTARG
      ;;
    h)
      echo "Usage: $0 [-c <comp_algorithm>] [-s <size_in_GB>] [-t <mthp_sizes>]"
      echo "       -c - zram compression algorithm (default: lzo)"
      echo "       -r - vm_reclaim_batchsize (default: 1)"
      echo "       -p - vm_page_cluster (default: 3)"
      echo "       -f - frequency in MHz (default:2500 Mhz)"
      echo "       -l - zram memory limit in GB (default: none)"
      echo "       -s - zram disk size in GB (default: 25% of total memory)"
      echo "       -t - mTHP sizes, comma-separated (e.g. 64kB,128kB)"
      echo "       -h - help"
      echo ""
      echo "Examples:"
      echo "  $0 -c lz4 -r 1 -p 3      # configure with zswap_compressor=lz4, vm_reclaim_batchsize=1 and vm_page_cluster=3"
      echo "  $0 -c lz4 -t 64kB,128kB  # configure with mTHP 64kB and 128kB enabled"
      echo ""
      echo "Available compression algorithms:"
      echo "  lzo, lz4, zstd, deflate-iaa, deflate-iaa-dynamic"
      exit
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)
${SCRIPT_DIR}/set_unset_lom.sh ${LOM_SET}
${SCRIPT_DIR}/set_core_frequency.sh -f ${CORE_FREQUENCY}
${SCRIPT_DIR}/reset_zram_zswap.sh; 
${SCRIPT_DIR}/enable_iaa.sh; 
ZRAM_PARAMS="-c ${ZRAM_COMP_ALGORITHM}"
[[ ! -z $ZRAM_MEM_LIMIT ]] && ZRAM_PARAMS+=" -l $ZRAM_MEM_LIMIT"
[[ ! -z $ZRAM_DISK_SIZE ]] && ZRAM_PARAMS+=" -s $ZRAM_DISK_SIZE"
if [[ -z "$ZRAM_DISK_SIZE" || "$ZRAM_DISK_SIZE" -ne 0 ]]; then
    echo "Configuring zram"
    ${SCRIPT_DIR}/config_zram.sh ${ZRAM_PARAMS} 
else
    echo "** Skipping zram Configuration **"
fi
MM_VM_PARAMS="-r ${VM_RECLAIM_BATCHSIZE} -p ${VM_PAGE_CLUSTER} -c ${ZRAM_COMP_ALGORITHM}"
[[ -n "$MTHP" ]] && MM_VM_PARAMS+=" -m $MTHP"
${SCRIPT_DIR}/config_mm_vm.sh ${MM_VM_PARAMS}; 
