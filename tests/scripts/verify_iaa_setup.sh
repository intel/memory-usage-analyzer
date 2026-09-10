#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
#
# Verify Intel Accelerator Architecture (IAA) device configuration and availability.
# Checks kernel version, IAA device presence, crypto module status, and device state.

set -o pipefail

# Global variables
verbose=0
IAA_DEVICE_ID="0cfe"
PASS=0
WARN=0
FAIL=0
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENABLE_IAA_SCRIPT="${SCRIPT_DIR}/enable_iaa.sh"

# Color codes for output (safe for log files - only used with TTY)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    BLUE='\033[0;34m'
    RESET='\033[0m'
else
    GREEN=''
    YELLOW=''
    RED=''
    BLUE=''
    RESET=''
fi

# Function to display usage information
usage() {
    cat << EOF
Usage: $0 [options]

Verify Intel Accelerator Architecture (IAA) device configuration and status.

Options:
    -v, --verbose       Enable verbose output
    -h, --help          Display this help message

Examples:
    $0                  # Run basic IAA verification checks
    $0 -v               # Run with verbose output

EOF
}

# Function to handle errors
handle_error() {
    echo "Error: $1" >&2
    exit 1
}

# Function to print status message
print_status() {
    local status=$1
    local message=$2
    local details=$3
    
    case "$status" in
        PASS)
            printf "%-40s ${GREEN}✓ PASS${RESET}\n" "$message"
            ((PASS++))
            ;;
        WARN)
            printf "%-40s ${YELLOW}⚠ WARN${RESET}\n" "$message"
            ((WARN++))
            ;;
        FAIL)
            printf "%-40s ${RED}✗ FAIL${RESET}\n" "$message"
            ((FAIL++))
            ;;
        INFO)
            printf "%-40s ${BLUE}ℹ INFO${RESET}\n" "$message"
            ;;
    esac
    
    if [[ -n "$details" ]]; then
        echo "  → $details"
    fi
}

# Ensure IAA is configured before checking lsmod-based state.
ensure_iaa_is_enabled() {
    if lsmod 2>/dev/null | grep -qi iaa_crypto; then
        return 0
    fi

    if [[ ! -x "$ENABLE_IAA_SCRIPT" ]]; then
        print_status "WARN" "IAA setup" "enable_iaa.sh not found or not executable at $ENABLE_IAA_SCRIPT"
        return 0
    fi

    print_status "INFO" "IAA setup" "IAA crypto module not loaded; running ${ENABLE_IAA_SCRIPT}"
    if "$ENABLE_IAA_SCRIPT" >/dev/null 2>&1; then
        return 0
    fi

    print_status "WARN" "IAA setup" "enable_iaa.sh exited non-zero; continuing with verification checks"
}

# Function to check if running as root
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        handle_error "This script must be run as root or with sudo"
    fi
}

# Function to check kernel version
check_kernel_version() {
    local kernel_ver
    kernel_ver=$(uname -r)
    
    # Extract major and minor versions
    local major_ver minor_ver
    major_ver=$(echo "$kernel_ver" | cut -d. -f1)
    minor_ver=$(echo "$kernel_ver" | cut -d. -f2)
    
    # Check for minimum kernel 6.8
    local min_major=6
    local min_minor=8
    local kernel_ok=0
    
    if [[ $major_ver -gt $min_major ]]; then
        kernel_ok=1
    elif [[ $major_ver -eq $min_major && $minor_ver -ge $min_minor ]]; then
        kernel_ok=1
    fi
    
    if [[ $kernel_ok -eq 1 ]]; then
        print_status "PASS" "Kernel version" "$kernel_ver (6.8 or later)"
    else
        print_status "FAIL" "Kernel version" "$kernel_ver (requires 6.8 or later)"
    fi
}
# Function to check IAA device count
check_iaa_device_count() {
    local count
    count=$(lspci -d:"${IAA_DEVICE_ID}" 2>/dev/null | wc -l)
    
    if [[ $count -gt 0 ]]; then
        print_status "PASS" "IAA devices (PCI)" "Found $count device(s)"
        
        if [[ $verbose == 1 ]]; then
            lspci -d:"${IAA_DEVICE_ID}" | sed 's/^/  /'
        fi
    else
        print_status "FAIL" "IAA devices (PCI)" "Expected at least 1 IAA device (PCI ID: ${IAA_DEVICE_ID})"
    fi
}

# Function to check IAA crypto module
check_iaa_crypto_module() {
    local modules
    modules=$(lsmod 2>/dev/null | grep -i iaa_crypto)
    
    if [[ -n "$modules" ]]; then
        local mod_name
        mod_name=$(echo "$modules" | awk '{print $1}')
        print_status "PASS" "IAA crypto module" "Loaded ($mod_name)"
        
        if [[ $verbose == 1 ]]; then
            echo "$modules" | sed 's/^/  /'
        fi
    else
        print_status "FAIL" "IAA crypto module" "Not loaded - modprobe iaa_crypto"
    fi
}

# Function to check IAA device state
check_iaa_device_state() {
    if [[ ! -d /sys/bus/dsa/devices ]]; then
        print_status "FAIL" "IAA device state" "DSA/IAA sysfs not available"
        return
    fi
    
    # IAA devices are symlinks in /sys/bus/dsa/devices, so we list them directly
    local iax_devices
    iax_devices=$(ls -d /sys/bus/dsa/devices/iax* 2>/dev/null | sort)
    
    if [[ -z "$iax_devices" ]]; then
        print_status "WARN" "IAA device state" "No devices found in sysfs"
        return
    fi
    
    local enabled_list=""
    local disabled_list=""
    local enabled_count=0
    local total_count=0
    
    for device in $iax_devices; do
        local dev_name
        dev_name=$(basename "$device")
        local state
        state=$(cat "$device/state" 2>/dev/null || echo "unknown")
        ((total_count++))
        
        if [[ "$state" == "enabled" ]]; then
            enabled_list="${enabled_list}${dev_name} "
            ((enabled_count++))
        else
            disabled_list="${disabled_list}${dev_name} "
        fi
    done
    
    if [[ $enabled_count -eq $total_count ]]; then
        print_status "PASS" "IAA device state" "All $total_count device(s) enabled"
        [[ $verbose == 1 ]] && echo "  Devices: ${enabled_list%% }"
    else
        print_status "WARN" "IAA device state" "$enabled_count/$total_count device(s) enabled"
        [[ $verbose == 1 ]] && echo "  Enabled: ${enabled_list%% }" && echo "  Disabled: ${disabled_list%% }"
    fi
}

# Function to check IAA crypto algorithms
check_iaa_algorithms() {
    if [[ ! -f /proc/crypto ]]; then
        print_status "WARN" "IAA crypto algorithms" "Crypto info not available"
        return
    fi
    
    local algos
    algos=$(awk '/^driver[[:space:]]*:[[:space:]]*deflate-iaa/{print $3}' /proc/crypto 2>/dev/null | sort -u | tr '\n' ' ')
    
    if [[ -n "$algos" ]]; then
        print_status "PASS" "IAA crypto algorithms" "${algos% }"
    else
        print_status "INFO" "IAA crypto algorithms" "None registered yet"
    fi
}

# Function to print summary report
print_summary() {
    local total=$((PASS + WARN + FAIL))
    echo ""
    
    if [[ $FAIL -gt 0 ]]; then
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${RED}FAILED:${RESET} $FAIL error(s), $WARN warning(s), $PASS passed"
        echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        return 1
    elif [[ $WARN -gt 0 ]]; then
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${YELLOW}WARNINGS:${RESET} $WARN warning(s), $PASS passed"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        return 0
    else
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        echo -e "${GREEN}SUCCESS:${RESET} All $total check(s) passed"
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
        return 0
    fi
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)
            verbose=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Main verification flow
check_root
ensure_iaa_is_enabled

echo ""
echo -e "${BLUE}IAA Device Verification${RESET}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

check_kernel_version
check_iaa_device_count
check_iaa_crypto_module
check_iaa_device_state
check_iaa_algorithms

print_summary
 
