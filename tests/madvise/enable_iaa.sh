#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Configure IAA devices

VERIFY_COMPRESS_PATH="/sys/bus/dsa/drivers/crypto/verify_compress"

iax_dev_id="0cfe"
num_iaa=$(lspci -d:${iax_dev_id} | wc -l)
sockets=$(lscpu | grep Socket | awk '{print $2}')
echo "Found ${num_iaa}  instances in ${sockets} sockets(s)"

#  The same number of devices will be configured in each socket, if there are  more than one socket
#  Normalize with respect to the number of sockets
device_num_per_socket=$(( num_iaa/sockets ))
num_iaa_per_socket=$(( num_iaa / sockets ))

iaa_wqs=2
verbose=0
iaa_engines=8
mode="dedicated"
wq_type="kernel"
iaa_crypto_mode="async"
verify_compress=0


# Function to handle errors
handle_error() {
    echo "Error: $1"
    exit 1
}

# Process arguments

while getopts "d:hm:q:vD" opt; do
  case $opt in
    d)
      device_num_per_socket=$OPTARG
      ;;
    m)
      iaa_crypto_mode=$OPTARG
      ;;
    q)
      iaa_wqs=$OPTARG
      ;;
    D)
      verbose=1
      ;;
    v)
      verify_compress=1
      ;;
    h)
      echo "Usage: $0 [-d <device_count>][-q <wq_per_device>][-v]"
      echo "       -d - number of devices"
      echo "       -q - number of WQs per device"
      echo "       -v - verbose mode"
      echo "       -h - help"
      exit
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit
      ;;
  esac
done

LOG="configure_iaa.log"

# Update wq_size based on number of wqs
wq_size=$(( 128 / iaa_wqs ))

# Take care of the enumeration, if DSA is enabled.
dsa=`lspci | grep -c 0b25`
#set first,step counters to correctly enumerate iax devices based on whether running on guest or host with or without dsa
first=0
step=1
[[ $dsa -gt 0 && -d /sys/bus/dsa/devices/dsa0 ]] && first=1 && step=2
echo "first index: ${first}, step: ${step}"


#
# Switch to software compressors and disable IAAs to have a clean start
#
COMPRESSOR=/sys/module/zswap/parameters/compressor
last_comp=`cat ${COMPRESSOR}`
echo lzo > ${COMPRESSOR}

echo "Disable IAA devices before configuring"

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
# Note: This is a temporary solution for during the kernel transition.
if [ -f /sys/bus/dsa/drivers/crypto/g_comp_wqs_per_iaa ];then
    echo 1 > /sys/bus/dsa/drivers/crypto/g_comp_wqs_per_iaa || handle_error "did not set g_comp_wqs_per_iaa"
elif [ -f /sys/bus/dsa/drivers/crypto/g_wqs_per_iaa ];then
    echo 1 > /sys/bus/dsa/drivers/crypto/g_wqs_per_iaa || handle_error "did not set g_wqs_per_iaa"
fi
if [ -f /sys/bus/dsa/drivers/crypto/g_consec_descs_per_gwq ];then
    echo 1 > /sys/bus/dsa/drivers/crypto/g_consec_descs_per_gwq || handle_error "did not set g_consec_descs_per_gwq"
fi
echo ${iaa_crypto_mode} > /sys/bus/dsa/drivers/crypto/sync_mode || handle_error "could not set sync_mode"



echo "Configuring ${device_num_per_socket} device(s) out of $num_iaa_per_socket per socket"
if [ "${device_num_per_socket}" -le "${num_iaa_per_socket}" ]; then
    echo "Configuring all devices"
    start=${first}
    end=$(( ${step} * ${device_num_per_socket} ))
else
   echo "ERROR: Not enough devices"
   exit
fi


#
# enable all iax devices and wqs
#
for (( socket = 0; socket < ${sockets}; socket += 1 )); do
for ((i = ${start}; i < ${end}; i += ${step})); do

    echo "Configuring iaa$i on socket ${socket}"

    for ((j = 0; j < ${iaa_engines}; j += 1)); do
        cmd="accel-config config-engine iax${i}/engine${i}.${j} --group-id=0"
        [[ $verbose == 1 ]] && echo $cmd; eval $cmd
    done

    # Config  WQs
    for ((j = 0; j < ${iaa_wqs}; j += 1)); do
        # Config WQ: group 0,  priority=10, mode=shared, type = kernel name=kernel, driver_name=crypto
        cmd="accel-config config-wq iax${i}/wq${i}.${j} -g 0 -s ${wq_size} -p 10 -m ${mode} -y ${wq_type} -n iaa_crypto${i}${j} -d crypto"
        [[ $verbose == 1 ]] && echo $cmd; eval $cmd
     done

    # Enable Device and WQs
    cmd="accel-config enable-device iax${i}"
    [[ $verbose == 1 ]] && echo $cmd; eval $cmd

    for ((j = 0; j < ${iaa_wqs}; j += 1)); do
        cmd="accel-config enable-wq iax${i}/wq${i}.${j}"
        [[ $verbose == 1 ]] && echo $cmd; eval $cmd
     done

done
    start=$(( start + ${step} * ${num_iaa_per_socket} ))
    end=$(( start + (${step} * ${device_num_per_socket}) ))
done

# Restore the last compressor
echo "$last_comp" > ${COMPRESSOR}

# Check if the configuration is correct
echo "Configured IAA devices:"
accel-config list | grep iax

