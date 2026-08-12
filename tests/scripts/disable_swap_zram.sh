#!/bin/bash
# disable_swap_zram.sh
# Disable all swap, reset and remove zram devices safely

set -e

# Check if zswap is enabled and disable it if enabled
zswap_enabled=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null)
if [[ "$zswap_enabled" == "Y" ]]; then
    echo 0 > /sys/module/zswap/parameters/enabled
fi

# Turning off all swap..."
swapon --show --noheadings | awk '{print $1}' | while read swapdev; do
    echo "Disabling swap on $swapdev"
    swapoff "$swapdev" || true
done

# Unmounting zram filesystems (if any)..."
mount | grep zram | awk '{print $1}' | while read zdev; do
    echo "Unmounting $zdev"
    umount "$zdev" || true
done


# Check and remove all existing zram devices
for zram_dev in /dev/zram*; do
    if [[ -e "$zram_dev" ]]; then
        device_num=$(basename "$zram_dev" | sed 's/zram//')
        echo "Removing existing zram device: $zram_dev"
        echo "$device_num" > /sys/class/zram-control/hot_remove
    fi
done


# Removing zram module..."
if lsmod | grep -q '^zram'; then
    rmmod zram && echo "zram module removed" || echo "Could not remove zram (still in use)"
else
    echo "zram module not loaded"
fi
swapon --show
