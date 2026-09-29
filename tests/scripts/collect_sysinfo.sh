#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#
# Collect host system information into SYSINFO_* variables.
# Source this file; do not execute it.

collect_sysinfo() {
    SYSINFO_CPU_MODEL=$(awk -F: '/^model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)
    SYSINFO_CPU_SOCKETS=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/{gsub(/[ \t]+/,"",$2); print $2; exit}')
    SYSINFO_CORES_PER_SOCKET=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/{gsub(/[ \t]+/,"",$2); print $2; exit}')
    SYSINFO_THREADS_PER_CORE=$(lscpu 2>/dev/null | awk -F: '/^Thread\(s\) per core/{gsub(/[ \t]+/,"",$2); print $2; exit}')
    SYSINFO_TOTAL_CPUS=$(nproc 2>/dev/null || echo "0")
    local _mem_kb
    _mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    SYSINFO_MEM_TOTAL_GB=$(awk -v m="$_mem_kb" 'BEGIN{printf "%.1f", m/1024/1024}')
    SYSINFO_NUMA_NODES=$(lscpu 2>/dev/null | awk -F: '/^NUMA node\(s\)/{gsub(/[ \t]+/,"",$2); print $2; exit}')
    SYSINFO_BIOS_VERSION=$(sudo -n dmidecode -s bios-version 2>/dev/null || echo "N/A")
    SYSINFO_BIOS_DATE=$(sudo -n dmidecode -s bios-release-date 2>/dev/null || echo "N/A")
}
