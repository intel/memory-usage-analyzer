#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Configure zswap

# Enable zswap
echo "Enabling zswap..."
sudo sh -c 'echo zsmalloc > /sys/module/zswap/parameters/zpool'
sudo sh -c 'echo 1 > /sys/module/zswap/parameters/enabled'

# Recheck the configuration
ZPOOL=$(cat /sys/module/zswap/parameters/zpool)
ENABLED=$(cat /sys/module/zswap/parameters/enabled)

if [ "$ZPOOL" == "zsmalloc" ] && [ "$ENABLED" == "Y" ]; then
    echo "zswap has been enabled with zpool set to zsmalloc."
else
    echo "Failed to configure zswap correctly. Please check the parameters."
fi
