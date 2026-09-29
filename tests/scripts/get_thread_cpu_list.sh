#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# get_thread_cpu_list.sh - Emit a CPU list for numactl --physcpubind sized for
# a given thread count, mirroring the "siblings-first" core_policy used by
# tests/redis/benchmark.sh (see get_redis_cpu_plan.sh): within each socket,
# all primary (non-SMT-sibling) cores are used before spilling onto that
# socket's sibling (hyperthread) cores, and the allocation only moves on to
# the next socket once both the primary and sibling cores of the current
# socket are exhausted.
#
# Usage: get_thread_cpu_list.sh <nthreads> [reserved_cpu_start=1]
#   nthreads:           number of CPUs to select
#   reserved_cpu_start: lowest CPU id eligible for selection (CPUs below this
#                       are skipped, e.g. to reserve cpu0 for the OS/driver
#                       thread). Default: 1.
#
# Prints a comma-separated CPU id list on stdout.

set -euo pipefail

nthreads=${1:?nthreads required}
reserved_cpu_start=${2:-1}

if [[ ! "$nthreads" =~ ^[0-9]+$ || "$nthreads" -lt 1 ]]; then
    echo "ERROR: invalid nthreads: $nthreads" >&2
    exit 1
fi

if [[ ! "$reserved_cpu_start" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid reserved_cpu_start: $reserved_cpu_start" >&2
    exit 1
fi

is_primary_core() {
    local c="$1" first
    first=$(cut -d, -f1 "/sys/devices/system/cpu/cpu${c}/topology/thread_siblings_list" 2>/dev/null || true)
    [[ -n "$first" && "$c" -eq "$first" ]]
}

mapfile -t sockets < <(lscpu --parse=SOCKET | awk -F, '!/^#/ && $1 != "" { s[$1]=1 } END { n=asorti(s, o); for (i=1;i<=n;i++) print o[i] }')

if [[ "${#sockets[@]}" -eq 0 ]]; then
    echo "ERROR: failed to determine CPU sockets via lscpu" >&2
    exit 1
fi

pool=()
for socket in "${sockets[@]}"; do
    mapfile -t socket_cpus < <(lscpu --parse=CPU,SOCKET | awk -F, -v s="$socket" '!/^#/ && $2==s { print $1 }' | sort -n)
    primary=()
    sibling=()
    for c in "${socket_cpus[@]}"; do
        [[ "$c" -lt "$reserved_cpu_start" ]] && continue
        if is_primary_core "$c"; then
            primary+=("$c")
        else
            sibling+=("$c")
        fi
    done
    pool+=("${primary[@]}" "${sibling[@]}")
done

if [[ "${#pool[@]}" -lt "$nthreads" ]]; then
    echo "ERROR: requested $nthreads threads but only ${#pool[@]} CPUs available (reserved_cpu_start=$reserved_cpu_start)" >&2
    exit 1
fi

selected=("${pool[@]:0:$nthreads}")
IFS=,
echo "${selected[*]}"
