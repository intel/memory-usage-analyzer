#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# vm_ctl.sh — Manage the paired server/client Redis benchmark VMs.
#
# Targets are "server<i>", "client<i>", "servers", "clients", or "all".
#
# Usage:
#   vm_ctl.sh start [target]       Start VM(s)          (default: all)
#   vm_ctl.sh stop  [target]       Stop VM(s)           (default: all)
#   vm_ctl.sh status               Show VM status
#   vm_ctl.sh ssh   <role> <id>    SSH into a VM        (e.g. ssh server 1)
#   vm_ctl.sh run   <role> <id> <cmd...>   Run a command in a VM
#
# Config via env (must match benchmark.sh): SERVER_VMS, INSTANCES,
# MEM_PER_INSTANCE_GB, CLIENT_MEM_GB, SERVER_VCPUS, CLIENT_VCPUS.

set -euo pipefail

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if command -v qemu-system-x86_64 &>/dev/null; then
    QEMU_BIN="qemu-system-x86_64"
elif [[ -x /usr/libexec/qemu-kvm ]]; then
    QEMU_BIN="/usr/libexec/qemu-kvm"
else
    echo "ERROR: QEMU not found"; exit 1
fi

# ─── Config (mirror benchmark.sh defaults) ───────────────────────────
SERVER_VMS="${SERVER_VMS:-1}"
CLIENT_VMS="$SERVER_VMS"
INSTANCES="${INSTANCES:-1}"
MEM_PER_INSTANCE_GB="${MEM_PER_INSTANCE_GB:-6}"
CLIENT_MEM_GB="${CLIENT_MEM_GB:-2}"
SERVER_MEM_GB=$(( INSTANCES * MEM_PER_INSTANCE_GB ))
SERVER_VCPUS="${SERVER_VCPUS:-$(( INSTANCES + 1 ))}"
CLIENT_VCPUS="${CLIENT_VCPUS:-$INSTANCES}"; (( CLIENT_VCPUS < 1 )) && CLIENT_VCPUS=1
VM_DISK_GB="${VM_DISK_GB:-20}"

VM_IMAGE_DIR="${THIS_DIR}/images"
SSH_KEY="${THIS_DIR}/vm_key"
SERVER_SSH_BASE="${SERVER_SSH_BASE:-2240}"
CLIENT_SSH_BASE="${CLIENT_SSH_BASE:-2340}"
REDIS_GUEST_BASE="${REDIS_GUEST_BASE:-9000}"
REDIS_HOST_BASE="${REDIS_HOST_BASE:-16000}"
CORE_POLICY="${CORE_POLICY:-contiguous}"
SERVER_CPUSETS="${SERVER_CPUSETS:-}"
CLIENT_CPUSETS="${CLIENT_CPUSETS:-}"
VM_USER="bench"
CG="/sys/fs/cgroup/redisbench_vm"
DB_FILE="${DB_FILE:-import_movies_10000r_10c.csv}"
DURATION="${DURATION:-120}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

source "${THIS_DIR}/vm_lib.sh"
compute_cpu_plan

start_target() {
    local target="$1" role i n
    case "$target" in
        all)     start_target servers; start_target clients ;;
        servers) for (( i=1; i<=SERVER_VMS; i++ )); do start_vm server "$i"; done ;;
        clients) for (( i=1; i<=CLIENT_VMS; i++ )); do start_vm client "$i"; done ;;
        server*) start_vm server "${target#server}" ;;
        client*) start_vm client "${target#client}" ;;
        *) echo "Unknown target '$target'"; exit 1 ;;
    esac
}

stop_target() {
    local target="$1" i
    case "$target" in
        all)     stop_all_vms ;;
        servers) for (( i=1; i<=SERVER_VMS; i++ )); do stop_vm server "$i"; done ;;
        clients) for (( i=1; i<=CLIENT_VMS; i++ )); do stop_vm client "$i"; done ;;
        server*) stop_vm server "${target#server}" ;;
        client*) stop_vm client "${target#client}" ;;
        *) echo "Unknown target '$target'"; exit 1 ;;
    esac
}

status_role() {
    local role="$1" n i pidfile port pid ssh_ok
    n=$(vm_count "$role")
    for (( i=1; i<=n; i++ )); do
        pidfile="$(vm_dir "$role" "$i")/qemu.pid"
        port=$(vm_ssh_port "$role" "$i")
        if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
            pid=$(cat "$pidfile")
            ssh_ok="no"
            ssh $SSH_OPTS -p "$port" "${VM_USER}@localhost" "true" 2>/dev/null && ssh_ok="yes"
            local ports_info=""
            [[ "$role" == "server" ]] && ports_info=", redis→$(redis_host_ports_for_server "$i")"
            echo "  ${role}${i}: RUNNING (pid=$pid, ssh=$port, reachable=$ssh_ok${ports_info})"
        else
            echo "  ${role}${i}: STOPPED"
        fi
    done
}

cmd="${1:-status}"; shift || true
case "$cmd" in
    start) start_target "${1:-all}" ;;
    stop)  stop_target  "${1:-all}" ;;
    status)
        echo "VM Status:"
        status_role server
        status_role client
        ;;
    ssh)
        role="${1:?Usage: vm_ctl.sh ssh <server|client> <id>}"
        id="${2:?Usage: vm_ctl.sh ssh <server|client> <id>}"
        exec ssh $SSH_OPTS -p "$(vm_ssh_port "$role" "$id")" "${VM_USER}@localhost"
        ;;
    run)
        role="${1:?Usage: vm_ctl.sh run <server|client> <id> <cmd...>}"
        id="${2:?Usage: vm_ctl.sh run <server|client> <id> <cmd...>}"
        shift 2
        ssh_role "$role" "$id" "$@"
        ;;
    *)
        echo "Usage: vm_ctl.sh {start|stop|status|ssh|run} [target] [args...]"
        echo "  targets: all | servers | clients | server<i> | client<i>"
        exit 1
        ;;
esac
