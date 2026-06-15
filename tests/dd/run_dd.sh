#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# zram microbenchmarks with dd

# Default settings
SWEEP="no"
BATCH_SIZES=(4096)  # Default: only 4K
CORE_FREQUENCY_MHZ=3000
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

# Configure IAA, if not already
../scripts/disable_swap_zram.sh; ../scripts/enable_iaa.sh 
# Set up frequency and LOM
../scripts/set_core_frequency.sh -f ${CORE_FREQUENCY_MHZ}
../scripts/set_unset_lom.sh set

comp_list="lz4 zstd deflate-iaa deflate-iaa-dynamic"

# Setup
yum install fio -y
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

# Clear stats for debug
echo 1 > /sys/kernel/debug/iaa_crypto/stats_reset

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
        ./enable_zram.sh -c $comp
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

umount -l /mnt/tmpfs && rmdir /mnt/tmpfs

cat /sys/kernel/debug/iaa_crypto/wq_stats > wq_stats.txt

echo ""
echo "=========================================="
echo "FINAL RESULTS"
echo "=========================================="
printf "%-25s %-12s %-12s %-12s %-15s\n" "Compressor" "Block_Size" "WR_BW(MB/s)" "RD_BW(MB/s)" "Compression_Ratio"
printf "%-25s %-12s %-12s %-12s %-15s\n" "-------------------------" "----------" "----------" "----------" "---------------"

for bs in "${BATCH_SIZES[@]}"; do
    for comp in $comp_list;do
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
python report_wq_stats.py wq_stats.txt  > /dev/null
