#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025, Intel Corporation
#
# Summarize a testsuite results directory into tables.
#
# Argument:
#
#     basedir - Directory containing results from running a testsuite
#     tag - comp_batchsize / pc
#

basedir=$1
tag=$2

data_file_suffix="_size_stats.csv"

targets=$(echo $(seq 0.05 0.05 0.95)" 0.98 0.99")

function extract_from_csv () {
    file=$1
    gawk 'BEGIN { \
             FS = ","; \
             split("'"${targets}"'", targets, " "); \
         } \
         NR > 1 { \
             a[NR] = $2; \
         } \
         END { \
             asort(a, a, "@val_num_asc"); \
             n = NR-1; \
	     printf("%d ", n); \
             for (i in targets) { \
                 printf("%g ", a[int(n * targets[i])]); \
             } \
         }' "${file}"
}

head_tformats=$(echo "${targets}" | sed 's/[^ ]*/%6s/g')
data_tformats=$(echo "${targets}" | sed 's/[^ ]*/%6d/g')

for event_type in zswap_compress_len zswap_batch_compress_len; do
    printed_header=0

    for dir in $(ls ${basedir} | sort -V); do
        title=$(basename "${dir}")
	if [ -f "${basedir}/${dir}"/len/*"${event_type}${data_file_suffix}" ]; then

	    if [ $printed_header == 0 ]; then
		printf '\n%-70s %10s '"${head_tformats}"' %10s\n' "${event_type}gth_(bytes)_${tag}" count ${targets} comp_ratio
		printed_header=1
	    fi

            values=$(extract_from_csv "${basedir}/${dir}"/len/*"${event_type}${data_file_suffix}")
            comp_ratio=$(cut -d' ' -f3 "${basedir}/${dir}"/len/*"${event_type}"_comp_avg.csv)

            printf '%-70s %10d '"${data_tformats}"' %10.2f\n' "${title}" ${values} "${comp_ratio}"
	fi
    done

done

