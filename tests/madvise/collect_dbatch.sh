#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Collect data for decompression batching
# The first part sweeps across different batch configurations for deflate-iaa and
# the second part focuses on the software compressors

# process arguments
preserve_logs=${1:-0};shift

comp_list=("deflate-iaa")
dataset_list=("silesia.tar")
freq_list=("2000" )
cbatch_list=("1")
dbatch_list=("0" "1" "2" "3" "4" "5")
# make sure that there are spaces in the comma separated combo selection
#mthp_list=("4kB" "16kB"  "64kB" "16kB,32kB,64kB")
mthp_list=("4kB")

# clear old logs for a fresh start
./clear_logs.sh


for freq in "${freq_list[@]}"; do
  for dataset in "${dataset_list[@]}"; do
      for cbatch in "${cbatch_list[@]}"; do
          for dbatch in "${dbatch_list[@]}"; do
              for mthp in "${mthp_list[@]}"; do
		  rm -r run.log
                  for comp in "${comp_list[@]}"; do
                      echo "Removing ${comp}_output"
                      rm -f ${comp}_output
                      echo $comp > /sys/module/zswap/parameters/compressor
                      echo "Collecting data for $comp at ${freq}MHz, cbatch ${cbatch}, dbatch ${dbatch}, mthp ${mthp}"
                      ./collect_bpftraces.sh -f ${freq} -t ${dataset} -c ${cbatch} -d ${dbatch} -m ${mthp} | tee -a run.log
                   done
                  ./process_bpftraces.py | tee -a run.log 
		   mthp_suffix=`echo ${mthp} | tr -d ' ' | tr ',' '_'`
	           result_dir="result_${freq}_${dataset}_c${cbatch}_d${dbatch}_${mthp_suffix}"
                   rm -rf ${result_dir}
                   echo "creating ${result_dir}"
                   mkdir ${result_dir}
                   cp *_output ${result_dir}
                   cp *.html ${result_dir}
                   cp *.xlsx ${result_dir}
                   cp perf_* ${result_dir}
		   cp run.log ${result_dir}
              done
          done
      done
  done
done

# Run single batch for software compressors

#comp_list=("lz4" "lzo-rle" "lzo" "zstd")
comp_list=("lz4" "zstd")
cbatch_list=("1")
dbatch_list=("0")

for freq in "${freq_list[@]}"; do
  for dataset in "${dataset_list[@]}"; do
      for cbatch in "${cbatch_list[@]}"; do
          for dbatch in "${dbatch_list[@]}"; do
              for mthp in "${mthp_list[@]}"; do
		  rm -r run.log
                  for comp in "${comp_list[@]}"; do
                      echo "Removing ${comp}_output"
                      rm -f ${comp}_output
                      echo $comp > /sys/module/zswap/parameters/compressor
                      echo "Collecting data for $comp at ${freq}MHz, cbatch ${cbatch}, dbatch ${dbatch}, mthp ${mthp}"
                      ./collect_bpftraces.sh -f ${freq} -t ${dataset} -c ${cbatch} -d ${dbatch} -m ${mthp} | tee -a run.log
                   done
                  ./process_bpftraces.py | tee -a run.log 
		   mthp_suffix=`echo ${mthp} | tr -d ' ' | tr ',' '_'`
	           result_dir="result_${freq}_${dataset}_c${cbatch}_d${dbatch}_${mthp_suffix}"
                   rm -rf ${result_dir}
                   echo "creating ${result_dir}"
                   mkdir ${result_dir}
                   cp *_output ${result_dir}
                   cp *.html ${result_dir}
                   cp *.xlsx ${result_dir}
                   cp perf_* ${result_dir}
		   cp run.log ${result_dir}
              done
          done
      done
  done
done

# Preserve the logs or clear them as needed.
if [ "${preserve_logs}" == "1" ]; then
    echo "Saving temporary logs  for debugging purposes"
else
    echo "Removing all the temporary logs"
    ./clear_logs.sh
fi
