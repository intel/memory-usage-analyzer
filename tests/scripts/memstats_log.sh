#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
# Usage: ./memstats_log.sh [--once] <cgroup-dir|memory.stat> [interval_sec] [out.csv]
set -euo pipefail

ONCE=0
if [[ "${1:-}" == "--once" ]]; then
    ONCE=1
    shift
fi

if (( $# < 1 || $# > 3 )); then
    echo "Usage: $0 [--once] <cgroup-dir|memory.stat> [interval_sec] [out.csv]" >&2
    exit 2
fi

STAT_PATH=$1
INTERVAL=${2:-1}
OUT=${3:-memstats.csv}
if [[ -d "$STAT_PATH" ]]; then
    CGROUP_DIR=${STAT_PATH%/}
    STAT_PATH="${CGROUP_DIR}/memory.stat"
else
    CGROUP_DIR=$(dirname "$STAT_PATH")
fi

[[ -r "$STAT_PATH" ]] || { echo "Cannot read cgroup memory statistics: $STAT_PATH" >&2; exit 1; }
awk -v interval="$INTERVAL" 'BEGIN { exit !(interval ~ /^[0-9]+([.][0-9]+)?$/ && interval > 0) }' \
    || { echo "Interval must be a positive number: $INTERVAL" >&2; exit 2; }

HEADER="timestamp_utc,elapsed_seconds,memory_current_bytes,memory_peak_bytes,swap_current_bytes,swap_peak_bytes,anon_bytes,file_bytes,shmem_bytes,page_cache_bytes,kernel_bytes,kernel_stack_bytes,pagetables_bytes,sock_bytes,slab_bytes,zswap_bytes,zswapped_bytes,swapcached_bytes,anon_thp_bytes,file_thp_bytes,inactive_anon_bytes,active_anon_bytes,inactive_file_bytes,active_file_bytes,file_mapped_bytes,file_dirty_bytes,file_writeback_bytes,workingset_refault_anon,workingset_refault_file,workingset_activate_anon,workingset_activate_file,pgfault,pgmajfault,pgscan,pgsteal,pressure_some_total_usec,pressure_full_total_usec,event_low,event_high,event_max,event_oom,event_oom_kill"
echo "$HEADER" > "$OUT"
START_NS=$(date +%s%N)

sample() {
    local values now_ns elapsed
    values=$(awk \
        -v current_path="$CGROUP_DIR/memory.current" \
        -v peak_path="$CGROUP_DIR/memory.peak" \
        -v swap_current_path="$CGROUP_DIR/memory.swap.current" \
        -v swap_peak_path="$CGROUP_DIR/memory.swap.peak" \
        -v pressure_path="$CGROUP_DIR/memory.pressure" \
        -v events_path="$CGROUP_DIR/memory.events" '
        function read_scalar(path, value) {
            if ((getline value < path) > 0 && value ~ /^[0-9]+$/) {
                close(path)
                return value + 0
            }
            close(path)
            return 0
        }
        { stat[$1]=$2 + 0 }
        END {
            while ((getline < events_path) > 0) event[$1]=$2 + 0
            close(events_path)
            while ((getline pressure_line < pressure_path) > 0) {
                count=split(pressure_line, pressure_fields, " ")
                pressure_type=pressure_fields[1]
                for (field=2; field<=count; field++) {
                    split(pressure_fields[field], pair, "=")
                    if (pair[1] == "total") pressure[pressure_type]=pair[2] + 0
                }
            }
            close(pressure_path)
            page_cache = stat["file"] - stat["shmem"]
            if (page_cache < 0) page_cache = 0
            printf "%.0f,%.0f,%.0f,%.0f", read_scalar(current_path), \
                read_scalar(peak_path), read_scalar(swap_current_path), read_scalar(swap_peak_path)
            printf ",%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f", \
                stat["anon"], stat["file"], stat["shmem"], page_cache, stat["kernel"], \
                stat["kernel_stack"], stat["pagetables"], stat["sock"], stat["slab"]
            printf ",%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f", \
                stat["zswap"], stat["zswapped"], stat["swapcached"], stat["anon_thp"], \
                stat["file_thp"], stat["inactive_anon"], stat["active_anon"], \
                stat["inactive_file"], stat["active_file"]
            printf ",%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f", \
                stat["file_mapped"], stat["file_dirty"], stat["file_writeback"], \
                stat["workingset_refault_anon"], stat["workingset_refault_file"], \
                stat["workingset_activate_anon"], stat["workingset_activate_file"], \
                stat["pgfault"], stat["pgmajfault"]
            printf ",%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.0f", stat["pgscan"], \
                stat["pgsteal"], pressure["some"], pressure["full"], event["low"], \
                event["high"], event["max"], event["oom"], event["oom_kill"]
        }
    ' "$STAT_PATH") || return 1
    now_ns=$(date +%s%N)
    elapsed=$(awk -v now="$now_ns" -v start="$START_NS" 'BEGIN { printf "%.6f", (now-start)/1000000000 }')
    printf '%s,%s,%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%S.%NZ")" "$elapsed" "$values" >> "$OUT"
}

if (( ONCE )); then
    sample
    exit 0
fi

echo "Logging memory statistics from $CGROUP_DIR every ${INTERVAL}s to $OUT (Ctrl-C to stop)"
trap 'echo; echo "Stopped. Saved: '"$OUT"'"; exit 0' INT TERM

while true; do
    if [[ -r "$STAT_PATH" ]]; then
        sample || true
    fi
    sleep "$INTERVAL"
done