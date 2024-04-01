#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

cgpath=${1:-/sys/fs/cgroup}; shift
cgname=${1:-memoryusageanalyzer}; shift

echo system info
uname -a
cat /proc/cmdline
grep -i name /etc/os-release
lscpu
cpupower frequency-info

echo
echo cgroup
if [[ -r ${cgpath}/cgroup.controllers ]]; then
    # cgroup v2
    grep . -r ${cgpath}/${cgname}
fi

echo
echo vm

grep . -H /sys/kernel/mm/transparent_hugepage/enabled
grep . -r /proc/sys/vm/*

if [[ -e "/dev/zram0" ]]; then
    echo
    echo zram
    grep . -H /sys/block/zram0/disksize
    grep . -H /sys/block/zram0/comp_algorithm
    echo "orig_data_size compr_data_size mem_used_total mem_limit mem_used_max same_pages pages_compacted huge_pages"
    cat /sys/block/zram0/mm_stat
fi

echo
echo zswap
grep . -r /sys/module/zswap/parameters /sys/kernel/debug/zswap

echo
echo block devices
lsblk

echo
echo memory
free -ht
