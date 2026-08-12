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
force_reconfig=1

# Function to handle errors
handle_error() {
    echo "Error: $1"
    exit 1
}

# Report the IAA deflate crypto variants the driver registered (e.g.
# deflate-iaa and deflate-iaa-dynamic). Both are usable by zram/zswap once IAA
# is crypto-bound, even though zram's comp_algorithm list may not advertise them.
report_iaa_algorithms() {
    local algos
    algos=$(awk '/^driver[[:space:]]*:[[:space:]]*deflate-iaa/{print $3}' /proc/crypto | sort -u | tr '\n' ' ')
    echo "IAA crypto algorithms registered: ${algos:-none}"
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
        -F|--force)
            force_reconfig=1
            shift
            ;;
        -h)
            echo "Usage: $0 [-d <device_count>][-q <wq_per_device>][-v][-c][--dc Y|N][--dd Y|N][-F]"
            echo "       -d  - number of devices per socket (default: ${device_num_per_socket})"
            echo "       -q  - number of WQs per device (default: ${iaa_wqs})"
            echo "       -v  - verbose mode"
            echo "       -c  - enable verify compress"
            echo "       --dc Y|N - distribute compression operations (default: Y)"
            echo "       --dd Y|N - distribute decompression operations (default: N)"
            echo "       -F  - force teardown+reconfigure even if IAA is already crypto-bound"
            echo "             (unsafe on kernels with the idxd EVL bug, e.g. stock Ubuntu 6.8)"
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

# ---------------------------------------------------------------------------
# Fast path: the in-tree iaa_crypto driver (mainline / Ubuntu / recent CentOS
# kernels) auto-configures and enables IAA devices at load, binding one WQ per
# device to the 'crypto' driver. On such kernels, tearing that setup down with
# 'accel-config disable-device' (or reloading iaa_crypto) triggers a NULL-ptr
# dereference in idxd_device_evl_free and oopses the machine. If IAA is already
# configured for crypto, use it as-is and skip the destructive reconfiguration.
# Pass -F/--force to override (only safe on kernels without the idxd EVL bug,
# e.g. the out-of-tree Intel driver where devices boot disabled).
iaa_already_configured() {
    local w bound=0
    for w in /sys/bus/dsa/devices/iax*/wq*; do
        [[ -e "$w/state" ]] || continue
        if [[ "$(cat "$w/state" 2>/dev/null)" == "enabled" && \
              "$(cat "$w/driver_name" 2>/dev/null)" == "crypto" ]]; then
            bound=1
        fi
    done
    [[ $bound -eq 1 ]]
}

if [[ "${force_reconfig}" != "1" ]] && iaa_already_configured; then
    echo "IAA already configured and crypto-bound by the kernel driver; skipping reconfiguration."
    echo "(pass -F/--force to tear down and reconfigure -- unsafe on kernels with the idxd EVL bug)"
    # Apply global, device-independent crypto tunables best-effort (no teardown).
    [[ -w ${VERIFY_COMPRESS_PATH} ]] && echo ${verify_compress} > ${VERIFY_COMPRESS_PATH} 2>/dev/null
    [[ -w /sys/bus/dsa/drivers/crypto/sync_mode ]] && echo ${iaa_crypto_mode} > /sys/bus/dsa/drivers/crypto/sync_mode 2>/dev/null

    echo -e "\nDetailed IAA Configuration:"
    total_devices=$(accel-config list 2>/dev/null | grep -c '"dev":"iax')
    total_wqs=$(accel-config list 2>/dev/null | grep -c '"dev":"wq[0-9]*\.[0-9]*"')
    echo "Number of IAA devices per socket: $(( total_devices / sockets ))"
    [ ${total_devices} -gt 0 ] && echo "Work queues per IAA device: $(( total_wqs / total_devices ))" || echo "Work queues per IAA device: 0"
    report_iaa_algorithms
    exit 0
fi

# Switch to software compressors and disable IAAs to have a clean start
COMPRESSOR=/sys/module/zswap/parameters/compressor
last_comp=`cat ${COMPRESSOR}`
echo lzo > ${COMPRESSOR}

# NOTE: On some kernels (observed on stock Ubuntu 6.8.0-*-generic) calling
# 'accel-config disable-device' on a device triggers a NULL-pointer dereference
# in the idxd driver (idxd_device_evl_free -> idxd_device_drv_remove) that
# oopses the kernel. Freshly loaded IAA devices are already "disabled", so only
# issue disable commands for components that are currently "enabled". This
# avoids the crash on a clean boot and is a no-op on kernels without the bug.
dev_state() { cat "/sys/bus/dsa/devices/$1/state" 2>/dev/null; }

[[ $verbose == 1 ]] && echo "Disable IAA devices before configuring"
for ((i = ${first}; i < ${step} * ${num_iaa}; i += ${step})); do
    [[ -d /sys/bus/dsa/devices/iax${i} ]] || continue
    for ((j = 0; j < ${iaa_wqs}; j += 1)); do
        if [[ "$(dev_state iax${i}/wq${i}.${j})" == "enabled" ]]; then
            cmd="accel-config disable-wq iax${i}/wq${i}.${j} >& /dev/null"
            [[ $verbose == 1 ]] && echo $cmd; eval $cmd
        fi
    done
    if [[ "$(dev_state iax${i})" == "enabled" ]]; then
        cmd="accel-config disable-device iax${i} >& /dev/null"
        [[ $verbose == 1 ]] && echo $cmd; eval $cmd
    else
        [[ $verbose == 1 ]] && echo "iax${i} already disabled, skipping"
    fi
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
report_iaa_algorithms
