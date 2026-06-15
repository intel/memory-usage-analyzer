#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

IAX_CONFIG_PATH=/sys/bus/dsa/devices

IAX_BIND_PATH=/sys/bus/dsa/drivers/idxd/bind
IAX_BIND_WQ_PATH=/sys/bus/dsa/drivers/crypto/bind

IAX_UNBIND_PATH=/sys/bus/dsa/drivers/idxd/unbind
IAX_UNBIND_WQ_PATH=/sys/bus/dsa/drivers/crypto/unbind

# input arg: if not 0, setup dedicated work queues (default: 1)
mode=${1:-1}; shift
use_x2=${1:-0}; shift
iaa_devices=${1:-4}; shift
iaa_engines=${1:-8}; shift
iaa_wqs=${1:-2}; shift
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


#
# count iax instances
#
iax_dev_id="0cfe"
num_iax_in_hw=$(lspci -d:${iax_dev_id} | wc -l)

#
# disable iax wqs and devices - by the calling function
#
#echo "Disable IAX"
#
#for ((i = 1; i < ${num_iax_in_hw} * 2; i += 2)); do
#    echo disable wq iax${i}/wq${i}.0
#    #accel-config disable-wq iax${i}/wq${i}.0
#    accel-config disable-wq wq${i}.0
#    echo disable iax iax${i}
#    #accel-config disable-device iax${i}
#    accel-config disable-device iax${i}
#done

#
# load iax config json
#
echo "Load IAX config: ${config_json}"
accel-config load-config -c ${config_json}

#
# enable iax devices and wqs
num_iax=${iaa_devices}
socket_iax_start=1
socket_iax_end=$(($num_iax*2))
for ((socket = 0; socket < ${sockets}; socket += 1)); do
   
    echo "Enable IAX  (${iaa_devices})"
    for ((i = ${socket_iax_start}; i < ${socket_iax_end} ; i += 2)); do
        #echo enable device iax${i}
        #accel-config enable-device iax${i}
        #echo enable wq iax${i}/wq${i}.0
        #accel-config enable-wq wq${i}.0
        echo enable iax iax${i}
        echo iax${i} > $IAX_BIND_PATH
    for ((j = 0; j < ${iaa_wqs}; j += 1)); do
        echo enable wq wq${i}.${j}
        if ! echo wq${i}.${j} > $IAX_BIND_WQ_PATH 2>/dev/null; then
            echo "  Warning: failed to bind wq${i}.${j} to crypto driver (skipping)"
        fi
    done
    done
    socket_iax_start=$(($socket_iax_start + ($num_iax)*2))
    socket_iax_end=$(($socket_iax_end + ($num_iax)*2))
done
