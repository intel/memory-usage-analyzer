#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025, Intel Corporation
#
# Runs zswap tests, placing results in a specified directory.
#
# Arguments:
#
#     compressor - ZSWAP compressor
#     basedir   - New directory under which to store the results
#                 (if not provided, current [date-time] will be used)
#

compressor=$1
basedir=$2

if [ -z "${basedir}" ]; then
    basedir=$(date '+%Y%m%d-%H%M%S')
fi

mkdir -p "${basedir}"

for subtest in len; do
    subtitle="${subtest}"-"${compressor}"
    script=./test-"${subtest}"
    dir="${basedir}"/"${subtest}"
    out="${dir}"/out
    trace="${dir}"/"${subtitle}".trace

    echo "========================================"
    echo "Test: ${subtitle}"
    echo "Results directory: ${dir}"
    echo "========================================"
    echo "Test: ${subtitle}" >/dev/kmsg

    mkdir -p "${dir}"

    echo "----------------------------------------"
    echo "Run ${script}"
    echo "----------------------------------------"
    "${script}" > "${out}"

    echo "----------------------------------------"
    echo "dump-zswap-hists-${subtest}"
    echo "----------------------------------------"
    ./dump-zswap-hists-"${subtest}" >> "${out}"

    echo "----------------------------------------"
    echo "calcpercent.py "${subtest}""
    echo "----------------------------------------"
    ./calcpercent.py "${out}" "${subtest}" 98 >> "${out}"

    echo "----------------------------------------"
    echo "cp /sys/kernel/debug/tracing/trace"
    echo "----------------------------------------"
    cp /sys/kernel/debug/tracing/trace "${trace}"

    echo "----------------------------------------"
    echo "trace_to_comp_avg.py"
    echo "----------------------------------------"
    if [[ "$compressor" == *"iaa"* ]]; then
	./trace_to_comp_avg.py -d "${dir}" -e zswap_batch_compress_len
    else
	./trace_to_comp_avg.py -d "${dir}" -e zswap_compress_len
    fi
done
