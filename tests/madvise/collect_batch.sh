#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Top level script for collect datapoints for IAA batching

#
# select the number of IAA devices
iaa_devices=4
preserve_logs=0

while getopts "hd:p:" arg; do
  case $arg in
    h)
      echo "./collect_batch [-d <iaa_devices_per_socket>] [-p <1/0>]"
      echo "Example: ./collect_batch -d 1 -p 1. 1 IAA device_per_socket and preserve intermediate results"
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

# Configure IAA
#./enable_kernel_iaa.sh 0 1 ${iaa_devices} 8 2 async
./enable_iaa.sh -d ${iaa_devices} -m async
# Configure zswap and zram.
./enable_zswap.sh
# swap disk can be used instead of zram. However, zram will avoid any disk access overheads
./enable_zram.sh


# Install bpftrace if it is not available
if [ ! -f /usr/bin/bpftrace ]; then
    echo "Installing bpftrace..."
    install bpftrace -y || handle_error "Failed to install bpftrace"
fi

# Run batch sweeps for (de)compression batching
./collect_cbatch.sh ${preserve_logs} | tee cb_silesia.txt
./collect_dbatch.sh ${preserve_logs} | tee db_silesia.txt

# Generate report
echo -e "\n*** SWAP_OUT_BATCH_SUMMARY ****\n" 
grep swap_out cb_silesia.txt
echo -e "\n*** SWAP_IN_SUMMARY ****\n"
grep swap_in db_silesia.txt


# Preserve the logs or clear them as needed.
if [ "${preserve_logs}" == "1" ]; then
    echo -e "\nSaving temporary logs  for debugging purposes"
else
    echo -e "\nRemoving all the temporary logs"
    rm -f cb_silesia.txt db_silesia.txt
fi

