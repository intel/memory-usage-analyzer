#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
# Usage: sudo ./zswap_log.sh [interval_sec] [out.csv]
set -euo pipefail

ZDIR="/sys/kernel/debug/zswap"
INTERVAL="${1:-1}"
OUT="${2:-zswap.csv}"

[[ -d "$ZDIR" ]] || { echo "zswap not found at $ZDIR. Mount debugfs?"; exit 1; }
[[ "$EUID" -eq 0 ]] || { echo "Run as root: sudo $0 ..."; exit 1; }

echo "timestamp,pool_bytes,stored_pages,logical_bytes,ratio" > "$OUT"
echo "Logging zswap every ${INTERVAL}s to $OUT (Ctrl-C to stop)"

trap 'echo; echo "Stopped. Saved: '"$OUT"'"; exit 0' INT

while true; do
  ts="$(date +"%F %T")"
  pool="$(cat "$ZDIR/pool_total_size")"
  pages="$(cat "$ZDIR/stored_pages")"
  logical=$(( pages * 4096 ))
  if [[ "$pool" -gt 0 ]]; then
    ratio="$(awk -v a="$logical" -v b="$pool" 'BEGIN{printf "%.4f", a/b}')"
  else
    ratio="0"
  fi
  echo "$ts,$pool,$pages,$logical,$ratio" >> "$OUT"
  sleep "$INTERVAL"
done
