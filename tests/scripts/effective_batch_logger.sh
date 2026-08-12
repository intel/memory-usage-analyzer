#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

set -euo pipefail

MODE="ebpf"
OUT_CSV=""
OUT_LOG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --out-csv)
            OUT_CSV="$2"
            shift 2
            ;;
        --out-log)
            OUT_LOG="$2"
            shift 2
            ;;
        --help|-h)
            cat <<'EOF'
Usage:
  effective_batch_logger.sh --mode ebpf --out-csv <file> --out-log <file>

This script runs in the foreground. Caller should run it in background and stop it with SIGTERM.
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

if [[ "$MODE" != "ebpf" ]]; then
    echo "Unsupported mode: $MODE" >&2
    exit 1
fi

if [[ -z "$OUT_CSV" || -z "$OUT_LOG" ]]; then
    echo "--out-csv and --out-log are required" >&2
    exit 1
fi

if ! command -v bpftrace >/dev/null 2>&1; then
    echo "bpftrace not found in PATH" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT_CSV")" "$(dirname "$OUT_LOG")"
: > "$OUT_LOG"
: > "$OUT_CSV"
printf "timestamp,event,effective_pages,effective_bytes,nr_scanned\n" >> "$OUT_CSV"

bt_prog=$(cat <<'EOF'
kretprobe:reclaim_pages
{
    $p = retval;
    printf("%llu,effective_reclaim,%llu,%llu,-1\n", nsecs, $p, $p * 4096);
}

kprobe:swapin_readahead
{
    @ra_active[tid] = 1;
    @ra_pages[tid] = 0;
}

kprobe:swap_read_folio
/@ra_active[tid]/
{
    @ra_pages[tid] = @ra_pages[tid] + 1;
}

kretprobe:swapin_readahead
/@ra_active[tid]/
{
    $p = @ra_pages[tid];
    printf("%llu,effective_page_cluster,%lld,%lld,-1\n", nsecs, $p, $p * 4096);
    delete(@ra_active[tid]);
    delete(@ra_pages[tid]);
}
EOF
)

exec bpftrace -q -B none -e "$bt_prog" >> "$OUT_CSV" 2>> "$OUT_LOG"
