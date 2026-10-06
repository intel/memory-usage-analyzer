#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# Verify zram across all four redis benchmarks. Runs each script with
# --swap-mode zram (all compressors, reduced data points) and collects every
# result directory under tests/scripts/zram_verify_results/.

set -u

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
RESULTS_ROOT="${THIS_DIR}/scripts/zram_verify_results"
RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RESULTS_DIR="${RESULTS_ROOT}/${RUN_STAMP}"

mkdir -p "${RESULTS_DIR}"
echo "=== zram verification run ${RUN_STAMP} ==="
echo "=== Results: ${RESULTS_DIR} ==="

summary=()

# run_one <label> <test_dir> <script> [extra args...]
run_one() {
    local label="$1" test_dir="$2" script="$3"; shift 3
    local outdir="${RESULTS_DIR}/${label}"
    local logfile="${RESULTS_DIR}/${label}.console.log"

    echo ""
    echo "============================================================"
    echo "=== Running ${label}: ${script} --swap-mode zram"
    echo "============================================================"

    mkdir -p "${outdir}"
    if ( cd "${test_dir}" && bash "./${script}" --swap-mode zram --logdir "${outdir}" "$@" ) 2>&1 | tee "${logfile}"; then
        echo "PASS  ${label}"
        summary+=("PASS  ${label}")
    else
        echo "FAIL  ${label} (see ${logfile})"
        summary+=("FAIL  ${label}")
    fi
}

run_one "redis_benchmark"       "${THIS_DIR}/redis"    "benchmark.sh"
run_one "redis_instance_sweep"  "${THIS_DIR}/redis"    "instance_sweep_script.sh"
run_one "redis_vm_benchmark"    "${THIS_DIR}/redis_vm" "benchmark.sh"
run_one "redis_vm_sweep"        "${THIS_DIR}/redis_vm" "vm_sweep_script.sh"

echo ""
echo "============================================================"
echo "=== zram verification summary (${RUN_STAMP})"
echo "============================================================"
for line in "${summary[@]}"; do
    echo "  ${line}"
done
echo "=== Results saved under ${RESULTS_DIR} ==="
