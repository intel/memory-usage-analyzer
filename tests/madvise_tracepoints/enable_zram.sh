#!/bin/bash 
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Configure zram as a swap device

# Enable zram 
MAX_MEM_SIZE=$( free -b | grep Mem | awk '{print $2}' )
# 30% of the max.memory
ZRAM_RATIO=0.3
ZRAM_DISK_SIZE=`echo "${MAX_MEM_SIZE}*${ZRAM_RATIO}" | bc`
ZRAM_DISK_SIZE=`printf %.f ${ZRAM_DISK_SIZE}`
ZRAM_MEM_LIMIT=${ZRAM_DISK_SIZE}

# setup zram
echo "Setting up zram"
swapoff -a
if [[  -e "/dev/zram0" ]]; then
    umount -f /dev/zram0 >& /dev/null
    echo 0 > /sys/class/zram-control/hot_remove
fi

modprobe zram num_devices=1
cat /sys/class/zram-control/hot_add > /dev/null

echo lzo > /sys/block/zram0/comp_algorithm
echo ${ZRAM_DISK_SIZE} > /sys/block/zram0/disksize
echo ${ZRAM_MEM_LIMIT} > /sys/block/zram0/mem_limit

mkswap /dev/zram0 > /dev/null
swapon /dev/zram0
