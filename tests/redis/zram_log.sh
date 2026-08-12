#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
# Usage: sudo ./zram_log.sh [interval_sec] [out.csv]
#
# Collects zram statistics from /sys/block/zram0/mm_stat and /sys/block/zram0/stat
# CSV columns match zswap_log.sh (pool_bytes, stored_pages, logical_bytes, ratio)
# so that zswap_report.sh / benchmark.sh can consume either format unchanged.
#
# mm_stat fields (space-separated):
#   1: orig_data_size      - uncompressed size of data stored
#   2: compr_data_size     - compressed size of data stored
#   3: mem_used_total      - actual memory used (includes allocator overhead)
#   4: mem_limit            - memory limit (0 = no limit)
#   5: mem_used_max        - max memory ever used
#   6: same_pages          - pages filled with same element
#   7: pages_compacted     - pages compacted by zram
#   8: huge_pages           - incompressible pages
#   9: huge_pages_since     - (kernel 5.15+) huge pages written since boot
set -euo pipefail

ZRAM_STAT="/sys/block/zram0/mm_stat"
INTERVAL="${1:-1}"
OUT="${2:-zram.csv}"

[[ -f "$ZRAM_STAT" ]] || { echo "zram not found at $ZRAM_STAT"; exit 1; }
[[ "$EUID" -eq 0 ]] || { echo "Run as root: sudo $0 ..."; exit 1; }

# Output CSV header — same column names as zswap_log.sh for compatibility
echo "timestamp,pool_bytes,stored_pages,logical_bytes,ratio" > "$OUT"
echo "Logging zram every ${INTERVAL}s to $OUT (Ctrl-C to stop)"

trap 'echo; echo "Stopped. Saved: '"$OUT"'"; exit 0' INT TERM

while true; do
  ts="$(date +"%F %T")"
  read -r orig_data compr_data mem_used _rest < "$ZRAM_STAT" || continue

  # Validate numeric fields
  [[ "$orig_data" =~ ^[0-9]+$ ]] || continue
  [[ "$mem_used" =~ ^[0-9]+$ ]] || continue

  # Map to zswap-compatible columns:
  #   pool_bytes   = mem_used_total  (actual memory consumed, like zswap pool_total_size)
  #   logical_bytes = orig_data_size (uncompressed data, like 4096 * stored_pages)
  #   stored_pages = orig_data_size / 4096
  pool="$mem_used"
  logical="$orig_data"
  pages=$(( orig_data / 4096 ))

  if [[ "$pool" -gt 0 ]]; then
    ratio="$(awk -v a="$logical" -v b="$pool" 'BEGIN{printf "%.4f", a/b}')"
  else
    ratio="0"
  fi
  echo "$ts,$pool,$pages,$logical,$ratio" >> "$OUT"
  sleep "$INTERVAL"
done
