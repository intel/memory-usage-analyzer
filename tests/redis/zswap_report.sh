#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
# Usage: ./zswap_report.sh <in.csv>
set -euo pipefail

IN="${1:-}"
[[ -n "$IN" ]] || { echo "Usage: $0 <in.csv>"; exit 1; }
[[ -f "$IN" ]] || { echo "File not found: $IN"; exit 1; }

to_gib() { awk -v b="$1" 'BEGIN{printf "%.3f", b/1024/1024/1024}'; }

# Row where pool_bytes is max
peak_line="$(awk -F, 'NR>1 { if ($2+0 > m) { m=$2+0; line=$0 } } END { print line }' "$IN")"
[[ -n "$peak_line" ]] || { echo "No data rows in $IN"; exit 1; }

peak_ts="$(echo "$peak_line" | awk -F, '{print $1}')"
peak_pool="$(echo "$peak_line" | awk -F, '{print $2}')"
peak_pages="$(echo "$peak_line" | awk -F, '{print $3}')"
peak_logical="$(echo "$peak_line" | awk -F, '{print $4}')"
peak_ratio="$(echo "$peak_line" | awk -F, '{print $5}')"

samples="$(awk 'END{print NR-1}' "$IN")"
start_ts="$(awk -F, 'NR==2{print $1}' "$IN")"
end_ts="$(awk -F, 'END{print $1}' "$IN")"

echo "================ zswap report ================"
echo "File:        $IN"
echo "Samples:     $samples"
echo "Start:       $start_ts"
echo "End:         $end_ts"
echo "---------------------------------------------"
echo "Peak pool_total_size:"
echo "  Time:              $peak_ts"
echo "  Pool size:         $(to_gib "$peak_pool") GiB  ($peak_pool bytes)"
echo "  Stored pages:      $peak_pages"
echo "  Logical stored:    $(to_gib "$peak_logical") GiB  ($peak_logical bytes)"
echo "  Compression ratio: ${peak_ratio}x  (logical/pool at that time)"
echo "============================================="
