#!/bin/bash 
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Configure zram as a swap device for memcached testing


ZRAM_MOUNT="/mnt/zram_disk"
ZRAM_DEV="/dev/zram0"
ZRAM_STAT="/sys/block/zram0/mm_stat"

# Set zram size to 25% of the total memory to start with
default_zram_size() {
  awk '/MemTotal/ {printf "%d\n", $2 * 1024 * 25 / 100}' /proc/meminfo
}

reset_zram(){
    # clear any previous usage of zram
    swapoff -a 2>/dev/null || true
    if mountpoint -q ${ZRAM_MOUNT} 2>/dev/null; then
        umount ${ZRAM_MOUNT}
        rm -rf ${ZRAM_MOUNT}
        echo "Unmounted existing /mnt/zram_disk"
    fi

    # Check and remove all existing zram devices
    for zram_dev in /dev/zram*; do
        if [[ -e "$zram_dev" ]]; then
            device_num=$(basename "$zram_dev" | sed 's/zram//')
            echo "Removing existing zram device: $zram_dev"
            echo "$device_num" > /sys/class/zram-control/hot_remove 
        fi
    done
}

setup_zram(){
    echo "Compression algorithm: $ZRAM_COMP_ALGORITHM"
    echo "ZRAM disk size: $((ZRAM_DISK_SIZE / 1024 / 1024 / 1024)) GB"
    [[ $ZRAM_MEM_LIMIT != "" ]] && echo "ZRAM memlimit: $((ZRAM_MEM_LIMIT / 1024 / 1024 / 1024)) GB"
    modprobe zram num_devices=1

    # Configure zram device
    echo "Setting compression algorithm to: ${ZRAM_COMP_ALGORITHM}"
    echo ${ZRAM_COMP_ALGORITHM} > /sys/block/zram0/comp_algorithm
    cat /sys/block/zram0/comp_algorithm
    echo ${ZRAM_DISK_SIZE} > /sys/block/zram0/disksize
    # This is optional and hence do it only if we want to limit zram allocation
    [[ $ZRAM_MEM_LIMIT != "" ]] && echo ${ZRAM_MEM_LIMIT} > /sys/block/zram0/mem_limit
}

ZRAM_COMP_ALGORITHM=lzo
ZRAM_DISK_SIZE=$(default_zram_size)
ZRAM_MEM_LIMIT=""
MODE="swap"

# Process inputs
while getopts "c:s:h:l:m:" opt; do
  case $opt in
    c)
      ZRAM_COMP_ALGORITHM=$OPTARG
      ;;
    s)
      # Size in GB
      ZRAM_DISK_SIZE=$(($OPTARG * 1024 * 1024 * 1024))
      ;;
    l)
      # Limit in GB
      ZRAM_MEM_LIMIT=$(($OPTARG * 1024 * 1024 * 1024))
      ;;
    m)
      # mode fs or swap       
      MODE=$OPTARG
      ;;
    h)
      echo "Usage: $0 [-c <comp_algorithm>] [-s <size_in_GB>]"
      echo "       -c - compression algorithm (default: lzo)"
      echo "       -s - ZRAM size in GB (default: 1)"
      echo "       -l - ZRAM memlimit in GB (default: 1)"
      echo "       -m - swap or fs (default: swap)"
      echo "       -h - help"
      echo ""
      echo "Examples:"
      echo "  $0                    # Create 1GB ZRAM with lzo compression"
      echo "  $0 -c lz4 -s 2        # Create 2GB ZRAM with lz4 compression"
      echo "  $0 -c zstd            # Create 1GB ZRAM with zstd compression"
      echo ""
      echo "Available compression algorithms:"
      echo "  lzo, lz4, zstd, deflate"
      exit
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done
# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" 
   exit 1
fi

# Reset
reset_zram

[[ ${MODE} == "stop" ]] && exit

case "$MODE" in
  swap)
    setup_zram
    mkswap ${ZRAM_DEV} 
    swapon ${ZRAM_DEV}
    cat ${ZRAM_STAT} 2>/dev/null || echo "Statistics not available"
    ;;
  fs)
    setup_zram
    # Create filesystem and mount (for testing data storage)
    echo "Creating ext4 filesystem on ZRAM..."
    mkfs.ext4 ${ZRAM_DEV} -q
    mkdir -p ${ZRAM_MOUNT}
    mount ${ZRAM_DEV} ${ZRAM_MOUNT}
    df -h ${ZRAM_MOUNT}
    ;;
  *)
    echo "${MODE} not valid"
    ;;
esac

