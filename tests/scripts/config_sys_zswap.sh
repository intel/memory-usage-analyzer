#!/bin/bash 
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Configure zram as a swap device for memcached testing

ZSWAP_COMP_ALGORITHM="lz4"
VM_PAGE_CLUSTER=3
VM_RECLAIM_BATCHSIZE=1
CORE_FREQUENCY=3200
LOM_SET="set"
MTHP=""

# Process inputs
while getopts "c:f:r:h:p:t:" opt; do
  case $opt in
    c)
      ZSWAP_COMP_ALGORITHM=$OPTARG
      ;;
    f)
      CORE_FREQUENCY=$OPTARG
      ;;
    p)
      VM_PAGE_CLUSTER=$OPTARG
      ;;
    r)
      VM_RECLAIM_BATCHSIZE=$OPTARG
      ;;
    t)
      # mTHP sizes, comma-separated
      MTHP=$OPTARG
      ;;
    h)
      echo "Usage: $0 [-c <comp_algorithm>] [-t <mthp_sizes>]"
      echo "       -c - zswap compression algorithm (default: lzo)"
      echo "       -r - vm_reclaim_batchsize(default: 1)"
      echo "       -p - vm_page_cluster(default: 3)"
      echo "       -f - frequency in MHz(default:2500 Mhz)"
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
${SCRIPT_DIR}/config_zram.sh;
${SCRIPT_DIR}/config_zswap.sh -c ${ZSWAP_COMP_ALGORITHM} 
MM_VM_PARAMS="-r ${VM_RECLAIM_BATCHSIZE} -p ${VM_PAGE_CLUSTER} -c ${ZSWAP_COMP_ALGORITHM}"
[[ -n "$MTHP" ]] && MM_VM_PARAMS+=" -m $MTHP"
${SCRIPT_DIR}/config_mm_vm.sh ${MM_VM_PARAMS}; 
