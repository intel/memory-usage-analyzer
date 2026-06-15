
#!/bin/bash 
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: reset zram and zswap modules

ZRAM_MOUNT="/mnt/zram_disk"
ZRAM_DEV="/dev/zram0"
SWAPFILE=/swapfile

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
    if lsmod | grep -qw zram; then
        rmmod zram
    fi
}

reset_zswap(){
    if [[ -d /sys/module/zswap ]] && [[ $(cat /sys/module/zswap/parameters/enabled) == Y ]]; then
        echo "Disabling zswap"
        echo N | sudo tee /sys/module/zswap/parameters/enabled
        sudo swapoff -a
    fi
}

reset_swap(){
    sudo swapoff "$SWAPFILE" 2>/dev/null
    sudo rm -f "$SWAPFILE"
}

reset_zram
reset_zswap
reset_swap
