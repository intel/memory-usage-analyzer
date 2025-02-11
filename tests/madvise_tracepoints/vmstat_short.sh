#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025, Intel Corporation

# Call the script with mthp_size stats to be reported: e.g.: 4 for 4kB, 64 for 64kB.
mthp=${1:-4}; shift

cat /proc/vmstat | grep -i 'zswpout '
cat /proc/vmstat | grep -i zswpin
cat /proc/vmstat | grep -i pswpout
cat /proc/vmstat | grep -i pswpin
cat /proc/vmstat | grep -i 'thp_swpout '
cat /proc/vmstat | grep -i thp_swpout_fallback
if [ $mthp != 4 ]; then
    echo "${mthp}kB-mTHP_swpout_fallback $(cat /sys/kernel/mm/transparent_hugepage/hugepages-${mthp}kB/stats/swpout_fallback)"
fi
cat /proc/vmstat | grep -i pgmajfault
cat /proc/vmstat | grep -i pgfault
cat /proc/vmstat | grep -i 'swap_ra '
cat /proc/vmstat | grep -i swap_ra_hit

if [ $mthp != 4 ]; then
    echo "ZSWPOUT-${mthp}kB $(cat /sys/kernel/mm/transparent_hugepage/hugepages-${mthp}kB/stats/zswpout)"
fi

if [ $mthp != 4 ]; then
    echo "SWPOUT-${mthp}kB $(cat /sys/kernel/mm/transparent_hugepage/hugepages-${mthp}kB/stats/swpout)"
fi
echo
echo "zswap_reject_alloc_fail $(cat /sys/kernel/debug/zswap/reject_alloc_fail)"
echo "zswap_reject_compress_fail $(cat /sys/kernel/debug/zswap/reject_compress_fail)"
echo "zswap_reject_reclaim_fail $(cat /sys/kernel/debug/zswap/reject_reclaim_fail)"
echo "zswap_reject_compress_poor $(cat /sys/kernel/debug/zswap/reject_compress_poor)"
echo "zswap_reject_kmemcache_fail $(cat /sys/kernel/debug/zswap/reject_kmemcache_fail)"
echo "zswap_pool_total_size $(cat /sys/kernel/debug/zswap/pool_total_size)"
echo "zswap_pool_limit_hit $(cat /sys/kernel/debug/zswap/pool_limit_hit)"
echo
if [ -f /sys/kernel/debug/iaa_crypto/wq_stats ]; then
    echo "IAA device/wq stats and global stats:"
    cat /sys/kernel/debug/iaa_crypto/wq_stats
    cat /sys/kernel/debug/iaa_crypto/global_stats
fi
echo
