#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Configure IAA devices

# This script is responsible for configuring Intel Accelerator Architecture (IAA) devices
# for use with zswap compression. It accepts parameters for device count, work queues,
# engines, global queues, and consecutive descriptors, but has sensible defaults for all
# IAA-specific parameters.

VERIFY_COMPRESS_PATH="/sys/bus/dsa/drivers/crypto/verify_compress"

iax_dev_id="0cfe"
# Direct IAA device detection using lspci
num_iaa=$(lspci -d:${iax_dev_id} | wc -l)
sockets=$(lscpu | grep Socket | awk '{print $2}')
[[ $verbose == 1 ]] && echo "Found ${num_iaa} instances in ${sockets} sockets(s)"

# The same number of devices will be configured in each socket
device_num_per_socket=$(( num_iaa/sockets ))
num_iaa_per_socket=$(( num_iaa / sockets ))

verbose=0
mode="dedicated"
wq_type="kernel"
iaa_crypto_mode="sync"
verify_compress=0
iaa_engines=8
iaa_wqs=2
iaa_global_queues=1
iaa_global_consec_descs=1
distribute_comps="Y"
distribute_decomps="N"

# Function to handle errors
handle_error() {
    echo "Error: $1"
    exit 1
}

# Process arguments - unified approach for both short and long options
while [[ $# -gt 0 ]]; do
    case $1 in
        -d)
            device_num_per_socket="$2"
            shift 2
            ;;
        -q)
            iaa_wqs="$2"
            shift 2
            ;;
        -v)
            verbose=1
            shift
            ;;
        -c)
            verify_compress=1
            shift
            ;;
        
        --dc)
            distribute_comps="$2"
            shift 2
            ;;
        --dd)
            distribute_decomps="$2"
            shift 2
            ;;
        -h)
            echo "Usage: $0 [-d <device_count>][-q <wq_per_device>][-v][-c][--dc Y|N][--dd Y|N]"
            echo "       -d  - number of devices per socket (default: ${device_num_per_socket})"
            echo "       -q  - number of WQs per device (default: ${iaa_wqs})"
            echo "       -v  - verbose mode"
            echo "       -c  - enable verify compress"
            echo "       --dc Y|N - distribute compression operations (default: Y)"
            echo "       --dd Y|N - distribute decompression operations (default: N)"
            echo "       -h  - help"
            exit 0
            ;;

        *)
            echo "Invalid option: $1" >&2
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

LOG="configure_iaa.log"

# Update wq_size based on number of wqs
wq_size=$(( 128 / iaa_wqs ))

# Take care of the enumeration, if DSA is enabled.
dsa=`lspci -Dnn | grep -c 0b25`
# Set enumeration parameters for iax devices
first=0
step=1
[[ $dsa -gt 0 && -d /sys/bus/dsa/devices/dsa0 ]] && first=1 && step=2
[[ $verbose == 1 ]] && echo "first index: ${first}, step: ${step}"

# Switch to software compressors and disable IAAs to have a clean start
COMPRESSOR=/sys/module/zswap/parameters/compressor
last_comp=`cat ${COMPRESSOR}`
echo lzo > ${COMPRESSOR}

[[ $verbose == 1 ]] && echo "Disable IAA devices before configuring" 
for ((i = ${first}; i < ${step} * ${num_iaa}; i += ${step})); do
    for ((j = 0; j < ${iaa_wqs}; j += 1)); do
        cmd="accel-config disable-wq iax${i}/wq${i}.${j} >& /dev/null"
        [[ $verbose == 1 ]] && echo $cmd; eval $cmd
     done
    cmd="accel-config disable-device iax${i} >& /dev/null"
    [[ $verbose == 1 ]] && echo $cmd; eval $cmd
done


rmmod iaa_crypto
modprobe iaa_crypto

# apply crypto parameters
echo $verify_compress > ${VERIFY_COMPRESS_PATH} || handle_error "did not change verify_compress"

if [ -f /sys/bus/dsa/drivers/crypto/g_comp_wqs_per_iaa ];then
    echo ${iaa_global_queues} > /sys/bus/dsa/drivers/crypto/g_comp_wqs_per_iaa || handle_error "did not set g_comp_wqs_per_iaa"
elif [ -f /sys/bus/dsa/drivers/crypto/g_wqs_per_iaa ];then
    echo ${iaa_global_queues} > /sys/bus/dsa/drivers/crypto/g_wqs_per_iaa || handle_error "did not set g_wqs_per_iaa"
fi
if [ -f /sys/bus/dsa/drivers/crypto/g_consec_descs_per_gwq ];then
    echo ${iaa_global_consec_descs} > /sys/bus/dsa/drivers/crypto/g_consec_descs_per_gwq || handle_error "did not set g_consec_descs_per_gwq"
fi
echo ${iaa_crypto_mode} > /sys/bus/dsa/drivers/crypto/sync_mode || handle_error "could not set sync_mode"

# Set distribution parameters after module reload but before device configuration
if [ -f /sys/bus/dsa/drivers/crypto/distribute_comps ]; then
    echo "${distribute_comps}" > /sys/bus/dsa/drivers/crypto/distribute_comps || echo "Warning: Could not set distribute_comps"
    [[ $verbose == 1 ]] && echo "Set distribute_comps to ${distribute_comps}"
fi
if [ -f /sys/bus/dsa/drivers/crypto/distribute_decomps ]; then
    echo "${distribute_decomps}" > /sys/bus/dsa/drivers/crypto/distribute_decomps || echo "Warning: Could not set distribute_decomps" 
    [[ $verbose == 1 ]] && echo "Set distribute_decomps to ${distribute_decomps}"
fi

[[ $verbose == 1 ]] && echo "Configuring ${device_num_per_socket} device(s) out of $num_iaa_per_socket per socket"
if [ "${device_num_per_socket}" -le "${num_iaa_per_socket}" ]; then
    [[ $verbose == 1 ]] && echo "Configuring all devices"
    start=${first}
    end=$(( ${step} * ${device_num_per_socket} ))
else
   echo "ERROR: Not enough devices"
   exit
fi

# Enable all iax devices and wqs
for (( socket = 0; socket < ${sockets}; socket += 1 )); do
for ((i = ${start}; i < ${end}; i += ${step})); do

    [[ $verbose == 1 ]] && echo "Configuring iaa$i on socket ${socket}"

    for ((j = 0; j < ${iaa_engines}; j += 1)); do
        cmd="accel-config config-engine iax${i}/engine${i}.${j} --group-id=0"
        [[ $verbose == 1 ]] && echo $cmd; eval $cmd
    done

    # Config WQs
    for ((j = 0; j < ${iaa_wqs}; j += 1)); do
        #cmd="accel-config config-wq iax${i}/wq${i}.${j} -g 0 -s ${wq_size} -p 10 -m ${mode} -y ${wq_type} -n iaa_crypto${i}${j} -d crypto"
        cmd="accel-config config-wq iax${i}/wq${i}.${j} -g 0 -s ${wq_size} -p 10 -m ${mode} -y ${wq_type} -n iaa_crypto -d crypto"
        [[ $verbose == 1 ]] && echo $cmd; eval $cmd
     done

    # Enable Device and WQs
    cmd="accel-config enable-device iax${i}"
    [[ $verbose == 1 ]] && echo $cmd; eval $cmd >& /dev/null

    for ((j = 0; j < ${iaa_wqs}; j += 1)); do
        cmd="accel-config enable-wq iax${i}/wq${i}.${j}"
        [[ $verbose == 1 ]] && echo $cmd; eval $cmd >& /dev/null
     done

done
    start=$(( start + ${step} * ${num_iaa_per_socket} ))
    end=$(( start + (${step} * ${device_num_per_socket}) ))
done

# Restore the last compressor
echo "$last_comp" > ${COMPRESSOR}

# Print configuration summary
[[ $verbose == 1 ]] && {
    echo "Configured IAA devices:"
    accel-config list | grep iax
}

echo -e "\nDetailed IAA Configuration:"
total_devices=$(accel-config list | grep -c '"dev":"iax')
total_wqs=$(accel-config list | grep -c '"dev":"wq[0-9]*\.[0-9]*"')
echo "Number of IAA devices per socket: $(( total_devices / sockets ))"
[ ${total_devices} -gt 0 ] && echo "Work queues per IAA device: $(( total_wqs / total_devices ))" || echo "Work queues per IAA device: 0"
