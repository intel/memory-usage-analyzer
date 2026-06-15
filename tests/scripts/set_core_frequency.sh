#!/bin/bash 
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#Description: Configure Core frequency

CORE_FREQUENCY=""
while getopts "f:h:" opt; do
  case $opt in
    f)
      # mode fs or swap       
      CORE_FREQUENCY=$OPTARG
      ;;
    h)
      echo "Usage: $0 [-c <comp_algorithm>] [-s <size_in_GB>]"
      echo "       -f - core frequency(default: dynamic)"
      echo "       -h - help"
      echo ""
      echo "Examples:"
      echo "  $0                    # Set frequency mode to dynamic"
      echo "  $0 -f 2500            # Set frequency to 2500MHz"
      echo ""
      exit
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$CORE_FREQUENCY" ]];then
    min_freq=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq) /1000 ))
    max_freq=$(( $(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq) /1000 ))
else
    min_freq=${CORE_FREQUENCY}
    max_freq=${CORE_FREQUENCY}
fi
cpupower frequency-set -g performance --min ${min_freq}MHz --max ${max_freq}MHz > /dev/null
cpupower frequency-info | grep "current CPU frequency" | grep asserted
