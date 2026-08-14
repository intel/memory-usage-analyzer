#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# Shared helpers for verifying compressed-swap compressor availability.
# Source this file from a script:  source "${THIS_DIR}/../scripts/compressor_lib.sh"

# Return the currently active compressor for a swap backend.
# Usage: active_compressor <zram|zswap>
active_compressor() {
    local mode="$1"
    if [[ "$mode" == "zram" ]]; then
        sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/block/zram0/comp_algorithm 2>/dev/null
    else
        cat /sys/module/zswap/parameters/compressor 2>/dev/null
    fi
}

# Verify the kernel actually activated the requested compressor. zram/zswap
# silently keep the previous compressor when the requested one is unavailable
# (e.g. deflate-iaa / deflate-iaa-dynamic without the iaa_crypto driver), so
# detect the mismatch and let the caller skip or abort the config.
# Usage: verify_compressor_active <zram|zswap> <requested_algo>
# Returns 0 on match, 1 (with a warning) on mismatch.
verify_compressor_active() {
    local mode="$1" want="$2" active
    active=$(active_compressor "$mode")
    if [[ "$active" != "$want" ]]; then
        echo "WARNING: ${mode} compressor '${want}' not available on this kernel (active: '${active}')" >&2
        return 1
    fi
    return 0
}

# Print an OS/kernel summary block describing whether deflate-iaa was usable on
# this kernel, mirroring the trailer emitted by tests/dd/run_dd.sh.
#   $1: space-separated deflate-iaa* algorithms that actually activated (may be empty)
#   $2: "true" if any deflate-iaa* config was attempted during the run
# Usage: print_iaa_support_summary "$ran_iaa_algos" "$iaa_attempted"
print_iaa_support_summary() {
    local ran_iaa="$1" attempted="${2:-false}" os_name
    os_name=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
    [[ -z "$os_name" ]] && os_name=$(uname -o 2>/dev/null || echo "unknown")
    echo "=========================================="
    echo "OS:     ${os_name}"
    echo "Kernel: $(uname -r) ($(uname -m))"
    if [[ -n "$ran_iaa" ]]; then
        echo "This OS/kernel SUPPORTS deflate-iaa (available: $(echo "$ran_iaa" | xargs))."
    elif [[ "$attempted" == "true" ]]; then
        echo "This OS/kernel does NOT support deflate-iaa (in-tree iaa_crypto driver not registered for zram)."
    fi
    echo "=========================================="
}
