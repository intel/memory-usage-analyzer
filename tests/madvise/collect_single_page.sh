#!/usr/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Top level script to collect datapoints for single page (no batching)

# Initialize variables
iaa_devices=4
# Turn on this for preserving the intermediate results
preserve_logs=0

# Process input arguments
while getopts "hd:p:" arg; do
  case $arg in
    h)
      echo "./collect_single_page [-d <iaa_devices_per_socket>] [-p <1/0>]" 
      echo "Example: ./collect_single_page -d 1 -p 1. 1 IAA device_per_socket and preserve intermediate results" 
      exit
      ;;
    d)
      iaa_devices=$OPTARG
      ;;
    p)
      preserve_logs=$OPTARG
      ;;
  esac
done

echo "Number of IAA device: $iaa_devices"

# Configure IAA devices
./enable_kernel_iaa.sh 0 1 ${iaa_devices} 8 2 sync  
# Configure zswap and zram.
./enable_zswap.sh 
# swap disk can be used instead of zram. However, zram will avoid any disk access overheads
./enable_zram.sh

# Install bpftrace if it is not available
if [ ! -f /usr/bin/bpftrace ]; then
    echo "Installing bpftrace..."
    install bpftrace -y || handle_error "Failed to install bpftrace"
fi

# If QAT is avaialble in kernel, enable it as well
QAT_ENABLED_IN_KERNEL=`bpftrace -l | grep qat_comp_alg_compress | wc -l`
if [ ${QAT_ENABLED_IN_KERNEL} -gt 0 ]; then
    ./enable_qat.sh 
fi


# Select compression algorithms.
if [ ${QAT_ENABLED_IN_KERNEL} -gt 0 ]; then
    comp_list=("deflate-iaa-canned" "deflate-iaa" "lz4" "qat_deflate" "zstd")
else
    comp_list=("deflate-iaa-canned" "deflate-iaa" "lz4" "zstd" )
fi

# Other possible values for compressors
#comp_list=("deflate-iaa-canned" "deflate-iaa-dynamic" "deflate-iaa" "lz4" "lzo-rle" "lzo" "zstd" "qat_deflate")
# Select the datasets as needed
#dataset_list=("silesia.tar" "defconfig.out")
dataset_list=("silesia.tar" )
freq_list=("2000" )
cbatch_list=("1")
dbatch_list=("0")
mthp_list=("4kB")
# Other possible values
# make sure that there are spaces in the comma separated combo selection
#mthp_list=("4kB" "16kB"  "64kB" "16kB,32kB,64kB")

# clear old logs for a fresh start
./clear_logs.sh

for freq in "${freq_list[@]}"; do
  for dataset in "${dataset_list[@]}"; do
      echo -e "\nData Corpus: ${dataset}\n"
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
		   ./summarize_single_page.sh run.log | tee -a run.log
		   mthp_suffix=`echo ${mthp} | tr -d ' ' | tr ',' '_'`
	           result_dir="result_${freq}_${dataset}_c${cbatch}_d${dbatch}_${mthp_suffix}"
                   rm -rf ${result_dir}
                   echo "Copying results to ${result_dir}"
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



# Clear intermediate logs as needed
if [ "${preserve_logs}" == "1" ]; then
    echo "Saving temporary logs  for debugging purposes"
else
    echo "Removing all the temporary logs"
    ./clear_logs.sh
fi


