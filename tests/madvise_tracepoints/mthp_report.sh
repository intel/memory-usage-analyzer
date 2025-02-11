#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025, Intel Corporation

echo "********************************************************************************"
echo "                           COMPRESSOR, mTHP SETTINGS IN EFFECT"
echo "********************************************************************************"
echo
echo "/sys/module/zswap/parameters/compressor = $(cat /sys/module/zswap/parameters/compressor)"
sysctl vm.compress-batchsize
sysctl vm.page-cluster
echo "/sys/kernel/mm/swap/singlemapped_ra_enabled = $(cat /sys/kernel/mm/swap/singlemapped_ra_enabled)"
echo
echo "hugepages-16kB = $(cat /sys/kernel/mm/transparent_hugepage/hugepages-16kB/enabled)"
echo "hugepages-32kB = $(cat /sys/kernel/mm/transparent_hugepage/hugepages-32kB/enabled)"
echo "hugepages-64kB = $(cat /sys/kernel/mm/transparent_hugepage/hugepages-64kB/enabled)"
echo "hugepages-128kB = $(cat /sys/kernel/mm/transparent_hugepage/hugepages-128kB/enabled)"
echo "hugepages-256kB = $(cat /sys/kernel/mm/transparent_hugepage/hugepages-256kB/enabled)"
echo "hugepages-512kB = $(cat /sys/kernel/mm/transparent_hugepage/hugepages-512kB/enabled)"
echo "hugepages-1024kB = $(cat /sys/kernel/mm/transparent_hugepage/hugepages-1024kB/enabled)"
echo "hugepages-2048kB = $(cat /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled)"
echo
echo "PMD-size THP enabled = $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "PMD-size THP defrag = $(cat /sys/kernel/mm/transparent_hugepage/defrag)"
echo
echo "********************************************************************************"
echo
echo "--------------------------------------------------------------------------------"
echo "After running workload: swapon --noheadings and free -h:"
swapon --noheadings
echo
free -h
echo "--------------------------------------------------------------------------------"
echo
