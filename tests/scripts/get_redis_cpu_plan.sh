#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Intel Corporation

set -euo pipefail

no_of_servers=${1:-1}
server_cpus_per_instance=${2:-1}
client_cpus_per_instance=${3:-1}
redis_server_cpu_start=${4:-0}
preferred_node=${5:-}
client_socket_policy=${6:-auto}
scenario_name=${7:-}
server_overflow_policy=${8:-siblings-first}
core_policy=${9:-spread-nodes}


THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

build_primary_sibling_pool() {
    local -n _src_ref=$1
    local _start=$2
    local -n _out_ref=$3
    local -a _prim=()
    local -a _sib=()
    local c

    for c in "${_src_ref[@]}"; do
        [[ "$c" -lt "$_start" ]] && continue
        if is_primary_core "$c"; then
            _prim+=("$c")
        else
            _sib+=("$c")
        fi
    done

    _out_ref=("${_prim[@]}" "${_sib[@]}")
}

get_first_socket_node() {
    local first_socket
    first_socket=$(lscpu --parse=SOCKET | awk -F, '!/^#/ && $1 != "" { sockets[$1]=1 } END { n=asorti(sockets, ordered); if (n >= 1) print ordered[1] }')
    lscpu --parse=SOCKET,NODE | awk -F, -v socket="$first_socket" '!/^#/ && $1==socket { print $2; exit }'
}

get_second_socket_id() {
    lscpu --parse=SOCKET | awk -F, '!/^#/ && $1 != "" { sockets[$1]=1 } END { n=asorti(sockets, ordered); if (n >= 2) print ordered[2] }'
}

get_socket_cpus() {
    local socket_id="$1"
    lscpu --parse=CPU,SOCKET | awk -F, -v socket="$socket_id" '!/^#/ && $2==socket { print $1 }'
}

get_first_node_for_socket() {
    local socket_id="$1"
    lscpu --parse=SOCKET,NODE | awk -F, -v socket="$socket_id" '!/^#/ && $1==socket && $2 != "" { nodes[$2]=1 } END { n=asorti(nodes, ordered); if (n >= 1) print ordered[1] }'
}

get_first_numa_node() {
    lscpu --parse=NODE | awk -F, '!/^#/ && $1 != "" { nodes[$1]=1 } END { n=asorti(nodes, ordered); if (n >= 1) print ordered[1] }'
}

get_next_numa_node_for_socket() {
    local socket_id="$1"
    local current_node="$2"
    lscpu --parse=SOCKET,NODE | awk -F, -v socket="$socket_id" -v current="$current_node" \
        '!/^#/ && $1==socket && $2 != "" && $2 > current { nodes[$2]=1 } END { n=asorti(nodes, ordered); if (n >= 1) print ordered[1] }'
}

get_numa_node_cpus() {
    local node_id="$1"
    if [[ -r "/sys/devices/system/node/node${node_id}/cpulist" ]]; then
        expand_cpulist "$(cat "/sys/devices/system/node/node${node_id}/cpulist")"
    fi
}

get_all_numa_nodes_for_socket() {
    local socket_id="$1"
    lscpu --parse=SOCKET,NODE | awk -F, -v socket="$socket_id" '!/^#/ && $1==socket && $2 != "" { nodes[$2]=1 } END { n=asorti(nodes, ordered); for (i=1; i<=n; i++) print ordered[i] }'
}

get_all_cpus() {
    expand_cpulist "$(lscpu --parse=CPU | awk -F, '!/^#/ && $1 != "" { cpus[$1]=1 } END { n=asorti(cpus, ordered); for (i=1; i<=n; i++) { if (i>1) printf ","; printf "%s", ordered[i] } }')"
}

is_primary_core() {
    local c="$1"
    local first
    first=$(cut -d, -f1 "/sys/devices/system/cpu/cpu${c}/topology/thread_siblings_list" 2>/dev/null || true)
    [[ -n "$first" && "$c" -eq "$first" ]]
}

if [[ ! "$no_of_servers" =~ ^[0-9]+$ || "$no_of_servers" -lt 1 ]]; then
    echo "ERROR: invalid number of servers: $no_of_servers" >&2
    exit 1
fi

if [[ ! "$server_cpus_per_instance" =~ ^[0-9]+$ || "$server_cpus_per_instance" -lt 1 ]]; then
    echo "ERROR: invalid server_cpus_per_instance: $server_cpus_per_instance" >&2
    exit 1
fi

if [[ ! "$client_cpus_per_instance" =~ ^[0-9]+$ || "$client_cpus_per_instance" -lt 1 ]]; then
    echo "ERROR: invalid client_cpus_per_instance: $client_cpus_per_instance" >&2
    exit 1
fi

if [[ ! "$redis_server_cpu_start" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid redis_server_cpu_start: $redis_server_cpu_start" >&2
    exit 1
fi

# Get socket IDs and NUMA nodes
first_socket=$(lscpu --parse=SOCKET | awk -F, '!/^#/ && $1 != "" { sockets[$1]=1 } END { n=asorti(sockets, ordered); print ordered[1] }')
second_socket=$(lscpu --parse=SOCKET | awk -F, '!/^#/ && $1 != "" { sockets[$1]=1 } END { n=asorti(sockets, ordered); print ordered[2] }')
server_node="$preferred_node"
if [[ -z "$server_node" || ! "$server_node" =~ ^[0-9]+$ ]]; then
    server_node=$(get_first_numa_node)
fi

if [[ -z "$server_node" || ! "$server_node" =~ ^[0-9]+$ ]]; then
    echo "ERROR: failed to resolve primary NUMA node for server allocation" >&2
    exit 1
fi

mapfile -t server_node_candidates < <(get_numa_node_cpus "$server_node")
if [[ "${#server_node_candidates[@]}" -eq 0 ]]; then
    echo "ERROR: NUMA node $server_node has no CPUs available" >&2
    exit 1
fi

server_primary_pool=()
server_sibling_pool=()
for c in "${server_node_candidates[@]}"; do
    [[ "$c" -lt "$redis_server_cpu_start" ]] && continue
    if is_primary_core "$c"; then
        server_primary_pool+=("$c")
    else
        server_sibling_pool+=("$c")
    fi
done

if [[ "$core_policy" == "spread-nodes" ]]; then
    # Collect primary cores across all NUMA nodes first, then siblings
    spread_primary=("${server_primary_pool[@]}")
    spread_sibling=("${server_sibling_pool[@]}")
    mapfile -t socket_nodes < <(get_all_numa_nodes_for_socket "$first_socket")
    for node in "${socket_nodes[@]}"; do
        [[ "$node" -eq "$server_node" ]] && continue
        mapfile -t node_candidates < <(get_numa_node_cpus "$node")
        for c in "${node_candidates[@]}"; do
            [[ "$c" -lt "$redis_server_cpu_start" ]] && continue
            if is_primary_core "$c"; then
                spread_primary+=("$c")
            else
                spread_sibling+=("$c")
            fi
        done
    done
    pool=("${spread_primary[@]}" "${spread_sibling[@]}")
else
    # siblings-first: primary+siblings per NUMA node, then next node
    pool=("${server_primary_pool[@]}" "${server_sibling_pool[@]}")

    # Try to expand pool with remaining NUMA nodes on the same socket
    mapfile -t socket_nodes < <(get_all_numa_nodes_for_socket "$first_socket")
    for node in "${socket_nodes[@]}"; do
        [[ "$node" -eq "$server_node" ]] && continue
        mapfile -t node_candidates < <(get_numa_node_cpus "$node")
        node_primary_pool=()
        node_sibling_pool=()
        for c in "${node_candidates[@]}"; do
            [[ "$c" -lt "$redis_server_cpu_start" ]] && continue
            if is_primary_core "$c"; then
                node_primary_pool+=("$c")
            else
                node_sibling_pool+=("$c")
            fi
        done
        pool+=("${node_primary_pool[@]}" "${node_sibling_pool[@]}")
    done
fi

server_cpu_need=$(( no_of_servers * server_cpus_per_instance ))

# If same-socket pool is insufficient, fall back to all online CPUs
server_allocation_mode="socket-local"
if [[ "${#pool[@]}" -lt "$server_cpu_need" ]]; then
    echo "INFO: Insufficient CPUs on socket $first_socket (have ${#pool[@]}, need $server_cpu_need); falling back to all online CPUs" >&2
    server_allocation_mode="all-cpus"
    pool=()
    mapfile -t all_cpu_list < <(get_all_cpus)
    all_primary_pool=()
    all_sibling_pool=()
    for c in "${all_cpu_list[@]}"; do
        [[ "$c" -lt "$redis_server_cpu_start" ]] && continue
        if is_primary_core "$c"; then
            all_primary_pool+=("$c")
        else
            all_sibling_pool+=("$c")
        fi
    done
    pool=("${all_primary_pool[@]}" "${all_sibling_pool[@]}")
fi

if [[ "${#pool[@]}" -lt "$server_cpu_need" ]]; then
    echo "ERROR: requested ${no_of_servers} servers x ${server_cpus_per_instance} cores but only ${#pool[@]} CPUs available system-wide" >&2
    exit 1
fi

selected=("${pool[@]:0:$server_cpu_need}")
server_cores_csv=$(IFS=,; echo "${selected[*]}")

client_cpu_need=$(( no_of_servers * client_cpus_per_instance ))
client_cores_csv=""

# Allocate clients from socket 1; on single-socket systems fall back to CPUs after server allocation.
client_allocation_mode="socket-local"
if [[ -z "$second_socket" || ! "$second_socket" =~ ^[0-9]+$ ]]; then
    echo "INFO: single-socket system; allocating clients from CPUs after server allocation" >&2
    client_node="$server_node"
    client_pool=("${pool[@]:$server_cpu_need}")
    if [[ "${#client_pool[@]}" -lt "$client_cpu_need" ]]; then
        echo "ERROR: requested ${client_cpu_need} client CPUs but only ${#client_pool[@]} CPUs available after server allocation" >&2
        exit 1
    fi
else
    client_node=$(get_first_node_for_socket "$second_socket")
    if [[ -z "$client_node" || ! "$client_node" =~ ^[0-9]+$ ]]; then
        echo "ERROR: failed to resolve client NUMA node on socket $second_socket" >&2
        exit 1
    fi

    mapfile -t client_node_candidates < <(get_numa_node_cpus "$client_node")
    if [[ "${#client_node_candidates[@]}" -eq 0 ]]; then
        echo "ERROR: client NUMA node $client_node has no CPUs available" >&2
        exit 1
    fi

    client_primary_pool=()
    client_sibling_pool=()
    for c in "${client_node_candidates[@]}"; do
        [[ "$c" -lt "$redis_server_cpu_start" ]] && continue
        if is_primary_core "$c"; then
            client_primary_pool+=("$c")
        else
            client_sibling_pool+=("$c")
        fi
    done

    if [[ "$core_policy" == "spread-nodes" ]]; then
        # Collect primary cores across all client NUMA nodes first, then siblings
        client_spread_primary=("${client_primary_pool[@]}")
        client_spread_sibling=("${client_sibling_pool[@]}")
        mapfile -t client_socket_nodes < <(get_all_numa_nodes_for_socket "$second_socket")
        for node in "${client_socket_nodes[@]}"; do
            [[ "$node" -eq "$client_node" ]] && continue
            mapfile -t node_candidates < <(get_numa_node_cpus "$node")
            for c in "${node_candidates[@]}"; do
                [[ "$c" -lt "$redis_server_cpu_start" ]] && continue
                if is_primary_core "$c"; then
                    client_spread_primary+=("$c")
                else
                    client_spread_sibling+=("$c")
                fi
            done
        done
        client_pool=("${client_spread_primary[@]}" "${client_spread_sibling[@]}")
    else
        # siblings-first: primary+siblings per NUMA node, then next node
        client_pool=("${client_primary_pool[@]}" "${client_sibling_pool[@]}")

        # Try to expand pool with remaining NUMA nodes on the same socket
        mapfile -t client_socket_nodes < <(get_all_numa_nodes_for_socket "$second_socket")
        for node in "${client_socket_nodes[@]}"; do
            [[ "$node" -eq "$client_node" ]] && continue
            mapfile -t node_candidates < <(get_numa_node_cpus "$node")
            node_primary_pool=()
            node_sibling_pool=()
            for c in "${node_candidates[@]}"; do
                [[ "$c" -lt "$redis_server_cpu_start" ]] && continue
                if is_primary_core "$c"; then
                    node_primary_pool+=("$c")
                else
                    node_sibling_pool+=("$c")
                fi
            done
            client_pool+=("${node_primary_pool[@]}" "${node_sibling_pool[@]}")
        done
    fi

    # If same-socket pool is insufficient, fall back to all online CPUs
    if [[ "${#client_pool[@]}" -lt "$client_cpu_need" ]]; then
        echo "INFO: Insufficient CPUs on socket $second_socket (have ${#client_pool[@]}, need $client_cpu_need); falling back to all online CPUs" >&2
        client_allocation_mode="all-cpus"
        client_pool=()
        mapfile -t all_cpu_list < <(get_all_cpus)
        all_primary_pool=()
        all_sibling_pool=()
        for c in "${all_cpu_list[@]}"; do
            [[ "$c" -lt "$redis_server_cpu_start" ]] && continue
            if is_primary_core "$c"; then
                all_primary_pool+=("$c")
            else
                all_sibling_pool+=("$c")
            fi
        done
        client_pool=("${all_primary_pool[@]}" "${all_sibling_pool[@]}")
    fi

    if [[ "${#client_pool[@]}" -lt "$client_cpu_need" ]]; then
        echo "ERROR: requested ${client_cpu_need} client CPUs but only ${#client_pool[@]} CPUs available system-wide" >&2
        exit 1
    fi
fi

client_selected=("${client_pool[@]:0:$client_cpu_need}")
mb_cpu_start="${client_selected[0]}"
client_cores_csv=$(IFS=,; echo "${client_selected[*]}")

# Human-readable plan print for logs (stderr), while stdout remains machine-parseable.
if [[ -n "$scenario_name" ]]; then
    printf '%s\n' \
        "CPU plan for scenario=${scenario_name}" \
        "  server_numa_node=$server_node" \
        "  client_numa_node=$client_node" \
        "  server_socket=$first_socket" \
        "  client_socket=${second_socket:-NA}" \
        "  server_allocation_mode=${server_allocation_mode}" \
        "  client_allocation_mode=${client_allocation_mode}" \
        "  overflow_policy=siblings-first" \
        "  core_policy=${core_policy}" \
        "  server_cores_per_instance=${server_cpus_per_instance}" \
        "  client_cores_per_instance=${client_cpus_per_instance}" \
        "  mb_cpu_start=${mb_cpu_start}" \
        "  server_cores=[${server_cores_csv}]" \
        "  client_cores=[${client_cores_csv}]" >&2
fi

echo "node=${server_node:-NA} server_socket=$first_socket client_socket=${second_socket:-NA} overflow_policy=siblings-first core_policy=${core_policy} server_allocation_mode=${server_allocation_mode} client_allocation_mode=${client_allocation_mode} server_cores=${server_cores_csv} client_cores=${client_cores_csv} mb_cpu_start=${mb_cpu_start} server_cpus_per_instance=${server_cpus_per_instance} client_cpus_per_instance=${client_cpus_per_instance}"
