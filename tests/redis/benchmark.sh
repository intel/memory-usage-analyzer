#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
LOGDIR="./logdir"
REDIS_CONFIGS="./redis_configs"
THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"


# Defaults
no_of_servers=1
compressor="deflate-iaa_r1_p3"
db_file=""
reps=10000
combined_lines=10
redis_server_cpus_per_instance=1
memtier_cpus_per_instance=1
client_socket_policy="auto"
server_overflow_policy="siblings-first"
core_policy="spread-nodes"
swap_mode="zswap"

print_usage() {
    cat <<'EOF_HELP'
Usage:
    benchmark.sh [no_of_servers] [compressor] [db_file] [server_cpus_per_instance] [client_cpus_per_instance] [client_socket_policy] [logdir]

Named options:
  --servers, -n <num>                 Number of redis servers
  --compressor, -c <name>             Compressor name or 'all'
  --reps, -r <num>                    Dataset repetitions for generation (default: 10000)
  --combined-lines <num>              Lines combined per entry for generation (default: 10)
  --db-file, -d <path>                Input DB file (.csv or .redis). Overrides
                                      the auto-generated dataset from --reps/--combined-lines
  --server-cpus <num>                 Cores per redis server instance
  --client-cpus <num>                 Cores per memtier client instance
  --client-socket-policy <auto|same>  Client socket policy
  --core-policy <siblings-first|spread-nodes>
                                      Core selection policy (default: spread-nodes)
                                        siblings-first:  primary+sibling cores of each NUMA node before next node
                                        spread-nodes:    primary cores across all NUMA nodes first, then siblings
  --swap-mode, -m <zswap|zram>        Swap mode (default: zswap)
  --logdir, -l <path>                 Output log directory
  --help, -h                          Show this help
EOF_HELP
}

positional_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --servers|-n)
            no_of_servers="$2"; shift 2 ;;
        --compressor|-c)
            compressor="$2"; shift 2 ;;
        --reps|-r)
            reps="$2"; shift 2 ;;
        --combined-lines)
            combined_lines="$2"; shift 2 ;;
        --db-file|-d)
            db_file="$2"; shift 2 ;;
        --server-cpus)
            redis_server_cpus_per_instance="$2"; shift 2 ;;
        --client-cpus)
            memtier_cpus_per_instance="$2"; shift 2 ;;
        --client-socket-policy)
            client_socket_policy="$2"; shift 2 ;;
        --overflow-policy)
            echo "INFO: --overflow-policy is ignored; use --core-policy instead"
            shift 2 ;;
        --core-policy)
            core_policy="$2"; shift 2 ;;
        --swap-mode|-m)
            swap_mode="$2"; shift 2 ;;
        --logdir|-l)
            LOGDIR="$2"; shift 2 ;;
        --help|-h)
            print_usage; exit 0 ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                positional_args+=("$1")
                shift
            done
            ;;
        -*)
            echo "ERROR: unknown option: $1"
            print_usage
            exit 1 ;;
        *)
            positional_args+=("$1")
            shift ;;
    esac
done

# Backward-compatible positional argument mapping
if [[ ${#positional_args[@]} -ge 1 ]]; then no_of_servers="${positional_args[0]}"; fi
if [[ ${#positional_args[@]} -ge 2 ]]; then compressor="${positional_args[1]}"; fi
if [[ ${#positional_args[@]} -ge 3 ]]; then db_file="${positional_args[2]}"; fi
if [[ ${#positional_args[@]} -ge 4 ]]; then redis_server_cpus_per_instance="${positional_args[3]}"; fi
if [[ ${#positional_args[@]} -ge 5 ]]; then memtier_cpus_per_instance="${positional_args[4]}"; fi
if [[ ${#positional_args[@]} -ge 6 ]]; then client_socket_policy="${positional_args[5]}"; fi
if [[ ${#positional_args[@]} -ge 7 ]]; then LOGDIR="${positional_args[6]}"; fi

if [[ "$swap_mode" != "zswap" && "$swap_mode" != "zram" ]]; then
    echo "ERROR: invalid swap mode '$swap_mode'. Must be 'zswap' or 'zram'."
    print_usage
    exit 1
fi

if [[ "$core_policy" != "siblings-first" && "$core_policy" != "spread-nodes" ]]; then
    echo "ERROR: invalid core policy '$core_policy'. Must be 'siblings-first' or 'spread-nodes'."
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
rm -rf ${LOGDIR}
rm -rf ${REDIS_CONFIGS}
rm -f *.log
rm -rf *.report
pkill -f zswap_log.sh
pkill -f zram_log.sh 2>/dev/null || true
rm -rf *.html

mkdir  ${LOGDIR}
mkdir  ${REDIS_CONFIGS}

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


    USAGE_SEC=$(( du /1000 ))
    USER_SEC=$(( dusr / 1000 ))
    SYS_SEC=$(( dsys / 1000 ))
    ELAPSED_SEC=$(( dt / 1000 ))
    
}


run_scenario() {
    local scenario="$1"
    local limit="$2"
    local logdir="$3"
    local cg="/sys/fs/cgroup/redisbench"
    local server_numa_node server_core_list client_core_list mb_cpu_start cpu_plan

    # start with a clean cgroup
    echo 1 | sudo tee "$cg/cgroup.kill" >/dev/null 2>/dev/null || true
    sudo rmdir "$cg" 2>/dev/null || true
    sudo mkdir -p "$cg"

    # Set memory limit before starting workload
    echo "$limit" | sudo tee "$cg/memory.max" >/dev/null

    mkdir -p "${logdir}/${scenario}"
    # Monitor compressed swap stats (zswap or zram)
    local swap_csv="${logdir}/${scenario}/zswap_run.csv"
    if [[ "$swap_mode" == "zram" ]]; then
        ./zram_log.sh 1 "$swap_csv" &
    else
        ./zswap_log.sh 1 "$swap_csv" &
    fi

    # Start workload and move it into cgroup ASAP
    cpu_plan=$("${THIS_DIR}/../scripts/get_redis_cpu_plan.sh" "${no_of_servers}" "${redis_server_cpus_per_instance}" "${memtier_cpus_per_instance}" "${redis_server_cpu_start}" "" "${client_socket_policy}" "${scenario}" "${server_overflow_policy}" "${core_policy}")
    server_numa_node=$(echo "$cpu_plan" | sed -n 's/.*node=\([^ ]*\).*/\1/p')
    server_core_list=$(echo "$cpu_plan" | sed -n 's/.*server_cores=\([^ ]*\).*/\1/p')
    client_core_list=$(echo "$cpu_plan" | sed -n 's/.*client_cores=\([^ ]*\).*/\1/p')
    mb_cpu_start=$(echo "$cpu_plan" | sed -n 's/.*mb_cpu_start=\([^ ]*\).*/\1/p')
    if [[ -z "$server_core_list" || -z "$client_core_list" || ! "$mb_cpu_start" =~ ^[0-9]+$ ]]; then
        echo "ERROR: invalid CPU plan output: ${cpu_plan}"
        exit 1
    fi

    ./redis_server_start.sh ${no_of_servers} "list:${server_core_list}" ${server_numa_node} ${redis_server_cpus_per_instance} &
    local pid=$!
    echo "$pid" | sudo tee "$cg/cgroup.procs" >/dev/null

    # Collect the wall clock time and cpu stat to get the utilization, system time, user time etc.
    read_vals_before
    ./mb_start.sh ${no_of_servers} ${db_file} ${mb_cpu_start} "${logdir}/${scenario}" prefill ${memtier_cpus_per_instance} "${client_core_list}"
    read_vals_after 
    prefill_cpu_pct=$CPU_PCT;prefill_user_pct=$USER_PCT;prefill_sys_pct=$SYS_PCT;prefill_sys_total_pct=$SYS_TOTAL_PCT
    read_vals_before
    ./mb_start.sh ${no_of_servers} ${db_file} ${mb_cpu_start} "${logdir}/${scenario}" run ${memtier_cpus_per_instance} "${client_core_list}"
    read_vals_after 
    run_cpu_pct=$CPU_PCT;run_user_pct=$USER_PCT;run_sys_pct=$SYS_PCT;run_sys_total_pct=$SYS_TOTAL_PCT


    local max_memory max_swap_memory throughput p99
    memory_peak=$(cat "$cg/memory.peak")
    memory_max=$(cat "$cg/memory.max")
    memory_swap_peak=$(cat "$cg/memory.swap.peak")

    # Stop swap monitor and wait for final CSV flush
    if [[ "$swap_mode" == "zram" ]]; then
        pkill -f zram_log.sh 2>/dev/null || true
    else
        pkill -f zswap_log.sh 2>/dev/null || true
    fi
    sleep 0.5  # allow logger to handle TERM and flush

    # Parse swap report once (avoid calling zswap_report.sh twice)
    local swap_report
    swap_report=$(./zswap_report.sh "$swap_csv")
    zswap_pool_size=$(echo "$swap_report" | awk '/Pool size:/{ print $3}')
    comp_ratio=$(echo "$swap_report" | awk '/Compression ratio:/{ print $3}')
    
    throughput_avg=0
    throughput_agg=0
    p99_max=0
    local actual_instances=0
    for (( i=1; i<=$no_of_servers; i++)); do
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
        # Aggregate (sum across all instances) and per-instance average throughput.
        
        throughput_avg=$(echo "$throughput_avg+$throughput" | bc)
        throughput_agg=$(echo "scale=2;$throughput_avg/1" | bc)

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
        throughput_avg=$(echo "scale=2;$throughput_avg/$actual_instances" | bc)
    else
        throughput_avg=0
    fi

    echo "scenario:$scenario, swap_mode:$swap_mode, memory_max:$memory_max, memory_peak:$memory_peak, zswap_pool_size:$zswap_pool_size, comp_ratio:$comp_ratio, memory_swap_peak:$memory_swap_peak, throughput:$throughput_avg, throughput_agg:$throughput_agg, p99:$p99_max, configured_instances:$no_of_servers, actual_instances:$actual_instances, prefill_cpu_pct:$prefill_cpu_pct, prefill_user_pct:$prefill_user_pct, prefill_sys_pct:$prefill_sys_pct, prefill_sys_total_pct:$prefill_sys_total_pct, run_cpu_pct:$run_cpu_pct, run_user_pct:$run_user_pct, run_sys_pct:$run_sys_pct, run_sys_total_pct:$run_sys_total_pct" | tee "${logdir}/${scenario}.log"

}

# The naming convention
# <compressor>_r<reclaim-0batchsize>_p<page-cluster>
if [ "$compressor" == "all" ];then
   # Check if this is a custom kernel with reclaim-batchsize support.
   if [ -f /proc/sys/vm/reclaim-batchsize ]; then
       compressor_list=("zstd_r1_p3" "lz4_r1_p3"  "deflate-iaa_r1_p3" "deflate-iaa-dynamic_r64_p5")
       #compressor_list=("zstd_r1_p3" "lz4_r1_p3" "deflate-iaa_r1_p3" "deflate-iaa_r64_p5" "deflate-iaa-dynamic_r1_p3" "deflate-iaa-dynamic_r64_p5")
   else
       compressor_list=("zstd_r1_p3" "lzo_r1_p3" "deflate-iaa_r1_p3")
   fi
else
   compressor_list=( "$compressor")
fi

# Verify the kernel actually activated the requested compressor so unavailable
# configs (e.g. deflate-iaa / deflate-iaa-dynamic) are skipped instead of run.
source "${THIS_DIR}/../scripts/compressor_lib.sh"

#echo "${compressor_list[@]}"
report_string=""
for comp in "${compressor_list[@]}"; do
    # Defaults
    comp_algo="$comp"
    reclaim_batchsize=1
    page_cluster=3

    # Match: compressor_r<number>_p<number>
    if [[ "$comp" =~ ^(.+)_r([0-9]+)_p([0-9]+)$ ]]; then
        comp_algo="${BASH_REMATCH[1]}"
        reclaim_batchsize="${BASH_REMATCH[2]}"
        page_cluster="${BASH_REMATCH[3]}"
    fi


    if [[ "$swap_mode" == "zram" ]]; then
        "${THIS_DIR}/../scripts/config_sys_zram.sh" \
            -c "$comp_algo" \
            -r "$reclaim_batchsize" \
            -p "$page_cluster"
    else
        "${THIS_DIR}/../scripts/config_sys_zswap.sh" \
            -c "$comp_algo" \
            -r "$reclaim_batchsize" \
            -p "$page_cluster"
    fi

    if ! verify_compressor_active "$swap_mode" "$comp_algo"; then
        continue
    fi

   
    LOGDIR_COMP=${LOGDIR}/${comp} 
    mkdir -p ${LOGDIR_COMP}

    run_scenario "baseline" "max" "${LOGDIR_COMP}"
    baseline_throughput="${throughput_agg:-0}"
    baseline_max=$(grep -oP 'memory_peak:\K[0-9]+' "${LOGDIR_COMP}/baseline.log")

    if [[ ! "$baseline_max" =~ ^[0-9]+$ ]] || (( baseline_max <= 0 )); then
        echo "ERROR: invalid baseline memory_peak '$baseline_max' in ${LOGDIR_COMP}/baseline.log" >&2
        echo "ERROR: skipping compressor '$comp' to avoid applying zero memory.max" >&2
        continue
    fi
    if ! awk -v b="$baseline_throughput" 'BEGIN {exit !(b+0 > 0)}'; then
        echo "ERROR: invalid baseline throughput '$baseline_throughput' for '$comp'" >&2
        echo "ERROR: skipping compressor '$comp' because throughput guard cannot be evaluated" >&2
        continue
    fi

    sweep_start=95
    sweep_step=-2
    sweep_end=65

    for memlimit in $(seq $sweep_start $sweep_step $sweep_end);do
        limit=$((baseline_max * memlimit /100))
        if (( limit <= 0 )); then
            echo "WARNING: computed non-positive limit ($limit), forcing to 1 byte" >&2
            limit=1
        fi
        echo "Limiting memory to $limit"
        run_scenario memlimit-${memlimit} ${limit} "${LOGDIR_COMP}"

        # Abort sweep when throughput drops by more than 10% vs baseline.
        if awk -v b="$baseline_throughput" -v c="${throughput_agg:-0}" 'BEGIN {drop=(b-c)/b*100; exit !(drop > 10)}'; then
            drop_pct=$(awk -v b="$baseline_throughput" -v c="${throughput_agg:-0}" 'BEGIN {printf "%.2f", (b-c)/b*100}')
            echo "Throughput dropped by ${drop_pct}% (>10%) at memlimit-${memlimit}; aborting remaining memory-limit sweep for '$comp'"
            break
        fi
    done

    # Generate report
    cat ${LOGDIR_COMP}/*.log | python report.py | tee ${LOGDIR_COMP}/$comp.report
    report_string+="${LOGDIR_COMP}/$comp.report "
done

report_string="${report_string% }"
python report_plot.py ${report_string} --output-dir ${LOGDIR}
