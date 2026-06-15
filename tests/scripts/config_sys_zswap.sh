#!/bin/bash 
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Configure zram as a swap device for memcached testing

ZSWAP_COMP_ALGORITHM="lz4"
VM_PAGE_CLUSTER=3
VM_RECLAIM_BATCHSIZE=1
CORE_FREQUENCY=3500
LOM_SET="set"

# Process inputs
while getopts "c:f:r:h:p:" opt; do
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
    h)
      echo "Usage: $0 [-c <comp_algorithm>] [-s <size_in_GB>]"
      echo "       -c - zswap compression algorithm (default: lzo)"
      echo "       -r - vm_reclaim_batchsize(default: 1)"
      echo "       -p - vm_page_cluster(default: 3)"
      echo "       -f - frequency in MHz(default:2500 Mhz)"
      echo "       -h - help"
      echo ""
      echo "Examples:"
      echo "  $0 -c lz4 -r 1 -p 3      # configure with zswap_compressor=lz4, vm_reclaim_batchsize=1 and vm_page_cluster=3"
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
${SCRIPT_DIR}/config_mm_vm.sh -r ${VM_RECLAIM_BATCHSIZE} -p ${VM_PAGE_CLUSTER} -c ${ZSWAP_COMP_ALGORITHM}; 
