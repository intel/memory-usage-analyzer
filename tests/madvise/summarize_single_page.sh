#!/usr/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: A helper script to generate reports for single-page runs

# Summarizes the key metrics from single-page microbenchmarks

input_file=$1
echo -e "\n----Single_Page Summary Start----"

echo -e "\ncompress: p50 latency (ns)"
echo "--------------"
awk '/ C/ { printf("%-30s %s\n", $1, $3) }' ${input_file}

echo -e "\ndecompress: p50 latency (ns)"
echo "--------------"
awk '/ D/ { printf("%-30s %s\n", $1, $3) }' ${input_file}

echo -e "\nswap_writepage: p50 latency (ns)"
echo "--------------"
awk '/ SW/ { printf("%-30s %s\n", $1, $3) }' ${input_file}

echo -e "\nswap_read_folio: p50 latency (ns)"
echo "--------------"
awk '/ SR/ { printf("%-30s %s\n", $1, $3) }' ${input_file}

echo -e "\nCompression Ratio (uncompressed_size/compressed_size) at compress() call"
echo "--------------"
awk '/ R / { printf("%-30s %s\n", $1, $3) }' ${input_file}

echo -e "\nzpool_comp_ratio"
echo "--------------"
awk '/ zpool_comp_ratio/ { printf("%-30s %s\n", $1, $3) }' ${input_file}

echo -e "\nzpool_total_size (bytes)"
echo "--------------"
awk '/ zpool_total_size/ { printf("%-30s %s\n", $1, $3) }' ${input_file}

echo -e "\npages_rejected"
echo "--------------"
awk '/compress_errors/ { printf("%-30s %s\n", $1, $3) }' ${input_file}
echo -e "\n----Single_Page Summary End----\n"
