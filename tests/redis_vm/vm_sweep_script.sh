#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# vm_sweep_script.sh — VM-count sweep for the paired server/client Redis VM
# benchmark.
#
# Sweeps the number of SERVER VMs (client VMs match 1:1) for a given compressor
# configuration under a FIXED host cgroup memory limit, producing .report files
# suitable for vm_sweep_reporter.py. The redis instances per VM (INSTANCES) is
# held fixed (default 1). Growing the VM count raises guest memory pressure
# (compression/swap) at a constant memory ceiling.
#
# Memory splitting mirrors tests/redis/instance_sweep_script.sh: an --init-limit
# total physical budget (GB) is split between the server cgroup and zram using
# the _l<mem-limit>_s<disk-size> fields of the compressor config name.
#
# Only the SERVER VMs are placed in the pressured cgroup ($CG); client VMs run
# unconstrained. Scenario log lines are consumed by vm_sweep_reporter.py.

set -euo pipefail

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
LOGDIR="${THIS_DIR}/logdir_vm_sweep"
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
VM_LIST="${VM_LIST:-}"                          # explicit sweep points (space/comma sep); empty -> swap-mode default
INSTANCES="${INSTANCES:-1}"                     # redis instances per server VM (fixed for now)
MEM_PER_INSTANCE_GB="${MEM_PER_INSTANCE_GB:-6}" # RAM per redis instance; server VM RAM = INSTANCES * this
CLIENT_MEM_GB="${CLIENT_MEM_GB:-2}"             # RAM per (unconstrained) client VM
SERVER_VCPUS="${SERVER_VCPUS:-}"                # vCPUs per server VM (empty -> INSTANCES + 1)
CLIENT_VCPUS="${CLIENT_VCPUS:-}"                # vCPUs per client VM (empty -> INSTANCES, min 1)
VM_DISK_GB="${VM_DISK_GB:-20}"                  # overlay disk size per VM (GB)

INIT_LIMIT="${INIT_LIMIT:-64}"                  # total physical memory budget in GB (cgroup + zram)
ZRAM_LIMIT="${ZRAM_LIMIT:-}"                     # zram physical mem limit GB (CLI override for _l)
ZRAM_DISKSIZE="${ZRAM_DISKSIZE:-}"              # zram virtual disk size GB (CLI override for _s)

DB_FILE="${DB_FILE:-}"                          # redis dataset staged into server VMs (empty -> derived from reps/cols)
REPS="${REPS:-4000}"                            # repeat_redis_file.py -r (dataset repetitions for generation)
COMBINED_LINES="${COMBINED_LINES:-3}"           # repeat_redis_file.py -c (lines combined per entry)
DURATION="${DURATION:-120}"                     # memtier run duration per scenario (seconds)
SWAP_MODE="${SWAP_MODE:-zswap}"                 # compressed-swap backend: zswap or zram
COMPRESSOR="${COMPRESSOR:-all}"                 # compressor profile to test, or 'all'
ACCEPT_KPI="${ACCEPT_KPI:-95}"                  # acceptable KPI threshold % (reporter crossing point)
REGRESSION_THRESHOLD="${REGRESSION_THRESHOLD:-10}" # % per-instance throughput drop vs first sweep point that stops the sweep for a compressor
CORE_FREQUENCY="${CORE_FREQUENCY:-}"            # core frequency MHz (passed to config_sys_*)
MTHP="${MTHP:-}"                                # mTHP sizes, comma-separated (e.g. 64kB,128kB)
PREFILL_TIMEOUT="${PREFILL_TIMEOUT:-600}"       # max seconds to wait for prefill (0=no timeout)

CORE_POLICY="${CORE_POLICY:-spread-nodes}"      # host-core assignment: spread-nodes | siblings-first
SERVER_CPUSETS="${SERVER_CPUSETS:-}"            # explicit per-server host cpusets (empty -> auto)
CLIENT_CPUSETS="${CLIENT_CPUSETS:-}"            # explicit per-client host cpusets (empty -> auto)

SSH_KEY="${THIS_DIR}/vm_key"
VM_IMAGE_DIR="${THIS_DIR}/images"
SERVER_SSH_BASE="${SERVER_SSH_BASE:-2240}"
CLIENT_SSH_BASE="${CLIENT_SSH_BASE:-2340}"
REDIS_GUEST_BASE="${REDIS_GUEST_BASE:-9000}"
REDIS_HOST_BASE="${REDIS_HOST_BASE:-16000}"
VM_BOOT_WAIT="${VM_BOOT_WAIT:-420}"
VM_START_STAGGER_SEC="${VM_START_STAGGER_SEC:-2}"
CG="/sys/fs/cgroup/redisbench_vm"

# ─── Usage ────────────────────────────────────────────────────────────
print_usage() {
    cat <<'EOF'
Usage: vm_sweep_script.sh [options]

Sweep options:
  --vm-list <points>        Server-VM counts to sweep (space/comma separated,
                            strictly ascending). Empty -> swap-mode default:
                              zswap: 10,15,16,17,18,19,20,21,22,23,24,25
                              zram:  10,15,16,18,20,22,24,26,28,30
  --instances <N>           Redis instances per server VM (default: 1)
  --mem-per-instance <GB>   RAM per redis instance; server RAM = N*this (default: 6)
  --client-mem <GB>         RAM per client VM (default: 2)
  --server-vcpus <N>        vCPUs per server VM (default: instances + 1)
  --client-vcpus <N>        vCPUs per client VM (default: instances)

Memory split (mirrors instance_sweep_script.sh):
  --init-limit <GB>         Total physical memory budget (default: 64)
                            cgroup memory.max = init-limit - zram-limit(l),
                            zram = zram-limit(l)
  --zram-limit <GB>         Zram physical mem limit (CLI override for _l in config name)
  --zram-disksize <GB>      Zram virtual disk size (CLI override for _s in config name)

CPU planning:
  --core-policy <p>         spread-nodes | siblings-first (default: spread-nodes)
  --server-cpusets <map>    Explicit per-server host cpusets, ';'-separated
  --client-cpusets <map>    Explicit per-client host cpusets

Dataset / workload:
  --db-file <name>          Redis dataset file. Overrides the auto-generated
                            dataset from --reps/--combined-lines
  --reps, -r <N>            Dataset repetitions for generation (default: 10000)
  --combined-lines <N>      Lines combined per entry for generation (default: 10)
  --duration <sec>          memtier run duration per scenario (default: 120)

Compressor:
  --swap-mode <mode>        zswap or zram (default: zswap)
  --compressor <name>       Compressor profile or 'all' (default: all)
  --frequency, -f <MHz>     Core frequency in MHz
  --mthp <sizes>            mTHP sizes, comma-separated (e.g. 64kB,128kB)
  --accept-kpi <pct>        Acceptable KPI threshold % (default: 95)
  --threshold, -t <pct>     Per-instance throughput drop vs the first (lowest-VM)
                            sweep point that stops the sweep for a compressor (default: 7)
  --logdir, -l <path>       Output directory (default: ./logdir_vm_sweep)
  --help, -h                Show this help

All VMs are provisioned once at the largest sweep point; each sweep point boots
the first N of them. Only server VMs are memory-limited (fixed cgroup
memory.max); client VMs run unconstrained.
EOF
}

# ─── Parse arguments ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm-list)           VM_LIST="$2"; shift 2 ;;
        --instances)         INSTANCES="$2"; shift 2 ;;
        --mem-per-instance)  MEM_PER_INSTANCE_GB="$2"; shift 2 ;;
        --client-mem)        CLIENT_MEM_GB="$2"; shift 2 ;;
        --server-vcpus)      SERVER_VCPUS="$2"; shift 2 ;;
        --client-vcpus)      CLIENT_VCPUS="$2"; shift 2 ;;
        --init-limit)        INIT_LIMIT="$2"; shift 2 ;;
        --zram-limit)        ZRAM_LIMIT="$2"; shift 2 ;;
        --zram-disksize)     ZRAM_DISKSIZE="$2"; shift 2 ;;
        --core-policy)       CORE_POLICY="$2"; shift 2 ;;
        --server-cpusets)    SERVER_CPUSETS="$2"; shift 2 ;;
        --client-cpusets)    CLIENT_CPUSETS="$2"; shift 2 ;;
        --db-file)           DB_FILE="$2"; shift 2 ;;
        --reps|-r)           REPS="$2"; shift 2 ;;
        --combined-lines)    COMBINED_LINES="$2"; shift 2 ;;
        --duration)          DURATION="$2"; shift 2 ;;
        --swap-mode)         SWAP_MODE="$2"; shift 2 ;;
        --compressor)        COMPRESSOR="$2"; shift 2 ;;
        --frequency|-f)      CORE_FREQUENCY="$2"; shift 2 ;;
        --mthp)              MTHP="$2"; shift 2 ;;
        --accept-kpi)        ACCEPT_KPI="$2"; shift 2 ;;
        --threshold|-t)      REGRESSION_THRESHOLD="$2"; shift 2 ;;
        --logdir|-l)         LOGDIR="$2"; shift 2 ;;
        --help|-h)           print_usage; exit 0 ;;
        *)                   echo "Unknown option: $1"; print_usage; exit 1 ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────────
if [[ "$SWAP_MODE" != "zswap" && "$SWAP_MODE" != "zram" ]]; then
    echo "ERROR: invalid swap mode '$SWAP_MODE'. Must be 'zswap' or 'zram'."; exit 1
fi
case "$CORE_POLICY" in
    spread-nodes|siblings-first) ;;
    *) echo "ERROR: invalid --core-policy '$CORE_POLICY'. Must be spread-nodes or siblings-first."; exit 1 ;;
esac
(( INSTANCES >= 1 ))   || { echo "ERROR: --instances must be >= 1"; exit 1; }

# Resolve the sweep points. An explicit VM_LIST (env or --vm-list) overrides the
# swap-mode default lists. Values may be space- or comma-separated.
if [[ -z "$VM_LIST" ]]; then
    if [[ "$SWAP_MODE" == "zram" ]]; then
        VM_LIST="30 32 34 35 36 37 38 39 40 42 44 46 48 50"
    else
        VM_LIST="30 32 34 35 36 37 38 39 40 42 44 46 48 50"
    fi
fi
read -r -a VM_POINTS <<< "${VM_LIST//,/ }"
(( ${#VM_POINTS[@]} >= 1 )) || { echo "ERROR: VM sweep list is empty"; exit 1; }
_prev_vm=0
for _p in "${VM_POINTS[@]}"; do
    [[ "$_p" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid VM count '$_p' in sweep list"; exit 1; }
    (( _p >= 1 ))           || { echo "ERROR: VM count must be >= 1 (got $_p)"; exit 1; }
    (( _p > _prev_vm ))     || { echo "ERROR: VM sweep list must be strictly ascending (got '$VM_LIST')"; exit 1; }
    _prev_vm="$_p"
done
# VM_MIN/VM_MAX drive provisioning and the host-memory budget check below.
VM_MIN="${VM_POINTS[0]}"
VM_MAX="${VM_POINTS[${#VM_POINTS[@]}-1]}"

# Derive the dataset filename from reps/combined_lines and generate it if missing.
# An explicit --db-file overrides both the name and the generation step.
if [[ -z "$DB_FILE" ]]; then
    DB_FILE="import_movies_${REPS}r_${COMBINED_LINES}c.csv"
    if [[ ! -f "${THIS_DIR}/${DB_FILE}" ]]; then
        echo "=== Generating dataset ${DB_FILE} (reps=${REPS}, combined_lines=${COMBINED_LINES}) ==="
        ( cd "${THIS_DIR}" && python repeat_redis_file.py -r "${REPS}" -c "${COMBINED_LINES}" )
    fi
fi

# ─── Derived config ───────────────────────────────────────────────────
SERVER_MEM_GB=$(( INSTANCES * MEM_PER_INSTANCE_GB ))
[[ -z "$SERVER_VCPUS" ]] && SERVER_VCPUS=$(( INSTANCES ))
if [[ -z "$CLIENT_VCPUS" ]]; then CLIENT_VCPUS="$INSTANCES"; (( CLIENT_VCPUS < 1 )) && CLIENT_VCPUS=1; fi

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
VM_USER="bench"

# Provisioning and the largest sweep point both boot VM_MAX VMs simultaneously.
# Server VMs are collectively capped by the cgroup budget (INIT_LIMIT) and
# overcommit via compression, so their PHYSICAL footprint is bounded by that
# budget — not their full configured guest RAM. Only client VMs (unconstrained)
# need their full configured RAM backed physically.
MAX_SERVER_MEM_GB=$(( VM_MAX * SERVER_MEM_GB ))
MAX_CLIENT_MEM_GB=$(( VM_MAX * CLIENT_MEM_GB ))
MAX_TOTAL_VM_MEM_GB=$(( MAX_SERVER_MEM_GB + MAX_CLIENT_MEM_GB ))
SERVER_PHYS_GB="$INIT_LIMIT"
(( MAX_SERVER_MEM_GB < SERVER_PHYS_GB )) && SERVER_PHYS_GB="$MAX_SERVER_MEM_GB"
PHYS_PEAK_GB=$(( SERVER_PHYS_GB + MAX_CLIENT_MEM_GB ))
HOST_RAM_GB=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
HOST_HEADROOM_GB=$(( HOST_RAM_GB * 10 / 100 )); (( HOST_HEADROOM_GB < 8 )) && HOST_HEADROOM_GB=8
AVAILABLE_RAM_GB=$(( HOST_RAM_GB - HOST_HEADROOM_GB ))
if (( PHYS_PEAK_GB > AVAILABLE_RAM_GB )); then
    echo "ERROR: peak physical VM memory ${PHYS_PEAK_GB}GB at ${VM_MAX} VMs (servers capped ~${SERVER_PHYS_GB}GB via cgroup + clients ${MAX_CLIENT_MEM_GB}GB)"
    echo "       exceeds available host RAM ${AVAILABLE_RAM_GB}GB (host ${HOST_RAM_GB}GB, ${HOST_HEADROOM_GB}GB reserved)."
    echo "       Reduce --vm-max / --client-mem / --init-limit."
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
        echo "    python repeat_redis_file.py -r ${REPS} -c ${COMBINED_LINES}"
        exit 1
    fi
    mkdir -p "$VM_IMAGE_DIR"
    cp "$dataset_src" "$staged_dataset"
    echo "Staged dataset into images/: $staged_dataset"
fi

export DB_FILE DURATION

# vm_lib.sh and the workload helpers below iterate 1..SERVER_VMS / 1..CLIENT_VMS.
# We set these to the current sweep point (or VM_MAX during provisioning).
SERVER_VMS="$VM_MAX"
CLIENT_VMS="$VM_MAX"

# ─── Source VM management library and compressor helpers ─────────────
source "${THIS_DIR}/vm_lib.sh"
source "${THIS_DIR}/../scripts/compressor_lib.sh"

# ─── Compressor config parsing (mirrors instance_sweep_script.sh) ────
# Extended naming: <algo>_r<reclaim-batchsize>_p<page-cluster>[_l<mem-limit-GB>_s<disk-size-GB>]
# Sets: comp_algo, reclaim_batchsize, page_cluster, cfg_zram_mem_limit, cfg_zram_disk_size
parse_comp_config() {
    local comp="$1"
    comp_algo="$comp"
    reclaim_batchsize=1
    page_cluster=3
    cfg_zram_mem_limit=""
    cfg_zram_disk_size=""

    if [[ "$comp" =~ ^(.+)_r([0-9]+)_p([0-9]+)_l([0-9]+)_s([0-9]+)$ ]]; then
        comp_algo="${BASH_REMATCH[1]}"
        reclaim_batchsize="${BASH_REMATCH[2]}"
        page_cluster="${BASH_REMATCH[3]}"
        cfg_zram_mem_limit="${BASH_REMATCH[4]}"
        cfg_zram_disk_size="${BASH_REMATCH[5]}"
    elif [[ "$comp" =~ ^(.+)_r([0-9]+)_p([0-9]+)$ ]]; then
        comp_algo="${BASH_REMATCH[1]}"
        reclaim_batchsize="${BASH_REMATCH[2]}"
        page_cluster="${BASH_REMATCH[3]}"
    fi

    # Command-line overrides take precedence over per-config values.
    [[ -n "$ZRAM_LIMIT" ]] && cfg_zram_mem_limit="$ZRAM_LIMIT"
    [[ -n "$ZRAM_DISKSIZE" ]] && cfg_zram_disk_size="$ZRAM_DISKSIZE"
    return 0
}

# Compute the fixed server-cgroup memory ceiling (bytes) for a compressor config.
# Sets: limit (bytes), eff_limit (GB). Same split as instance_sweep_script.sh.
compute_memory_limit() {
    if [[ "${cfg_zram_disk_size:-0}" == "0" && "${cfg_zram_mem_limit:-0}" == "0" ]]; then
        eff_limit="${INIT_LIMIT}"
        echo "=== Memory limit: ${eff_limit} GB (baseline, no zram split) ==="
    else
        local zram_reserved="${cfg_zram_mem_limit:-0}"
        eff_limit=$(( INIT_LIMIT - zram_reserved ))
        if (( eff_limit <= 0 )); then
            echo "ERROR: init-limit (${INIT_LIMIT}GB) must be > zram-limit (${zram_reserved}GB)" >&2
            exit 1
        fi
        echo "=== Memory limit: ${eff_limit}GB cgroup + ${zram_reserved}GB zram = ${INIT_LIMIT}GB total ==="
    fi
    limit=$(( eff_limit * 1024 * 1024 * 1024 ))
}

# ─── Configure compressor on host (with memory split args) ───────────
configure_swap_for_compressor() {
    local comp="$1"
    parse_comp_config "$comp"
    local args=(-c "$comp_algo" -r "$reclaim_batchsize" -p "$page_cluster")
    [[ -n "$CORE_FREQUENCY" ]] && args+=(-f "$CORE_FREQUENCY")
    [[ -n "$MTHP" ]] && args+=(-t "$MTHP")
    echo "Configuring $SWAP_MODE: algo=$comp_algo r=$reclaim_batchsize p=$page_cluster l=${cfg_zram_mem_limit:-auto} s=${cfg_zram_disk_size:-auto} mthp=${MTHP:-none}"
    if [[ "$SWAP_MODE" == "zram" ]]; then
        [[ -n "$cfg_zram_mem_limit" ]] && args+=(-l "$cfg_zram_mem_limit")
        [[ -n "$cfg_zram_disk_size" ]] && args+=(-s "$cfg_zram_disk_size")
        "${THIS_DIR}/../scripts/config_sys_zram.sh" "${args[@]}" || {
            echo "ERROR: Failed to configure $comp_algo — skipping"; return 1; }
    else
        "${THIS_DIR}/../scripts/config_sys_zswap.sh" "${args[@]}" || {
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
        local ports; ports="$(redis_host_ports_for_server "$i")"
        (
            ssh_role client "$i" "TARGET_HOST=10.0.2.2 TARGET_PORTS='${ports}' DB_FILE=${DB_FILE} VCPUS=${CLIENT_VCPUS} bash /home/${VM_USER}/run_workload.sh client-prefill" \
                > "${cout}/prefill.log" 2>&1
        ) &
        pids+=($!)
    done

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
        local ports; ports="$(redis_host_ports_for_server "$i")"
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
# Sets RESULT_THROUGHPUT (mean/instance), RESULT_THROUGHPUT_AGG (sum),
# RESULT_P99_MAX, RESULT_ACTUAL_INSTANCES, RESULT_ACTUAL_VMS.
parse_run_results() {
    local out_dir="$1"; local sum_tput=0 max_p99=0 inst_count=0 vm_count=0
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
        vm_count=$(( vm_count + 1 ))
    done
    RESULT_ACTUAL_INSTANCES="$inst_count"
    RESULT_ACTUAL_VMS="$vm_count"
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

# ─── Run a single VM-count scenario under the fixed memory ceiling ───
run_vm_scenario() {
    local scenario="$1" limit_bytes="$2" logdir="$3"
    local scenario_dir="${logdir}/${scenario}"; mkdir -p "$scenario_dir"
    local total_instances=$(( SERVER_VMS * INSTANCES ))

    echo ""
    echo "========================================="
    echo " Scenario: $scenario (${SERVER_VMS} server VMs, limit $(( limit_bytes / 1073741824 ))GB)"
    echo "========================================="

    # Clean start: stop VMs, recreate cgroup unlimited, boot the first N VMs.
    stop_all_vms
    kill_all_qemu_processes
    sleep 2
    echo 1 | sudo tee "$CG/cgroup.kill" >/dev/null 2>/dev/null || true
    sleep 1
    sudo rmdir "$CG" 2>/dev/null || true
    wait_for_ports_free 30
    sudo mkdir -p "$CG"
    echo "max" | sudo tee "$CG/memory.max" >/dev/null
    # Baseline runs with swap disabled in the cgroup so hitting memory.max
    # OOM-kills VMs instead of overflowing into zswap/zram.
    if [[ "${IS_BASELINE:-false}" == true ]]; then
        echo "0" | sudo tee "$CG/memory.swap.max" >/dev/null 2>/dev/null || true
    else
        echo "max" | sudo tee "$CG/memory.swap.max" >/dev/null 2>/dev/null || true
    fi

    boot_all_vms "$VM_START_STAGGER_SEC"
    for (( i=1; i<=SERVER_VMS; i++ )); do wait_for_vm_ssh server "$i" "$VM_BOOT_WAIT"; done
    for (( i=1; i<=CLIENT_VMS; i++ )); do wait_for_vm_ssh client "$i" "$VM_BOOT_WAIT"; done
    deploy_workload_scripts

    # Fixed hard memory ceiling (memory.max) applied BEFORE prefill so data loads
    # under pressure — excess pages reclaim into the configured zswap/zram.
    echo "$limit_bytes" | sudo tee "$CG/memory.max" >/dev/null

    # Compressed-swap stats monitor (skipped for the swap-disabled baseline).
    local swap_csv="${scenario_dir}/zswap_run.csv" swap_logger_pid=""
    if [[ "${IS_BASELINE:-false}" != true ]]; then
        if [[ "$SWAP_MODE" == "zram" ]] && [ -f "${REDIS_DIR}/zram_log.sh" ]; then
            "${REDIS_DIR}/zram_log.sh" 1 "$swap_csv" & swap_logger_pid=$!
        elif [ -f "${REDIS_DIR}/zswap_log.sh" ]; then
            "${REDIS_DIR}/zswap_log.sh" 1 "$swap_csv" & swap_logger_pid=$!
        fi
    fi

    echo "  Starting ${total_instances} redis instance(s) across ${SERVER_VMS} server VM(s)..."
    run_start_all_servers "$scenario_dir" || echo "WARNING: server start failed in '$scenario'"

    echo "  Prefilling from ${CLIENT_VMS} client VM(s) (dataset=${DB_FILE})..."
    read_vals_before
    local prefill_rc=0
    run_prefill_all_clients "$scenario_dir" || prefill_rc=$?
    read_vals_after
    local prefill_cpu_pct=$CPU_PCT prefill_user_pct=$USER_PCT prefill_sys_pct=$SYS_PCT prefill_sys_total_pct=$SYS_TOTAL_PCT

    # Validate prefill by key counts (exit code alone is unreliable under pressure).
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

    if (( prefill_failed == 1 )); then
        echo "  Skipping memtier run (prefill incomplete)"
        if [[ -n "$swap_logger_pid" ]]; then kill "$swap_logger_pid" 2>/dev/null || true; wait "$swap_logger_pid" 2>/dev/null || true; fi
        collect_host_stats "$swap_csv"
        echo "scenario:$scenario, swap_mode:$SWAP_MODE, memory_limit:$limit_bytes, memory_peak:$HOST_MEMORY_PEAK, zswap_pool_size:${HOST_ZSWAP_POOL:-0}, comp_ratio:${HOST_COMP_RATIO:-0}, memory_swap_peak:${HOST_SWAP_PEAK:-0}, throughput:0, throughput_agg:0, p99:0, server_vms:$SERVER_VMS, instances_per_server:$INSTANCES, configured_instances:$total_instances, actual_vms:0, actual_instances:0, scenario_status:invalid, invalid_reason:prefill_failed, prefill_cpu_pct:$prefill_cpu_pct, prefill_user_pct:$prefill_user_pct, prefill_sys_pct:$prefill_sys_pct, prefill_sys_total_pct:$prefill_sys_total_pct, run_cpu_pct:0, run_user_pct:0, run_sys_pct:0, run_sys_total_pct:0" \
            | tee "${logdir}/${scenario}.log"
        return
    fi

    echo "  Running memtier from ${CLIENT_VMS} client VM(s) (duration=${DURATION}s)..."
    read_vals_before
    run_measure_all_clients "$scenario_dir" || echo "WARNING: run failed in '$scenario' (status=$RUN_WORKLOAD_STATUS)"
    read_vals_after
    local run_cpu_pct=$CPU_PCT run_user_pct=$USER_PCT run_sys_pct=$SYS_PCT run_sys_total_pct=$SYS_TOTAL_PCT

    if [[ -n "$swap_logger_pid" ]]; then kill "$swap_logger_pid" 2>/dev/null || true; wait "$swap_logger_pid" 2>/dev/null || true; fi
    sleep 1

    collect_host_stats "$swap_csv"
    parse_run_results "$scenario_dir"

    echo "scenario:$scenario, swap_mode:$SWAP_MODE, memory_limit:$limit_bytes, memory_peak:$HOST_MEMORY_PEAK, zswap_pool_size:$HOST_ZSWAP_POOL, comp_ratio:$HOST_COMP_RATIO, memory_swap_peak:$HOST_SWAP_PEAK, throughput:$RESULT_THROUGHPUT, throughput_agg:$RESULT_THROUGHPUT_AGG, p99:$RESULT_P99_MAX, server_vms:$SERVER_VMS, instances_per_server:$INSTANCES, configured_instances:$total_instances, actual_vms:${RESULT_ACTUAL_VMS:-0}, actual_instances:${RESULT_ACTUAL_INSTANCES:-0}, prefill_cpu_pct:$prefill_cpu_pct, prefill_user_pct:$prefill_user_pct, prefill_sys_pct:$prefill_sys_pct, prefill_sys_total_pct:$prefill_sys_total_pct, run_cpu_pct:$run_cpu_pct, run_user_pct:$run_user_pct, run_sys_pct:$run_sys_pct, run_sys_total_pct:$run_sys_total_pct" \
        | tee "${logdir}/${scenario}.log"
}

# ─── Main ─────────────────────────────────────────────────────────────
echo "========================================="
echo " Redis VM-Count Sweep Benchmark"
echo "========================================="
echo "VM sweep:     ${VM_POINTS[*]} server VMs (client VMs 1:1)"
echo "Instances/VM: ${INSTANCES}  (${MEM_PER_INSTANCE_GB}GB each -> ${SERVER_MEM_GB}GB/server VM)"
echo "Client VM:    ${CLIENT_MEM_GB}GB each  [unconstrained]"
echo "Init limit:   ${INIT_LIMIT}GB total budget (cgroup + zram)"
echo "Dataset:      ${DB_FILE}"
echo "Duration:     ${DURATION}s"
echo "Core policy:  ${CORE_POLICY}"
echo "Swap mode:    ${SWAP_MODE}"
echo "Compressor:   ${COMPRESSOR}"
echo "Threshold:    ${REGRESSION_THRESHOLD}% per-instance throughput regression"
echo "Peak VM mem:  ${MAX_TOTAL_VM_MEM_GB}GB at ${VM_MAX} VMs (host ${HOST_RAM_GB}GB)"
echo "Log dir:      ${LOGDIR}"
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

# ─── Provision all VMs once at VM_MAX (overlays, cloud-init, packages,
#     dataset staging), then snapshot so each sweep point restores fast. ─
SERVER_VMS="$VM_MAX"; CLIENT_VMS="$VM_MAX"
compute_cpu_plan
create_fresh_overlays
ensure_cidata_all_vms

# ─── Save run configuration metadata (drives reporter System Config) ─
source "${THIS_DIR}/../scripts/collect_sysinfo.sh"
collect_sysinfo
_qemu_version=$($QEMU_BIN --version 2>/dev/null | head -1 || echo "N/A")
cat > "${LOGDIR}/run_config.json" <<RUNCFG
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
  "vm_min": "$VM_MIN",
  "vm_max": "$VM_MAX",
  "vm_list": "${VM_POINTS[*]}",
  "instances_per_server": "$INSTANCES",
  "mem_per_instance_gb": "$MEM_PER_INSTANCE_GB",
  "server_mem_gb": "$SERVER_MEM_GB",
  "client_mem_gb": "$CLIENT_MEM_GB",
  "server_vcpus": "$SERVER_VCPUS",
  "client_vcpus": "$CLIENT_VCPUS",
  "core_policy": "$CORE_POLICY",
  "swap_mode": "$SWAP_MODE",
  "requested_compressor": "$COMPRESSOR",
  "init_limit_gb": "$INIT_LIMIT",
  "accept_kpi_pct": "$ACCEPT_KPI",
  "regression_threshold_pct": "$REGRESSION_THRESHOLD"
}
RUNCFG
echo "Saved run_config.json"

prepare_fresh_vms_for_scenario "dataset + memtier staging (one-time, ${VM_MAX} VMs)"
snapshot_vm_overlays

# ─── Compressor list (extended _l/_s naming for the memory split) ────
declare -a compressor_list=()
if [[ "$COMPRESSOR" == "all" ]]; then
    if [ -f /proc/sys/vm/reclaim-batchsize ]; then
        compressor_list=(
            "deflate-iaa_r64_p5_l0_s0"
            "deflate-iaa_r64_p5_l12_s64"
            "deflate-iaa-dynamic_r64_p5_l12_s64"
            "zstd_r1_p3_l12_s64"
            "lz4_r1_p3_l12_s64"
        )
    else
        compressor_list=("lzo_r1_p3" "deflate-iaa_r1_p3" "zstd_r1_p3" "lz4_r1_p3")
    fi
else
    compressor_list=("$COMPRESSOR")
fi

# ─── Run the VM-count sweep for each compressor ──────────────────────
iaa_attempted=false
ran_iaa_algos=""
report_string=""

for comp in "${compressor_list[@]}"; do
    parse_comp_config "$comp"
    echo ""
    echo "============================================================"
    echo "=== Configuration: $comp"
    echo "===   algo=$comp_algo r=$reclaim_batchsize p=$page_cluster l=${cfg_zram_mem_limit:-auto} s=${cfg_zram_disk_size:-auto}"
    echo "============================================================"

    [[ "$comp_algo" == deflate-iaa* ]] && iaa_attempted=true

    # Baseline (_l0_s0): no compressed swap. Run against a pure physical-RAM
    # ceiling so overflow past --init-limit OOM-kills VMs (fewer VMs fit)
    # instead of being absorbed by zswap/zram.
    IS_BASELINE=false
    if [[ "$cfg_zram_mem_limit" == "0" && "$cfg_zram_disk_size" == "0" ]]; then
        IS_BASELINE=true
    fi

    if [[ "$IS_BASELINE" == true ]]; then
        echo "=== Baseline config: compressed swap disabled (pure ${INIT_LIMIT}GB RAM ceiling; OOM on overflow) ==="
        # Tear down any active zram/zswap swap device so the host has no swap
        # space at all; the per-scenario cgroup also pins memory.swap.max=0.
        "${THIS_DIR}/../scripts/reset_zram_zswap.sh" || true
        # Fixed server-cgroup memory ceiling.
        compute_memory_limit
    else
        configure_swap_for_compressor "$comp" || continue

        # Fixed server-cgroup memory ceiling.
        compute_memory_limit

        if ! verify_compressor_active "$SWAP_MODE" "$comp_algo"; then
            continue
        fi
        [[ "$comp_algo" == deflate-iaa* ]] && ran_iaa_algos+="$comp_algo "
    fi

    LOGDIR_COMP="${LOGDIR}/${comp}"
    rm -rf "$LOGDIR_COMP"; mkdir -p "$LOGDIR_COMP"

    # Sweep the server-VM count under the fixed memory ceiling. Abort early once
    # per-instance throughput falls REGRESSION_THRESHOLD% below the first (lowest-
    # VM) point — adding more VMs past that only degrades this compressor further.
    baseline_tput=""
    for vms in "${VM_POINTS[@]}"; do
        SERVER_VMS="$vms"; CLIENT_VMS="$vms"
        compute_cpu_plan
        echo "=== Running ${vms} server VMs (limit ${eff_limit}GB / ${limit} bytes) ==="
        restore_vm_overlays
        run_vm_scenario "vms-${vms}" "$limit" "$LOGDIR_COMP" || true

        # Per-instance throughput of this sweep point (0 if the point was invalid).
        cur_tput=$(grep -oP 'throughput:\K[0-9.]+' "${LOGDIR_COMP}/vms-${vms}.log" 2>/dev/null | head -1)
        cur_tput="${cur_tput:-0}"
        if [[ -z "$baseline_tput" ]]; then
            # First valid point (> 0) becomes the regression reference.
            if awk -v b="$cur_tput" 'BEGIN{exit !(b+0>0)}'; then
                baseline_tput="$cur_tput"
                echo "  Baseline per-instance throughput (vms-${vms}): ${baseline_tput} ops/sec"
            fi
        elif awk -v b="$baseline_tput" -v c="$cur_tput" -v thr="$REGRESSION_THRESHOLD" \
                'BEGIN{exit !((b-c)/b*100 >= thr)}'; then
            drop_pct=$(awk -v b="$baseline_tput" -v c="$cur_tput" 'BEGIN{printf "%.2f", (b-c)/b*100}')
            echo "Throughput dropped by ${drop_pct}% (>=${REGRESSION_THRESHOLD}%) at vms-${vms}; preserving this point and aborting sweep for '$comp'"
            break
        fi
    done

    # Validate that the first sweep point produced valid results.
    first_log="${LOGDIR_COMP}/vms-${VM_MIN}.log"
    if [[ ! -f "$first_log" ]] || ! grep -q "actual_vms:[[:space:]]*[1-9]" "$first_log"; then
        echo "WARNING: first sweep point (${VM_MIN} VMs) failed — skipping compressor ${comp}" >&2
        continue
    fi

    # Generate per-compressor report (reporter uses the smallest count as baseline).
    if ls "${LOGDIR_COMP}"/vms-*.log 1>/dev/null 2>&1; then
        cat "${LOGDIR_COMP}"/vms-*.log \
            | python "${THIS_DIR}/vm_sweep_reporter.py" --accept-kpi "${ACCEPT_KPI}" \
            > "${LOGDIR_COMP}/${comp}.report"
        cat "${LOGDIR_COMP}/${comp}.report"
        report_string+="${LOGDIR_COMP}/${comp}.report "
    else
        echo "WARNING: no sweep logs produced for ${comp} — skipping report"
    fi
done

# ─── Final cleanup ───────────────────────────────────────────────────
stop_all_vms
echo 1 | sudo tee "$CG/cgroup.kill" >/dev/null 2>/dev/null || true
sleep 2
sudo rmdir "$CG" 2>/dev/null || true

# ─── Aggregate HTML report ───────────────────────────────────────────
report_string="${report_string% }"
if [[ -n "$report_string" ]]; then
    echo "Generating HTML report..."
    python "${THIS_DIR}/vm_sweep_reporter.py" --plot ${report_string} \
        --accept-kpi "${ACCEPT_KPI}" --output-dir "${LOGDIR}" \
        || echo "WARNING: plot generation failed"
fi

echo ""
echo "========================================="
echo " VM sweep complete. Results in ${LOGDIR}"
echo "========================================="

# Summarize deflate-iaa availability for this OS/kernel.
print_iaa_support_summary "$ran_iaa_algos" "$iaa_attempted"
