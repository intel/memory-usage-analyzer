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
            echo -e "${GREEN}✓ PASS${RESET}: $message"
            ((PASS++))
            ;;
        WARN)
            echo -e "${YELLOW}⚠ WARN${RESET}: $message"
            ((WARN++))
            ;;
        FAIL)
            echo -e "${RED}✗ FAIL${RESET}: $message"
            ((FAIL++))
            ;;
        INFO)
            echo -e "${BLUE}ℹ INFO${RESET}: $message"
            ;;
    esac
    
    if [[ -n "$details" ]]; then
        echo "         $details"
    fi
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
    
    local major_ver
    major_ver=$(echo "$kernel_ver" | cut -d. -f1)
    
    if [[ $major_ver -ge 6 ]]; then
        print_status "PASS" "Kernel version $kernel_ver is IAA-compatible (6.x or later)"
    else
        print_status "WARN" "Kernel version $kernel_ver may not have IAA support" "IAA support requires kernel 6.x or later"
    fi
}

# Function to check IAA device count
check_iaa_device_count() {
    local count
    count=$(lspci -d:"${IAA_DEVICE_ID}" 2>/dev/null | wc -l)
    
    if [[ $count -gt 0 ]]; then
        print_status "PASS" "Found $count IAA device(s)"
        
        if [[ $verbose == 1 ]]; then
            echo "         Device details:"
            lspci -d:"${IAA_DEVICE_ID}" | sed 's/^/         /'
        fi
    else
        print_status "FAIL" "No IAA devices detected" "Expected at least 1 IAA device (PCI ID: ${IAA_DEVICE_ID})"
    fi
}

# Function to check IAA crypto module
check_iaa_crypto_module() {
    local modules
    modules=$(lsmod 2>/dev/null | grep -i iaa_crypto)
    
    if [[ -n "$modules" ]]; then
        local mod_name
        mod_name=$(echo "$modules" | awk '{print $1}')
        print_status "PASS" "IAA crypto module loaded ($mod_name)"
        
        if [[ $verbose == 1 ]]; then
            echo "$modules" | sed 's/^/         /'
        fi
    else
        print_status "FAIL" "IAA crypto modules not loaded" "Load with: modprobe iaa_crypto"
    fi
}

# Function to check IAA device state
check_iaa_device_state() {
    if [[ ! -d /sys/bus/dsa/devices ]]; then
        print_status "FAIL" "DSA/IAA sysfs not available" "Check if DSA driver is loaded"
        return
    fi
    
    # IAA devices are symlinks in /sys/bus/dsa/devices, so we list them directly
    local iax_devices
    iax_devices=$(ls -d /sys/bus/dsa/devices/iax* 2>/dev/null | sort)
    
    if [[ -z "$iax_devices" ]]; then
        print_status "WARN" "No IAA devices found in sysfs" "Devices may not be enumerated yet"
        return
    fi
    
    local all_enabled=1
    local enabled_count=0
    local total_count=0
    
    echo "         Device States:"
    for device in $iax_devices; do
        local dev_name
        dev_name=$(basename "$device")
        local state
        state=$(cat "$device/state" 2>/dev/null || echo "unknown")
        ((total_count++))
        
        if [[ "$state" == "enabled" ]]; then
            echo -e "         ${GREEN}✓${RESET} $dev_name: $state"
            ((enabled_count++))
        else
            echo -e "         ${RED}✗${RESET} $dev_name: $state"
            all_enabled=0
        fi
    done
    
    if [[ $all_enabled -eq 1 ]]; then
        print_status "PASS" "All $enabled_count IAA device(s) are enabled"
    else
        print_status "WARN" "$enabled_count/$total_count IAA device(s) are enabled"
    fi
}

# Function to check IAA crypto algorithms
check_iaa_algorithms() {
    if [[ ! -f /proc/crypto ]]; then
        print_status "WARN" "Crypto information not available" "/proc/crypto not found"
        return
    fi
    
    local algos
    algos=$(awk '/^driver[[:space:]]*:[[:space:]]*deflate-iaa/{print $3}' /proc/crypto 2>/dev/null | sort -u | tr '\n' ' ')
    
    if [[ -n "$algos" ]]; then
        print_status "PASS" "IAA crypto algorithms registered" "Algorithms: $algos"
    else
        print_status "INFO" "No IAA crypto algorithms registered yet" "Enable IAA crypto module to register algorithms"
    fi
}

# Function to print summary report
print_summary() {
    echo ""
    echo "===================================================="
    echo "  IAA Verification Summary"
    echo "===================================================="
    printf "  %-10s %d\n" "PASS:" "$PASS"
    printf "  %-10s %d\n" "WARN:" "$WARN"
    printf "  %-10s %d\n" "FAIL:" "$FAIL"
    echo "===================================================="
    
    if [[ $FAIL -gt 0 ]]; then
        echo -e "\n${RED}Status: FAILED${RESET} - Fix errors above before using IAA"
        return 1
    elif [[ $WARN -gt 0 ]]; then
        echo -e "\n${YELLOW}Status: WARNINGS DETECTED${RESET} - Review warnings for non-critical issues"
        return 0
    else
        echo -e "\n${GREEN}Status: ALL CHECKS PASSED${RESET} - IAA is properly configured"
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
echo ""
echo "===================================================="
echo "  IAA Device Verification"
echo "===================================================="
echo ""

check_kernel_version
check_iaa_device_count
check_iaa_crypto_module
check_iaa_device_state
check_iaa_algorithms

print_summary
 
