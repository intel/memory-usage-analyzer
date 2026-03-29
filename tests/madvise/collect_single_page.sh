#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, I# If QAT is available in kernel, enable it as well
QAT_ENABLED_IN_KERNEL=$(bpftrace -l 2>/dev/null | grep qat_comp_alg_compress | wc -l)
if [ ${QAT_ENABLED_IN_KERNEL} -gt 0 ]; then
    echo "QAT detected in kernel, enabling..."
    ./enable_qat.sh || handle_error "Failed to enable QAT"
fi


comp_list=()
# Create the compression algorithm list. Keep the alphabetical order for easy reportingoration
#Description: Top level script to collect datapoints for single page (no batching)

# Error handling function
handle_error() {
    echo "ERROR: $1" >&2
    exit 1
}

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

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    handle_error "This script requires root privileges. Please run with sudo."
fi

# Configure IAA devices
if [ ${iaa_devices} -gt 0 ]; then
    echo "Configuring IAA with $iaa_devices device(s) per socket..."
    #./enable_kernel_iaa.sh 0 1 ${iaa_devices} 8 2 sync  
    ./enable_iaa.sh -d ${iaa_devices} -m sync || handle_error "Failed to configure IAA devices"
fi

# Configure zswap and zram.
echo "Configuring zswap..."
./enable_zswap.sh || handle_error "Failed to configure zswap"

# swap disk can be used instead of zram. However, zram will avoid any disk access overheads
echo "Configuring zram..."
./enable_zram.sh || handle_error "Failed to configure zram"

# Check for dataset
if [ ! -f "silesia.tar" ]; then
    echo "Dataset silesia.tar not found. Attempting to download..."
    wget --no-check-certificate http://wanos.co/assets/silesia.tar || handle_error "Failed to download silesia.tar"
fi

# Install bpftrace if it is not available
if [ ! -f /usr/bin/bpftrace ]; then
    echo "Installing bpftrace..."
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y bpftrace || handle_error "Failed to install bpftrace"
    elif command -v yum &> /dev/null; then
        yum install bpftrace -y || handle_error "Failed to install bpftrace"
    else
        handle_error "Package manager not found. Please install bpftrace manually."
    fi
fi

# If QAT is available in kernel, enable it as well
QAT_ENABLED_IN_KERNEL=`bpftrace -l | grep qat_comp_alg_compress | wc -l`
if [ ${QAT_ENABLED_IN_KERNEL} -gt 0 ]; then
    ./enable_qat.sh 
fi


comp_list=()
# Create the compression algorithm list. Keep the alphabetical order for easy reporting
if [ ${iaa_devices} -gt 0 ]; then
    comp_list+=("deflate-iaa")
    echo "Added deflate-iaa to compressor list"
fi
comp_list+=("lz4")
if [ ${QAT_ENABLED_IN_KERNEL} -gt 0 ]; then
    comp_list+=("qat_deflate")
    echo "Added qat_deflate to compressor list"
fi
comp_list+=("zstd")

echo "Final compressor list: ${comp_list[*]}"


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
echo "Clearing old logs..."
./clear_logs.sh

# Check if zswap module is loaded
if [ ! -d "/sys/module/zswap" ]; then
    handle_error "zswap kernel module is not loaded"
fi

for freq in "${freq_list[@]}"; do
  for dataset in "${dataset_list[@]}"; do
      echo -e "\nData Corpus: ${dataset}\n"
      for cbatch in "${cbatch_list[@]}"; do
          for dbatch in "${dbatch_list[@]}"; do
              for mthp in "${mthp_list[@]}"; do
                  # Remove old run log if it exists
                  [ -f run.log ] && rm -f run.log
                  
                  for comp in "${comp_list[@]}"; do
                      echo "Removing ${comp}_output if it exists"
                      [ -f "${comp}_output" ] && rm -f "${comp}_output"
                      
                      echo "Setting compressor to $comp"
                      echo "$comp" > /sys/module/zswap/parameters/compressor || handle_error "Failed to set compressor to $comp"
                      
                      echo "Collecting data for $comp at ${freq}MHz, cbatch ${cbatch}, dbatch ${dbatch}, mthp ${mthp}"
                      ./collect_bpftraces.sh -f ${freq} -t ${dataset} -c ${cbatch} -d ${dbatch} -m ${mthp} | tee -a run.log || 
                          handle_error "Failed to collect bpftraces for $comp"
                   done
                   echo "Processing bpftraces..."
                   ./process_bpftraces.py | tee -a run.log || handle_error "Failed to process bpftraces"
                   
                   echo "Summarizing results..."
                   ./summarize_single_page.sh run.log | tee -a run.log || handle_error "Failed to summarize results"
                   
                   mthp_suffix=$(echo ${mthp} | tr -d ' ' | tr ',' '_')
                   result_dir="result_${freq}_${dataset}_c${cbatch}_d${dbatch}_${mthp_suffix}"
                   
                   echo "Creating results directory: ${result_dir}"
                   [ -d "${result_dir}" ] && rm -rf "${result_dir}"
                   mkdir -p "${result_dir}" || handle_error "Failed to create results directory"
                   
                   echo "Copying results to ${result_dir}"
                   # Use for loop to handle case where no files match pattern
                   for file in *_output *.html *.xlsx perf_* run.log; do
                       if [ -f "$file" ]; then
                           cp "$file" "${result_dir}/" || handle_error "Failed to copy $file to results directory"
                       fi
                   done
                   
                   echo "Results saved to ${result_dir}"
              done
          done
      done
  done
done



# Clear intermediate logs as needed
if [ "${preserve_logs}" == "1" ]; then
    echo "Saving temporary logs for debugging purposes"
else
    echo "Removing all the temporary logs"
    ./clear_logs.sh
fi

echo "Collection completed successfully!"


