#!/bin/bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Intel Corporation

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DATE=$(date +%Y%m%d_%H%M%S)

# Get the number of cores per socket and threads per core (sibling cores)
cores_per_socket=$(lscpu | grep "Core(s) per socket:" | awk '{print $4}')
threads_per_core=$(lscpu | grep "Thread(s) per core:" | awk '{print $4}')

if [[ -z "$cores_per_socket" || ! "$cores_per_socket" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Could not determine cores per socket"
    exit 1
fi

if [[ -z "$threads_per_core" || ! "$threads_per_core" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Could not determine threads per core"
    exit 1
fi

# Calculate total logical CPUs per socket (cores × threads per core)
total_cpus_per_socket=$(( cores_per_socket * threads_per_core ))

echo "Cores per socket: $cores_per_socket"
echo "Threads per core: $threads_per_core"
echo "Total logical CPUs per socket: $total_cpus_per_socket"

# Calculate the different core counts
core_counts=(1)
core_counts+=($(( total_cpus_per_socket * 25 / 100 )))
core_counts+=($(( total_cpus_per_socket * 50 /100 )))
core_counts+=($(( total_cpus_per_socket * 75 / 100 )))
core_counts+=($(( total_cpus_per_socket )))

echo "Running benchmarks with the following core counts: ${core_counts[@]}"

# Run benchmark.sh for each core count
for cores in "${core_counts[@]}"; do
    logdir="${THIS_DIR}/logdir_i${cores}_c4_t1_p1_${DATE}"
    echo ""
    echo "========================================="
    echo "Running benchmark with $cores cores"
    echo "Logdir: $logdir"
    echo "========================================="
    
    cd "${THIS_DIR}"
    ./benchmark.sh  "$cores" all --logdir "$logdir"
    
    if [[ $? -ne 0 ]]; then
        echo "ERROR: benchmark.sh failed for core count $cores"
        exit 1
    fi
done

echo ""
echo "========================================="
echo "All benchmarks completed successfully!"
echo "Results saved in:"
for cores in "${core_counts[@]}"; do
    echo "  ${THIS_DIR}/logdir_i${cores}_c4_t1_p1_${DATE}"
done
echo "========================================="

