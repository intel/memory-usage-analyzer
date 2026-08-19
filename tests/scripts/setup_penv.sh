#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Shared helper to ensure a workload-local python venv (penv)
#             exists and has this repo's setup.py dependencies (matplotlib,
#             bokeh, pandas, ...) installed. Source this file, then call
#             setup_penv "<workload_dir>" to create/verify "<workload_dir>/penv"
#             and get PYTHON set to its interpreter.
#
# Example (from tests/redis/benchmark.sh):
#   source "${THIS_DIR}/../scripts/setup_penv.sh"
#   setup_penv "${THIS_DIR}"

SETUP_PENV_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SETUP_PENV_REPO_ROOT="$( cd "${SETUP_PENV_SCRIPT_DIR}/../.." && pwd )"

setup_penv() {
    local workload_dir="$1"
    local venv_dir="${workload_dir}/penv"

    if [[ ! -x "${venv_dir}/bin/python" ]]; then
        echo "=== Creating Python venv at ${venv_dir} ==="
        python3 -m venv "${venv_dir}" || { echo "ERROR: failed to create venv at ${venv_dir}"; exit 1; }
    fi

    # Debian/Ubuntu strip ensurepip's bundled pip from python3-venv, so a
    # freshly created venv can be missing pip entirely; bootstrap it.
    if ! "${venv_dir}/bin/python" -m pip --version >/dev/null 2>&1; then
        echo "=== Bootstrapping pip in ${venv_dir} ==="
        "${venv_dir}/bin/python" -m ensurepip --upgrade >/dev/null 2>&1
        if ! "${venv_dir}/bin/python" -m pip --version >/dev/null 2>&1; then
            curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py \
                && "${venv_dir}/bin/python" /tmp/get-pip.py >/dev/null
        fi
        if ! "${venv_dir}/bin/python" -m pip --version >/dev/null 2>&1; then
            echo "ERROR: pip unavailable in ${venv_dir}. Install it via: apt-get install -y python3-pip python3-venv" >&2
            exit 1
        fi
    fi

    if ! "${venv_dir}/bin/python" -c "import matplotlib, bokeh" >/dev/null 2>&1; then
        echo "=== Installing Python dependencies from ${SETUP_PENV_REPO_ROOT}/setup.py into ${venv_dir} ==="
        "${venv_dir}/bin/python" -m pip install --upgrade pip >/dev/null
        "${venv_dir}/bin/python" -m pip install "${SETUP_PENV_REPO_ROOT}" \
            || { echo "ERROR: failed to install dependencies from ${SETUP_PENV_REPO_ROOT}/setup.py"; exit 1; }
    fi

    if ! "${venv_dir}/bin/python" -c "import matplotlib, bokeh" >/dev/null 2>&1; then
        echo "ERROR: matplotlib/bokeh still not importable via ${venv_dir}/bin/python" >&2
        exit 1
    fi

    # Use the venv's python explicitly so callers still find matplotlib/pandas/etc.
    # even when invoked with sudo, which strips PATH/VIRTUAL_ENV and would
    # otherwise fall back to the system interpreter.
    PYTHON="${venv_dir}/bin/python"
}
