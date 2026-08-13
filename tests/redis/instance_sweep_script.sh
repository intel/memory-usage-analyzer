#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# Instance Sweep Script
# Sweeps the number of Redis server instances for a given compressor configuration
# and memory limit, producing .report files suitable for instance_sweep_reporter.py.

set -euo pipefail

LOGDIR="./logdir_instance_sweep"
REDIS_CONFIGS="./redis_configs"
THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REDIS_PORT_BASE=9001

# Defaults
compressor="all"
reps=4000
combined_lines=3
db_file=""
redis_server_cpus_per_instance=1
memtier_cpus_per_instance=1
client_socket_policy="auto"
server_overflow_policy="siblings-first"
swap_mode="zram"

init_limit=64

instance_min=40
instance_max=65
instance_step=5

accept_kpi=95
oom_kill_checks=1
phase_timeout=1800
core_frequency="3500"
zram_mem_limit=""
zram_disk_size=""

print_usage() {
    cat <<'EOF_HELP'
Usage: instance_sweep_script.sh [options]

Named options:
  --compressor, -c <name>             Compressor name or 'all'
  --reps, -r <num>                    Dataset repetitions for generation (default: 4000)
  --combined-lines <num>              Lines combined per entry for generation (default: 3)
  --db-file, -d <path>                Input DB file (.csv or .redis). Overrides
                                      the auto-generated dataset from --reps/--combined-lines
  --server-cpus <num>                 Cores per redis server instance
  --client-cpus <num>                 Cores per memtier client instance
  --client-socket-policy <auto|same>  Client socket policy
  --swap-mode, -m <zswap|zram>        Swap mode (default: zram)
  --instance-min <num>                Min number of instances (default: 45)
  --instance-max <num>                Max number of instances (default: 60)
  --instance-step <num>               Step size for instance sweep (default: 15)
  --accept-kpi <num>                  Acceptable KPI threshold % (default: 95)
  --oom-kill-checks <num>             Cumulative new OOM kills before abort (default: 6)
                                      Checked every 30s; aborts if total new
                                      OOM kills since phase start >= threshold
  --phase-timeout <sec>               Max seconds per phase before kill (default: 1800)
                                      Also checks server liveness every 30s;
                                      aborts immediately if zero servers respond
  --frequency, -f <MHz>               Core frequency in MHz
  --init-limit <GB>                   Total physical memory budget in GB (default: 64)
                                      Split: cgroup = init-limit - zram-limit(l),
                                      zram = zram-limit(l). E.g. with l=12:
                                      cgroup=52GB, zram=12GB, total=64GB
  --zram-limit <GB>                   Zram physical memory limit in GB (CLI override
                                      for the 'l' value in config name). Subtracted
                                      from init-limit to set cgroup memory.max.
                                      E.g. --init-limit 64 --zram-limit 12:
                                      cgroup=52GB, zram=12GB
  --zram-disksize <GB>                Zram virtual disk size in GB (CLI override
                                      for the 's' value in config name). Controls
                                      how much swap space zram advertises.
                                      E.g. --zram-disksize 64: zram offers 64GB
                                      of swap (compressed to fit in zram-limit)
  --logdir, -l <path>                 Output log directory
  --help, -h                          Show this help
EOF_HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --compressor|-c)         compressor="$2";                    shift 2 ;;
        --reps|-r)               reps="$2";                          shift 2 ;;
        --combined-lines)        combined_lines="$2";                shift 2 ;;
        --db-file|-d)            db_file="$2";                       shift 2 ;;
        --server-cpus)           redis_server_cpus_per_instance="$2"; shift 2 ;;
        --client-cpus)           memtier_cpus_per_instance="$2";     shift 2 ;;
        --client-socket-policy)  client_socket_policy="$2";          shift 2 ;;
        --swap-mode|-m)          swap_mode="$2";                     shift 2 ;;
        --init-limit)            init_limit="$2";                    shift 2 ;;
        --instance-min)          instance_min="$2";                  shift 2 ;;
        --instance-max)          instance_max="$2";                  shift 2 ;;
        --instance-step)         instance_step="$2";                 shift 2 ;;
        --accept-kpi)            accept_kpi="$2";                    shift 2 ;;
        --oom-kill-checks)        oom_kill_checks="$2";                shift 2 ;;
        --phase-timeout)         phase_timeout="$2";                  shift 2 ;;
        --frequency|-f)          core_frequency="$2";                shift 2 ;;
        --zram-limit)            zram_mem_limit="$2";                shift 2 ;;
        --zram-disksize)         zram_disk_size="$2";                shift 2 ;;
        --logdir|-l)             LOGDIR="$2";                        shift 2 ;;
        --help|-h)               print_usage; exit 0 ;;
        *)  echo "ERROR: unknown option: $1"; print_usage; exit 1 ;;
    esac
done

if [[ "$swap_mode" != "zswap" && "$swap_mode" != "zram" ]]; then
    echo "ERROR: invalid swap mode '$swap_mode'. Must be 'zswap' or 'zram'."
    print_usage
    exit 1
fi

# Derive the dataset filename from reps/combined_lines and generate it if missing.
# An explicit --db-file overrides both the name and the generation step.
if [[ -z "$db_file" ]]; then
    db_file="import_movies_${reps}r_${combined_lines}c.csv"
    if [[ ! -f "$db_file" ]]; then
        echo "=== Generating dataset ${db_file} (reps=${reps}, combined_lines=${combined_lines}) ==="
        python repeat_redis_file.py -r "${reps}" -c "${combined_lines}"
    fi
fi

# Clear all previous results
rm -rf "${LOGDIR}"
rm -rf "${REDIS_CONFIGS}"
rm -f *.log
pkill -f zswap_log.sh 2>/dev/null || true
pkill -f zram_log.sh 2>/dev/null || true
rm -f *.html

mkdir -p "${LOGDIR}"
mkdir -p "${REDIS_CONFIGS}"

# Reserve the 2 CPUs for system level activites
redis_server_cpu_start=0

# Read initial cgroup CPU stats
read_vals_before() {
    read u1 usr1 sys1 < <(awk '
    /usage_usec/  {u=$2}
    /user_usec/   {usr=$2}
    /system_usec/ {sys=$2}
    END {print u, usr, sys}
    ' "$cg/cpu.stat")
    # System-wide CPU jiffies (htop-style). The aggregate "cpu" line in
    # /proc/stat already sums all logical CPUs; busy = total - idle - iowait.
    read sys_busy1 sys_total1 < <(awk '/^cpu /{
        idle=$5+$6;                                  # idle + iowait
        total=$2+$3+$4+$5+$6+$7+$8+$9;               # user..steal
        print total-idle, total}' /proc/stat)
    t1=$(date +%s%N)
}
# Read final cgroup CPU stats and populate result variables
read_vals_after() {

    t2=$(date +%s%N)
    read u2 usr2 sys2 < <(awk '
    /usage_usec/  {u=$2}
    /user_usec/   {usr=$2}
    /system_usec/ {sys=$2}
    END {print u, usr, sys}
    ' "$cg/cpu.stat")

    read sys_busy2 sys_total2 < <(awk '/^cpu /{
        idle=$5+$6;
        total=$2+$3+$4+$5+$6+$7+$8+$9;
        print total-idle, total}' /proc/stat)


    du=$((u2 - u1))
    dusr=$((usr2 - usr1))
    dsys=$((sys2 - sys1))
    dt=$(((t2 - t1) / 1000))   # nanoseconds -> microseconds

    CPU_PCT=$(awk -v c="$du"   -v t="$dt" 'BEGIN {printf "%.2f", (t>0 ? (c/t)*100 : 0)}')
    USER_PCT=$(awk -v c="$dusr" -v t="$dt" 'BEGIN {printf "%.2f", (t>0 ? (c/t)*100 : 0)}')
    SYS_PCT=$(awk -v c="$dsys" -v t="$dt" 'BEGIN {printf "%.2f", (t>0 ? (c/t)*100 : 0)}')

    # System-wide total CPU utilization normalized to 100% (like htop's header
    # gauge): busy jiffies / total jiffies across all cores over the interval.
    SYS_TOTAL_PCT=$(awk -v b1="$sys_busy1" -v t1="$sys_total1" -v b2="$sys_busy2" -v t2="$sys_total2" \
        'BEGIN {dt=t2-t1; printf "%.2f", (dt>0 ? ((b2-b1)/dt)*100 : 0)}')
}

# Wait for Redis servers to become ready, with retries.
# Writes the count of alive servers to the variable named in $2.
# Bails out early after 3 consecutive unresponsive ports (servers start
# sequentially, so if server N failed, N+1..max likely did too).
wait_and_count_servers() {
    local no_of_servers="$1" result_var="$2" label="${3:-}" max="${4:-30}"
    local alive=0 port_no=$REDIS_PORT_BASE consecutive_fail=0
    for (( i=1; i<=no_of_servers; i++ )); do
        local attempt=0 got_pong=0
        while (( attempt++ < max )); do
            if redis-cli -h 127.0.0.1 -p "$port_no" PING 2>/dev/null | grep -q PONG; then
                alive=$(( alive + 1 ))
                got_pong=1
                consecutive_fail=0
                break
            fi
            sleep 2
        done
        if (( got_pong == 0 )); then
            echo "WARNING: Redis instance $i (port $port_no) not responding${label:+ $label}"
            consecutive_fail=$(( consecutive_fail + 1 ))
            if (( consecutive_fail >= 3 && i < no_of_servers )); then
                echo "WARNING: ${consecutive_fail} consecutive ports dead — skipping remaining $(( no_of_servers - i )) servers"
                break
            fi
        fi
        port_no=$(( port_no + 1 ))
    done
    printf -v "$result_var" '%d' "$alive"
}

# Monitor a background process for OOM kills, server liveness, and phase timeout.
# Checks every 30 seconds for:
#   1) OOM kills >= threshold       → kill immediately
#   2) Zero Redis servers responding → kill immediately
#   3) Wall-clock >= phase_timeout   → kill as last resort
# Usage: oom_monitor_wait <pid> <no_of_servers> <result_var>
oom_monitor_wait() {
    local target_pid="$1" no_of_servers="$2" result_var="$3"
    local cg="/sys/fs/cgroup/redisbench"
    (
        local initial_oom_count start_time
        initial_oom_count=$(awk '/^oom_kill / {print $2}' "$cg/memory.events" 2>/dev/null || echo 0)
        start_time=$(date +%s)
        echo "INFO: OOM monitor started — kill if ${oom_kill_checks}+ OOM kills, 0 servers alive, or ${phase_timeout}s timeout (${no_of_servers} instances)"

        while kill -0 "$target_pid" 2>/dev/null; do
            sleep 60

            # Check 1: OOM kills
            local current_oom_count
            current_oom_count=$(awk '/^oom_kill / {print $2}' "$cg/memory.events" 2>/dev/null || echo 0)
            local new_kills=$(( current_oom_count - initial_oom_count ))
            if (( new_kills >= oom_kill_checks )); then
                echo "WARNING: ${new_kills} new OOM kills detected (threshold=${oom_kill_checks}) — killing process $target_pid"
                kill "$target_pid" 2>/dev/null || true
                break
            elif (( new_kills > 0 )); then
                echo "INFO: ${new_kills} new OOM kills so far (threshold=${oom_kill_checks}) — continuing"
            fi

            # Check 2: Server liveness — PING a sample of ports
            local alive=0 port_no=$REDIS_PORT_BASE
            for (( p=0; p<no_of_servers; p++ )); do
                if redis-cli -h 127.0.0.1 -p "$port_no" PING 2>/dev/null | grep -q PONG; then
                    alive=$(( alive + 1 ))
                    break  # at least one alive, no need to check all
                fi
                port_no=$(( port_no + 1 ))
            done
            if (( alive == 0 )); then
                echo "WARNING: zero Redis servers responding — killing process $target_pid"
                kill "$target_pid" 2>/dev/null || true
                break
            fi

            # Check 3: Wall-clock timeout
            local elapsed=$(( $(date +%s) - start_time ))
            if (( elapsed >= phase_timeout )); then
                echo "WARNING: phase timeout ${phase_timeout}s exceeded (${elapsed}s elapsed) — killing process $target_pid"
                kill "$target_pid" 2>/dev/null || true
                break
            fi
        done
    ) &
    local monitor_pid=$!
    local rc=0
    wait "$target_pid" || rc=$?
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    printf -v "$result_var" '%d' "$rc"
}

# Stop the background swap stats logger (zram or zswap).
stop_swap_logger() {
    if [[ "$swap_mode" == "zram" ]]; then
        pkill -f zram_log.sh 2>/dev/null || true
    else
        pkill -f zswap_log.sh 2>/dev/null || true
    fi
}

# Kill all redis servers and clean up the cgroup.
cleanup_scenario() {
    stop_swap_logger
    pkill -f redis-server 2>/dev/null || true
    echo 1 | sudo tee /sys/fs/cgroup/redisbench/cgroup.kill >/dev/null 2>/dev/null || true
    sleep 1
}

# Parse a compressor config string into its components.
# Sets: comp_algo, reclaim_batchsize, page_cluster, cfg_zram_mem_limit, cfg_zram_disk_size
# Extended naming convention: <algo>_r<reclaim-batchsize>_p<page-cluster>[_l<mem-limit-GB>_s<disk-size-GB>]
parse_comp_config() {
    local comp="$1"
    comp_algo="$comp"
    reclaim_batchsize=1
    page_cluster=3
    cfg_zram_mem_limit=""
    cfg_zram_disk_size=""

    # Match: algo_r<N>_p<N>_l<N>_s<N>
    if [[ "$comp" =~ ^(.+)_r([0-9]+)_p([0-9]+)_l([0-9]+)_s([0-9]+)$ ]]; then
        comp_algo="${BASH_REMATCH[1]}"
        reclaim_batchsize="${BASH_REMATCH[2]}"
        page_cluster="${BASH_REMATCH[3]}"
        cfg_zram_mem_limit="${BASH_REMATCH[4]}"
        cfg_zram_disk_size="${BASH_REMATCH[5]}"
    # Match: algo_r<N>_p<N>
    elif [[ "$comp" =~ ^(.+)_r([0-9]+)_p([0-9]+)$ ]]; then
        comp_algo="${BASH_REMATCH[1]}"
        reclaim_batchsize="${BASH_REMATCH[2]}"
        page_cluster="${BASH_REMATCH[3]}"
    fi

    # Command-line overrides take precedence over per-config values
    [[ -n "$zram_mem_limit" ]] && cfg_zram_mem_limit="$zram_mem_limit"
    [[ -n "$zram_disk_size" ]] && cfg_zram_disk_size="$zram_disk_size"
    return 0
}

# Compute the effective cgroup memory limit (bytes) for a compressor config.
# Sets: limit (bytes), eff_limit (GB)
compute_memory_limit() {
    if [[ "${cfg_zram_disk_size:-0}" == "0" && "${cfg_zram_mem_limit:-0}" == "0" ]]; then
        eff_limit="${init_limit}"
        echo "=== Memory limit: ${eff_limit} GB (baseline, no zram) ==="
    else
        local zram_reserved="${cfg_zram_mem_limit:-0}"
        eff_limit=$(( init_limit - zram_reserved ))
        if (( eff_limit <= 0 )); then
            echo "ERROR: init_limit (${init_limit}GB) must be > zram_mem_limit (${zram_reserved}GB)" >&2
            exit 1
        fi
        echo "=== Memory limit: ${eff_limit}GB cgroup + ${zram_reserved}GB zram = ${init_limit}GB total ==="
    fi
    limit=$(( eff_limit * 1024 * 1024 * 1024 ))
}


run_instance_scenario() {
    local no_of_servers="$1"
    local limit="$2"
    local logdir="$3"
    local scenario="${4:-instances-${no_of_servers}}"
    local cg="/sys/fs/cgroup/redisbench"
    local server_numa_node server_core_list client_core_list mb_cpu_start cpu_plan

    # start with a clean cgroup
    echo 1 | sudo tee "$cg/cgroup.kill" >/dev/null 2>/dev/null || true
    sudo rmdir "$cg" 2>/dev/null || true
    sudo mkdir -p "$cg"

    # Set memory limit before starting workload (matches memcomp-squeeze.py --init-limit)
    echo "$limit" | sudo tee "$cg/memory.max" >/dev/null

    mkdir -p "${logdir}/${scenario}"
    # Monitor compressed swap stats (zswap or zram) — only if swap is configured
    local swap_csv="${logdir}/${scenario}/zswap_run.csv"
    local swap_active=true
    if [[ "$swap_mode" == "zram" && ! -f /sys/block/zram0/mm_stat ]]; then
        swap_active=false
        echo "INFO: No zram device — skipping swap logger for ${scenario}"
    elif [[ "$swap_mode" == "zram" ]]; then
        ./zram_log.sh 1 "$swap_csv" &
    else
        ./zswap_log.sh 1 "$swap_csv" &
    fi

    # Start workload and move it into cgroup ASAP
    cpu_plan=$("${THIS_DIR}/../scripts/get_redis_cpu_plan.sh" "${no_of_servers}" "${redis_server_cpus_per_instance}" "${memtier_cpus_per_instance}" "${redis_server_cpu_start}" "" "${client_socket_policy}" "${scenario}" "${server_overflow_policy}")
    server_numa_node=$(echo "$cpu_plan" | sed -n 's/.*node=\([^ ]*\).*/\1/p')
    server_core_list=$(echo "$cpu_plan" | sed -n 's/.*server_cores=\([^ ]*\).*/\1/p')
    client_core_list=$(echo "$cpu_plan" | sed -n 's/.*client_cores=\([^ ]*\).*/\1/p')
    mb_cpu_start=$(echo "$cpu_plan" | sed -n 's/.*mb_cpu_start=\([^ ]*\).*/\1/p')
    if [[ -z "$server_core_list" || -z "$client_core_list" || ! "$mb_cpu_start" =~ ^[0-9]+$ ]]; then
        echo "ERROR: invalid CPU plan output: ${cpu_plan}"
        return 1
    fi

    ./redis_server_start.sh ${no_of_servers} "list:${server_core_list}" ${server_numa_node} ${redis_server_cpus_per_instance} &
    local pid=$!
    echo "$pid" | sudo tee "$cg/cgroup.procs" >/dev/null

    # Wait for all servers to respond (with retries — servers start sequentially)
    echo "=== Waiting for ${no_of_servers} Redis servers to become ready ==="
    local ready_count
    wait_and_count_servers "${no_of_servers}" ready_count "(startup)"
    if [[ "$ready_count" -eq 0 ]]; then
        echo "WARNING: No Redis servers started — skipping scenario ${scenario}"
        cleanup_scenario
        return 1
    fi
    if [[ "$ready_count" -lt "$no_of_servers" ]]; then
        echo "WARNING: Only ${ready_count}/${no_of_servers} servers started"
    fi

    # Prefill — run in background with OOM monitoring
    read_vals_before
    local mb_prefill_rc=0
    ./mb_start.sh ${no_of_servers} ${db_file} ${mb_cpu_start} "${logdir}/${scenario}" prefill ${memtier_cpus_per_instance} "${client_core_list}" &
    local mb_prefill_pid=$!
    oom_monitor_wait "$mb_prefill_pid" "${no_of_servers}" mb_prefill_rc
    read_vals_after
    prefill_cpu_pct=$CPU_PCT;prefill_user_pct=$USER_PCT;prefill_sys_pct=$SYS_PCT;prefill_sys_total_pct=$SYS_TOTAL_PCT

    if [[ "$mb_prefill_rc" -ne 0 ]]; then
        echo "WARNING: prefill failed (rc=${mb_prefill_rc}) for scenario ${scenario} — skipping run phase"
        run_cpu_pct="0.00"; run_user_pct="0.00"; run_sys_pct="0.00"; run_sys_total_pct="0.00"
    else
        # Run (under memory pressure — swap/compression active)
        read_vals_before
        local mb_run_rc=0
        ./mb_start.sh ${no_of_servers} ${db_file} ${mb_cpu_start} "${logdir}/${scenario}" run ${memtier_cpus_per_instance} "${client_core_list}" &
        local mb_pid=$!
        oom_monitor_wait "$mb_pid" "${no_of_servers}" mb_run_rc
        read_vals_after
        run_cpu_pct=$CPU_PCT;run_user_pct=$USER_PCT;run_sys_pct=$SYS_PCT;run_sys_total_pct=$SYS_TOTAL_PCT

        if [[ "$mb_run_rc" -ne 0 ]]; then
            echo "WARNING: mb_start.sh run failed (rc=${mb_run_rc})"
        fi
    fi

    # Collect cgroup metrics
    local throughput p99
    memory_peak=$(cat "$cg/memory.peak" 2>/dev/null || echo 0)
    memory_max=$(cat "$cg/memory.max" 2>/dev/null || echo 0)
    memory_swap_peak=$(cat "$cg/memory.swap.peak" 2>/dev/null || echo 0)

    # Stop swap monitor and wait for final CSV flush
    if [[ "$swap_active" == true ]]; then
        stop_swap_logger
        sleep 0.5
    fi

    # Parse swap report once (avoid calling zswap_report.sh twice)
    local swap_report
    if [[ "$swap_active" == true && -f "$swap_csv" ]]; then
        swap_report=$(./zswap_report.sh "$swap_csv") || true
        zswap_pool_size=$(echo "$swap_report" | awk '/Pool size:/{ print $3}')
        comp_ratio=$(echo "$swap_report" | awk '/Compression ratio:/{ print $3}')
    else
        zswap_pool_size=0
        comp_ratio=0
    fi

    local throughput_sum=0 throughput_avg=0 throughput_agg=0 p99_max=0 actual_instances=0
    for (( i=1; i<=no_of_servers; i++ )); do
        local run_log="${logdir}/${scenario}/run_${i}.log"

        if [[ ! -f "$run_log" ]]; then
            echo "WARNING: missing ${run_log} (instance $i skipped)"
            continue
        fi

        throughput=$(awk '/^Totals/ {print $2; exit}' "$run_log")
        if [[ -z "$throughput" || ! "$throughput" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            echo "WARNING: invalid Totals throughput in ${run_log} (instance $i skipped)"
            continue
        fi

        actual_instances=$(( actual_instances + 1 ))
        throughput_sum=$(echo "$throughput_sum + $throughput" | bc)

        p99=$(awk '/^Totals/ {print $7; exit}' "$run_log")
        if [[ -n "$p99" && "$p99" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            if (( $(echo "$p99 > $p99_max" | bc -l) )); then
                p99_max=$p99
            fi
        else
            echo "WARNING: invalid Totals p99 in ${run_log}"
        fi
    done
    if (( actual_instances > 0 )); then
        throughput_agg=$(echo "scale=2; $throughput_sum / 1" | bc)
        throughput_avg=$(echo "scale=2; $throughput_sum / $actual_instances" | bc)
    fi

    echo "scenario:$scenario, swap_mode:$swap_mode, memory_max:$memory_max, memory_peak:$memory_peak, zswap_pool_size:$zswap_pool_size, comp_ratio:$comp_ratio, memory_swap_peak:$memory_swap_peak, throughput:$throughput_avg, throughput_agg:$throughput_agg, p99:$p99_max, configured_instances:$no_of_servers, actual_instances:$actual_instances, prefill_cpu_pct:$prefill_cpu_pct, prefill_user_pct:$prefill_user_pct, prefill_sys_pct:$prefill_sys_pct, prefill_sys_total_pct:$prefill_sys_total_pct, run_cpu_pct:$run_cpu_pct, run_user_pct:$run_user_pct, run_sys_pct:$run_sys_pct, run_sys_total_pct:$run_sys_total_pct" | tee "${logdir}/${scenario}.log"

    # Cleanup
    pkill -f redis-server 2>/dev/null || true
    echo 1 | sudo tee "$cg/cgroup.kill" >/dev/null 2>/dev/null || true
    sleep 1
}

# Build compressor list
# Extended naming convention: <algo>_r<reclaim-batchsize>_p<page-cluster>[_l<mem-limit-GB>_s<disk-size-GB>]
# The first entry in 'all' is the baseline config (runs with unlimited memory).
if [[ "$compressor" == "all" ]]; then
    if [[ -f /proc/sys/vm/reclaim-batchsize ]]; then
        compressor_list=(
            "deflate-iaa_r64_p5_l0_s0"
            #"deflate-iaa_r64_p5_l12_s64"
            #"deflate-iaa-dynamic_r32_p3_l12_s64"
            "deflate-iaa-dynamic_r64_p5_l12_s64"
            #"zstd_r1_p3_l12_s64"
            "lz4_r1_p3_l12_s64"
        )
    else
        compressor_list=("lzo_r1_p3" "deflate-iaa_r1_p3")
    fi
else
    compressor_list=( "$compressor" )
fi

#echo "${compressor_list[@]}"
report_string=""

for comp in "${compressor_list[@]}"; do
    parse_comp_config "$comp"

    echo ""
    echo "============================================================"
    echo "=== Configuration: $comp"
    echo "===   algo=$comp_algo  r=$reclaim_batchsize  p=$page_cluster  l=${cfg_zram_mem_limit:-auto}  s=${cfg_zram_disk_size:-auto}"
    echo "============================================================"

    if [[ "$swap_mode" == "zram" ]]; then
        swap_args=(-c "$comp_algo" -r "$reclaim_batchsize" -p "$page_cluster")
        [[ -n "$core_frequency" ]] && swap_args+=(-f "$core_frequency")
        [[ -n "$cfg_zram_mem_limit" ]] && swap_args+=(-l "$cfg_zram_mem_limit")
        [[ -n "$cfg_zram_disk_size" ]] && swap_args+=(-s "$cfg_zram_disk_size")
        "${THIS_DIR}/../scripts/config_sys_zram.sh" "${swap_args[@]}"
    else
        "${THIS_DIR}/../scripts/config_sys_zswap.sh" \
            -c "$comp_algo" \
            -r "$reclaim_batchsize" \
            -p "$page_cluster" \
            ${core_frequency:+-f "$core_frequency"}
    fi

    LOGDIR_COMP="${LOGDIR}/${comp}"
    mkdir -p "${LOGDIR_COMP}"

    # Compute cgroup memory limit for this compressor config
    # Baseline (_l0_s0): limit = init_limit (64 GB) — full system memory
    # Zram    (_l12_s64): limit = init_limit - zram_mem_limit (64 - 12 = 52 GB)
    compute_memory_limit

    # Sweep instance counts under the cgroup memory limit
    for (( instances=instance_min; instances<=instance_max; instances+=instance_step )); do
        echo "=== Running ${instances} instances, limit ${eff_limit}GB (${limit} bytes) ==="
        run_instance_scenario "${instances}" "${limit}" "${LOGDIR_COMP}" || true
    done

    # Validate that the first sweep point produced valid results
    first_log="${LOGDIR_COMP}/instances-${instance_min}.log"
    if [[ ! -f "$first_log" ]] || ! grep -q "actual_instances:[[:space:]]*[1-9]" "$first_log"; then
        echo "WARNING: first sweep point (${instance_min} instances) failed — skipping compressor ${comp}" >&2
        continue
    fi

    # Generate report — reporter uses the first row (instance_min) as baseline
    if ls "${LOGDIR_COMP}"/instances-*.log 1>/dev/null 2>&1; then
        cat "${LOGDIR_COMP}"/instances-*.log \
            | python instance_sweep_reporter.py --accept-kpi "${accept_kpi}" \
            > "${LOGDIR_COMP}/${comp}.report"
        cat "${LOGDIR_COMP}/${comp}.report"
        report_string+="${LOGDIR_COMP}/${comp}.report "
    else
        echo "WARNING: no sweep logs produced for ${comp} — skipping report"
    fi
done

report_string="${report_string% }"
if [[ -n "$report_string" ]]; then
    python instance_sweep_reporter.py --plot ${report_string} --accept-kpi "${accept_kpi}" --output-dir "${LOGDIR}"
fi

echo "=== Instance sweep complete. Results in ${LOGDIR} ==="
