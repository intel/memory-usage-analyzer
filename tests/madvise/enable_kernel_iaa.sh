#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Configure IAA devices

IAX_CONFIG_PATH=/sys/bus/dsa/devices

IAX_BIND_PATH=/sys/bus/dsa/drivers/idxd/bind
IAX_BIND_WQ_PATH=/sys/bus/dsa/drivers/crypto/bind

IAX_UNBIND_PATH=/sys/bus/dsa/drivers/idxd/unbind
IAX_UNBIND_WQ_PATH=/sys/bus/dsa/drivers/crypto/unbind
VERIFY_COMPRESS_PATH=/sys/bus/dsa/drivers/crypto/verify_compress
COMPRESSOR=/sys/module/zswap/parameters/compressor

# Function to handle errors
handle_error() {
    echo "Error: $1"
    exit 1
}

last_comp=`cat ${COMPRESSOR}` 
# default compressor is changed to lzo in disabld_iaa
source ./disable_iaa

# input arg: if not 0, setup dedicated work queues (default: 0)
verify_compress=${1:-0}; shift
mode=${1:-1}; shift
iaa_devices=${1:-4}; shift
iaa_engines=${1:-8}; shift
iaa_wqs=${1:-2}; shift
iaa_crypto_mode=${1:-async}; shift
echo "enabled iaa_devices per socket: (${iaa_devices})"
echo "enabled iaa_engines per device: (${iaa_engines})"


# Get number of cores and sockets
sockets=$(lscpu | grep Socket | awk '{print $2}')
cores=$(lscpu | grep socket | awk '{print $4}')

if [ ${iaa_engines} -eq 8 ]; then
  engine_string=""
else
  engine_string="-engine-${iaa_engines}"
fi

if [ ${iaa_wqs} -ne 1 ]; then
  wq_string="-${iaa_wqs}wq"
else
  wq_string=""
fi


#
# select iax config
#
dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo ${dir}
if [ ${mode} -eq 0 ]; then
    config_json=${dir}/iax-${iaa_devices}${engine_string}${wq_string}-swq.json
elif [ ${mode} -eq 1 ]; then
    config_json=${dir}/iax-${iaa_devices}${engine_string}${wq_string}-dwq.json
else
    echo "unsupported mode ${mode}"
    exit
fi
echo $config_json



# apply verify-compress
echo $verify_compress > ${VERIFY_COMPRESS_PATH} || handle_error "did not change verify_compress"

echo 1 > /sys/bus/dsa/drivers/crypto/g_wqs_per_iaa || handle_error "did not set g_wqs_per_iaa"
echo 1 > /sys/bus/dsa/drivers/crypto/g_consec_descs_per_gwq || handle_error "did not set g_consec_descs_per_gwq"
echo ${iaa_crypto_mode} > /sys/bus/dsa/drivers/crypto/sync_mode || handle_error "could not set sync_mode"
#echo sync > /sys/bus/dsa/drivers/crypto/sync_mode || handle_error "could not set sync_mode"

#
# load iax config json
#
echo "Load IAX config: ${config_json}"
accel-config load-config -c ${config_json}

# Note: In some system, there will be more IAA devices per socket, but may wanted to limit the usage
# which may need special handling to align with the IAA device numbering

#
# count iax instances
#
iax_dev_id="0cfe"
num_iax_in_hw=$(lspci -d:${iax_dev_id} | wc -l)
iaa_devices_per_socket=$(( num_iax_in_hw/sockets ))
echo "iaa_devices_per_socket: ${iaa_devices_per_socket}"
if [ ${iaa_devices_per_socket} -gt ${iaa_devices} ]; then
    echo "WARNING: Changing the number of IAA devices to ${iaa_devices_per_socket}"
    iaa_devices=${iaa_devices_per_socket}
fi

#
# enable iax devices and wqs
num_iax=${iaa_devices}
socket_iax_start=1
socket_iax_end=$(($num_iax*2))
for ((socket = 0; socket < ${sockets}; socket += 1)); do
   
    echo "Enable IAX  (${iaa_devices})"
    for ((i = ${socket_iax_start}; i < ${socket_iax_end} ; i += 2)); do
        echo enable iax iax${i}
        echo iax${i} > $IAX_BIND_PATH
        for ((j = 0; j < ${iaa_wqs}; j += 1)); do
            echo enable wq wq${i}.${j}
            echo wq${i}.${j} > $IAX_BIND_WQ_PATH
        done
    done
    socket_iax_start=$(($socket_iax_start + ($num_iax)*2))
    socket_iax_end=$(($socket_iax_end + ($num_iax)*2))
done

echo "$last_comp" > ${COMPRESSOR} 
