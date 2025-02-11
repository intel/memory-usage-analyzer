#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025, Intel Corporation
#
# Run madvise tests to measure ZSWAP IAA single-page/batching latency
# for (de)compress batch-sizes in [1, 32]. The tests can also be run with ZSTD
# for comparing (de)compress latency with IAA.
#
# Arguments:
#
#     frequency  - Core frequency to set using cpupower: default 2000 MHz.
#     platform   - Platform name suffix for output dir: default "EMR".
#
# Variables used:
#
#     compressor - ZSWAP compressor to use: default "deflate-iaa-canned":
#
#                  Choices:
#                  --------
#                  "deflate-iaa-canned"/"deflate-iaa"/"zstd".
#
#                  "deflate-iaa-canned": canned mode.
#                  "deflate-iaa": fixed mode.
#
# Pre-requisite:
#
# Run './configure_iaa.sh" exactly once after a reboot, and before running
# this script, to configure IAA devices, WQs and driver parameters.
#
# zswap_latency.sh itself can be run any number of times once IAA has been
# configured.
#
################################################################################

freq=${1:-2000}
platform=${2:-"EMR"}
timestamp=$(date '+%Y%m%d-%H%M%S')

# Build the madvise_test executable if not already built
if [ ! -f memory_madvise_readpages ]; then
    echo -e "\nBuilding memory_madvise_readpages..."
    gcc -o memory_madvise_readpages memory_madvise_readpages.c
fi

# Download the silesia.tar dataset if it is not present in datasets.
if [ ! -f datasets/silesia.tar ]; then
    echo -e "\nDownloading silesia.tar..."
    wget --no-check-certificate http://wanos.co/assets/silesia.tar
    mv silesia.tar datasets/
    echo -e "Done!\n"
fi

cpupower frequency-set -g performance --min ${freq}MHz --max ${freq}MHz > /dev/null

mkdir -p reports

echo -e "\n******************************************************************************************" | tee -a run.log latency_summaries.txt
echo | tee -a run.log latency_summaries.txt
echo "Starting ZSWAP [de]compress latency tests with core freq ${freq} MHz at ${timestamp}:" | tee -a run.log latency_summaries.txt

for compressor in "deflate-iaa-canned" "zstd"; do
    if [ $compressor == "zstd" ]; then
	batch_sizes='1'
	pc_vals='0'
    else
	batch_sizes='1 2 4 8 16 32'
	pc_vals='0 1 2 3 4 5'
    fi

    for pc in 0; do
	for mthp_size in 4; do

	    mkdir -p data/${timestamp}_${platform}_${freq}_${compressor}_mthp${mthp_size}k_pc${pc}_comp

	    echo | tee -a run.log
	    echo "================================================================================" | tee -a run.log
	    echo -e "Start BATCH-COMPRESS-LATENCY runs for folio size ${mthp_size}kB, ${compressor}:\nCOMPRESS batch-size in [${batch_sizes}]" | tee -a run.log
	    echo | tee -a run.log
	    echo "Run directory data/${timestamp}_${platform}_${freq}_${compressor}_mthp${mthp_size}k_pc${pc}_comp" | tee -a run.log
	    echo "================================================================================" | tee -a run.log
	    echo | tee -a run.log

	    for comp_batchsize in $batch_sizes; do

		echo "${compressor} vm.compress-batchsize ${comp_batchsize}..." | tee -a run.log
		./zswap_config.py -c ${compressor} -cb_sz ${comp_batchsize} --page-cluster ${pc} -mthp ${mthp_size} -pthp never -z zsmalloc >> run.log 2>&1
		numactl -C 1 ./run_suite_comp.sh ${compressor} data/${timestamp}_${platform}_${freq}_${compressor}_mthp${mthp_size}k_pc${pc}_comp/cb${comp_batchsize} >> run.log

		echo >> run.log
		echo "--------------------------------------------------------------------------------" >> run.log
		echo "VMSTATS, MTHP STATS, ZSWAP STATS:" >> run.log
		echo "--------------------------------------------------------------------------------" >> run.log
		source ./vmstat_short.sh ${mthp_size} >> run.log
		echo "--------------------------------------------------------------------------------" >> run.log
		source ./mthp_report.sh >> run.log
		echo "--------------------------------------------------------------------------------" >> run.log
		echo >> run.log
	    done

	    echo -e "\nDone!\n================================================================================" | tee -a run.log
	    echo | tee -a run.log

	    if [ $compressor == "zstd" ]; then
		lat_events="zswap_compress"
	    else
		lat_events="zswap_batch_compress"
	    fi

	    ./summarize_lat.sh data/${timestamp}_${platform}_${freq}_${compressor}_mthp${mthp_size}k_pc${pc}_comp ${compressor}_${mthp_size}k_pc_${pc} ${lat_events} >> reports/zswap_${timestamp}_${platform}_${freq}_${compressor}_mthp${mthp_size}k_pc${pc}_compress_latencies.txt
	done
    done

    for cb in 1; do
	for mthp_size in 4; do

	    mkdir -p data/${timestamp}_${platform}_${freq}_${compressor}_mthp${mthp_size}k_cb${cb}_decomp

	    echo | tee -a run.log
	    echo "================================================================================" | tee -a run.log
	    echo -e "Start BATCH-DECOMPRESS-LATENCY runs for folio size ${mthp_size}kB, ${compressor}:\nDECOMPRESS page-cluster in [${pc_vals}]" | tee -a run.log
	    echo | tee -a run.log
	    echo "Run directory data/${timestamp}_${platform}_${freq}_${compressor}_mthp${mthp_size}k_cb${cb}_decomp" | tee -a run.log
	    echo "================================================================================" | tee -a run.log
	    echo | tee -a run.log

	    for pc in $pc_vals; do

		decomp_batchsize=$((2**${pc}))
		echo "${compressor} vm.page-cluster ${pc} (decompress batchsize ${decomp_batchsize})..." | tee -a run.log
		./zswap_config.py -c ${compressor} -cb_sz ${cb} --page-cluster ${pc} -mthp ${mthp_size} -pthp never -z zsmalloc >> run.log 2>&1
		numactl -C 1 ./run_suite_decomp.sh ${compressor} ${decomp_batchsize} data/${timestamp}_${platform}_${freq}_${compressor}_mthp${mthp_size}k_cb${cb}_decomp/db${decomp_batchsize} >> run.log

		echo >> run.log
		echo "--------------------------------------------------------------------------------" >> run.log
		echo "VMSTATS, MTHP STATS, ZSWAP STATS:" >> run.log
		echo "--------------------------------------------------------------------------------" >> run.log
		source ./vmstat_short.sh ${mthp_size} >> run.log
		echo "--------------------------------------------------------------------------------" >> run.log
		source ./mthp_report.sh >> run.log
		echo "--------------------------------------------------------------------------------" >> run.log
		echo >> run.log
	    done

	    echo -e "\nDone!\n================================================================================" | tee -a run.log
	    echo | tee -a run.log

	    if [ $compressor == "zstd" ]; then
		lat_events="zswap_decompress"
	    else
		lat_events="zswap_decompress,zswap_batch_decompress"
	    fi

	    ./summarize_lat.sh data/${timestamp}_${platform}_${freq}_${compressor}_mthp${mthp_size}k_cb${cb}_decomp ${compressor}_${mthp_size}k_cb_${cb} ${lat_events} >> reports/zswap_${timestamp}_${platform}_${freq}_${compressor}_mthp${mthp_size}k_cb${cb}_decompress_latencies.txt
	done
    done
done

echo | tee -a run.log latency_summaries.txt
echo -e "\nSummary (all latencies are normalized per-page):\n------------------------------------------------" | tee -a run.log latency_summaries.txt

sed -i -e 's/0.00//g' reports/*${timestamp}*latencies*.txt

for compressor in "deflate-iaa-canned" "zstd"; do
    echo -e "\n\n${compressor}:" | tee -a run.log latency_summaries.txt
    if [[ "$compressor" == *"iaa"* ]]; then
	echo -e "-------------------" | tee -a run.log latency_summaries.txt
    else
	echo -e "-----" | tee -a run.log latency_summaries.txt
    fi
    cat reports/*${timestamp}*${compressor}*_compress_latencies*.txt | tee -a run.log latency_summaries.txt
    cat reports/*${timestamp}*${compressor}*_decompress_latencies*.txt | tee -a run.log latency_summaries.txt
done

echo | tee -a run.log latency_summaries.txt
echo -e "\nFinished ZSWAP [de]compress latency tests with core freq ${freq} MHz at ${timestamp}." | tee -a run.log latency_summaries.txt
echo | tee -a run.log latency_summaries.txt

echo -e "******************************************************************************************\n" | tee -a run.log latency_summaries.txt
