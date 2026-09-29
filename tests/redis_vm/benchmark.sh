#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# benchmark.sh — Paired server/client VM Redis memory benchmark.
#
# Topology
# --------
#   * V SERVER VMs, each running N redis instances (each instance sized for the
#     dataset, ~MEM_PER_INSTANCE_GB). Server VM RAM = N * MEM_PER_INSTANCE_GB.
#   * V CLIENT VMs running memtier_benchmark, paired 1:1 with the servers:
#     client<i> drives every redis instance of server<i>.
#   * ONLY the SERVER VMs are placed in the host cgroup ($CG). Their anonymous
#     guest memory is what the host kernel compresses (zswap/zram) as we sweep
#     memory.max down — this is the memory we estimate/characterise. Client VMs
#     run UNCONSTRAINED so the load generator is never the bottleneck.
#
# Networking: QEMU user-mode (SLIRP). Each server VM forwards its instance ports
# 9001..900N to unique host ports; the paired client reaches them via the SLIRP
# gateway 10.0.2.2:<host_port>. No bridges / NET_ADMIN needed.
#
# CPU plan: server and client VMs get disjoint host-core blocks using the same
# planner/policies as tests/redis/benchmark.sh (spread-nodes | siblings-first),
# pinned via numactl.
#
# Flow (per compressor):
#   1. Configure zswap/zram compressor on the host
#   2. Boot servers (in $CG) + clients (outside $CG), unlimited for boot
#   3. Baseline run (unlimited) -> peak server memory + aggregate throughput
#   4. Sweep memory.max down (% of baseline peak), re-run at each step
#   5. Collect compression stats (host cgroup) + throughput/p99 (client VMs)
#
# Output log lines are compatible with tests/redis/report.py and report_plot.py.

set -euo pipefail

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOGDIR="${THIS_DIR}/logdir"
REDIS_DIR="${THIS_DIR}/../redis"

if command -v qemu-system-x86_64 &>/dev/null; then
    QEMU_BIN="qemu-system-x86_64"
elif [[ -x /usr/libexec/qemu-kvm ]]; then
    QEMU_BIN="/usr/libexec/qemu-kvm"
else
    echo "ERROR: QEMU not found (tried qemu-system-x86_64 and /usr/libexec/qemu-kvm)"
    exit 1
fi

# ─── Defaults ─────────────────────────────────────────────────────────
SERVER_VMS="${SERVER_VMS:-16}"                 # number of server VMs (client VMs match 1:1)
INSTANCES="${INSTANCES:-1}"                   # redis instances per server VM
MEM_PER_INSTANCE_GB="${MEM_PER_INSTANCE_GB:-6}"  # RAM per redis instance; server VM RAM = INSTANCES * this
CLIENT_MEM_GB="${CLIENT_MEM_GB:-2}"           # RAM per (unconstrained) client VM
SERVER_VCPUS="${SERVER_VCPUS:-}"              # vCPUs per server VM (empty -> INSTANCES + 1)
CLIENT_VCPUS="${CLIENT_VCPUS:-}"              # vCPUs per client VM (empty -> INSTANCES, min 1)
VM_DISK_GB="${VM_DISK_GB:-20}"                # overlay disk size per VM (GB)

DB_FILE="${DB_FILE:-import_movies_10000r_10c.csv}"  # redis dataset staged into server VMs
DB_FILE_EXPLICIT=0                            # set to 1 when --db-file is passed (skips name auto-resolution)
DATA_REPS="${DATA_REPS:-}"                    # repeat_redis_file.py -r used to build the dataset name (optional)
DATA_COLS="${DATA_COLS:-}"                    # repeat_redis_file.py -c used to build the dataset name (optional)
DATA_INPUT="${DATA_INPUT:-import_movies.redis}"  # base input file for dataset name resolution
DURATION="${DURATION:-120}"                   # memtier run duration per scenario (seconds)
SWAP_MODE="${SWAP_MODE:-zswap}"               # compressed-swap backend: zswap or zram
COMPRESSOR="${COMPRESSOR:-all}"               # compressor profile to test, or 'all' for the built-in list
SWEEP_START="${SWEEP_START:-90}"              # first memory limit, as % of baseline peak
SWEEP_END="${SWEEP_END:-50}"                  # last memory limit, as % of baseline peak
SWEEP_STEP="${SWEEP_STEP:-5}"                 # % decrement between sweep steps
REGRESSION_THRESHOLD="${REGRESSION_THRESHOLD:-6}"  # % agg-throughput drop vs baseline that stops the sweep for a compressor
MTHP="${MTHP:-}"                              # mTHP sizes, comma-separated (e.g. 64kB,128kB)
PREFILL_TIMEOUT="${PREFILL_TIMEOUT:-600}"    # max seconds to wait for prefill to complete (0=no timeout)

CORE_POLICY="${CORE_POLICY:-spread-nodes}"   # host-core assignment: spread-nodes | siblings-first
SERVER_CPUSETS="${SERVER_CPUSETS:-}"         # explicit per-server host cpusets "0-1;2-3" (empty -> auto by policy)
CLIENT_CPUSETS="${CLIENT_CPUSETS:-}"         # explicit per-client host cpusets (empty -> auto by policy)

SSH_KEY="${THIS_DIR}/vm_key"                  # SSH private key for the VMs (created by setup_vm.sh)
VM_IMAGE_DIR="${THIS_DIR}/images"             # where base image, overlays and staged artifacts live
SERVER_SSH_BASE="${SERVER_SSH_BASE:-2240}"    # host SSH port for server1 (server<i> -> base + i-1)
CLIENT_SSH_BASE="${CLIENT_SSH_BASE:-2340}"    # host SSH port for client1 (client<i> -> base + i-1)
REDIS_GUEST_BASE="${REDIS_GUEST_BASE:-9000}"  # in-guest redis port base (instance j -> base + j)
REDIS_HOST_BASE="${REDIS_HOST_BASE:-16000}"   # host port base that redis instances are forwarded to
VM_BOOT_WAIT="${VM_BOOT_WAIT:-420}"           # max seconds to wait for a VM's SSH after boot
VM_START_STAGGER_SEC="${VM_START_STAGGER_SEC:-2}"  # delay between starting consecutive VMs
CG="/sys/fs/cgroup/redisbench_vm"             # cgroup that holds the (pressured) server VMs

# ─── Usage ────────────────────────────────────────────────────────────
print_usage() {
    cat <<'EOF'
Usage: benchmark.sh [options]

Topology options:
  --server-vms <V>          Number of server VMs (client VMs match 1:1) (default: 1)
  --instances <N>           Redis instances per server VM (default: 1)
  --mem-per-instance <GB>   RAM per redis instance; server RAM = N*this (default: 6)
  --client-mem <GB>         RAM per client VM (default: 2)
  --server-vcpus <N>        vCPUs per server VM (default: instances + 1)
  --client-vcpus <N>        vCPUs per client VM (default: instances)

CPU planning:
  --core-policy <p>         spread-nodes | siblings-first (default: spread-nodes)
  --server-cpusets <map>    Explicit per-server host cpusets, ';'-separated (e.g. "0-2;3-5")
  --client-cpusets <map>    Explicit per-client host cpusets

Dataset / workload:
  --db-file <name>          Redis dataset file (default: import_movies_10000r_10c.csv)
  --data-reps <N>           Resolve dataset name repeat_redis_file.py used (-r)
  --data-cols <N>           Resolve dataset name (repeat_redis_file.py -c)
  --data-input <file>       Base input for name resolution (default: import_movies.redis)
  --duration <sec>          memtier run duration per scenario (default: 120)

Sweep / compressor:
  --swap-mode <mode>        zswap or zram (default: zswap)
  --compressor <name>       Compressor profile or 'all' (default: all)
  --sweep-start <pct>       Start of memory sweep, % of baseline peak (default: 95)
  --sweep-end <pct>         End of memory sweep, % of baseline peak (default: 65)
  --sweep-step <pct>        Sweep step in % (default: 2)
  --mthp <sizes>            mTHP sizes, comma-separated (e.g. 64kB,128kB)
  --threshold, -t <pct>     Throughput regression threshold to stop sweep (default: 10)
  --logdir, -l <path>       Output directory (default: ./logdir)
  --help, -h                Show this help

Only the SERVER VMs are memory-limited (cgroup memory.max). Client VMs run
unconstrained. The baseline (unlimited) run yields the memory estimation; the
sweep characterises throughput/latency regression vs compressor.

Example:
  # 2 server VMs x 3 instances (9GB each), 2 paired client VMs, all compressors
  ./benchmark.sh --server-vms 2 --instances 3 --mem-per-instance 3
EOF
}

# ─── Parse arguments ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-vms)        SERVER_VMS="$2"; shift 2 ;;
        --instances)         INSTANCES="$2"; shift 2 ;;
        --mem-per-instance)  MEM_PER_INSTANCE_GB="$2"; shift 2 ;;
        --client-mem)        CLIENT_MEM_GB="$2"; shift 2 ;;
        --server-vcpus)      SERVER_VCPUS="$2"; shift 2 ;;
        --client-vcpus)      CLIENT_VCPUS="$2"; shift 2 ;;
        --core-policy)       CORE_POLICY="$2"; shift 2 ;;
        --server-cpusets)    SERVER_CPUSETS="$2"; shift 2 ;;
        --client-cpusets)    CLIENT_CPUSETS="$2"; shift 2 ;;
        --db-file)           DB_FILE="$2"; DB_FILE_EXPLICIT=1; shift 2 ;;
        --data-reps)         DATA_REPS="$2"; shift 2 ;;
        --data-cols)         DATA_COLS="$2"; shift 2 ;;
        --data-input)        DATA_INPUT="$2"; shift 2 ;;
        --duration)          DURATION="$2"; shift 2 ;;
        --swap-mode)         SWAP_MODE="$2"; shift 2 ;;
        --compressor)        COMPRESSOR="$2"; shift 2 ;;
        --sweep-start)       SWEEP_START="$2"; shift 2 ;;
        --sweep-end)         SWEEP_END="$2"; shift 2 ;;
        --sweep-step)        SWEEP_STEP="$2"; shift 2 ;;
        --mthp)              MTHP="$2"; shift 2 ;;
        --threshold|-t)      REGRESSION_THRESHOLD="$2"; shift 2 ;;
        --logdir|-l)         LOGDIR="$2"; shift 2 ;;
        --help|-h)           print_usage; exit 0 ;;
        *)                   echo "Unknown option: $1"; print_usage; exit 1 ;;
    esac
done

# ─── Derived config ───────────────────────────────────────────────────
CLIENT_VMS="$SERVER_VMS"
SERVER_MEM_GB=$(( INSTANCES * MEM_PER_INSTANCE_GB ))
[[ -z "$SERVER_VCPUS" ]] && SERVER_VCPUS=$(( INSTANCES ))
if [[ -z "$CLIENT_VCPUS" ]]; then CLIENT_VCPUS="$INSTANCES"; (( CLIENT_VCPUS < 1 )) && CLIENT_VCPUS=1; fi

# ─── Validation ───────────────────────────────────────────────────────
if [[ "$SWAP_MODE" != "zswap" && "$SWAP_MODE" != "zram" ]]; then
    echo "ERROR: invalid swap mode '$SWAP_MODE'. Must be 'zswap' or 'zram'."; exit 1
fi
case "$CORE_POLICY" in
    spread-nodes|siblings-first) ;;
    contiguous)
        echo "INFO: --core-policy=contiguous is deprecated; using siblings-first"
        CORE_POLICY="siblings-first"
        ;;
    numa-split)
        echo "INFO: --core-policy=numa-split is deprecated; using spread-nodes"
        CORE_POLICY="spread-nodes"
        ;;
    *)
        echo "ERROR: invalid --core-policy '$CORE_POLICY'. Must be spread-nodes or siblings-first."
        exit 1
        ;;
esac
(( SERVER_VMS >= 1 )) || { echo "ERROR: --server-vms must be >= 1"; exit 1; }
(( INSTANCES  >= 1 )) || { echo "ERROR: --instances must be >= 1"; exit 1; }

# Resolve the repeat_redis_file.py dataset name (must match setup_vm.sh).
if [[ -n "$DATA_REPS" || -n "$DATA_COLS" ]] && (( DB_FILE_EXPLICIT == 0 )); then
    _input_base="$(basename "${DATA_INPUT%.redis}")"
    DB_FILE="${_input_base}_${DATA_REPS:-1}r_${DATA_COLS:-1}c.csv"
fi

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
VM_USER="bench"

TOTAL_SERVER_MEM_GB=$(( SERVER_VMS * SERVER_MEM_GB ))
TOTAL_CLIENT_MEM_GB=$(( CLIENT_VMS * CLIENT_MEM_GB ))
TOTAL_VM_MEM_GB=$(( TOTAL_SERVER_MEM_GB + TOTAL_CLIENT_MEM_GB ))
TOTAL_INSTANCES=$(( SERVER_VMS * INSTANCES ))

# ─── Validate total VM memory fits the host ───────────────────────────
HOST_RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
HOST_HEADROOM_GB=$(( HOST_RAM_GB * 10 / 100 )); (( HOST_HEADROOM_GB < 8 )) && HOST_HEADROOM_GB=8
AVAILABLE_RAM_GB=$(( HOST_RAM_GB - HOST_HEADROOM_GB ))
if (( TOTAL_VM_MEM_GB > AVAILABLE_RAM_GB )); then
    echo "ERROR: total VM memory ${TOTAL_VM_MEM_GB}GB (servers ${TOTAL_SERVER_MEM_GB}GB + clients ${TOTAL_CLIENT_MEM_GB}GB)"
    echo "       exceeds available host RAM ${AVAILABLE_RAM_GB}GB (host ${HOST_RAM_GB}GB, ${HOST_HEADROOM_GB}GB reserved)."
    echo "       Reduce --server-vms / --instances / --mem-per-instance."
    exit 1
fi

# ─── Stage dataset into images/ (generate it first with repeat_redis_file.py) ─
staged_dataset="${VM_IMAGE_DIR}/${DB_FILE}"
if [[ ! -f "$staged_dataset" ]]; then
    dataset_src=""
    if [[ -f "${THIS_DIR}/${DB_FILE}" ]]; then dataset_src="${THIS_DIR}/${DB_FILE}";
    elif [[ -f "${REDIS_DIR}/${DB_FILE}" ]]; then dataset_src="${REDIS_DIR}/${DB_FILE}"; fi
    if [[ -z "$dataset_src" ]]; then
        echo "ERROR: dataset '${DB_FILE}' not found in ${VM_IMAGE_DIR}, ${THIS_DIR}, or ${REDIS_DIR}."
        echo "  Generate it first, e.g.:"
        echo "    python repeat_redis_file.py -r 10000 -c 10"
        exit 1
    fi
    mkdir -p "$VM_IMAGE_DIR"
    cp "$dataset_src" "$staged_dataset"
    echo "Staged dataset into images/: $staged_dataset"
fi

export DB_FILE DURATION

# ─── Source VM management library ─────────────────────────────────────
source "${THIS_DIR}/vm_lib.sh"

# ─── Configure compressor on host ────────────────────────────────────
configure_swap_for_compressor() {
    local comp="$1"
    local comp_algo="$comp" reclaim_batchsize=1 page_cluster=3
    if [[ "$comp" =~ ^(.+)_r([0-9]+)_p([0-9]+)$ ]]; then
        comp_algo="${BASH_REMATCH[1]}"; reclaim_batchsize="${BASH_REMATCH[2]}"; page_cluster="${BASH_REMATCH[3]}"
    fi
    local config_args=(-c "$comp_algo" -r "$reclaim_batchsize" -p "$page_cluster")
    [[ -n "$MTHP" ]] && config_args+=(-t "$MTHP")
    echo "Configuring $SWAP_MODE: compressor=$comp_algo reclaim_batchsize=$reclaim_batchsize page_cluster=$page_cluster mthp=$MTHP"
    if [[ "$SWAP_MODE" == "zram" ]]; then
        "${THIS_DIR}/../scripts/config_sys_zram.sh" "${config_args[@]}" || {
            echo "ERROR: Failed to configure $comp_algo — skipping"; return 1; }
    else
        "${THIS_DIR}/../scripts/config_sys_zswap.sh" "${config_args[@]}" || {
            echo "ERROR: Failed to configure $comp_algo — skipping"; return 1; }
    fi
}

# ─── cgroup CPU accounting (server VMs only) ─────────────────────────
read_vals_before() {
    read u1 usr1 sys1 < <(awk '/usage_usec/{u=$2} /user_usec/{usr=$2} /system_usec/{sys=$2} END{print u+0, usr+0, sys+0}' "$CG/cpu.stat" 2>/dev/null)
    read sys_busy1 sys_total1 < <(awk '/^cpu /{idle=$5+$6; total=$2+$3+$4+$5+$6+$7+$8+$9; print total-idle, total}' /proc/stat)
    t1=$(date +%s%N)
}
read_vals_after() {
    t2=$(date +%s%N)
    read u2 usr2 sys2 < <(awk '/usage_usec/{u=$2} /user_usec/{usr=$2} /system_usec/{sys=$2} END{print u+0, usr+0, sys+0}' "$CG/cpu.stat" 2>/dev/null)
    read sys_busy2 sys_total2 < <(awk '/^cpu /{idle=$5+$6; total=$2+$3+$4+$5+$6+$7+$8+$9; print total-idle, total}' /proc/stat)
    local du dusr dsys dt
    du=$((u2-u1)); dusr=$((usr2-usr1)); dsys=$((sys2-sys1)); dt=$(((t2-t1)/1000))
    CPU_PCT=$(awk -v c="$du" -v t="$dt" 'BEGIN{printf "%.2f", (t>0?(c/t)*100:0)}')
    USER_PCT=$(awk -v c="$dusr" -v t="$dt" 'BEGIN{printf "%.2f", (t>0?(c/t)*100:0)}')
    SYS_PCT=$(awk -v c="$dsys" -v t="$dt" 'BEGIN{printf "%.2f", (t>0?(c/t)*100:0)}')
    SYS_TOTAL_PCT=$(awk -v b1="$sys_busy1" -v t1="$sys_total1" -v b2="$sys_busy2" -v t2="$sys_total2" 'BEGIN{dt=t2-t1; printf "%.2f", (dt>0?((b2-b1)/dt)*100:0)}')
}

# ─── Start empty redis instances in all server VMs (parallel) ────────
run_start_all_servers() {
    local out_dir="$1"; local pids=() failed=0; mkdir -p "$out_dir"
    for (( i=1; i<=SERVER_VMS; i++ )); do
        local sout="${out_dir}/server${i}"; mkdir -p "$sout"
        (
            ssh_role server "$i" "INSTANCES=${INSTANCES} VCPUS=${SERVER_VCPUS} bash /home/${VM_USER}/run_workload.sh server-start" \
                > "${sout}/server_start.log" 2>&1
        ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
    return $failed
}

# ─── Prefill remote servers from all client VMs (parallel) ───────────
run_prefill_all_clients() {
    local out_dir="$1"; local pids=() failed=0; mkdir -p "$out_dir"
    for (( i=1; i<=CLIENT_VMS; i++ )); do
        local cout="${out_dir}/client${i}"; mkdir -p "$cout"
        local ports; ports="$(redis_host_ports_for_server "$i")"   # paired server<i>'s host ports
        (
            ssh_role client "$i" "TARGET_HOST=10.0.2.2 TARGET_PORTS='${ports}' DB_FILE=${DB_FILE} VCPUS=${CLIENT_VCPUS} bash /home/${VM_USER}/run_workload.sh client-prefill" \
                > "${cout}/prefill.log" 2>&1
        ) &
        pids+=($!)
    done

    # Wait with timeout to avoid hanging indefinitely under memory pressure
    if (( PREFILL_TIMEOUT > 0 )); then
        local elapsed=0
        while (( elapsed < PREFILL_TIMEOUT )); do
            local running=0
            for pid in "${pids[@]}"; do
                kill -0 "$pid" 2>/dev/null && { running=1; break; }
            done
            (( running == 0 )) && break
            sleep 5
            elapsed=$(( elapsed + 5 ))
        done
        # Kill any still-running prefill processes
        if (( elapsed >= PREFILL_TIMEOUT )); then
            echo "WARNING: prefill timed out after ${PREFILL_TIMEOUT}s — killing remaining prefill processes" >&2
            for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
            for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
            return 1
        fi
    fi

    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
    return $failed
}

# ─── Run memtier in all client VMs (parallel), collect results ───────
run_measure_all_clients() {
    local out_dir="$1"; local pids=() failed=0
    RUN_WORKLOAD_STATUS="ok"; RUN_WORKLOAD_DEAD_VMS=""

    for (( i=1; i<=CLIENT_VMS; i++ )); do
        local cout="${out_dir}/client${i}"; mkdir -p "$cout"
        local ports; ports="$(redis_host_ports_for_server "$i")"   # paired server<i>'s host ports
        (
            ssh_role client "$i" "TARGET_HOST=10.0.2.2 TARGET_PORTS='${ports}' DURATION=${DURATION} VCPUS=${CLIENT_VCPUS} bash /home/${VM_USER}/run_workload.sh client-run" \
                > "${cout}/workload.log" 2>&1
        ) &
        pids+=($!)
    done

    # Abort if any SERVER VM dies during the run (they are the pressured ones).
    while true; do
        local running=0
        for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && { running=1; break; }; done
        (( running == 0 )) && break
        local dead; dead=$(get_dead_vms server)
        if [[ -n "$dead" ]]; then
            echo "ERROR: server VM(s) died during run: $dead" >&2
            RUN_WORKLOAD_STATUS="vm_died"; RUN_WORKLOAD_DEAD_VMS="$dead"
            for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
            for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
            return 1
        fi
        sleep 2
    done
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done

    for (( i=1; i<=CLIENT_VMS; i++ )); do
        local remote_result
        remote_result=$(ssh_role client "$i" "cat /home/bench/benchmark_result.txt 2>/dev/null" 2>/dev/null || true)
        [[ -n "$remote_result" ]] && echo "$remote_result" > "${out_dir}/client${i}/benchmark_result.txt"
    done

    if (( failed == 1 )); then RUN_WORKLOAD_STATUS="run_failed"; return 1; fi
}

# ─── Aggregate throughput/p99 across client VMs (and their instances) ─
# throughput_agg: sum of ops/sec across ALL instances. throughput: mean per
# instance. p99: max. actual_instances: number of instances with a valid result.
parse_run_results() {
    local out_dir="$1"; local sum_tput=0 max_p99=0 inst_count=0
    for (( i=1; i<=CLIENT_VMS; i++ )); do
        local result="${out_dir}/client${i}/benchmark_result.txt"
        [[ -f "$result" ]] || continue
        local tput p99 inst
        tput=$(awk '/^throughput/{print $2; exit}' "$result")
        p99=$(awk '/^p99/{print $2; exit}' "$result")
        inst=$(awk '/^instances/{print $2; exit}' "$result")
        [[ -n "$tput" ]] && awk -v v="$tput" 'BEGIN{exit !(v+0>0)}' || continue
        sum_tput=$(awk -v a="$sum_tput" -v b="$tput" 'BEGIN{printf "%.2f", a+b}')
        max_p99=$(awk -v a="$max_p99" -v b="${p99:-0}" 'BEGIN{printf "%.2f", (b+0>a+0)?b:a}')
        inst_count=$(( inst_count + ${inst:-0} ))
    done
    RESULT_ACTUAL_INSTANCES="$inst_count"
    if (( inst_count > 0 )); then
        RESULT_THROUGHPUT=$(awk -v s="$sum_tput" -v n="$inst_count" 'BEGIN{printf "%.2f", s/n}')
        RESULT_THROUGHPUT_AGG="$sum_tput"
    else
        RESULT_THROUGHPUT=0; RESULT_THROUGHPUT_AGG=0
    fi
    RESULT_P99_MAX="$max_p99"
}

# ─── Collect host-side memory + compression stats (server cgroup) ────
collect_host_stats() {
    local swap_csv="${1:-}"
    HOST_MEMORY_PEAK=$(cat "$CG/memory.peak" 2>/dev/null || echo 0)
    HOST_MEMORY_HIGH=$(cat "$CG/memory.high" 2>/dev/null || echo max)
    HOST_MEMORY_MAX=$(cat "$CG/memory.max" 2>/dev/null || echo 0)
    HOST_SWAP_PEAK=$(cat "$CG/memory.swap.peak" 2>/dev/null || echo 0)
    HOST_ZSWAP_POOL=0; HOST_COMP_RATIO=0
    if [[ -n "$swap_csv" && -f "$swap_csv" && -x "${REDIS_DIR}/zswap_report.sh" ]]; then
        local swap_report; swap_report=$("${REDIS_DIR}/zswap_report.sh" "$swap_csv" 2>/dev/null || true)
        HOST_ZSWAP_POOL=$(echo "$swap_report" | awk '/Pool size:/{print $3; exit}')
        HOST_COMP_RATIO=$(echo "$swap_report" | awk '/Compression ratio:/{print $3; exit}')
        [[ -n "$HOST_ZSWAP_POOL" ]] || HOST_ZSWAP_POOL=0
        [[ -n "$HOST_COMP_RATIO" ]] || HOST_COMP_RATIO=0
    fi
}

# ─── Run a single scenario (baseline or memlimit-XX) ─────────────────
run_scenario() {
    local scenario="$1" limit_bytes="$2"
    local scenario_dir="${LOGDIR}/${scenario}"; mkdir -p "$scenario_dir"

    echo ""
    echo "========================================="
    if [[ "$limit_bytes" == "max" ]]; then
        echo " Scenario: $scenario (server limit: unlimited)"
    else
        echo " Scenario: $scenario (server limit: $(( limit_bytes / 1073741824 ))GB)"
    fi
    echo "========================================="

    # Clean start: stop VMs, recreate cgroup unlimited, boot servers in it.
    stop_all_vms
    kill_all_qemu_processes
    sleep 2
    echo 1 | sudo tee "$CG/cgroup.kill" >/dev/null 2>/dev/null || true
    sleep 1
    sudo rmdir "$CG" 2>/dev/null || true
    wait_for_ports_free 30
    sudo mkdir -p "$CG"
    echo "max" | sudo tee "$CG/memory.max" >/dev/null
    echo "max" | sudo tee "$CG/memory.swap.max" >/dev/null 2>/dev/null || true

    boot_all_vms "$VM_START_STAGGER_SEC"

    for (( i=1; i<=SERVER_VMS; i++ )); do wait_for_vm_ssh server "$i" "$VM_BOOT_WAIT"; done
    for (( i=1; i<=CLIENT_VMS; i++ )); do wait_for_vm_ssh client "$i" "$VM_BOOT_WAIT"; done
    deploy_workload_scripts

    # Apply the server memory limit BEFORE prefill so the dataset loads under pressure.
    # Use memory.high (throttle) instead of memory.max (OOM kill) to avoid
    # cgroup OOM kills under 2MB mTHP, where reclaim granularity is too coarse.
    if [[ "$limit_bytes" != "max" ]]; then
        echo "$limit_bytes" | sudo tee "$CG/memory.high" >/dev/null
    fi

    # Compressed-swap stats monitor.
    local swap_csv="${scenario_dir}/zswap_run.csv" swap_logger_pid=""
    if [[ "$SWAP_MODE" == "zram" ]] && [ -f "${REDIS_DIR}/zram_log.sh" ]; then
        "${REDIS_DIR}/zram_log.sh" 1 "$swap_csv" & swap_logger_pid=$!
    elif [ -f "${REDIS_DIR}/zswap_log.sh" ]; then
        "${REDIS_DIR}/zswap_log.sh" 1 "$swap_csv" & swap_logger_pid=$!
    fi

    # Start empty redis instances on all server VMs.
    echo "  Starting ${TOTAL_INSTANCES} redis instance(s) across ${SERVER_VMS} server VM(s)..."
    run_start_all_servers "$scenario_dir" || echo "WARNING: server start failed in '$scenario'"

    # Prefill from the CLIENT VMs (populate remote servers) with CPU accounting
    # on the server cgroup (measures the pressured server's load work).
    echo "  Prefilling from ${CLIENT_VMS} client VM(s) (dataset=${DB_FILE})..."
    read_vals_before
    local prefill_rc=0
    run_prefill_all_clients "$scenario_dir" || prefill_rc=$?
    read_vals_after
    local prefill_cpu_pct=$CPU_PCT prefill_user_pct=$USER_PCT prefill_sys_pct=$SYS_PCT prefill_sys_total_pct=$SYS_TOTAL_PCT

    # Validate prefill by checking key counts in the logs (exit code alone is
    # unreliable — memtier may return non-zero even when all data was loaded).
    local prefill_failed=0
    if (( prefill_rc != 0 )); then
        local loaded_clients=0
        for (( _ci=1; _ci<=CLIENT_VMS; _ci++ )); do
            local _plog="${scenario_dir}/client${_ci}/prefill.log"
            if [[ -f "$_plog" ]] && grep -q "keys resident" "$_plog"; then
                loaded_clients=$(( loaded_clients + 1 ))
            fi
        done
        if (( loaded_clients == CLIENT_VMS )); then
            echo "  Prefill exit code non-zero but all $loaded_clients clients loaded keys — continuing"
        elif (( loaded_clients > 0 )); then
            echo "WARNING: prefill partially completed ($loaded_clients/$CLIENT_VMS clients loaded) in '$scenario'"
        else
            prefill_failed=1
            echo "WARNING: prefill failed/timed out in '$scenario' (0/$CLIENT_VMS clients loaded)"
        fi
    fi

    # If prefill completely failed, skip the run — results would be meaningless (empty DB).
    if (( prefill_failed == 1 )); then
        echo "  Skipping memtier run (prefill incomplete — data not loaded under this pressure)"
        if [[ -n "$swap_logger_pid" ]]; then kill "$swap_logger_pid" 2>/dev/null || true; wait "$swap_logger_pid" 2>/dev/null || true; fi
        collect_host_stats "$swap_csv"
        RESULT_THROUGHPUT=0; RESULT_THROUGHPUT_AGG=0; RESULT_P99_MAX=0; RESULT_ACTUAL_INSTANCES=0
        local memory_limit_display; [[ "$scenario" == "baseline" ]] && memory_limit_display="max" || memory_limit_display="$limit_bytes"
        echo "scenario:$scenario, swap_mode:$SWAP_MODE, memory_limit:$memory_limit_display, memory_peak:$HOST_MEMORY_PEAK, zswap_pool_size:${HOST_ZSWAP_POOL:-0}, comp_ratio:${HOST_COMP_RATIO:-0}, memory_swap_peak:${HOST_SWAP_PEAK:-0}, throughput:0, throughput_agg:0, p99:0, configured_instances:$TOTAL_INSTANCES, actual_instances:0, scenario_status:invalid, invalid_reason:prefill_failed, prefill_cpu_pct:$prefill_cpu_pct, prefill_user_pct:$prefill_user_pct, prefill_sys_pct:$prefill_sys_pct, prefill_sys_total_pct:$prefill_sys_total_pct, run_cpu_pct:0, run_user_pct:0, run_sys_pct:0, run_sys_total_pct:0" \
            | tee "${LOGDIR}/${scenario}.log"
        return
    fi

    # Run (memtier from client VMs) with CPU accounting (server cgroup).
    echo "  Running memtier from ${CLIENT_VMS} client VM(s) (duration=${DURATION}s)..."
    read_vals_before
    local run_failed=0
    run_measure_all_clients "$scenario_dir" || { run_failed=1; echo "WARNING: run failed in '$scenario' (status=$RUN_WORKLOAD_STATUS)"; }
    read_vals_after
    local run_cpu_pct=$CPU_PCT run_user_pct=$USER_PCT run_sys_pct=$SYS_PCT run_sys_total_pct=$SYS_TOTAL_PCT

    if [[ -n "$swap_logger_pid" ]]; then kill "$swap_logger_pid" 2>/dev/null || true; wait "$swap_logger_pid" 2>/dev/null || true; fi
    sleep 1

    collect_host_stats "$swap_csv"
    parse_run_results "$scenario_dir"

    local memory_limit_display
    if [[ "$scenario" == "baseline" ]]; then memory_limit_display="max"; else memory_limit_display="$limit_bytes"; fi

    echo "scenario:$scenario, swap_mode:$SWAP_MODE, memory_limit:$memory_limit_display, memory_peak:$HOST_MEMORY_PEAK, zswap_pool_size:$HOST_ZSWAP_POOL, comp_ratio:$HOST_COMP_RATIO, memory_swap_peak:$HOST_SWAP_PEAK, throughput:$RESULT_THROUGHPUT, throughput_agg:$RESULT_THROUGHPUT_AGG, p99:$RESULT_P99_MAX, configured_instances:$TOTAL_INSTANCES, actual_instances:${RESULT_ACTUAL_INSTANCES:-0}, prefill_cpu_pct:$prefill_cpu_pct, prefill_user_pct:$prefill_user_pct, prefill_sys_pct:$prefill_sys_pct, prefill_sys_total_pct:$prefill_sys_total_pct, run_cpu_pct:$run_cpu_pct, run_user_pct:$run_user_pct, run_sys_pct:$run_sys_pct, run_sys_total_pct:$run_sys_total_pct" \
        | tee "${LOGDIR}/${scenario}.log"
}

# ─── Main ─────────────────────────────────────────────────────────────
compute_cpu_plan

echo "========================================="
echo " Redis Server/Client VM Memory Benchmark"
echo "========================================="
echo "Server VMs:   $SERVER_VMS × ${SERVER_MEM_GB}GB (${INSTANCES}×${MEM_PER_INSTANCE_GB}GB), ${SERVER_VCPUS} vCPU  [in cgroup]"
echo "Client VMs:   $CLIENT_VMS × ${CLIENT_MEM_GB}GB, ${CLIENT_VCPUS} vCPU  [unconstrained]"
echo "Instances:    $TOTAL_INSTANCES total (${INSTANCES}/server)"
echo "Total VM mem: ${TOTAL_VM_MEM_GB}GB (servers ${TOTAL_SERVER_MEM_GB}GB + clients ${TOTAL_CLIENT_MEM_GB}GB)"
echo "Dataset:      $DB_FILE"
echo "Duration:     ${DURATION}s"
echo "Core policy:  $CORE_POLICY"
for (( i=1; i<=SERVER_VMS; i++ )); do echo "  server$i cpus: ${SERVER_CPUSET[$i]:-auto}  mem: ${SERVER_MEMPOL[$i]:-localalloc}"; done
for (( i=1; i<=CLIENT_VMS; i++ )); do echo "  client$i cpus: ${CLIENT_CPUSET[$i]:-auto}  mem: ${CLIENT_MEMPOL[$i]:-localalloc}"; done
echo "Swap mode:    $SWAP_MODE"
echo "Compressor:   $COMPRESSOR"
echo "Sweep:        ${SWEEP_START}% → ${SWEEP_END}% (step ${SWEEP_STEP}%)"
echo "Threshold:    ${REGRESSION_THRESHOLD}% throughput regression"
echo "Log dir:      $LOGDIR"
echo "========================================="
echo ""

reduce_variance
echo ""
preflight_checks || exit 1

echo "Cleaning up previous run..."
kill_all_qemu_processes
sleep 2
stop_all_vms
echo 1 | sudo tee "$CG/cgroup.kill" >/dev/null 2>/dev/null || true
sudo rmdir "$CG" 2>/dev/null || true

rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"

create_fresh_overlays
ensure_cidata_all_vms

# ─── Compressor list ─────────────────────────────────────────────────
declare -a compressor_list=()
if [[ "$COMPRESSOR" == "all" ]]; then
    if [ -f /proc/sys/vm/reclaim-batchsize ]; then
        #compressor_list=("deflate-iaa-dynamic_r32_p5" "deflate-iaa-dynamic_r64_p5")
        #compressor_list=("lz4_r1_p3" "deflate-iaa-dynamic_r1_p3" "defalte-iaa-dynamic_r8_p3" "defalte-iaa-dynamic_r16_p3" "zstd_r1_p3")
        #compressor_list=("lz4_r1_p3" "defalte-iaa-dynamic_r8_p3" "zstd_r1_p3")
        compressor_list=("lz4_r1_p3" "zstd_r1_p3" "deflate-iaa_r1_p3" "deflate-iaa-dynamic_r8_p3" "deflate-iaa-dynamic_r16_p3" "deflate-iaa-dynamic_r32_p3" "deflate-iaa-dynamic_r64_p5" )
        #compressor_list=("lz4_r1_p3" "zstd_r1_p3" "deflate-iaa_r1_p3" "deflate-iaa-dynamic_r8_p3" )
    else
        compressor_list=("lzo_r1_p3" "deflate-iaa_r1_p3")
    fi
else
    compressor_list=("$COMPRESSOR")
fi

orig_logdir="$LOGDIR"

# ─── Save run configuration metadata ─────────────────────────────────
source "${THIS_DIR}/../scripts/collect_sysinfo.sh"
collect_sysinfo
_qemu_version=$($QEMU_BIN --version 2>/dev/null | head -1 || echo "N/A")
cat > "${orig_logdir}/run_config.json" <<RUNCFG
{
  "date": "$(date -Iseconds)",
  "hostname": "$(hostname)",
  "kernel": "$(uname -r)",
  "cpu_model": "$SYSINFO_CPU_MODEL",
  "cpu_sockets": "${SYSINFO_CPU_SOCKETS:-0}",
  "cores_per_socket": "${SYSINFO_CORES_PER_SOCKET:-0}",
  "threads_per_core": "${SYSINFO_THREADS_PER_CORE:-0}",
  "total_cpus": "${SYSINFO_TOTAL_CPUS:-0}",
  "numa_nodes": "${SYSINFO_NUMA_NODES:-0}",
  "host_mem_total_gb": "$SYSINFO_MEM_TOTAL_GB",
  "bios_version": "$SYSINFO_BIOS_VERSION",
  "bios_date": "$SYSINFO_BIOS_DATE",
  "qemu_version": "$_qemu_version",
  "db_file": "$DB_FILE",
  "duration_sec": "$DURATION",
  "server_vms": "$SERVER_VMS",
  "client_vms": "$CLIENT_VMS",
  "instances_per_server": "$INSTANCES",
  "total_instances": "$TOTAL_INSTANCES",
  "mem_per_instance_gb": "$MEM_PER_INSTANCE_GB",
  "server_mem_gb": "$SERVER_MEM_GB",
  "client_mem_gb": "$CLIENT_MEM_GB",
  "server_vcpus": "$SERVER_VCPUS",
  "client_vcpus": "$CLIENT_VCPUS",
  "core_policy": "$CORE_POLICY",
  "swap_mode": "$SWAP_MODE",
  "requested_compressor": "$COMPRESSOR",
  "sweep_start_pct": "$SWEEP_START",
  "sweep_end_pct": "$SWEEP_END",
  "sweep_step_pct": "$SWEEP_STEP",
  "regression_threshold_pct": "$REGRESSION_THRESHOLD",
  "total_vm_mem_gb": "$TOTAL_VM_MEM_GB",
  "mthp": "$MTHP"
}
RUNCFG
echo "Saved run_config.json"

# ─── One-time dataset + memtier staging + snapshot ───────────────────
prepare_fresh_vms_for_scenario "dataset + memtier staging (one-time)"
snapshot_vm_overlays

# ─── Run sweep for each compressor ───────────────────────────────────
report_string=""
for comp in "${compressor_list[@]}"; do
    if [[ ${#compressor_list[@]} -gt 1 ]]; then LOGDIR="${orig_logdir}/${comp}"; else LOGDIR="$orig_logdir"; fi
    rm -rf "$LOGDIR"; mkdir -p "$LOGDIR"

    configure_swap_for_compressor "$comp" || continue
    restore_vm_overlays

    run_scenario "baseline" "max"
    baseline_tput="$RESULT_THROUGHPUT_AGG"
    baseline_peak=$(grep -oP 'memory_peak:\K[0-9]+' "${LOGDIR}/baseline.log")

    if [[ ! "$baseline_peak" =~ ^[0-9]+$ ]] || (( baseline_peak <= 0 )); then
        echo "ERROR: invalid baseline memory_peak '$baseline_peak'; skipping '$comp'." >&2; continue
    fi
    if ! awk -v b="$baseline_tput" 'BEGIN {exit !(b+0 > 0)}'; then
        echo "ERROR: invalid baseline throughput '$baseline_tput'; skipping '$comp'." >&2; continue
    fi
    echo "  Baseline peak server memory: $(( baseline_peak / 1073741824 ))GB ($baseline_peak bytes)"
    echo "  Baseline agg throughput: ${baseline_tput} ops/sec"

    for (( pct = SWEEP_START; pct >= SWEEP_END; pct -= SWEEP_STEP )); do
        limit_bytes=$(( baseline_peak * pct / 100 ))
        (( limit_bytes <= 0 )) && limit_bytes=1
        echo "Limiting server memory to $limit_bytes ( ${pct}% of baseline peak )"
        restore_vm_overlays
        run_scenario "memlimit-${pct}" "$limit_bytes"

        if awk -v b="$baseline_tput" -v c="${RESULT_THROUGHPUT_AGG:-0}" -v thr="$REGRESSION_THRESHOLD" \
            'BEGIN {drop=(b-c)/b*100; exit !(drop >= thr)}'; then
            drop_pct=$(awk -v b="$baseline_tput" -v c="${RESULT_THROUGHPUT_AGG:-0}" 'BEGIN {printf "%.2f", (b-c)/b*100}')
            echo "Throughput dropped by ${drop_pct}% (>=${REGRESSION_THRESHOLD}%) at memlimit-${pct}; preserving this point and aborting sweep for '$comp'"
            break
        fi
    done

    echo ""
    echo "Generating report for $comp..."
    cat "${LOGDIR}"/*.log | python "${THIS_DIR}/report.py" | tee "${LOGDIR}/${comp}.report"
    report_string+="${LOGDIR}/${comp}.report "
done

# Final cleanup
stop_all_vms
echo 1 | sudo tee "$CG/cgroup.kill" >/dev/null 2>/dev/null || true
sleep 2
sudo rmdir "$CG" 2>/dev/null || true

LOGDIR="$orig_logdir"
report_string="${report_string% }"
if [[ -n "$report_string" ]]; then
    echo "Generating HTML plot..."
    python "${REDIS_DIR}/report_plot.py" ${report_string} --output-dir "${orig_logdir}" \
        || echo "WARNING: plot generation failed"
fi

echo ""
echo "========================================="
echo " Benchmark complete"
echo "========================================="
echo "Results: $orig_logdir"
