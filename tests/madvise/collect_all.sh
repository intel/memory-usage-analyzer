#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation
comp_list=("lz4" "lzo-rle" "lzo" "deflate-iaa" "deflate-iaa-canned" "zstd")

freq_list=("2500" "2900")
dataset_list=("silesia.tar" "defconfig.out")

for freq in "${freq_list[@]}"; do
  for dataset in "${dataset_list[@]}"; do
    for comp in "${comp_list[@]}"; do
      echo "Removing ${comp}_output"
      rm -f ${comp}_output
      echo $comp > /sys/module/zswap/parameters/compressor
      echo "Collecting data for $comp at ${freq}MHz"
      ./collect_bpftraces.sh -f $freq -t $dataset
    done
    ./process_bpftraces.py
    rm -rf result_$freq_$dataset
    echo "creating result_$freq_$dataset"
    mkdir result_${freq}_${dataset}
    cp *_output result_${freq}_${dataset}
    cp *.html result_${freq}_${dataset}
    cp *.xlsx result_${freq}_${dataset}
    cp perf_* result_${freq}_${dataset}
  done
done
