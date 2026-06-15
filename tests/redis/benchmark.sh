#!/usr/bin/bash 
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
LOGDIR="./logdir"
REDIS_CONFIGS="./redis_configs"
THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"



# Clear all previous results
rm -rf ${LOGDIR}
rm -rf ${REDIS_CONFIGS}
rm -f *.log
rm -rf *.report
pkill -f zswap_log.sh
rm -rf *.html

mkdir  ${LOGDIR}
mkdir  ${REDIS_CONFIGS}

no_of_servers=${1-1}
compressor=${2:-deflate-iaa_r1_p3}
db_file=${3-import_movies_10000r_10c.csv}

# Reserve the 2 CPUs for system level activites
redis_server_cpu_start=2
redis_server_cpus_per_instance=1

# Read initial cgroup CPU stats
read_vals_before() {
    read u1 usr1 sys1 < <(awk '
    /usage_usec/  {u=$2}
    /user_usec/   {usr=$2}
    /system_usec/ {sys=$2}
    END {print u, usr, sys}
    ' "$cg/cpu.stat")
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


    du=$((u2 - u1))
    dusr=$((usr2 - usr1))
    dsys=$((sys2 - sys1))
    dt=$(((t2 - t1) / 1000))   # nanoseconds -> microseconds

    CPU_PCT=$(awk -v c="$du"   -v t="$dt" 'BEGIN {printf "%.2f", (t>0 ? (c/t)*100 : 0)}')
    USER_PCT=$(awk -v c="$dusr" -v t="$dt" 'BEGIN {printf "%.2f", (t>0 ? (c/t)*100 : 0)}')
    SYS_PCT=$(awk -v c="$dsys" -v t="$dt" 'BEGIN {printf "%.2f", (t>0 ? (c/t)*100 : 0)}')

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

    # start with a clean cgroup
    echo 1 | sudo tee "$cg/cgroup.kill"
    rmdir "$cg"
    mkdir "$cg"

    # Set memory limit before starting workload
    echo "$limit" > "$cg/memory.max"

    mkdir -p "${logdir}/${scenario}"
    # Monitor zswap stats
    ./zswap_log.sh 1 "${logdir}/${scenario}/zswap_run.csv"  &

    # Start workload and move it into cgroup ASAP
    ./redis_server_start.sh ${no_of_servers} ${redis_server_cpu_start} &
    local pid=$!
    echo "$pid" | sudo tee "$cg/cgroup.procs" >/dev/null

    # add two CPU separations between server and clients
    mb_cpu_start=$(( redis_server_cpus_per_instance*no_of_servers + redis_server_cpu_start + 2 ))

    # Collect the wall clock time and cpu stat to get the utilization, system time, user time etc.
    read_vals_before
    ./mb_start.sh ${no_of_servers} ${db_file} ${mb_cpu_start} "${logdir}/${scenario}" prefill
    read_vals_after 
    prefill_cpu_pct=$CPU_PCT;prefill_user_pct=$USER_PCT;prefill_sys_pct=$SYS_PCT
    read_vals_before
    ./mb_start.sh ${no_of_servers} ${db_file} ${mb_cpu_start} "${logdir}/${scenario}" run
    read_vals_after 
    run_cpu_pct=$CPU_PCT;run_user_pct=$USER_PCT;run_sys_pct=$SYS_PCT


    local max_memory max_swap_memory throughput p99
    memory_peak=$(cat "$cg/memory.peak")
    memory_max=$(cat "$cg/memory.max")
    memory_swap_peak=$(cat "$cg/memory.swap.peak")

    # Stop zswap monitor
    pkill -f zswap_log.sh
    zswap_pool_size=$(./zswap_report.sh ${logdir}/${scenario}/zswap_run.csv | awk '/Pool size:/{ print $3}')
    comp_ratio=$(./zswap_report.sh ${logdir}/${scenario}/zswap_run.csv | awk '/Compression ratio:/{ print $3}')
    
    throughput_avg=0
    p99_max=0
    for (( i=1; i<=$no_of_servers; i++)); do
        throughput=$(awk '/^Totals/ {print $2}' "${logdir}/${scenario}/run_${i}.log")
        throughput_avg=$(echo "$throughput_avg+$throughput" | bc)
        p99=$(awk '/^Totals/ {print $7}' "${logdir}/${scenario}/run_${i}.log")
        if (( $(echo "$p99 > $p99_max" | bc -l) )); then
            p99_max=$p99
        fi 
    done
    throughput_avg=$(echo "scale=2;$throughput_avg/$no_of_servers" | bc)

    
    echo "scenario:$scenario, memory_max:$memory_max, memory_peak:$memory_peak, zswap_pool_size:$zswap_pool_size, comp_ratio:$comp_ratio, memory_swap_peak:$memory_swap_peak, throughput:$throughput_avg, p99:$p99_max, prefill_cpu_pct:$prefill_cpu_pct, prefill_user_pct:$prefill_user_pct, prefill_sys_pct:$prefill_sys_pct, run_cpu_pct:$run_cpu_pct, run_user_pct:$run_user_pct, run_sys_pct:$run_sys_pct" | tee "${logdir}/${scenario}.log"

}

# The naming convention
# <compressor>_r<reclaim-0batchsize>_p<page-cluster>
if [ "$compressor" == "all" ];then
   # Check if this is a custom kernel with reclaim-batchsize support.
   if [ -f /proc/sys/vm/reclaim-batchsize ]; then
       compressor_list=("zstd_r1_p3" "lz4_r1_p3"  "deflate-iaa-dynamic_r64_p5")
       #compressor_list=("zstd_r1_p3" "lz4_r1_p3" "deflate-iaa_r1_p3" "deflate-iaa_r64_p5" "deflate-iaa-dynamic_r1_p3" "deflate-iaa-dynamic_r64_p5")
   else
       compressor_list=("lzo_r1_p3" "deflate_iaa_r1_p3")
   fi
else
   compressor_list=( "$compressor")
fi

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


    "${THIS_DIR}/../scripts/config_sys_zswap.sh" \
        -c "$comp_algo" \
        -r "$reclaim_batchsize" \
        -p "$page_cluster"

   
    LOGDIR_COMP=${LOGDIR}/${comp} 
    mkdir -p ${LOGDIR_COMP}

    run_scenario "baseline" "max" "${LOGDIR_COMP}"
    baseline_max=$(awk -F'memory_peak:|,' '/memory_peak:/ {print $4; exit}' ${LOGDIR_COMP}/baseline.log)
    #echo "$baseline_max"
    #for memlimit in {95..85..-5} {84..80..-1};do
    for memlimit in {95..85..-5};do
        limit=$((baseline_max * memlimit /100))
        echo "Limiting memory to $limit"
        run_scenario memlimit-${memlimit} ${limit} "${LOGDIR_COMP}"
    done

    # Generate report
    cat ${LOGDIR_COMP}/*.log | python report.py | tee ${LOGDIR_COMP}/$comp.report
    report_string+="${LOGDIR_COMP}/$comp.report "
done

report_string="${report_string% }"
python report_plot.py ${report_string} --output-dir ${LOGDIR}

