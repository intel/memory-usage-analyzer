#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#
# ┌──────────────────────────────────────────────────────────────────┐
# │  swap_stats.sh — Unified zswap/zram Monitor & Verifier          │
# │  Auto-detects backend. Beautiful terminal visualization.         │
# └──────────────────────────────────────────────────────────────────┘
#
# Usage:
#   ./swap_stats.sh                  # one-shot: full summary
#   ./swap_stats.sh -v [dur] [int]   # verify: monitor deltas for N seconds
#   ./swap_stats.sh -w [interval]    # watch: continuous refresh
#   ./swap_stats.sh -a [dur] [int]   # all: summary + verify in one pass
#   ./swap_stats.sh -h               # help
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════
#  COLORS & STYLING
# ══════════════════════════════════════════════════════════════════════

if [[ -t 1 ]] && command -v tput &>/dev/null && (( $(tput colors 2>/dev/null || echo 0) >= 8 )); then
    B="\033[1m"          # bold
    D="\033[2m"          # dim
    U="\033[4m"          # underline
    R="\033[0m"          # reset
    RED="\033[31m"
    GRN="\033[32m"
    YLW="\033[33m"
    BLU="\033[34m"
    MAG="\033[35m"
    CYN="\033[36m"
    WHT="\033[37m"
    BRED="\033[1;31m"
    BGRN="\033[1;32m"
    BYLW="\033[1;33m"
    BBLU="\033[1;34m"
    BMAG="\033[1;35m"
    BCYN="\033[1;36m"
    BWHT="\033[1;37m"
    # Backgrounds
    BG_GRN="\033[42;30m"
    BG_YLW="\033[43;30m"
    BG_RED="\033[41;97m"
    BG_BLU="\033[44;97m"
    BG_CYN="\033[46;30m"
    BG_MAG="\033[45;97m"
else
    B="" D="" U="" R=""
    RED="" GRN="" YLW="" BLU="" MAG="" CYN="" WHT=""
    BRED="" BGRN="" BYLW="" BBLU="" BMAG="" BCYN="" BWHT=""
    BG_GRN="" BG_YLW="" BG_RED="" BG_BLU="" BG_CYN="" BG_MAG=""
fi

# ── argument parsing ─────────────────────────────────────────────────

MODE="summary"
WATCH_INTERVAL=3
VERIFY_DURATION=10
VERIFY_SAMPLE=1

usage() {
    echo -e "${B}${BCYN}╔══════════════════════════════════════════════════════════╗${R}"
    echo -e "${B}${BCYN}║${R}  ${B}swap_stats.sh${R} — Swap Compression Monitor & Verifier   ${B}${BCYN}║${R}"
    echo -e "${B}${BCYN}╚══════════════════════════════════════════════════════════╝${R}"
    echo ""
    echo -e "  ${B}Usage:${R} $0 [mode] [options]"
    echo ""
    echo -e "  ${B}Modes:${R}"
    echo -e "    ${BGRN}(default)${R}              Full summary of all parameters & usage"
    echo -e "    ${BGRN}-v${R} [duration] [sample] Verify activity over time (default: 10s/1s)"
    echo -e "    ${BGRN}-w${R} [interval]          Watch mode with auto-refresh (default: 3s)"
    echo -e "    ${BGRN}-a${R} [duration] [sample] Summary + Verify combined"
    echo -e "    ${BGRN}-h${R}                     This help"
    echo ""
    echo -e "  ${B}Examples:${R}"
    echo -e "    ${D}\$ ./swap_stats.sh${R}            # quick summary"
    echo -e "    ${D}\$ ./swap_stats.sh -v 20 2${R}    # verify for 20s, sample every 2s"
    echo -e "    ${D}\$ ./swap_stats.sh -w 5${R}       # watch every 5s"
    echo -e "    ${D}\$ ./swap_stats.sh -a 15${R}      # summary + 15s verify"
    echo ""
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v) MODE="verify"
            [[ "${2:-}" =~ ^[0-9]+$ ]] && { VERIFY_DURATION="$2"; shift; }
            [[ "${2:-}" =~ ^[0-9]+$ ]] && { VERIFY_SAMPLE="$2"; shift; }
            shift ;;
        -w) MODE="watch"
            [[ "${2:-}" =~ ^[0-9]+$ ]] && { WATCH_INTERVAL="$2"; shift; }
            shift ;;
        -a) MODE="all"
            [[ "${2:-}" =~ ^[0-9]+$ ]] && { VERIFY_DURATION="$2"; shift; }
            [[ "${2:-}" =~ ^[0-9]+$ ]] && { VERIFY_SAMPLE="$2"; shift; }
            shift ;;
        -h|--help) usage ;;
        *)  echo -e "${BRED}Unknown option:${R} $1" >&2; usage ;;
    esac
done

# ══════════════════════════════════════════════════════════════════════
#  HELPERS
# ══════════════════════════════════════════════════════════════════════

read_safe() {
    local file="$1"
    if [[ -f "$file" ]] && [[ -r "$file" ]]; then
        cat "$file" 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

read_num() {
    local v; v=$(read_safe "$1")
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "0"
}

bytes_to_human() {
    local b="$1"
    if [[ "$b" =~ ^-?[0-9]+$ ]] && (( b != 0 )); then
        local abs=${b#-} sign=""
        (( b < 0 )) && sign="-"
        awk -v b="$abs" -v s="$sign" 'BEGIN {
            if (b >= 1073741824) printf "%s%.2f GiB", s, b/1073741824
            else if (b >= 1048576) printf "%s%.1f MiB", s, b/1048576
            else if (b >= 1024)    printf "%s%.1f KiB", s, b/1024
            else                   printf "%s%d B", s, b
        }'
    else
        echo "0"
    fi
}

get_active() {
    echo "$1" | grep -o '\[[^]]*\]' | tr -d '[]' || echo "$1"
}

# ── formatted output helpers ─────────────────────────────────────────

# Section header with box drawing
section() {
    local title="$1" color="${2:-$BCYN}"
    echo ""
    echo -e "  ${color}┌─── ${B}${title}${R}${color} ───────────────────────────────────────────${R}"
}

# Key-value pair with colors
kv() {
    local key="$1" val="$2" color="${3:-$WHT}"
    printf "  ${CYN}│${R}  %-26s " "$key"
    echo -e "${color}${val}${R}"
}

# Key-value with status indicator
kv_status() {
    local key="$1" val="$2" status="$3"
    local icon color
    case "$status" in
        good)    icon="●"; color="$BGRN" ;;
        warn)    icon="●"; color="$BYLW" ;;
        bad)     icon="●"; color="$BRED" ;;
        info)    icon="◆"; color="$BCYN" ;;
        neutral) icon="○"; color="$WHT" ;;
        *)       icon="·"; color="$WHT" ;;
    esac
    printf "  ${CYN}│${R}  %-26s " "$key"
    echo -e "${color}${icon} ${val}${R}"
}

# Section footer
section_end() {
    echo -e "  ${CYN}└──────────────────────────────────────────────────────────${R}"
}

# Progress bar (width=30)
progress_bar() {
    local pct="$1" width=30 color="${2:-$BGRN}"
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    (( filled > 0 )) && bar+=$(printf "%0.s█" $(seq 1 $filled))
    (( empty > 0 ))  && bar+=$(printf "%0.s░" $(seq 1 $empty))

    # Color based on percentage
    if (( pct >= 90 )); then color="$BRED"
    elif (( pct >= 70 )); then color="$BYLW"
    fi
    printf "${color}%s${R} %3d%%" "$bar" "$pct"
}

# Delta display with arrow
delta_fmt() {
    local val="$1" unit="${2:-}"
    if (( val > 0 )); then
        echo -e "${BGRN}▲ +${val}${unit}${R}"
    elif (( val < 0 )); then
        echo -e "${BRED}▼ ${val}${unit}${R}"
    else
        echo -e "${D}── 0${unit}${R}"
    fi
}

# Banner
banner() {
    local text="$1" bg="${2:-$BG_BLU}"
    local pad=$(( (58 - ${#text}) / 2 ))
    local lpad=$(printf "%${pad}s" "")
    local rpad=$(printf "%$(( 58 - ${#text} - pad ))s" "")
    echo -e "  ${bg} ${lpad}${text}${rpad} ${R}"
}

# ══════════════════════════════════════════════════════════════════════
#  DETECTION
# ══════════════════════════════════════════════════════════════════════

ZSWAP_ENABLED=false
ZRAM_ACTIVE=false
ZSWAP_DIR="/sys/kernel/debug/zswap"
BACKEND="none"

zswap_en=$(read_safe /sys/module/zswap/parameters/enabled)
[[ "$zswap_en" == "Y" || "$zswap_en" == "1" ]] && ZSWAP_ENABLED=true

if swapon --show=NAME 2>/dev/null | grep -q zram; then
    ZRAM_ACTIVE=true
elif [[ -b /dev/zram0 ]] && [[ -f /sys/block/zram0/mm_stat ]]; then
    local_orig=$(awk '{print $1}' /sys/block/zram0/mm_stat 2>/dev/null || echo 0)
    (( local_orig > 0 )) && ZRAM_ACTIVE=true
fi

if $ZSWAP_ENABLED; then
    BACKEND="zswap"
elif $ZRAM_ACTIVE; then
    BACKEND="zram"
fi

# ══════════════════════════════════════════════════════════════════════
#  SUMMARY PRINTERS
# ══════════════════════════════════════════════════════════════════════

print_header() {
    echo ""
    echo -e "  ${BCYN}╔══════════════════════════════════════════════════════════╗${R}"
    echo -e "  ${BCYN}║${R}${B}        ⚡ SWAP COMPRESSION MONITOR ⚡                   ${BCYN}║${R}"
    echo -e "  ${BCYN}╠══════════════════════════════════════════════════════════╣${R}"
    printf "  ${BCYN}║${R}  %-18s ${BWHT}%s${R}%*s${BCYN}║${R}\n" "Time:" "$(date '+%F %T')" 19 ""
    printf "  ${BCYN}║${R}  %-18s " "Backend:"
    case "$BACKEND" in
        zswap) printf "${BG_BLU} ZSWAP ${R}%*s${BCYN}║${R}\n" 31 "" ;;
        zram)  printf "${BG_MAG} ZRAM  ${R}%*s${BCYN}║${R}\n" 31 "" ;;
        none)  printf "${BG_RED} NONE  ${R}%*s${BCYN}║${R}\n" 31 "" ;;
    esac
    printf "  ${BCYN}║${R}  %-18s ${BWHT}%s${R}%*s${BCYN}║${R}\n" "Hostname:" "$(hostname -s)" $((37 - ${#HOSTNAME})) ""
    echo -e "  ${BCYN}╚══════════════════════════════════════════════════════════╝${R}"
}

print_zswap_params() {
    section "zswap Module Parameters" "$BBLU"
    local en=$(read_safe /sys/module/zswap/parameters/enabled)
    if [[ "$en" == "Y" || "$en" == "1" ]]; then
        kv_status "enabled" "YES" "good"
    else
        kv_status "enabled" "NO" "neutral"
    fi
    kv "compressor"           "$(read_safe /sys/module/zswap/parameters/compressor)" "$BWHT"
    kv "zpool"                "$(read_safe /sys/module/zswap/parameters/zpool)" "$WHT"
    kv "max_pool_percent"     "$(read_safe /sys/module/zswap/parameters/max_pool_percent)%" "$WHT"
    kv "accept_threshold_pct" "$(read_safe /sys/module/zswap/parameters/accept_threshold_percent)%" "$WHT"
    section_end
}

print_zswap_usage() {
    section "zswap Usage Statistics" "$BBLU"
    if [[ ! -d "$ZSWAP_DIR" ]]; then
        kv_status "debugfs" "NOT MOUNTED ($ZSWAP_DIR)" "warn"
        kv "hint" "sudo mount -t debugfs none /sys/kernel/debug" "$D"
        section_end
        return
    fi

    local pool_size stored_pages
    pool_size=$(read_num "$ZSWAP_DIR/pool_total_size")
    stored_pages=$(read_num "$ZSWAP_DIR/stored_pages")
    local logical=$(( stored_pages * 4096 ))
    local ratio="0.00"
    (( pool_size > 0 )) && ratio=$(awk -v a="$logical" -v b="$pool_size" 'BEGIN{printf "%.2f", a/b}')

    kv "pool_total_size"  "$(bytes_to_human "$pool_size")  ${D}($pool_size B)${R}" "$BWHT"
    kv "stored_pages"     "$stored_pages" "$WHT"
    kv "logical_stored"   "$(bytes_to_human "$logical")  ${D}($logical B)${R}" "$BWHT"

    # Compression ratio with visual gauge
    local ratio_int=${ratio%.*}
    local ratio_color="$BGRN"
    (( ratio_int < 2 )) && ratio_color="$BYLW"
    (( ratio_int < 1 )) && ratio_color="$BRED"
    kv "compression_ratio" "${ratio_color}${ratio}x${R}" "$R"

    local rr=$(read_safe "$ZSWAP_DIR/reject_reclaim_fail")
    local ra=$(read_safe "$ZSWAP_DIR/reject_alloc_fail")
    local rk=$(read_safe "$ZSWAP_DIR/reject_kmemcache_fail")
    [[ "$rr" != "0" ]] && kv_status "reject_reclaim" "$rr" "warn" || kv "reject_reclaim" "$rr" "$D"
    [[ "$ra" != "0" ]] && kv_status "reject_alloc" "$ra" "warn" || kv "reject_alloc" "$ra" "$D"
    [[ "$rk" != "0" ]] && kv_status "reject_kmemcache" "$rk" "warn" || kv "reject_kmemcache" "$rk" "$D"

    local wb=$(read_safe "$ZSWAP_DIR/written_back_pages")
    [[ "$wb" != "N/A" ]] && kv "written_back_pages" "$wb" "$WHT"
    section_end
}

print_zram_params() {
    section "zram Block Device" "$BMAG"
    if [[ ! -d /sys/block/zram0 ]]; then
        kv_status "zram0" "NOT FOUND" "bad"
        section_end
        return
    fi

    local algo disksize
    algo=$(get_active "$(read_safe /sys/block/zram0/comp_algorithm)")
    disksize=$(read_num /sys/block/zram0/disksize)

    kv "comp_algorithm" "$algo" "$BWHT"
    kv "disksize"       "$(bytes_to_human "$disksize")  ${D}($disksize B)${R}" "$BWHT"
    kv "mem_limit"      "$(read_safe /sys/block/zram0/mem_limit)" "$WHT"

    local bs=$(read_safe /sys/block/zram0/batch_size)
    [[ "$bs" != "N/A" ]] && kv "batch_size" "$bs" "$WHT"
    section_end
}

print_zram_usage() {
    section "zram Usage Statistics" "$BMAG"
    local mm_stat="/sys/block/zram0/mm_stat"
    if [[ ! -f "$mm_stat" ]]; then
        kv_status "mm_stat" "NOT AVAILABLE" "bad"
        section_end
        return
    fi

    local orig compr mem_used mem_limit mem_max same_pages compacted huge_pages
    read -r orig compr mem_used mem_limit mem_max same_pages compacted huge_pages _ < "$mm_stat"

    local ratio="0.00"
    (( mem_used > 0 )) && ratio=$(awk -v a="$orig" -v b="$mem_used" 'BEGIN{printf "%.2f", a/b}')

    kv "orig_data_size"  "$(bytes_to_human "$orig")  ${D}($orig B)${R}" "$BWHT"
    kv "compr_data_size" "$(bytes_to_human "$compr")  ${D}($compr B)${R}" "$WHT"
    kv "mem_used_total"  "$(bytes_to_human "$mem_used")  ${D}($mem_used B)${R}" "$BWHT"
    kv "mem_used_max"    "$(bytes_to_human "$mem_max")" "$WHT"

    # Compression ratio with color coding
    local ratio_int=${ratio%.*}
    local rc="$BGRN"; (( ratio_int < 2 )) && rc="$BYLW"; (( ratio_int < 1 )) && rc="$BRED"
    kv "compression_ratio" "${rc}${ratio}x${R}  ${D}(orig / mem_used)${R}" "$R"

    # Usage bar if disksize > 0
    local disksize=$(read_num /sys/block/zram0/disksize)
    if (( disksize > 0 && orig > 0 )); then
        local usage_pct=$(( orig * 100 / disksize ))
        printf "  ${CYN}│${R}  %-26s %s\n" "disk usage" "$(progress_bar $usage_pct)"
    fi

    kv "same_pages"      "$same_pages" "$D"
    kv "pages_compacted" "$compacted" "$D"
    (( huge_pages > 0 )) && kv_status "huge_pages" "$huge_pages" "warn" || kv "huge_pages" "$huge_pages" "$D"

    # io_stat
    local io_stat="/sys/block/zram0/io_stat"
    if [[ -f "$io_stat" ]]; then
        local fr fw inv nf
        read -r fr fw inv nf _ < "$io_stat"
        (( fr > 0 )) && kv_status "failed_reads" "$fr" "bad" || kv "failed_reads" "$fr" "$D"
        (( fw > 0 )) && kv_status "failed_writes" "$fw" "bad" || kv "failed_writes" "$fw" "$D"
        kv "notify_free" "$nf" "$D"
    fi
    section_end
}

print_vm_params() {
    section "VM & Swap Tuning" "$BYLW"
    kv "swappiness"        "$(read_safe /proc/sys/vm/swappiness)" "$BWHT"
    kv "page-cluster"      "$(read_safe /proc/sys/vm/page-cluster)" "$WHT"
    kv "overcommit_memory" "$(read_safe /proc/sys/vm/overcommit_memory)" "$WHT"

    local rb=$(read_safe /proc/sys/vm/reclaim-batchsize)
    [[ "$rb" != "N/A" ]] && kv "reclaim-batchsize" "$rb" "$WHT"
    local sra=$(read_safe /sys/kernel/mm/swap/singlemapped_ra_enabled)
    [[ "$sra" != "N/A" ]] && kv "singlemapped_ra" "$sra" "$WHT"
    section_end
}

print_thp_params() {
    section "Transparent Hugepage (THP)" "$BYLW"
    if [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        local thp_val=$(get_active "$(read_safe /sys/kernel/mm/transparent_hugepage/enabled)")
        case "$thp_val" in
            always)  kv_status "THP enabled" "$thp_val" "good" ;;
            madvise) kv_status "THP enabled" "$thp_val" "info" ;;
            never)   kv_status "THP enabled" "$thp_val" "neutral" ;;
            *)       kv "THP enabled" "$thp_val" "$WHT" ;;
        esac
    fi
    if [[ -f /sys/kernel/mm/transparent_hugepage/defrag ]]; then
        kv "THP defrag" "$(get_active "$(read_safe /sys/kernel/mm/transparent_hugepage/defrag)")" "$WHT"
    fi

    local has_mthp=false
    for size in 16kB 32kB 64kB 128kB 256kB 512kB 1024kB 2048kB; do
        local p="/sys/kernel/mm/transparent_hugepage/hugepages-${size}/enabled"
        if [[ -f "$p" ]]; then
            has_mthp=true
            local sv=$(get_active "$(read_safe "$p")")
            kv "  ${size}" "$sv" "$D"
        fi
    done
    $has_mthp || kv "mTHP" "not available" "$D"
    section_end
}

print_swap_devices() {
    section "Active Swap Devices" "$BGRN"
    local swap_info
    swap_info=$(swapon --show 2>/dev/null)
    if [[ -n "$swap_info" ]]; then
        echo "$swap_info" | while IFS= read -r line; do
            printf "  ${CYN}│${R}  %s\n" "$line"
        done
    else
        kv_status "swap" "No swap devices active" "warn"
    fi
    section_end
}

print_memory_summary() {
    section "System Memory" "$BGRN"

    # Parse /proc/meminfo for bars
    local mem_total mem_used mem_free swap_total swap_used
    mem_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    mem_free=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    mem_used=$(( mem_total - mem_free ))
    swap_total=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
    swap_used=$(( swap_total - $(awk '/^SwapFree:/ {print $2}' /proc/meminfo) ))

    local mem_pct=0 swap_pct=0
    (( mem_total > 0 ))  && mem_pct=$(( mem_used * 100 / mem_total ))
    (( swap_total > 0 )) && swap_pct=$(( swap_used * 100 / swap_total ))

    printf "  ${CYN}│${R}  %-13s %s  ${D}%s / %s${R}\n" "RAM:" \
        "$(progress_bar $mem_pct)" \
        "$(bytes_to_human $(( mem_used * 1024 )))" \
        "$(bytes_to_human $(( mem_total * 1024 )))"
    printf "  ${CYN}│${R}  %-13s %s  ${D}%s / %s${R}\n" "Swap:" \
        "$(progress_bar $swap_pct)" \
        "$(bytes_to_human $(( swap_used * 1024 )))" \
        "$(bytes_to_human $(( swap_total * 1024 )))"
    section_end
}

print_iaa_info() {
    section "IAA / DSA Accelerators" "$BMAG"
    local sync_mode=$(read_safe /sys/bus/dsa/drivers/crypto/sync_mode)
    [[ "$sync_mode" != "N/A" ]] && kv "crypto sync_mode" "$sync_mode" "$WHT"

    if [[ -d /sys/bus/dsa/devices ]]; then
        local count=$(ls /sys/bus/dsa/devices/ 2>/dev/null | grep -c "iax" || echo "0")
        if (( count > 0 )); then
            kv_status "IAA devices" "$count found" "good"
        else
            kv_status "IAA devices" "0 (none configured)" "neutral"
        fi
    else
        kv_status "DSA bus" "not available" "neutral"
    fi

    local rh=$(read_safe /sys/module/zhybrid/parameters/range_high)
    local rl=$(read_safe /sys/module/zhybrid/parameters/range_low)
    if [[ "$rh" != "N/A" ]]; then
        kv "zhybrid range_high" "$rh" "$WHT"
        kv "zhybrid range_low"  "$rl" "$WHT"
    fi
    section_end
}

print_cgroup_stats() {
    local cg="/sys/fs/cgroup/redisbench"
    [[ -d "$cg" ]] || return

    section "cgroup: redisbench" "$BYLW"
    local mem_cur=$(read_num "$cg/memory.current")
    local mem_peak=$(read_num "$cg/memory.peak")
    local mem_max=$(read_safe "$cg/memory.max")
    local swap_cur=$(read_num "$cg/memory.swap.current")
    local swap_peak=$(read_num "$cg/memory.swap.peak")

    kv "memory.current"      "$(bytes_to_human "$mem_cur")" "$BWHT"
    kv "memory.peak"         "$(bytes_to_human "$mem_peak")" "$BWHT"
    kv "memory.max"          "$mem_max" "$WHT"

    # Show usage bar if max is numeric
    if [[ "$mem_max" =~ ^[0-9]+$ ]] && (( mem_max > 0 )); then
        local cg_pct=$(( mem_cur * 100 / mem_max ))
        printf "  ${CYN}│${R}  %-26s %s\n" "cgroup usage" "$(progress_bar $cg_pct)"
    fi

    kv "memory.swap.current" "$(bytes_to_human "$swap_cur")" "$WHT"
    kv "memory.swap.peak"    "$(bytes_to_human "$swap_peak")" "$WHT"
    section_end
}

# ── combined summary ─────────────────────────────────────────────────

print_summary() {
    print_header

    case "$BACKEND" in
        zswap)
            print_zswap_params
            print_zswap_usage
            [[ -d /sys/block/zram0 ]] && print_zram_params
            ;;
        zram)
            print_zram_params
            print_zram_usage
            [[ -d /sys/module/zswap ]] && print_zswap_params
            ;;
        none)
            echo ""
            banner "⚠  No active swap compression detected  ⚠" "$BG_YLW"
            echo ""
            [[ -d /sys/module/zswap ]] && print_zswap_params
            [[ -d /sys/block/zram0 ]]  && print_zram_params
            ;;
    esac

    print_vm_params
    print_thp_params
    print_iaa_info
    print_swap_devices
    print_memory_summary
    print_cgroup_stats
    echo ""
}

# ══════════════════════════════════════════════════════════════════════
#  VERIFY MODE
# ══════════════════════════════════════════════════════════════════════

declare -A SNAP

take_zswap_snap() {
    local p="$1"
    SNAP[${p}_pool]=$(read_num "$ZSWAP_DIR/pool_total_size")
    SNAP[${p}_stored]=$(read_num "$ZSWAP_DIR/stored_pages")
    SNAP[${p}_reject_reclaim]=$(read_num "$ZSWAP_DIR/reject_reclaim_fail")
    SNAP[${p}_reject_alloc]=$(read_num "$ZSWAP_DIR/reject_alloc_fail")
    SNAP[${p}_reject_kmem]=$(read_num "$ZSWAP_DIR/reject_kmemcache_fail")
    SNAP[${p}_writeback]=$(read_num "$ZSWAP_DIR/written_back_pages")
    SNAP[${p}_logical]=$(( ${SNAP[${p}_stored]} * 4096 ))
}

take_zram_snap() {
    local p="$1" mm="/sys/block/zram0/mm_stat"
    if [[ -f "$mm" ]]; then
        read -r orig compr mem_used mem_limit mem_max same compact huge _ < "$mm"
    else
        orig=0; compr=0; mem_used=0; mem_limit=0; mem_max=0; same=0; compact=0; huge=0
    fi
    SNAP[${p}_orig]=$orig; SNAP[${p}_compr]=$compr
    SNAP[${p}_mem_used]=$mem_used; SNAP[${p}_mem_max]=$mem_max
    SNAP[${p}_same]=$same; SNAP[${p}_compact]=$compact; SNAP[${p}_huge]=$huge

    local io="/sys/block/zram0/io_stat"
    if [[ -f "$io" ]]; then
        read -r fr fw inv nf _ < "$io"
    else
        fr=0; fw=0; inv=0; nf=0
    fi
    SNAP[${p}_failed_reads]=$fr; SNAP[${p}_failed_writes]=$fw; SNAP[${p}_notify_free]=$nf
}

take_swap_snap() {
    local p="$1"
    SNAP[${p}_pswpin]=$(awk '/^pswpin / {print $2}' /proc/vmstat 2>/dev/null || echo 0)
    SNAP[${p}_pswpout]=$(awk '/^pswpout / {print $2}' /proc/vmstat 2>/dev/null || echo 0)
    SNAP[${p}_swap_used_kb]=$(awk '/^SwapFree:/ {free=$2} /^SwapTotal:/ {total=$2} END {print total-free}' /proc/meminfo 2>/dev/null || echo 0)
}

snap_delta() { echo $(( ${SNAP[after_$1]:-0} - ${SNAP[before_$1]:-0} )); }
snap_val()   { echo "${SNAP[after_$1]:-0}"; }

run_verify() {
    local dur="$VERIFY_DURATION" si="$VERIFY_SAMPLE"

    echo ""
    echo -e "  ${BCYN}╔══════════════════════════════════════════════════════════╗${R}"
    echo -e "  ${BCYN}║${R}${B}         🔍 SWAP BACKEND VERIFICATION 🔍                 ${BCYN}║${R}"
    echo -e "  ${BCYN}╚══════════════════════════════════════════════════════════╝${R}"

    # Quick config
    section "Active Configuration" "$BCYN"
    if $ZSWAP_ENABLED; then
        kv_status "zswap" "ENABLED" "good"
        kv "  compressor" "$(read_safe /sys/module/zswap/parameters/compressor)" "$WHT"
    else
        kv_status "zswap" "disabled" "neutral"
    fi
    if $ZRAM_ACTIVE; then
        kv_status "zram" "ACTIVE (swap)" "good"
        kv "  algorithm" "$(get_active "$(read_safe /sys/block/zram0/comp_algorithm)")" "$WHT"
        kv "  disksize"  "$(bytes_to_human "$(read_num /sys/block/zram0/disksize)")" "$WHT"
    else
        kv_status "zram" "inactive" "neutral"
    fi
    kv "swappiness" "$(read_safe /proc/sys/vm/swappiness)" "$WHT"
    section_end

    if ! $ZSWAP_ENABLED && ! $ZRAM_ACTIVE; then
        echo ""
        banner "ERROR: No swap compression backend active!" "$BG_RED"
        echo -e "  ${RED}Configure zswap or zram before running benchmarks.${R}"
        return 1
    fi

    # Snapshots
    take_swap_snap "before"
    $ZSWAP_ENABLED && take_zswap_snap "before"
    $ZRAM_ACTIVE   && take_zram_snap  "before"

    # Live progress with animated bar
    section "Monitoring (${dur}s, sample every ${si}s)" "$BCYN"
    local samples=0 elapsed=0
    while (( elapsed < dur )); do
        sleep "$si"
        elapsed=$(( elapsed + si ))
        samples=$(( samples + 1 ))

        local cur_swap_kb
        cur_swap_kb=$(awk '/^SwapFree:/ {free=$2} /^SwapTotal:/ {total=$2} END {print total-free}' /proc/meminfo)
        local swap_delta_kb=$(( cur_swap_kb - ${SNAP[before_swap_used_kb]} ))
        local prog_pct=$(( elapsed * 100 / dur ))
        local prog_bar=$(progress_bar $prog_pct "$BCYN")

        printf "\r  ${CYN}│${R}  %s  ${D}swap Δ:${R} %+6d KiB" "$prog_bar" "$swap_delta_kb"
    done
    echo ""
    section_end

    # After snapshots
    take_swap_snap "after"
    $ZSWAP_ENABLED && take_zswap_snap "after"
    $ZRAM_ACTIVE   && take_zram_snap  "after"

    # Results
    local d_pswpin=$(snap_delta pswpin) d_pswpout=$(snap_delta pswpout) d_swap_kb=$(snap_delta swap_used_kb)

    section "Results — vmstat" "$BGRN"
    printf "  ${CYN}│${R}  %-26s %s\n" "pages swapped in" "$(delta_fmt $d_pswpin)"
    printf "  ${CYN}│${R}  %-26s %s\n" "pages swapped out" "$(delta_fmt $d_pswpout)"
    printf "  ${CYN}│${R}  %-26s %s\n" "swap used change" "$(delta_fmt $d_swap_kb " KiB")"
    kv "swap used (now)" "$(snap_val swap_used_kb) KiB" "$WHT"
    section_end

    local activity=false

    if $ZSWAP_ENABLED; then
        local d_pool=$(snap_delta pool) d_stored=$(snap_delta stored) d_logical=$(snap_delta logical)
        local d_reject_r=$(snap_delta reject_reclaim) d_reject_a=$(snap_delta reject_alloc) d_wb=$(snap_delta writeback)
        local pool_now=$(snap_val pool) stored_now=$(snap_val stored) logical_now=$(snap_val logical)

        local ratio="0.00"
        [[ "$pool_now" =~ ^[0-9]+$ ]] && (( pool_now > 0 )) && \
            ratio=$(awk -v a="$logical_now" -v b="$pool_now" 'BEGIN{printf "%.2f", a/b}')

        section "Results — zswap" "$BBLU"
        printf "  ${CYN}│${R}  %-26s %-20s %s\n" "pool_total_size" "$(bytes_to_human "$pool_now")" "$(delta_fmt $d_pool)"
        printf "  ${CYN}│${R}  %-26s %-20s %s\n" "stored_pages" "$stored_now" "$(delta_fmt $d_stored)"
        printf "  ${CYN}│${R}  %-26s %-20s %s\n" "logical_stored" "$(bytes_to_human "$logical_now")" "$(delta_fmt $d_logical)"
        kv "compression_ratio" "${ratio}x" "$BWHT"
        (( d_reject_r != 0 )) && printf "  ${CYN}│${R}  %-26s %s\n" "reject_reclaim" "$(delta_fmt $d_reject_r)"
        (( d_reject_a != 0 )) && printf "  ${CYN}│${R}  %-26s %s\n" "reject_alloc" "$(delta_fmt $d_reject_a)"
        (( d_wb != 0 )) && printf "  ${CYN}│${R}  %-26s %s\n" "written_back" "$(delta_fmt $d_wb)"
        section_end

        (( d_stored != 0 || d_pool != 0 )) && activity=true
    fi

    if $ZRAM_ACTIVE; then
        local d_orig=$(snap_delta orig) d_compr=$(snap_delta compr) d_mem=$(snap_delta mem_used)
        local d_same=$(snap_delta same) d_compact=$(snap_delta compact)
        local d_huge=$(snap_delta huge) d_nf=$(snap_delta notify_free)
        local orig_now=$(snap_val orig) mem_now=$(snap_val mem_used)

        local ratio="0.00"
        [[ "$mem_now" =~ ^[0-9]+$ ]] && (( mem_now > 0 )) && \
            ratio=$(awk -v a="$orig_now" -v b="$mem_now" 'BEGIN{printf "%.2f", a/b}')

        section "Results — zram" "$BMAG"
        printf "  ${CYN}│${R}  %-26s %-20s %s\n" "orig_data_size" "$(bytes_to_human "$orig_now")" "$(delta_fmt $d_orig)"
        printf "  ${CYN}│${R}  %-26s %-20s %s\n" "compr_data_size" "$(bytes_to_human "$(snap_val compr)")" "$(delta_fmt $d_compr)"
        printf "  ${CYN}│${R}  %-26s %-20s %s\n" "mem_used_total" "$(bytes_to_human "$mem_now")" "$(delta_fmt $d_mem)"
        kv "mem_used_max" "$(bytes_to_human "$(snap_val mem_max)")" "$WHT"
        kv "compression_ratio" "${ratio}x" "$BWHT"
        (( d_same != 0 ))    && printf "  ${CYN}│${R}  %-26s %s\n" "same_pages" "$(delta_fmt $d_same)"
        (( d_huge != 0 ))    && printf "  ${CYN}│${R}  %-26s %s\n" "huge_pages" "$(delta_fmt $d_huge)"
        (( d_compact != 0 )) && printf "  ${CYN}│${R}  %-26s %s\n" "pages_compacted" "$(delta_fmt $d_compact)"
        (( d_nf != 0 ))      && printf "  ${CYN}│${R}  %-26s %s\n" "notify_free" "$(delta_fmt $d_nf)"
        section_end

        (( d_orig != 0 || d_mem != 0 )) && activity=true
    fi

    # Final Verdict
    echo ""
    if $activity; then
        echo -e "  ${BG_GRN}                                                          ${R}"
        echo -e "  ${BG_GRN}   ✔ VERDICT: ${BACKEND^^} is ACTIVELY COMPRESSING            ${R}"
        echo -e "  ${BG_GRN}     Usage changed during the ${dur}s monitoring window       ${R}"
        echo -e "  ${BG_GRN}                                                          ${R}"
    else
        echo -e "  ${BG_YLW}                                                          ${R}"
        echo -e "  ${BG_YLW}   ○ VERDICT: ${BACKEND^^} is ENABLED but IDLE                ${R}"
        echo -e "  ${BG_YLW}     No usage change detected in ${dur}s                     ${R}"
        echo -e "  ${BG_YLW}     Apply memory pressure to trigger compression         ${R}"
        echo -e "  ${BG_YLW}                                                          ${R}"
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════

case "$MODE" in
    summary)
        print_summary
        ;;
    verify)
        run_verify
        ;;
    watch)
        while true; do
            clear
            print_summary
            echo -e "  ${D}Auto-refreshing in ${WATCH_INTERVAL}s… (Ctrl-C to stop)${R}"
            sleep "$WATCH_INTERVAL"
        done
        ;;
    all)
        print_summary
        run_verify
        ;;
esac
