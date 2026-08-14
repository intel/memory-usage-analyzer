#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# zram microbenchmarks with dd

# Default settings
SWEEP="no"
BATCH_SIZES=(4096)  # Default: only 4K
CORE_FREQUENCY_MHZ=3200
DD_PATH="dd"
if dd --version | grep -q "(coreutils) 9.5"; then
    echo "dd is version 9.5"
else
    if [[ -f /opt/coreutils-9.5/bin/dd ]]; then
       DD_PATH="/opt/coreutils-9.5/bin/dd"
       echo "Using dd from ${DD_PATH}"
    else
       echo "build dd 9.5 with ./build_dd.sh"
       exit
    fi
fi

# Process arguments
while getopts "sf:h" opt; do
  case $opt in
    s)
      SWEEP="yes"
      BATCH_SIZES=(4096 8192 16384 32768 65536 131072 262144 524288 1048576 2097152)
      ;;
    f)
      CORE_FREQUENCY_MHZ=$OPTARG
      ;;
    h)
      echo "Usage: $0 [--block_sweep]"
      echo "  -s: test all block sizes (4K, 8K, 16K, 32K)"
      echo "  default:       test 4K only"
      exit 0
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

# Configure the system for zram (core frequency + IAA + zram device).
../scripts/config_sys_zram.sh -f ${CORE_FREQUENCY_MHZ}

# Candidate compressors. deflate-iaa / deflate-iaa-dynamic need the iaa_crypto
# driver bound into zram's compress path (both Ubuntu and CentOS in-tree
# drivers register them once IAA is configured).
candidate_comp_list="lz4 lzo-rle zstd deflate-iaa deflate-iaa-dynamic"

# Bring up a clean, *uninitialized* zram device for probing. comp_algorithm can
# only be changed while the device has no disksize set, so tear down whatever
# config_sys_zram.sh left behind first (the per-compressor loop recreates it).
swapoff /dev/zram0 2>/dev/null || true
umount /mnt/zram_disk 2>/dev/null || true
echo 0 > /sys/class/zram-control/hot_remove 2>/dev/null || true
modprobe zram 2>/dev/null || true
[[ -e /sys/block/zram0 ]] || cat /sys/class/zram-control/hot_add >/dev/null 2>&1 || true

# Detect selectable compressors by actually trying to set each one. The
# comp_algorithm sysfs "list" only advertises the built-in backends plus the
# currently-active algorithm, so crypto-backed algorithms (deflate-iaa,
# deflate-iaa-dynamic) are usable even though they are absent from that list.
# Probing by write is the reliable, distro-agnostic test.
comp_list=""
for comp in $candidate_comp_list; do
    if echo "$comp" > /sys/block/zram0/comp_algorithm 2>/dev/null &&
       [[ "$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/block/zram0/comp_algorithm)" == "$comp" ]]; then
        comp_list+="$comp "
    else
        echo "WARNING: compressor '$comp' not selectable for zram on this kernel; skipping" >&2
    fi
done
comp_list=$(echo "$comp_list" | xargs)
if [[ -z "$comp_list" ]]; then
    echo "ERROR: no supported zram compressors detected" >&2
    exit 1
fi
echo "Testing compressors: $comp_list"

# Install required tools on both Ubuntu (apt-get) and CentOS (dnf/yum).
required_pkgs="fio bc numactl"
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y $required_pkgs
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y $required_pkgs
elif command -v yum >/dev/null 2>&1; then
    yum install -y $required_pkgs
else
    echo "WARNING: no supported package manager (apt-get/dnf/yum); please install: $required_pkgs" >&2
fi
content_file=silesia.tar
if ! [ -f ${content_file} ];then
    wget --no-check-certificate http://wanos.co/assets/silesia.tar 
fi

# Clean up old log files
echo "Cleaning up old log files..."
rm -f *_wr.log *_rd.log *_zram_wr.log

file_size=$(ls -l silesia.tar | awk '{print $5 }')

echo "Sweep mode: $SWEEP"
if [[ "$SWEEP" == "yes" ]]; then
    echo "Testing block sizes: 4K, 8K, 16K, 32K"
else
    echo "Testing block size: 4K only"
fi

# Clear IAA stats when the in-tree iaa_crypto driver exposes them (skipped on
# kernels without IAA, e.g. stock Ubuntu/CentOS without the driver loaded).
IAA_STATS_DIR="/sys/kernel/debug/iaa_crypto"
if [[ -w "${IAA_STATS_DIR}/stats_reset" ]]; then
    echo 1 > "${IAA_STATS_DIR}/stats_reset"
fi

# create tmpfs for input to avoid overhead of filesystem
mkdir -p /mnt/tmpfs
mount -t tmpfs -o size=8G,mpol=bind:0 tmpfs /mnt/tmpfs
mount | grep tmpfs
cp silesia.tar /mnt/tmpfs

for bs in "${BATCH_SIZES[@]}"; do
    echo ""
    echo "=========================================="
    echo "Testing with block size: ${bs} bytes ($((bs/1024))K)"
    echo "=========================================="
    
    block_count=$(( file_size / bs ))

    for comp in $comp_list; do
        echo "Testing compressor: $comp with block size $((bs/1024))K"
        echo "Running Enabling ZRAM..."
        if ! ./enable_zram.sh -c $comp; then
            echo "WARNING: skipping '$comp' at block size $((bs/1024))K — compressor unavailable" >&2
            rm -f ${comp}_${bs}_wr.log ${comp}_${bs}_rd.log ${comp}_${bs}_zram_wr.log
            continue
        fi
        numactl --membind=0 taskset -c 1 ${DD_PATH} if=/mnt/tmpfs/silesia.tar of=/mnt/zram_disk/silesia_w.tar oflag=direct  bs=${bs} count=${block_count}  status=progress 2>&1 | tee ${comp}_${bs}_wr.log
        # Collect zram stats after write
        echo "ZRAM stats after write:" | tee -a ${comp}_${bs}_zram_wr.log
        echo "orig_data_size compr_data_size mem_used_total mem_limit mem_used_max same_pages pages_compacted huge_pages huge_pages_since" | tee -a ${comp}_${bs}_zram_wr.log
        cat /sys/block/zram0/mm_stat | tee -a ${comp}_${bs}_zram_wr.log
        # Clear caches
        sync; echo 3 > /proc/sys/vm/drop_caches
	# use /dev/null instead of temp_rd.tar to avoid write overheads
        numactl --membind=0 taskset -c 1  ${DD_PATH} if=/mnt/zram_disk/silesia_w.tar  of=/dev/null iflag=direct  bs=${bs} count=${block_count}  status=progress 2>&1 | tee ${comp}_${bs}_rd.log
        # Clean up temp file
        #rm -f temp_rd.tar

    done
done

# Release the tmpfs input mount. Try a normal unmount first and only fall back
# to a lazy one; skip rmdir while it is still detaching to avoid a busy error.
sync
if umount /mnt/tmpfs 2>/dev/null; then
    rmdir /mnt/tmpfs 2>/dev/null || true
else
    umount -l /mnt/tmpfs 2>/dev/null || true
fi

# Collect IAA work-queue stats only when the driver exposes them.
if [[ -r "${IAA_STATS_DIR}/wq_stats" ]]; then
    cat "${IAA_STATS_DIR}/wq_stats" > wq_stats.txt
fi

SUMMARY_FILE="dd_zram_summary.txt"

generate_summary() {
echo "=========================================="
echo "FINAL RESULTS"
echo "=========================================="
printf "%-25s %-12s %-12s %-12s %-15s\n" "Compressor" "Block_Size" "WR_BW(MB/s)" "RD_BW(MB/s)" "Compression_Ratio"
printf "%-25s %-12s %-12s %-12s %-15s\n" "-------------------------" "----------" "----------" "----------" "---------------"

for bs in "${BATCH_SIZES[@]}"; do
    for comp in $comp_list;do
        if [[ ! -f "${comp}_${bs}_wr.log" ]] || [[ ! -f "${comp}_${bs}_rd.log" ]]; then
            printf "%-25s %-12s %-12s %-12s %-15s\n" "$comp" "$((bs/1024))K" "SKIPPED" "SKIPPED" "N/A"
            continue
        fi
        wr_bw=$(tail -n 1 ${comp}_${bs}_wr.log | awk -F, '{print $4}'| awk '{print $1}')
        wr_bw_unit=$(tail -n 1 ${comp}_${bs}_wr.log | awk -F, '{print $4}'| awk '{print $2}')
	[[ $wr_bw_unit == "GB/s" ]] && wr_bw=$(echo "scale=2; $wr_bw * 1024" | bc)
        rd_bw=$(tail -n 1 ${comp}_${bs}_rd.log | awk -F, '{print $4}'| awk '{print $1}')
        rd_bw_unit=$(tail -n 1 ${comp}_${bs}_rd.log | awk -F, '{print $4}'| awk '{print $2}')
	[[ $rd_bw_unit == "GB/s" ]] && rd_bw=$(echo "scale=2; $rd_bw * 1024" | bc)

        block_size_k="${bs}/1024"
        block_size_display="$((bs/1024))K"
        
        # Parse zram stats to get compression ratio
        if [[ -f "${comp}_${bs}_zram_wr.log" ]]; then
            # Get the last line with numbers (skip header lines)
            zram_stats=$(grep -E '^[0-9]' "${comp}_${bs}_zram_wr.log" | tail -n 1)
            if [[ -n "$zram_stats" ]]; then
                orig_data_size=$(echo $zram_stats | awk '{print $1}')
                mem_used_max=$(echo $zram_stats | awk '{print $5}')
                # Calculate compression ratio (original / compressed)
                compression_ratio=$(awk "BEGIN {printf \"%.2f\", $orig_data_size / $mem_used_max}")
            else
                compression_ratio="N/A"
            fi
        else
            compression_ratio="N/A"
        fi
        
        printf "%-25s %-12s %-12s %-12s %-15s\n" "$comp" "$block_size_display" "$wr_bw" "$rd_bw" "$compression_ratio"
    done
done

echo "=========================================="
echo "This run only benchmarked zram."
os_name=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")
[[ -z "$os_name" ]] && os_name=$(uname -o 2>/dev/null || echo "unknown")
echo "OS:     ${os_name}"
echo "Kernel: $(uname -r) ($(uname -m))"
if [[ " $comp_list " == *" deflate-iaa "* || " $comp_list " == *" deflate-iaa-dynamic "* ]]; then
    echo "This OS/kernel SUPPORTS deflate-iaa (available: $(echo "$comp_list" | grep -o 'deflate-iaa[a-z-]*' | tr '\n' ' '))."
else
    echo "This OS/kernel does NOT support deflate-iaa (in-tree iaa_crypto driver not registered for zram)."
fi
echo "=========================================="
}

# Print the summary and persist it to a file.
generate_summary | tee "${SUMMARY_FILE}"
echo ""
echo "Summary written to $(pwd)/${SUMMARY_FILE}"
