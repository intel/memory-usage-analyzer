#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Configure IAA devices

# Usage : ./configure_iaa.sh  <devices> <wq_size>
# devices: 0 - all devices or comma seperated device numbers
# wq_size: 0 - all devices or comma seperated device numbers
# For example, ./configure_iaa.sh 1 2 - configure 1 IAA device(s) and 2 WQs per device
#              ./configure_iaa.sh 4 2 - configure 4 IAA device(s) and 2 WQs per device

dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
#echo ${dir}
#
# count iax instances
#
iax_dev_id="0cfe"
num_iax=$(lspci -d:${iax_dev_id} | wc -l)
echo "Found ${num_iax}  instances"

device_num=${1:-$num_iax}; shift
iaa_wqs=${1:-2}; shift
iaa_engines=8
wq_size=$(( 128 / iaa_wqs ))
mode="dedicated"

# Take care of the enumeration, if DSA is enabled.
dsa=`lspci | grep -c 0b25`
#set first,step counters to correctly enumerate iax devices based on whether running on guest or host with or without dsa
first=0
step=1
[[ $dsa -gt 0 && -d /sys/bus/dsa/devices/dsa0 ]] && first=1 && step=2
echo "first index: ${first}, step: ${step}"

#
# disable iax wqs and devices
#
echo "Disable IAA devices before configuring"

for ((i = ${first}; i < ${step} * ${num_iax}; i += ${step})); do
    for ((j = 0; j < ${iaa_wqs}; j += 1)); do
        cmd="accel-config disable-wq iax${i}/wq${i}.{j} >& /dev/null"
	echo $cmd; eval $cmd
     done
    cmd="accel-config disable-device iax${i} >& /dev/null"
    echo $cmd; eval $cmd
done

echo "Configuring devices: ${device_num}"

if [ ${device_num} == $num_iax ]; then
    echo "Configuring all devices"
    start=${first}
    end=$(( ${step} * ${num_iax} ))
else
    echo "Configuring devices ${device_num}"
    declare -a array=($(echo ${device_num}| tr "," " ")) 
    start=${array[0]}
    if [ ${array[1]}  ];then
        end=$((${array[1]} + 1 ))
    else
        end=$((${array[0]} + 1 ))
    fi
fi



#
# enable all iax devices and wqs
#
echo "Enable  ${start} to ${end}"
for ((i = ${start}; i < ${end}; i += ${step})); do
    # Config  Devices, Engines and groups
    for ((j = 0; j < ${iaa_engines}; j += 1)); do
        cmd="accel-config config-engine iax${i}/engine${i}.${j} --group-id=0"
	echo $cmd; eval $cmd
    done

    # Config  WQs
    for ((j = 0; j < ${iaa_wqs}; j += 1)); do
        # Config WQ: group 0,  priority=10, mode=shared, type = kernel name=kernel, driver_name=crypto
        cmd="accel-config config-wq iax${i}/wq${i}.${j} -g 0 -s ${wq_size} -p 10 -m ${mode} -y kernel -n iaa_crypto -b 1 -d crypto"
	echo $cmd; eval $cmd
     done

    # Enable Device and WQs
    cmd="accel-config enable-device iax${i}"
    echo $cmd; eval $cmd
    for ((j = 0; j < ${iaa_wqs}; j += 1)); do
        cmd="accel-config enable-wq iax${i}/wq${i}.${j}"
	echo $cmd; eval $cmd
     done

done


