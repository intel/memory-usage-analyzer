#!/bin/bash 
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Configure zram as a swap device for memcached testing

ZRAM_COMP_ALGORITHM=${1:-lzo}
# Default to 1GB ZRAM size for memcached testing
ZRAM_DISK_SIZE=$((1 * 1024 * 1024 * 1024))  # 1GB in bytes
ZRAM_MEM_LIMIT=${ZRAM_DISK_SIZE}

# Process inputs
while getopts "c:s:h" opt; do
  case $opt in
    c)
      ZRAM_COMP_ALGORITHM=$OPTARG
      ;;
    s)
      # Size in GB
      ZRAM_DISK_SIZE=$(($OPTARG * 1024 * 1024 * 1024))
      ZRAM_MEM_LIMIT=${ZRAM_DISK_SIZE}
      ;;
    h)
      echo "Usage: $0 [-c <comp_algorithm>] [-s <size_in_GB>]"
      echo "       -c - compression algorithm (default: lzo)"
      echo "       -s - ZRAM size in GB (default: 1)"
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

echo "=================================================================="
echo "ZRAM SETUP FOR MEMCACHED TESTING"
echo "=================================================================="
echo "Compression algorithm: $ZRAM_COMP_ALGORITHM"
echo "ZRAM disk size:        $((ZRAM_DISK_SIZE / 1024 / 1024 / 1024)) GB"
echo "=================================================================="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" 
   exit 1
fi

# setup zram

# clear any previous usage of zram
echo "Cleaning up any existing ZRAM setup..."
swapoff -a 2>/dev/null || true
if mountpoint -q /mnt/zram_disk 2>/dev/null; then
    umount /mnt/zram_disk
    echo "Unmounted existing /mnt/zram_disk"
fi

# Check and remove all existing zram devices
echo "Checking for existing zram devices..."
for zram_dev in /dev/zram*; do
    if [[ -e "$zram_dev" ]]; then
        device_num=$(basename "$zram_dev" | sed 's/zram//')
        echo "Removing existing zram device: $zram_dev"
        echo "$device_num" > /sys/class/zram-control/hot_remove 2>/dev/null || true
    fi
done

# Load zram module and create device
echo "Loading zram module..."
modprobe zram 
cat /sys/class/zram-control/hot_add > /dev/null

# Configure zram device
echo "Configuring ZRAM device..."

# Extract base compressor name (remove batch size suffix if present)
BASE_COMP_ALGORITHM=${ZRAM_COMP_ALGORITHM}
if [[ "${ZRAM_COMP_ALGORITHM}" == *"_b_"* ]]; then
    # Extract everything before _b_ (e.g., deflate-iaa-dynamic_b_1 -> deflate-iaa-dynamic)
    BASE_COMP_ALGORITHM=$(echo "${ZRAM_COMP_ALGORITHM}" | sed 's/_b_.*$//')
fi

echo "Setting compression algorithm to: ${BASE_COMP_ALGORITHM}"
echo ${BASE_COMP_ALGORITHM} > /sys/block/zram0/comp_algorithm

echo ${ZRAM_DISK_SIZE} > /sys/block/zram0/disksize
echo ${ZRAM_MEM_LIMIT} > /sys/block/zram0/mem_limit

# Configure IAA batch size if using IAA compressor
if [[ "${ZRAM_COMP_ALGORITHM}" == *"iaa"* ]]; then
    # Default batch size for IAA
    batch_size=8
    
    # Check if specific batch size is requested in compressor name
    if [[ "${ZRAM_COMP_ALGORITHM}" == *"_b_1"* ]]; then
        batch_size=1
    elif [[ "${ZRAM_COMP_ALGORITHM}" == *"_b_2"* ]]; then
        batch_size=2
    elif [[ "${ZRAM_COMP_ALGORITHM}" == *"_b_4"* ]]; then
        batch_size=4
    elif [[ "${ZRAM_COMP_ALGORITHM}" == *"_b_8"* ]]; then
        batch_size=8
    fi
    
    echo "Setting IAA batch size to: $batch_size"
    if [[ -f /sys/block/zram0/batch_size ]]; then
        echo ${batch_size} > /sys/block/zram0/batch_size
        echo "IAA batch size configured: $(cat /sys/block/zram0/batch_size)"
    else
        echo "Warning: /sys/block/zram0/batch_size not available"
    fi
fi

# Disable single-mapped readahead for consistent memory compression testing
if [[ -f /sys/kernel/mm/swap/singlemapped_ra_enabled ]]; then
    echo "Disabling single-mapped readahead..."
    echo false > /sys/kernel/mm/swap/singlemapped_ra_enabled
fi

# Create filesystem and mount (for testing data storage)
echo "Creating ext4 filesystem on ZRAM..."
mkfs.ext4 /dev/zram0 -q
mkdir -p /mnt/zram_disk
mount /dev/zram0 /mnt/zram_disk

echo ""
echo "=================================================================="
echo "ZRAM SETUP COMPLETE"
echo "=================================================================="
echo "ZRAM devices available:"
ls -la /dev/zram*
echo ""
echo "ZRAM mount point: /mnt/zram_disk"
echo "Available space:"
df -h /mnt/zram_disk
echo ""
echo "ZRAM statistics:"
cat /sys/block/zram0/mm_stat 2>/dev/null || echo "Statistics not available"
echo "=================================================================="
