#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Create a swap space, if zram is not used

# Default values
DEFAULT_SWAP_LOCATION="/mnt/nvme1/swapfile"
DEFAULT_SWAP_SIZE=10 # in GB

# Parse command line arguments for swap location and size
while getopts "l:s:" opt; do
  case $opt in
    l) SWAP_LOCATION="$OPTARG" ;;
    s) SWAP_SIZE="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# Set default values if not provided
SWAP_LOCATION=${SWAP_LOCATION:-$DEFAULT_SWAP_LOCATION}
SWAP_SIZE=${SWAP_SIZE:-$DEFAULT_SWAP_SIZE}

# Check for active swap
SWAP_ACTIVE=$(swapon -s)

# Check if swap is not in the specified swap location
if ! echo "$SWAP_ACTIVE" | grep -q "$SWAP_LOCATION"; then
  # Extract directory from SWAP_LOCATION
  SWAP_DIR=$(dirname "$SWAP_LOCATION")

  # Check available space in the specified directory
  AVAILABLE_SPACE=$(df "$SWAP_DIR" | awk 'NR==2 {print $4}')
  # Convert available space to GB (assuming 1K block size)
  AVAILABLE_SPACE_GB=$((AVAILABLE_SPACE / 1024 / 1024))

  if [ "$AVAILABLE_SPACE_GB" -gt "$SWAP_SIZE" ]; then
    echo "Creating swap file at $SWAP_LOCATION...it may take some time"
    sudo dd if=/dev/zero of="$SWAP_LOCATION" bs=1G count="$SWAP_SIZE"
    sudo chmod 600 "$SWAP_LOCATION"
    sudo mkswap "$SWAP_LOCATION"
    sudo swapon "$SWAP_LOCATION"
    echo "$SWAP_LOCATION swap swap defaults 0 0" | sudo tee -a /etc/fstab
    echo "Swap file created and activated at $SWAP_LOCATION with size ${SWAP_SIZE}GB."
  else
    echo "Not enough space in $SWAP_DIR to create swap space."
    exit 1
  fi
else
  echo "Swap is already active on $SWAP_LOCATION."
fi
