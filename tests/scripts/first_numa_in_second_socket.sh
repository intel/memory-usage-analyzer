#!/usr/bin/bash
for n in /sys/devices/system/node/node*; do
    nid=${n##*node}
    first_cpu=$(cat $n/cpulist | sed 's/-.*//')
    socket=$(cat /sys/devices/system/cpu/cpu$first_cpu/topology/physical_package_id)
    echo "$nid $socket"
done | awk '$2==1 {print $1}' | sort -n | head -1

