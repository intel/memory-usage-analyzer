#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# Shared helpers for monitoring iaa_crypto usage in benchmark scripts.

IAA_CRYPTO_DEBUGFS="${IAA_CRYPTO_DEBUGFS:-/sys/kernel/debug/iaa_crypto}"
IAA_DEVICE_STATS_SOURCE="${IAA_DEVICE_STATS_SOURCE:-}"
IAA_DEVICE_STATS_ERROR="${IAA_DEVICE_STATS_ERROR:-}"

iaa_monitor_is_iaa_compressor() {
    local profile="$1"
    [[ "$profile" == deflate-iaa* ]]
}

iaa_monitor_reset_stats() {
    local reset_file="${IAA_CRYPTO_DEBUGFS}/stats_reset"
    [[ -e "$reset_file" ]] || return 0

    echo 1 > "$reset_file" 2>/dev/null || IAA_DEVICE_STATS_ERROR="cannot reset IAA stats via $reset_file"
}

# Read a debugfs file, skipping the sudo fork when already root (also avoids
# sudo ever blocking on a password prompt from a backgrounded sampler).
iaa_monitor_read_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    if [[ "$EUID" -eq 0 ]]; then
        cat "$f" 2>/dev/null || true
    else
        sudo cat "$f" 2>/dev/null || true
    fi
}

iaa_monitor_capture_global_stats() {
    iaa_monitor_read_file "${IAA_CRYPTO_DEBUGFS}/global_stats"
}

iaa_monitor_get_stat() {
    local metric="$1"
    local stats="$2"
    echo "$stats" | grep "$metric" | grep -oP '\K[0-9]+$' || echo "0"
}

iaa_monitor_collect_global_snapshot() {
    local stats
    stats="$(iaa_monitor_capture_global_stats)"
    [[ -z "$stats" ]] && echo "" && return

    # Single awk pass instead of four forked grep|grep pipelines per snapshot,
    # since this runs on every sampler tick.
    awk '
        /total_comp_calls:/      { cc = $NF }
        /total_decomp_calls:/    { dc = $NF }
        /total_comp_bytes_in:/   { cb_in = $NF; have_cb_in = 1 }
        /total_comp_bytes_out:/  { cb_out = $NF }
        /total_decomp_bytes_in:/ { db_in = $NF }
        /total_decomp_bytes_out:/ { db_out = $NF; have_db_out = 1 }
        END {
            cb = have_cb_in ? cb_in : cb_out
            db = have_db_out ? db_out : db_in
            printf "%d|%d|%d|%d\n", cc + 0, dc + 0, cb + 0, db + 0
        }
    ' <<< "$stats"
}

iaa_monitor_calc_throughput_mbs() {
    local bytes="$1"
    local ns="$2"
    if [[ ! "$ns" =~ ^[0-9]+$ ]] || [[ ! "$bytes" =~ ^[0-9]+$ ]] || [[ $ns -le 0 ]] || [[ $bytes -le 0 ]]; then
        echo "0.0"
        return
    fi

    awk -v b="$bytes" -v ns="$ns" 'BEGIN{printf "%.2f", (b * 1000000000.0) / (ns * 1048576.0)}'
}

iaa_monitor_calc_throughput() {
    local before="$1"
    local after="$2"
    local comp_elapsed_ns="$3"
    local decomp_elapsed_ns="$4"
    [[ -z "$before" ]] || [[ -z "$after" ]] && echo "" && return

    local before_comp_calls before_decomp_calls before_comp_bytes before_decomp_bytes
    local after_comp_calls after_decomp_calls after_comp_bytes after_decomp_bytes
    IFS='|' read -r before_comp_calls before_decomp_calls before_comp_bytes before_decomp_bytes <<< "$before"
    IFS='|' read -r after_comp_calls after_decomp_calls after_comp_bytes after_decomp_bytes <<< "$after"

    local delta_comp_calls=$((after_comp_calls - before_comp_calls))
    local delta_decomp_calls=$((after_decomp_calls - before_decomp_calls))
    local delta_comp_bytes=$((after_comp_bytes - before_comp_bytes))
    local delta_decomp_bytes=$((after_decomp_bytes - before_decomp_bytes))
    local comp_mbs decomp_mbs
    comp_mbs="$(iaa_monitor_calc_throughput_mbs "$delta_comp_bytes" "$comp_elapsed_ns")"
    decomp_mbs="$(iaa_monitor_calc_throughput_mbs "$delta_decomp_bytes" "$decomp_elapsed_ns")"
    echo "$delta_comp_calls|$delta_decomp_calls|$delta_comp_bytes|$delta_decomp_bytes|$comp_mbs|$decomp_mbs"
}

# The single before/after snapshot above divides total bytes by the whole
# page-in/page-out wall-clock time, which also includes fault-handling
# overhead unrelated to (de)compression and so underestimates true IAA
# throughput. The sampler below polls global_stats on a fixed interval so
# throughput can instead be computed only over the windows where the byte
# counters actually advanced ("busy" time).

# Poll global_stats every interval_ms and append "ts_ns|snapshot" lines to
# samples_file until iaa_monitor_sampler_stop is called. Prints the sampler
# PID to stdout.
iaa_monitor_sampler_start() {
    local interval_ms="$1"
    local samples_file="$2"
    local sleep_s
    sleep_s=$(awk -v ms="$interval_ms" 'BEGIN{printf "%.3f", ms/1000.0}')

    : > "$samples_file"
    # Detach stdio: otherwise this background subshell inherits the write end
    # of the caller's `$(iaa_monitor_sampler_start ...)` pipe, and that
    # command substitution blocks forever waiting for EOF since the loop
    # never exits on its own.
    (
        # errexit is inherited from the caller; disable it here so a single
        # empty/failed snapshot can't silently kill the sampler loop.
        set +e
        while true; do
            snap="$(iaa_monitor_collect_global_snapshot)"
            if [[ -n "$snap" ]]; then
                # Bash builtin (no fork), unlike `date +%s%N`.
                ts="${EPOCHREALTIME/./}000"
                echo "${ts}|${snap}" >> "$samples_file"
            fi
            sleep "$sleep_s"
        done
    ) < /dev/null > /dev/null 2>&1 &
    echo $!
}

iaa_monitor_sampler_stop() {
    local pid="$1"
    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    return 0
}

# Compute "busy-window" throughput from a samples file: bytes advanced summed
# over only the sampling intervals where that counter increased, divided by
# the cumulative duration of those intervals (idle intervals are excluded).
# Also tracks the peak single-interval throughput (highest instantaneous
# MB/s seen between any two consecutive samples).
# Output: comp_mbs|decomp_mbs|peak_comp_mbs|peak_decomp_mbs|comp_active_intervals|decomp_active_intervals|total_intervals
iaa_monitor_analyze_samples() {
    local samples_file="$1"
    if [[ ! -s "$samples_file" ]]; then
        echo ""
        return
    fi

    awk -F'|' '
        NR == 1 { pts = $1; pcb = $4; pdb = $5; next }
        {
            dt = $1 - pts
            if (dt > 0) {
                total++
                dcomp = $4 - pcb
                ddecomp = $5 - pdb
                if (dcomp > 0) {
                    comp_bytes_sum += dcomp; comp_ns_sum += dt; comp_active++
                    comp_mbs_i = (dcomp * 1000000000.0) / (dt * 1048576.0)
                    if (comp_mbs_i > peak_comp) peak_comp = comp_mbs_i
                }
                if (ddecomp > 0) {
                    decomp_bytes_sum += ddecomp; decomp_ns_sum += dt; decomp_active++
                    decomp_mbs_i = (ddecomp * 1000000000.0) / (dt * 1048576.0)
                    if (decomp_mbs_i > peak_decomp) peak_decomp = decomp_mbs_i
                }
            }
            pts = $1; pcb = $4; pdb = $5
        }
        END {
            comp_mbs = (comp_ns_sum > 0) ? (comp_bytes_sum * 1000000000.0) / (comp_ns_sum * 1048576.0) : 0
            decomp_mbs = (decomp_ns_sum > 0) ? (decomp_bytes_sum * 1000000000.0) / (decomp_ns_sum * 1048576.0) : 0
            printf "%.2f|%.2f|%.2f|%.2f|%d|%d|%d\n", comp_mbs, decomp_mbs, peak_comp + 0, peak_decomp + 0, comp_active + 0, decomp_active + 0, total + 0
        }
    ' "$samples_file"
}

iaa_monitor_capture_device_stats() {
    local out_file="$1"
    local stats_file=""

    if [[ -r "${IAA_CRYPTO_DEBUGFS}/stats" ]]; then
        stats_file="${IAA_CRYPTO_DEBUGFS}/stats"
    elif [[ -r "${IAA_CRYPTO_DEBUGFS}/wq_stats" ]]; then
        stats_file="${IAA_CRYPTO_DEBUGFS}/wq_stats"
    else
        IAA_DEVICE_STATS_ERROR="IAA device stats not available at ${IAA_CRYPTO_DEBUGFS}/stats or ${IAA_CRYPTO_DEBUGFS}/wq_stats"
        return 0
    fi

    IAA_DEVICE_STATS_SOURCE="$stats_file"
    local content
    content="$(iaa_monitor_read_file "$stats_file")"
    if [[ -z "$content" ]]; then
        IAA_DEVICE_STATS_ERROR="cannot read IAA device stats from $stats_file"
        rm -f "$out_file"
        return 0
    fi
    printf '%s\n' "$content" > "$out_file"
}

iaa_monitor_print_device_report() {
    local log_dir="$1"
    local report_file="${log_dir}/iaa_device_usage_report.txt"
    local stats_source="${IAA_DEVICE_STATS_SOURCE:-${IAA_CRYPTO_DEBUGFS}/stats or ${IAA_CRYPTO_DEBUGFS}/wq_stats}"
    local have_stats=0
    local stats_file

    mkdir -p "$log_dir"

    for stats_file in "$log_dir"/*/iaa_stats_*.txt; do
        [[ -s "$stats_file" ]] && have_stats=1 && break
    done

    if (( ! have_stats )); then
        {
            echo ""
            echo "--- IAA device usage from ${stats_source} ---"
            echo "IAA device usage report unavailable: no per-device stats were captured."
            [[ -n "$IAA_DEVICE_STATS_ERROR" ]] && echo "$IAA_DEVICE_STATS_ERROR"
            echo "Check that ${IAA_CRYPTO_DEBUGFS}/stats or ${IAA_CRYPTO_DEBUGFS}/wq_stats exists and is readable."
        } > "$report_file"
        echo "IAA device stats report available at: $report_file"
        return 0
    fi

    {
        echo ""
        echo "--- IAA device usage from ${stats_source} ---"
        printf "%-28s %8s %6s %15s %15s %15s %15s %15s\n" \
            "Compressor" "Run" "IAA" "CompCalls" "DecompCalls" "CompBytes" "DecompBytes" "TotalBytes"
        printf "%-28s %8s %6s %15s %15s %15s %15s %15s\n" \
            "----------------------------" "--------" "----" "--------------" "--------------" "--------------" "--------------" "--------------"

        for stats_file in "$log_dir"/*/iaa_stats_*.txt; do
            [[ -s "$stats_file" ]] || continue

            local profile run_name profile_dir file_name
            profile_dir="$(dirname "$stats_file")"
            profile="$(basename "$profile_dir")"
            file_name="$(basename "$stats_file")"
            run_name="${file_name#iaa_stats_}"
            run_name="${run_name%.txt}"

            awk -v profile="$profile" -v run_name="$run_name" '
                function reset_device() {
                    id = "--"
                    comp_calls = 0
                    decomp_calls = 0
                    comp_bytes = 0
                    decomp_bytes = 0
                    in_wqs = 0
                    seen = 0
                }
                function emit_device() {
                    if (!seen) {
                        return
                    }
                    printf "%-28s %8s %6s %15d %15d %15d %15d %15d\n", \
                        profile, run_name, id, comp_calls, decomp_calls, comp_bytes, decomp_bytes, comp_bytes + decomp_bytes
                }
                BEGIN { reset_device() }
                /^iaa device:/ { emit_device(); reset_device(); seen = 1; next }
                /^[[:space:]]*wqs:/ { in_wqs = 1; next }
                in_wqs { next }
                {
                    key = $1
                    sub(/:$/, "", key)
                    if (key == "id") id = $2
                    else if (key == "comp_calls") comp_calls = $2 + 0
                    else if (key == "decomp_calls") decomp_calls = $2 + 0
                    else if (key == "comp_bytes") comp_bytes = $2 + 0
                    else if (key == "decomp_bytes") decomp_bytes = $2 + 0
                }
                END { emit_device() }
            ' "$stats_file"
        done
    } > "$report_file"
    echo "IAA device stats report available at: $report_file"
}