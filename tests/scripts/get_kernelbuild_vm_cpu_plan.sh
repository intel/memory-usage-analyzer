#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Intel Corporation
#
# Compute a CPU plan for the kernelbuild_vm benchmark.
# Uses only primary (non-HT) cores from the first socket (all its NUMA nodes,
# supporting SNC2/SNC3 topologies where one socket spans multiple nodes).
# Output (stdout, machine-parseable):
#   num_vms=<N> vm_cpus=<M> available_cores=<C> nodes=<n0,n1,...> vm_cpusets=<set1;set2;...>

set -euo pipefail

VM_CPUS=${1:-8}
CPU_START=${2:-0}
CORE_POLICY=${3:-primary-only}  # primary-only | all

if [[ ! "$VM_CPUS" =~ ^[0-9]+$ || "$VM_CPUS" -lt 1 ]]; then
    echo "ERROR: invalid VM_CPUS: $VM_CPUS" >&2
    exit 1
fi

expand_cpulist() {
    local cpulist="$1"
    tr ',' '\n' <<<"$cpulist" | while read -r r; do
        [[ -z "$r" ]] && continue
        if [[ "$r" == *-* ]]; then
            IFS=- read -r a b <<<"$r"
            seq "$a" "$b"
        else
            echo "$r"
        fi
    done
}

is_primary_core() {
    local c="$1"
    local first
    first=$(cut -d, -f1 "/sys/devices/system/cpu/cpu${c}/topology/thread_siblings_list" 2>/dev/null || true)
    [[ -n "$first" && "$c" -eq "$first" ]]
}

get_first_socket_id() {
    lscpu --parse=SOCKET | awk -F, '!/^#/ && $1 != "" { sockets[$1]=1 } END { n=asorti(sockets, ordered); if (n >= 1) print ordered[1] }'
}

get_all_numa_nodes_for_socket() {
    local socket_id="$1"
    lscpu --parse=SOCKET,NODE | awk -F, -v socket="$socket_id" \
        '!/^#/ && $1==socket && $2 != "" { nodes[$2]=1 } END { n=asorti(nodes, ordered); for (i=1; i<=n; i++) print ordered[i] }'
}

get_numa_node_cpus() {
    local node_id="$1"
    if [[ -r "/sys/devices/system/node/node${node_id}/cpulist" ]]; then
        expand_cpulist "$(cat "/sys/devices/system/node/node${node_id}/cpulist")"
    fi
}

# Resolve first socket and all its NUMA nodes (handles SNC2/SNC3)
first_socket=$(get_first_socket_id)
mapfile -t socket_nodes < <(get_all_numa_nodes_for_socket "$first_socket")

if [[ "${#socket_nodes[@]}" -eq 0 ]]; then
    echo "ERROR: no NUMA nodes found for socket $first_socket" >&2
    exit 1
fi

nodes_csv=$(IFS=,; echo "${socket_nodes[*]}")

# Collect primary cores from all NUMA nodes on this socket
pool=()
for node in "${socket_nodes[@]}"; do
    mapfile -t node_cpus < <(get_numa_node_cpus "$node")
    for c in "${node_cpus[@]}"; do
        [[ "$c" -lt "$CPU_START" ]] && continue
        if [[ "$CORE_POLICY" == "primary-only" ]]; then
            is_primary_core "$c" && pool+=("$c")
        else
            pool+=("$c")
        fi
    done
done

available_cores=${#pool[@]}
if (( available_cores < VM_CPUS )); then
    echo "ERROR: only $available_cores cores available on socket $first_socket nodes=[$nodes_csv] (need at least $VM_CPUS)" >&2
    exit 1
fi

num_vms=$(( available_cores / VM_CPUS ))

# Build per-VM cpusets (semicolon-separated, each is a comma-separated list)
vm_cpusets=""
for (( v=0; v<num_vms; v++ )); do
    offset=$(( v * VM_CPUS ))
    vm_cores=("${pool[@]:$offset:$VM_CPUS}")
    csv=$(IFS=,; echo "${vm_cores[*]}")
    if [[ -z "$vm_cpusets" ]]; then
        vm_cpusets="$csv"
    else
        vm_cpusets="${vm_cpusets};${csv}"
    fi
done

# Human-readable summary on stderr
cat >&2 <<EOF
Kernelbuild VM CPU plan:
  socket=$first_socket nodes=[$nodes_csv] (${#socket_nodes[@]} NUMA node(s))
  core_policy=$CORE_POLICY
  available_cores=$available_cores
  vm_cpus=$VM_CPUS
  num_vms=$num_vms
  vm_cpusets=[$vm_cpusets]
EOF

echo "num_vms=${num_vms} vm_cpus=${VM_CPUS} available_cores=${available_cores} nodes=${nodes_csv} vm_cpusets=${vm_cpusets}"
