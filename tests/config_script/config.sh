#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

if [ $EUID -ne 0 ]
  then echo "Must run as root or with sudo."
  exit
fi

zram_comp_algorithm=$1; shift
zram_disksize=$1; shift
zram_mem_limit=$1; shift
zswap_zpool=$1; shift
zswap_max_pool_percent=$1; shift
zswap_enabled=$1; shift
cgpath=$1; shift
cgname=$1; shift
cguser=$1; shift
vm_swappiness=$1; shift

# ====================================================================
# check cgroup version first
if [[ -r ${cgpath}/cgroup.controllers ]]; then
    if [[ -e ${cgpath}/${cgname} ]]; then
        # remove existing cgroup v2
        until rmdir ${cgpath}/${cgname} >& /dev/null; do
            cat ${cgpath}/${cgname}/cgroup.procs | xargs kill -9 >& /dev/null
            sleep 1
        done
    fi
else
    # remove existing cgroup v1
    if [[ -e ${cgpath}/memory/${cgname} ]]; then
        # kill any processes the cgroup
        until rmdir ${cgpath}/memory/${cgname} >& /dev/null; do
            cat ${cgpath}/memory/${cgname}/tasks | xargs kill -9 >& /dev/null
            sleep 1
        done
    fi
    if [[ -e ${cgpath}/cpu/${cgname} ]]; then
        # kill any processes the cgroup
        until rmdir ${cgpath}/cpu/${cgname} >& /dev/null; do
            cat ${cgpath}/cpu/${cgname}/tasks | xargs kill -9 >& /dev/null
            sleep 1
        done
    fi
    if [[ -e ${cgpath}/blkio/${cgname} ]]; then
        # kill any processes the cgroup
        until rmdir ${cgpath}/blkio/${cgname} >& /dev/null; do
            cat ${cgpath}/blkio/${cgname}/tasks | xargs kill -9 >& /dev/null
            sleep 1
        done
    fi
fi

# remove all swap devices
swapoff -a
if [[ -e "/dev/zram0" ]]; then
    umount -f /dev/zram0 >& /dev/null
    echo 0 > /sys/class/zram-control/hot_remove
fi

# setup zram
if [[ ${zram_disksize} -gt 0 ]]; then
    modprobe zram num_devices=1

    if [[ ! -e "/dev/zram0" ]]; then
        cat /sys/class/zram-control/hot_add > /dev/null
    fi

    echo ${zram_comp_algorithm} > /sys/block/zram0/comp_algorithm
    echo ${zram_disksize} > /sys/block/zram0/disksize
    echo ${zram_mem_limit} > /sys/block/zram0/mem_limit

    mkswap /dev/zram0 > /dev/null
    swapon /dev/zram0
else
    swapon -a
fi

# setup zswap
echo ${zswap_max_pool_percent} > /sys/module/zswap/parameters/max_pool_percent

# setup cgroup
if [[ -r ${cgpath}/cgroup.controllers ]]; then
    mkdir ${cgpath}/${cgname}
    chown ${cguser} ${cgpath}/cgroup.procs
    chown -R ${cguser} ${cgpath}/${cgname}
    # set swappiness
    echo max > ${cgpath}/${cgname}/memory.swap.max
else
    mkdir ${cgpath}/memory/${cgname}
    mkdir ${cgpath}/cpu/${cgname}
    mkdir ${cgpath}/blkio/${cgname}
    chown -R ${cguser} ${cgpath}/memory/${cgname}
    chown -R ${cguser} ${cgpath}/cpu/${cgname}
    chown -R ${cguser} ${cgpath}/blkio/${cgname}
    # set swappiness
    echo ${vm_swappiness} > ${cgpath}/memory/${cgname}/memory.swappiness
fi

echo ${vm_swappiness} > /proc/sys/vm/swappiness

# disable thp
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# enable overcommit
echo 1 > /proc/sys/vm/overcommit_memory

