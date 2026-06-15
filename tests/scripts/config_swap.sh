#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
SWAPFILE=/swapfile
REQUIRED_SIZE_GB=32
REQUIRED_SIZE=$(( REQUIRED_SIZE_GB * 1024 * 1024 * 1024)) 

if [[ -f "$SWAPFILE" ]]; then
    CURRENT_SIZE=$(stat -c%s "$SWAPFILE")

    if (( CURRENT_SIZE >= REQUIRED_SIZE )); then
        echo "Swap file exists and is >= 32G. Nothing to do."
    else
        echo "Swap file exists but is smaller than 32G. Recreating..."
        sudo swapoff "$SWAPFILE" 2>/dev/null
        sudo rm -f "$SWAPFILE"
        sudo fallocate -l ${REQUIRED_SIZE_GB}G "$SWAPFILE"
        sudo chmod 600 "$SWAPFILE"
        sudo mkswap "$SWAPFILE"
        sudo swapon "$SWAPFILE"
    fi
else
    echo "Swap file does not exist. Creating 32G swap file..."
    sudo fallocate -l ${REQUIRED_SIZE_GB}G "$SWAPFILE"
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE"
    sudo swapon "$SWAPFILE"
fi
