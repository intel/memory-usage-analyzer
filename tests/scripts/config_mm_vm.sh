#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Configure zswap

VM_RECLAIM_BATCHSIZE=1
VM_PAGE_CLUSTER=3
COMPRESSION_ALGORITHM=lz4
MTHP="4kB"

show_status() {
  local f
  for f in \
    /proc/sys/vm/reclaim-batchsize \
    /proc/sys/vm/page-cluster \
    /proc/sys/vm/swappiness \
    /proc/sys/vm/overcommit_memory \
    /sys/kernel/mm/swap/singlemapped_ra_enabled; do
    if [[ -e "$f" ]]; then
      grep . -H "$f" || true
    else
      echo "INFO: optional knob not available: $f"
    fi
  done
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

# Process inputs
while getopts "c:r:p:m:h:" opt; do
  case $opt in
    r)
      VM_RECLAIM_BATCHSIZE=$OPTARG
      ;;
    p)
      VM_PAGE_CLUSTER=$OPTARG
      ;;
    c)
      COMPRESSION_ALGORITHM=$OPTARG
      ;;
    m)
      MTHP=$OPTARG
      ;;
    h)
      echo "Usage: $0 [-c <comp_algorithm>] [-r <vm_reclaim_batchsize>] [-p <vm_page_cluster>] [-m <mthp_sizes>]"
      echo "       -c - compression algorithm (default: lz4)"
      echo "       -p - vm_page_cluster (default: 3)"
      echo "       -r - vm_reclaim_batchsize (default: 64)"
      echo "       -m - mTHP sizes, comma-separated (default: 4kB)"
      echo "            available: 16kB,32kB,64kB,128kB,256kB,512kB,1024kB,2048kB"
      echo "       -h - help"
      echo ""
      echo "Examples:"
      echo "  $0 -c deflate-iaa-dynamic -p 3 -r 64"
      echo "  $0 -m 64kB,128kB"
      echo ""
      echo "Available compression algorithms:"
      echo "  lzo, lz4, zstd, deflate-iaa"
      exit
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

update_sysfs /proc/sys/vm/reclaim-batchsize ${VM_RECLAIM_BATCHSIZE}
update_sysfs /proc/sys/vm/page-cluster      ${VM_PAGE_CLUSTER} 
update_sysfs /proc/sys/vm/swappiness 100
update_sysfs /proc/sys/vm/overcommit_memory 1

update_sysfs /sys/kernel/mm/swap/singlemapped_ra_enabled false
if [[ "${COMPRESSION_ALGORITHM}" == *"deflate"* ]]; then
    update_sysfs /sys/kernel/mm/swap/singlemapped_ra_enabled true
fi

# Disable THP and set mTHP
update_sysfs /sys/kernel/mm/transparent_hugepage/enabled never
update_sysfs /sys/kernel/mm/transparent_hugepage/defrag never
mthp_list="4kB"
mthp_sizes=('16kB' '32kB' '64kB' '128kB' '256kB' '512kB' '1024kB' '2048kB')
IFS=',' read -a mthp_list <<< "$MTHP"
#echo ${mthp_list[@]}
for mthp in "${mthp_sizes[@]}"; do
    update_sysfs /sys/kernel/mm/transparent_hugepage/hugepages-${mthp}/enabled never
done
max_mthp=0
for mthp in "${mthp_list[@]}"; do
    mthp=`echo $mthp | tr -d ' '`
    if [[ ${mthp_sizes[@]} =~ ($mthp) ]] ; then
        if [ $mthp != '4kB' ]; then
            echo "configuring mthp ${mthp}"
            update_sysfs /sys/kernel/mm/transparent_hugepage/hugepages-${mthp}/enabled always
	fi
    fi
done

show_status
exit 0
