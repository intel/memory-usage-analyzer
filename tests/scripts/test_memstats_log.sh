#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
set -euo pipefail

THIS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

assert_value() {
    local field=$1 expected=$2 actual
    actual=$(awk -F, -v field="$field" '
        NR == 1 { for (column=1; column<=NF; column++) columns[$column]=column; next }
        NR == 2 { print $(columns[field]) }
    ' "$TMP_DIR/out.csv")
    [[ "$actual" == "$expected" ]] || {
        echo "$field: expected $expected, got $actual" >&2
        exit 1
    }
}

assert_numeric() {
    local field=$1
    local actual
    actual=$(awk -F, -v field="$field" '
        NR == 1 { for (column=1; column<=NF; column++) columns[$column]=column; next }
        NR == 2 { print $(columns[field]) }
    ' "$TMP_DIR/out.csv")
    [[ "$actual" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        echo "$field: expected a non-negative number, got $actual" >&2
        exit 1
    }
}

cat > "$TMP_DIR/memory.stat" <<'EOF'
anon 2000
file 1000
shmem 200
kernel 400
slab 300
zswap 70
zswapped 140
file_mapped 300
inactive_file 600
active_file 400
workingset_refault_file 7
pgfault 50
pgmajfault 2
pgscan 11
pgsteal 10
EOF
echo 5000 > "$TMP_DIR/memory.current"
echo 6000 > "$TMP_DIR/memory.peak"
echo 700 > "$TMP_DIR/memory.swap.current"
echo 800 > "$TMP_DIR/memory.swap.peak"
cat > "$TMP_DIR/memory.events" <<'EOF'
low 1
high 2
max 3
oom 4
oom_kill 5
EOF
cat > "$TMP_DIR/memory.pressure" <<'EOF'
some avg10=0.00 avg60=0.00 avg300=0.00 total=1234
full avg10=0.00 avg60=0.00 avg300=0.00 total=567
EOF

bash "$THIS_DIR/memstats_log.sh" --once "$TMP_DIR" 1 "$TMP_DIR/out.csv"
assert_numeric elapsed_seconds
assert_value memory_current_bytes 5000
assert_value memory_peak_bytes 6000
assert_value anon_bytes 2000
assert_value page_cache_bytes 800
assert_value zswapped_bytes 140
assert_value workingset_refault_file 7
assert_value pgscan 11
assert_value pressure_some_total_usec 1234
assert_value pressure_full_total_usec 567
assert_value event_oom_kill 5

cat > "$TMP_DIR/memory.stat" <<'EOF'
file 100
shmem 200
EOF
rm -f "$TMP_DIR/memory.current" "$TMP_DIR/memory.events"
bash "$THIS_DIR/memstats_log.sh" --once "$TMP_DIR/memory.stat" 0.1 "$TMP_DIR/out.csv"
assert_value memory_current_bytes 0
assert_value page_cache_bytes 0
assert_value event_oom 0

echo "memstats_log.sh tests passed"