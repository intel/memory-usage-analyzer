#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Intel Corporation
#
# Pack VMs onto shared host-CPU blocks to oversubscribe host CPUs.
#
# zswap software compression runs on the reclaiming VM's own pinned cores, so
# giving each VM a private core block (1:1) hides the compression cost on
# idle-ish siblings. With factor F>1 every F VMs share one host-CPU block, so
# software compression competes with the guest build and the hardware (IAA)
# offload advantage becomes visible. Memory footprint is unchanged.
#
# Usage:
#   oversubscribe_vm_cpusets.sh <vm_host_cpusets> <num_vms> <factor>
#     vm_host_cpusets : semicolon-separated per-VM host CPU sets (1:1 map)
#     num_vms         : number of VMs
#     factor          : oversubscription factor (>=1; 1 returns input unchanged)
#
# Output (stdout): packed semicolon-separated cpuset map (num_vms entries).
# Human-readable summary is written to stderr.

set -euo pipefail

vm_host_cpusets="${1:-}"
num_vms="${2:-0}"
factor="${3:-1}"

if [[ ! "$factor" =~ ^[0-9]+$ ]] || (( factor < 1 )); then
    echo "ERROR: invalid oversubscription factor '$factor'. Must be a positive integer." >&2
    exit 1
fi
if [[ ! "$num_vms" =~ ^[0-9]+$ ]] || (( num_vms < 1 )); then
    echo "ERROR: invalid num_vms '$num_vms'. Must be a positive integer." >&2
    exit 1
fi

# Nothing to do: no map or 1:1 requested — echo input unchanged.
if (( factor == 1 )) || [[ -z "$vm_host_cpusets" ]]; then
    echo "$vm_host_cpusets"
    exit 0
fi

IFS=';' read -r -a orig_cpusets <<< "$vm_host_cpusets"
n=${#orig_cpusets[@]}
if (( n == 0 )); then
    echo "$vm_host_cpusets"
    exit 0
fi

packed=()
for (( v=0; v<num_vms; v++ )); do
    g=$(( v / factor ))
    (( g >= n )) && g=$(( g % n ))
    packed+=("${orig_cpusets[$g]}")
done

blocks=$(( (num_vms + factor - 1) / factor ))
echo "CPU oversubscription ${factor}:1 -> packed ${num_vms} VM(s) onto ${blocks} host-CPU block(s)" >&2

( IFS=';'; echo "${packed[*]}" )
