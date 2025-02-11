#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025, Intel Corporation
#
# One-time setup of IAA devices and WQs. Please run this script once, after
# reboot and before running tests/workloads with IAA as the zswap compressor.
#
# Arguments:
#
#     iaa_devices  - Number of IAA devices to enable: default 1.
#
################################################################################

iaa_devices=${1:-1}

# Configure IAA
./enable_kernel_iaa.sh 0 1 ${iaa_devices} 8 2 async
# Configure zswap.
./enable_zswap.sh
# Optional: swap disk can be used instead of zram.
# This will configure 30% of available memory for zram.
./enable_zram.sh


