#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# zram_microbench.sh — Measure zram per-page latency under varying concurrency
# and batching configurations (matching redis/benchmark.sh profile naming).
#
# Compressor profiles use the convention: <algorithm>_r<reclaim_batchsize>_p<page_cluster>
#
# Usage:
#   sudo ./zram_microbench.sh [options]
#
# Options:
#   --compressor, -c <profile|all>  Compressor profile or 'all' (default: all)
#   --threads, -t <list>            Comma-separated thread counts (default: 1,2,4,8,16,32)
#   --frequency, -f <MHz>           Core frequency for IAA (default: 3200)
#   --pages, -p <num>               Pages per thread (default: from dataset)
#   --dataset, -d <file>            Data file for page content (default: silesia.tar)
#   --help, -h                      Show this help

set -euo pipefail

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# ─── Defaults ─────────────────────────────────────────────────────────
DATASET="silesia.tar"
CORE_FREQUENCY=3200
COMPRESSOR="all"
THREAD_LIST_STR="1,2,4,8,16,32,64"
PAGES_OVERRIDE=""
BASELINE_ONLY=1

# ─── Usage ────────────────────────────────────────────────────────────
print_usage() {
    cat <<'EOF'
Usage:
    zram_microbench.sh [options]

Options:
  --compressor, -c <profile|all>  Compressor profile(s) (default: all)
                                  Examples: deflate-iaa_r1_p3, lz4_r1_p3, all
  --threads, -t <list>            Comma-separated thread counts (default: 1,2,4,8,16,32)
  --multi-thread, -m              Run multi-threaded sweep (default: baseline only)
  --frequency, -f <MHz>           Core frequency (default: 3200)
  --pages, -p <num>               Pages per thread (0 = use full dataset, default)
  --dataset, -d <file>            Data file for page content (default: silesia.tar)
  --help, -h                      Show this help

Compressor profile naming: <algorithm>_r<reclaim_batchsize>_p<page_cluster>
  deflate-iaa_r1_p3         IAA deflate, batchsize=1, page_cluster=3
  deflate-iaa_r64_p5        IAA deflate, batchsize=64, page_cluster=5
  deflate-iaa-dynamic_r64_p5  IAA dynamic mode, batchsize=64, page_cluster=5
  lz4_r1_p3                 lz4 CPU, batchsize=1, page_cluster=3
  lzo_r1_p3                 lzo CPU, batchsize=1, page_cluster=3
  zstd_r1_p3                zstd CPU, batchsize=1, page_cluster=3

Flow:
  For each compressor profile:
    1. Configure zram compressor, reclaim_batchsize, page_cluster
    2. Run single-threaded baseline
    3. Run multi-threaded tests at each thread count
    4. Report per-page latency table
EOF
}

# ─── Parse arguments ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --compressor|-c) COMPRESSOR="$2"; shift 2 ;;
        --threads|-t)    THREAD_LIST_STR="$2"; shift 2 ;;
        --multi-thread|-m) BASELINE_ONLY=0; shift ;;
        --frequency|-f)  CORE_FREQUENCY="$2"; shift 2 ;;
        --pages|-p)      PAGES_OVERRIDE="$2"; shift 2 ;;
        --dataset|-d)    DATASET="$2"; shift 2 ;;
        --help|-h)       print_usage; exit 0 ;;
        *)               echo "Unknown option: $1"; print_usage; exit 1 ;;
    esac
done

# Parse thread list
IFS=',' read -ra THREAD_LIST <<< "$THREAD_LIST_STR"

# ─── Helpers ──────────────────────────────────────────────────────────
handle_error() {
    echo "Error: $1"
    exit 1
}

# Format integer values with thousands separators for readable console tables.
fmt_int_commas() {
    local n="$1"
    if [[ ! "$n" =~ ^-?[0-9]+$ ]]; then
        echo "$n"
        return
    fi

    local sign=""
    if [[ "$n" == -* ]]; then
        sign="-"
        n="${n#-}"
    fi

    local out=""
    while (( ${#n} > 3 )); do
        out=",${n: -3}${out}"
        n="${n:0:${#n}-3}"
    done
    echo "${sign}${n}${out}"
}

# Configure zram/kernel params for a compressor profile
configure_compressor() {
    local profile="$1"
    local comp_algo="$profile"
    local reclaim_batchsize=1
    local page_cluster=3

    # Parse profile: <algorithm>_r<batchsize>_p<page_cluster>
    if [[ "$profile" =~ ^(.+)_r([0-9]+)_p([0-9]+)$ ]]; then
        comp_algo="${BASH_REMATCH[1]}"
        reclaim_batchsize="${BASH_REMATCH[2]}"
        page_cluster="${BASH_REMATCH[3]}"
    fi

    "${THIS_DIR}/../scripts/config_sys_zram.sh" \
        -c "$comp_algo" \
        -r "$reclaim_batchsize" \
        -p "$page_cluster" \
        -f "$CORE_FREQUENCY" > /dev/null 2>&1
}

# ─── Build compressor list ────────────────────────────────────────────
declare -a compressor_list=()
if [[ "$COMPRESSOR" == "all" ]]; then
    if [ -f /proc/sys/vm/reclaim-batchsize ]; then
        compressor_list=(
            "lzo-rle_r1_p3"
            "lz4_r1_p3"
            "zstd_r1_p3"
            "deflate-iaa_r1_p3"
            "deflate-iaa_r64_p5"
            "deflate-iaa-dynamic_r1_p3"
            "deflate-iaa-dynamic_r64_p5"
        )
    else
        compressor_list=(
            "lzo-rle_r1_p3"
            "lz4_r1_p3"
            "zstd_r1_p3"
            "deflate-iaa_r1_p3"
            "deflate-iaa-dynamic_r1_p3"
        )
    fi
else
    compressor_list=("$COMPRESSOR")
fi

# ─── Setup ────────────────────────────────────────────────────────────

# Check if the dataset exists, if not download it
if [ ! -f "$DATASET" ] ; then
    echo "Downloading $DATASET from http://wanos.co/assets/silesia.tar"
    wget --no-check-certificate "http://wanos.co/assets/silesia.tar" || handle_error "Failed to download $DATASET"
fi

# Calculate pages from dataset
SZ=$(ls -s "$DATASET" | awk '{print $1}')
NPGS=$(echo "scale=0; $SZ/4-1" | bc -l)

if [[ -n "$PAGES_OVERRIDE" ]] && (( PAGES_OVERRIDE > 0 )); then
    NPGS_PER_THREAD=$PAGES_OVERRIDE
else
    NPGS_PER_THREAD=$NPGS
fi

# Build executables
echo "Building madvise_test..."
gcc -O2 -o madvise_test madvise_test.c || handle_error "Failed to build madvise_test"

echo "Building madvise_test_mt..."
gcc -O2 -pthread -o madvise_test_mt madvise_test_mt.c || handle_error "Failed to build madvise_test_mt"

# Disable THP (reduces measurement noise)
echo 'never' > /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled 2>/dev/null || true
echo 'never' > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

echo "========================================="
echo " zram Microbenchmark"
echo "========================================="
echo "Dataset:      $DATASET ($SZ KB)"
echo "Pages/thread: $NPGS_PER_THREAD ($(( NPGS_PER_THREAD * 4 / 1024 )) MB)"
echo "Thread list:  ${THREAD_LIST[*]}"
echo "Frequency:    ${CORE_FREQUENCY} MHz"
echo "Compressors:  ${compressor_list[*]}"
echo "========================================="
echo ""

# ─── Run benchmarks ──────────────────────────────────────────────────

# Collect all results first, then print clean table
declare -a ALL_PROFILES=()
declare -a ALL_BASELINE_OUT=()
declare -a ALL_BASELINE_OUT_TOTAL=()
declare -a ALL_BASELINE_OUT_SYS_TOTAL=()
declare -a ALL_BASELINE_IN=()
declare -a ALL_BASELINE_IN_TOTAL=()
declare -a ALL_BASELINE_IN_SYS_TOTAL=()
declare -a ALL_RATIO=()
declare -a ALL_STORED_PAGES=()
declare -a ALL_POOL_PAGES=()
declare -a ALL_MT_OUT=()
declare -a ALL_MT_IN=()
declare -a ALL_MT_OUT_SYS=()
declare -a ALL_MT_IN_SYS=()
declare -a ALL_MT_RATIO=()
declare -a ALL_MT_ZPOOL_PGS=()

for profile in "${compressor_list[@]}"; do
    echo "Testing: $profile ..." >&2
    configure_compressor "$profile"

    # Single-threaded baseline
    baseline_result=$(./madvise_test "$DATASET" "$NPGS_PER_THREAD" 2>&1)
    b_out=$(echo "$baseline_result" | grep "swap_out:" | grep -oP 'average=\K[0-9]+')
    b_out_total=$(echo "$baseline_result" | grep "swap_out:" | grep -oP 'total=\K[0-9]+')
    b_out_sys_total=$(echo "$baseline_result" | grep "swap_out_sys:" | grep -oP 'total=\K[0-9]+')
    b_in=$(echo "$baseline_result" | grep "swap_in:" | grep -oP 'average=\K[0-9]+')
    b_in_total=$(echo "$baseline_result" | grep "swap_in:" | grep -oP 'total=\K[0-9]+')
    b_in_sys_total=$(echo "$baseline_result" | grep "swap_in_sys:" | grep -oP 'total=\K[0-9]+')

    # Capture compression ratio and zpool pages from madvise_test output
    b_ratio=$(echo "$baseline_result" | grep -oP 'zpool_comp_ratio:\s*\K[0-9.]+')
    b_stored=$(echo "$baseline_result" | grep -oP 'zpool_stored_pages:\s*\K[0-9]+')
    b_pool_size=$(echo "$baseline_result" | grep -oP 'zpool_total_size:\s*\K[0-9]+')
    b_pool_pages=0
    if [[ -n "$b_pool_size" ]] && [[ "$b_pool_size" -gt 0 ]]; then
        b_pool_pages=$(( b_pool_size / 4096 ))
    fi
    # Multi-threaded sweep
    mt_out=""
    mt_in=""
    mt_out_sys=""
    mt_in_sys=""
    mt_ratio=""
    mt_zpool_pgs=""
    if (( BASELINE_ONLY == 0 )); then
        for nthreads in "${THREAD_LIST[@]}"; do
            result=$(./madvise_test_mt "$DATASET" "$NPGS_PER_THREAD" "$nthreads" 2>/dev/null)
            avg_out=$(echo "$result" | grep "swap_out_avg_ns" | awk -F= '{print $2}')
            avg_in=$(echo "$result" | grep "swap_in_avg_ns" | awk -F= '{print $2}')
            avg_out_sys=$(echo "$result" | grep "swap_out_sys_avg_ns" | awk -F= '{print $2}')
            avg_in_sys=$(echo "$result" | grep "swap_in_sys_avg_ns" | awk -F= '{print $2}')
            ratio=$(echo "$result" | grep "zpool_comp_ratio" | awk -F= '{print $2}')
            pool_size=$(echo "$result" | grep "zpool_total_size" | awk -F= '{print $2}')
            pool_pgs=0
            if [[ -n "$pool_size" ]] && [[ "$pool_size" -gt 0 ]]; then
                pool_pgs=$(( pool_size / 4096 ))
            fi
            mt_out+="${avg_out:-err} "
            mt_in+="${avg_in:-err} "
            mt_out_sys+="${avg_out_sys:-err} "
            mt_in_sys+="${avg_in_sys:-err} "
            mt_ratio+="${ratio:-0} "
            mt_zpool_pgs+="${pool_pgs:-0} "
        done
    fi

    ALL_PROFILES+=("$profile")
    ALL_BASELINE_OUT+=("${b_out:-err}")
    ALL_BASELINE_OUT_TOTAL+=("${b_out_total:-0}")
    ALL_BASELINE_OUT_SYS_TOTAL+=("${b_out_sys_total:-0}")
    ALL_BASELINE_IN+=("${b_in:-err}")
    ALL_BASELINE_IN_TOTAL+=("${b_in_total:-0}")
    ALL_BASELINE_IN_SYS_TOTAL+=("${b_in_sys_total:-0}")
    ALL_RATIO+=("${b_ratio:-0}")
    ALL_STORED_PAGES+=("${b_stored:-0}")
    ALL_POOL_PAGES+=("${b_pool_pages:-0}")
    ALL_MT_OUT+=("$mt_out")
    ALL_MT_IN+=("$mt_in")
    ALL_MT_OUT_SYS+=("$mt_out_sys")
    ALL_MT_IN_SYS+=("$mt_in_sys")
    ALL_MT_RATIO+=("$mt_ratio")
    ALL_MT_ZPOOL_PGS+=("$mt_zpool_pgs")
done

# ─── Print clean report ──────────────────────────────────────────────
echo ""
echo "========================================="
echo " Swap-Out (Compression) ns/page"
echo "========================================="
echo ""
printf "%-32s %10s" "Compressor" "1T(base)"
if (( BASELINE_ONLY == 0 )); then
    for nthreads in "${THREAD_LIST[@]}"; do
        printf " %8s" "${nthreads}T"
    done
fi
echo ""
printf "%-32s %10s" "────────────────────────────────" "────────"
if (( BASELINE_ONLY == 0 )); then
    for nthreads in "${THREAD_LIST[@]}"; do
        printf " %8s" "────────"
    done
fi
echo ""

for i in "${!ALL_PROFILES[@]}"; do
    base_out_fmt="$(fmt_int_commas "${ALL_BASELINE_OUT[$i]}")"
    printf "%-32s %10s" "${ALL_PROFILES[$i]}" "$base_out_fmt"
    if (( BASELINE_ONLY == 0 )); then
        for val in ${ALL_MT_OUT[$i]}; do
            val_fmt="$(fmt_int_commas "$val")"
            printf " %8s" "$val_fmt"
        done
    fi
    echo ""
done

echo ""
echo "========================================="
echo " Swap-In (Decompression) ns/page"
echo "========================================="
echo ""
printf "%-32s %10s" "Compressor" "1T(base)"
if (( BASELINE_ONLY == 0 )); then
    for nthreads in "${THREAD_LIST[@]}"; do
        printf " %8s" "${nthreads}T"
    done
fi
echo ""
printf "%-32s %10s" "────────────────────────────────" "────────"
if (( BASELINE_ONLY == 0 )); then
    for nthreads in "${THREAD_LIST[@]}"; do
        printf " %8s" "────────"
    done
fi
echo ""

for i in "${!ALL_PROFILES[@]}"; do
    base_in_fmt="$(fmt_int_commas "${ALL_BASELINE_IN[$i]}")"
    printf "%-32s %10s" "${ALL_PROFILES[$i]}" "$base_in_fmt"
    if (( BASELINE_ONLY == 0 )); then
        for val in ${ALL_MT_IN[$i]}; do
            val_fmt="$(fmt_int_commas "$val")"
            printf " %8s" "$val_fmt"
        done
    fi
    echo ""
done

# ─── Single-thread: Memory, Time ───────────────────────────────────────
total_pages_1t="$NPGS_PER_THREAD"
total_mb_1t=$(( total_pages_1t * 4 / 1024 ))
total_pages_1t_fmt="$(fmt_int_commas "$total_pages_1t")"
total_mb_1t_fmt="$(fmt_int_commas "$total_mb_1t")"
echo ""
echo " threads=1T, pages_per_thread=${NPGS_PER_THREAD}, total_pages=${total_pages_1t_fmt}, test_workset_mb=${total_mb_1t_fmt}"
echo ""
printf "%-28s %6s %10s %12s %12s %15s %15s\n" "Compressor" "Ratio" "Zpool-Pgs" "Swap-Out(ms)" "Swap-In(ms)" "Swap-Out-Sys(ms)" "Swap-In-Sys(ms)"
printf "%-28s %6s %10s %12s %12s %15s %15s\n" "────────────────────────────" "──────" "────────" "──────────" "──────────" "──────────────" "──────────────"
for i in "${!ALL_PROFILES[@]}"; do
    pool_pg="${ALL_POOL_PAGES[$i]}"
    out_total="${ALL_BASELINE_OUT_TOTAL[$i]}"
    out_sys_total="${ALL_BASELINE_OUT_SYS_TOTAL[$i]}"
    in_total="${ALL_BASELINE_IN_TOTAL[$i]}"
    in_sys_total="${ALL_BASELINE_IN_SYS_TOTAL[$i]}"
    out_ms="--"
    out_sys_ms="--"
    in_ms="--"
    in_sys_ms="--"

    if [[ "$out_total" -gt 0 ]]; then
        out_ms=$(awk -v t="$out_total" 'BEGIN{printf "%.1f", t/1000000}')
    fi
    if [[ "$in_total" -gt 0 ]]; then
        in_ms=$(awk -v t="$in_total" 'BEGIN{printf "%.1f", t/1000000}')
    fi
    if [[ "$out_sys_total" -gt 0 ]]; then
        out_sys_ms=$(awk -v t="$out_sys_total" 'BEGIN{printf "%.1f", t/1000000}')
    fi
    if [[ "$in_sys_total" -gt 0 ]]; then
        in_sys_ms=$(awk -v t="$in_sys_total" 'BEGIN{printf "%.1f", t/1000000}')
    fi
    pool_pg_fmt="$(fmt_int_commas "$pool_pg")"
    printf "%-28s %6s %10s %12s %12s %15s %15s\n" \
        "${ALL_PROFILES[$i]}" "${ALL_RATIO[$i]}" "$pool_pg_fmt" "$out_ms" "$in_ms" "$out_sys_ms" "$in_sys_ms"
done

# ─── Multi-threaded: Memory, Time per thread count ───────────────────
if (( BASELINE_ONLY == 0 )); then
    j=0
    for nthreads in "${THREAD_LIST[@]}"; do
        total_pages=$(( NPGS_PER_THREAD * nthreads ))
        total_mb=$(( total_pages * 4 / 1024 ))
        total_pages_fmt="$(fmt_int_commas "$total_pages")"
        total_mb_fmt="$(fmt_int_commas "$total_mb")"
        echo ""
        echo "-----------------------------------------"
        echo " threads=${nthreads}T, pages_per_thread=${NPGS_PER_THREAD}, total_pages=${total_pages_fmt}, test_workset_mb=${total_mb_fmt}"
        echo ""
        printf "%-28s %6s %10s %12s %12s %15s %15s\n" "Compressor" "Ratio" "Zpool-Pgs" "Swap-Out(ns)" "Swap-In(ns)" "Swap-Out-Sys(ns)" "Swap-In-Sys(ns)"
        printf "%-28s %6s %10s %12s %12s %15s %15s\n" "────────────────────────────" "──────" "────────" "──────────" "──────────" "──────────────" "──────────────"

        for i in "${!ALL_PROFILES[@]}"; do
            # Get the j-th value from each space-separated array
            read -ra out_arr <<< "${ALL_MT_OUT[$i]}"
            read -ra in_arr <<< "${ALL_MT_IN[$i]}"
            read -ra out_sys_arr <<< "${ALL_MT_OUT_SYS[$i]}"
            read -ra in_sys_arr <<< "${ALL_MT_IN_SYS[$i]}"
            read -ra ratio_arr <<< "${ALL_MT_RATIO[$i]}"
            read -ra zpool_arr <<< "${ALL_MT_ZPOOL_PGS[$i]}"

            ns_out="${out_arr[$j]:-err}"
            ns_in="${in_arr[$j]:-err}"
            ns_out_sys="${out_sys_arr[$j]:-err}"
            ns_in_sys="${in_sys_arr[$j]:-err}"
            ratio="${ratio_arr[$j]:-0}"
            zpool_pgs="${zpool_arr[$j]:-0}"

            ns_out_fmt="$(fmt_int_commas "$ns_out")"
            ns_in_fmt="$(fmt_int_commas "$ns_in")"
            ns_out_sys_fmt="$(fmt_int_commas "$ns_out_sys")"
            ns_in_sys_fmt="$(fmt_int_commas "$ns_in_sys")"
            zpool_pgs_fmt="$(fmt_int_commas "$zpool_pgs")"

            printf "%-28s %6s %10s %12s %12s %15s %15s\n" \
                "${ALL_PROFILES[$i]}" "$ratio" "$zpool_pgs_fmt" "$ns_out_fmt" "$ns_in_fmt" "$ns_out_sys_fmt" "$ns_in_sys_fmt"
        done
        j=$((j+1))
    done
fi
echo ""

# ─── TSV output for Excel ─────────────────────────────────────────────
TSV_FILE="${THIS_DIR}/results.tsv"
{
    # Single-threaded baseline
    printf "Compressor\tRatio\tZpool-Pgs\tSwap-Out(ms)\tSwap-In(ms)\tSwap-Out-Sys(ms)\tSwap-In-Sys(ms)\n"
    for i in "${!ALL_PROFILES[@]}"; do
        out_ms=$(awk -v t="${ALL_BASELINE_OUT_TOTAL[$i]}" 'BEGIN{printf "%.1f", t/1000000}')
        in_ms=$(awk -v t="${ALL_BASELINE_IN_TOTAL[$i]}" 'BEGIN{printf "%.1f", t/1000000}')
        out_sys_ms=$(awk -v t="${ALL_BASELINE_OUT_SYS_TOTAL[$i]}" 'BEGIN{printf "%.1f", t/1000000}')
        in_sys_ms=$(awk -v t="${ALL_BASELINE_IN_SYS_TOTAL[$i]}" 'BEGIN{printf "%.1f", t/1000000}')
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "${ALL_PROFILES[$i]}" "${ALL_RATIO[$i]}" "${ALL_POOL_PAGES[$i]}" "$out_ms" "$in_ms" "$out_sys_ms" "$in_sys_ms"
    done

    if (( BASELINE_ONLY == 0 )); then
        # Multi-threaded: one block per thread count
        j=0
        for nthreads in "${THREAD_LIST[@]}"; do
            printf "\n"
            printf "${nthreads}T\tCompressor\tRatio\tZpool-Pgs\tSwap-Out(ns/pg)\tSwap-In(ns/pg)\tSwap-Out-Sys(ns/pg)\tSwap-In-Sys(ns/pg)\n"
            for i in "${!ALL_PROFILES[@]}"; do
                read -ra out_arr <<< "${ALL_MT_OUT[$i]}"
                read -ra in_arr <<< "${ALL_MT_IN[$i]}"
                read -ra out_sys_arr <<< "${ALL_MT_OUT_SYS[$i]}"
                read -ra in_sys_arr <<< "${ALL_MT_IN_SYS[$i]}"
                read -ra ratio_arr <<< "${ALL_MT_RATIO[$i]}"
                read -ra zpool_arr <<< "${ALL_MT_ZPOOL_PGS[$i]}"
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                    "${nthreads}T" "${ALL_PROFILES[$i]}" "${ratio_arr[$j]:-0}" "${zpool_arr[$j]:-0}" "${out_arr[$j]:-err}" "${in_arr[$j]:-err}" "${out_sys_arr[$j]:-err}" "${in_sys_arr[$j]:-err}"
            done
            j=$((j+1))
        done

        # Flat swap-out table (all threads in one sheet-friendly block)
        printf "\n"
        printf "Swap-Out(ns/pg)\t1T(base)"
        for nthreads in "${THREAD_LIST[@]}"; do
            printf "\t%sT" "$nthreads"
        done
        printf "\n"
        for i in "${!ALL_PROFILES[@]}"; do
            base_out_fmt="$(fmt_int_commas "${ALL_BASELINE_OUT[$i]}")"
            printf "%s\t%s" "${ALL_PROFILES[$i]}" "$base_out_fmt"
            for val in ${ALL_MT_OUT[$i]}; do
                val_fmt="$(fmt_int_commas "$val")"
                printf "\t%s" "$val_fmt"
            done
            printf "\n"
        done

        # Flat swap-in table
        printf "\n"
        printf "Swap-In(ns/pg)\t1T(base)"
        for nthreads in "${THREAD_LIST[@]}"; do
            printf "\t%sT" "$nthreads"
        done
        printf "\n"
        for i in "${!ALL_PROFILES[@]}"; do
            base_in_fmt="$(fmt_int_commas "${ALL_BASELINE_IN[$i]}")"
            printf "%s\t%s" "${ALL_PROFILES[$i]}" "$base_in_fmt"
            for val in ${ALL_MT_IN[$i]}; do
                val_fmt="$(fmt_int_commas "$val")"
                printf "\t%s" "$val_fmt"
            done
            printf "\n"
        done
    fi
} > "$TSV_FILE"
echo "TSV saved: $TSV_FILE (paste into Excel)"

