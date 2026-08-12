
#!/bin/bash 
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: reset zram and zswap modules

ZRAM_MOUNT="/mnt/zram_disk"
ZRAM_DEV="/dev/zram0"
SWAPFILE=/swapfile
MAX_WAIT=30
# Residual pages threshold: same-filled/orphaned pages that never drain.
# 100 pages = 400KB — negligible, safe to proceed.
DRAIN_RESIDUAL_THRESHOLD=100

wait_for_zswap_drain() {
    if [[ ! -d /sys/kernel/debug/zswap ]]; then
        return 0
    fi
    local stored prev_stored=0 stall_count=0 swapoff_tried=0
    for (( i=0; i<MAX_WAIT; i++ )); do
        stored=$(cat /sys/kernel/debug/zswap/stored_pages 2>/dev/null || echo 0)
        if (( stored == 0 )); then
            return 0
        fi
        # Residual same-filled/orphaned pages won't drain — accept if below threshold
        if (( stored <= DRAIN_RESIDUAL_THRESHOLD )); then
            echo "  zswap drain complete (residual: $stored pages — same-filled/orphaned, safe to ignore)"
            return 0
        fi
        # Detect stall: if stored_pages hasn't changed for 3 consecutive checks,
        # the pages are orphaned and passive drain will never clear them.
        if (( stored == prev_stored )); then
            stall_count=$((stall_count + 1))
        else
            stall_count=0
        fi
        prev_stored=$stored
        # Force-flush via swapoff when drain stalls.  swapoff faults all swap
        # entries back into RAM, which also invalidates the corresponding zswap
        # entries — clearing orphaned pages whose owning process already exited.
        if (( stall_count >= 3 && swapoff_tried == 0 )); then
            swapoff_tried=1
            echo "  zswap drain stalled at $stored pages — forcing swapoff to flush..."
            echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>/dev/null || true
            sudo swapoff -a 2>/dev/null || true
            sleep 2
            sudo swapon -a 2>/dev/null || true
            continue
        fi
        echo "  Waiting for zswap drain (stored_pages=$stored)..."
        sleep 1
    done
    echo "WARNING: zswap pool not fully drained after ${MAX_WAIT}s (stored_pages=$stored)" >&2
    return 1
}

reset_zswap(){
    if [[ -d /sys/module/zswap ]] && [[ $(cat /sys/module/zswap/parameters/enabled 2>/dev/null) == Y ]]; then
        echo "Disabling zswap"
        echo N | sudo tee /sys/module/zswap/parameters/enabled >/dev/null

        # Wait for zswap pool to drain back to swap device
        wait_for_zswap_drain
    fi
}

reset_swap(){
    # Disable all swap — retries if busy
    local attempts=0
    while swapon --show=NAME --noheadings 2>/dev/null | grep -q .; do
        sudo swapoff -a 2>/dev/null
        attempts=$((attempts + 1))
        if (( attempts >= MAX_WAIT )); then
            echo "WARNING: swapoff still failing after ${MAX_WAIT} attempts" >&2
            # Force: drop caches to release swap references
            echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>/dev/null
            sudo swapoff -a 2>/dev/null || true
            break
        fi
        sleep 1
    done

    sudo rm -f "$SWAPFILE"
}

reset_zram(){
    if mountpoint -q ${ZRAM_MOUNT} 2>/dev/null; then
        umount ${ZRAM_MOUNT}
        rm -rf ${ZRAM_MOUNT}
        echo "Unmounted existing /mnt/zram_disk"
    fi

    # Remove all existing zram devices — retry if busy
    for zram_dev in /dev/zram*; do
        if [[ -e "$zram_dev" ]]; then
            local device_num
            device_num=$(basename "$zram_dev" | sed 's/zram//')
            # Reset the device first (releases internal allocations)
            if [[ -f "/sys/block/zram${device_num}/reset" ]]; then
                echo 1 > "/sys/block/zram${device_num}/reset" 2>/dev/null || true
            fi
            echo "Removing zram device: $zram_dev"
            echo "$device_num" > /sys/class/zram-control/hot_remove 2>/dev/null || true
        fi
    done

    if lsmod | grep -qw zram; then
        rmmod zram 2>/dev/null || true
        if lsmod | grep -qw zram; then
            echo "WARNING: could not unload zram module (still in use)" >&2
        fi
    fi
}

# Order matters: disable zswap first (drains pool to swap), then swap off, then remove zram
reset_zswap
reset_swap
reset_zram
