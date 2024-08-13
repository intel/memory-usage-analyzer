#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

# Define the location of the swap file
SWAP="silesia.tar"
COMP=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null)
CORE_FREQUENCY=2500


while getopts "f:t:" opt; do
  case $opt in
    f) CORE_FREQUENCY="$OPTARG" ;;
    t) SWAP="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# Function to handle errors
handle_error() {
    echo "Error: $1"
    exit 1
}


# Set CPU frequency to 2.5GHz for performance
cpupower frequency-set -g performance --min ${CORE_FREQUENCY}MHz --max ${CORE_FREQUENCY}MHz > /dev/null || handle_error "Failed to set CPU frequency"

# Check if the swap file exists, if not download it
if [ ! -f "$SWAP" ] ; then
    case "$SWAP" in
        "defconfig.out")
	    echo "unzipping defconfig.out.gz"
            gunzip < defconfig.out.gz > defconfig.out ;;
        "silesia.tar")
             echo "Downloading $SWAP from http://wanos.co/assets/silesia.tar"
             wget --no-check-certificate http://wanos.co/assets/silesia.tar || handle_error "Failed to download $SWAP" ;;
          *) echo "Invalid file $SWAP" ;  exit 1 ;
     esac
fi


# Install bpftrace if it is not available
if [ ! -f /usr/bin/bpftrace ]; then
    echo "Installing bpftrace..."
    yum install bpftrace -y || handle_error "Failed to install bpftrace"
fi

# Build the madvise_test executable if not already built
if [ ! -f madvise_test ]; then
    echo "Building madvise_test..."
    gcc -o madvise_test madvise_test.c || handle_error "Failed to build madvise_test"
fi

# Turn off read-ahead to optimize performance
echo 0 > /proc/sys/vm/page-cluster || handle_error "Failed to set page-cluster"


# Clear transparent huge pages configuration
echo 'never' > /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled || handle_error "Failed to clear hugepages-2048kB configuration"
echo 'never' > /sys/kernel/mm/transparent_hugepage/enabled || handle_error "Failed to clear transparent_hugepage configuration"

# Calculate swap size and pages
SZ=$(ls -s "$SWAP" | awk '{print $1}')
NPGS=$(echo "scale=0; $SZ/4-1" | bc -l)


CMD="./madvise_test ${SWAP} ${NPGS}"
if [[ $COMP == 'deflate-iaa-canned' || $COMP == 'deflate-iaa-dynamic'||$COMP == 'deflate-iaa' ]];then
    COMP_STR="iaa_comp_acompress"
    DCOMP_STR="iaa_comp_adecompress"
    SZ_STR="arg0+68"
elif [ $COMP == 'lzo-rle' ]; then
    COMP_STR="lzorle_scompress"
    DCOMP_STR="lzorle_sdecompress"
    SZ_STR="arg4"
else
    COMP_STR="${COMP}_scompress"
    DCOMP_STR="${COMP}_sdecompress"
    SZ_STR="arg4"
fi

PROG=`echo "kprobe:${COMP_STR} { @start=nsecs; @sz=${SZ_STR}; } kretprobe:${COMP_STR} { printf (\"C %d\\nR %d\\n\", nsecs-@start, *@sz); }
            kprobe:${DCOMP_STR} { @start=nsecs; } kretprobe:${DCOMP_STR} { printf (\"D %d\\n\", nsecs-@start); }
	    kprobe:handle_mm_fault /(arg1&0xfff) == 0/{@pf[cpu]=nsecs; if(arg2!=0x1254) {@pf[cpu]=0;}} kretprobe:handle_mm_fault {if(@pf[cpu]) {printf(\"P %d\\n\", nsecs-@pf[cpu]);} @pf[cpu]=0;}
	    kprobe:swap_writepage { @start_swap_write=nsecs; } kretprobe:swap_writepage { printf (\"SW %d\\n\", nsecs-@start_swap_write); }
	    kprobe:swap_read_folio { @start_swap_read=nsecs; } kretprobe:swap_read_folio { printf (\"SR %d\\n\", nsecs-@start_swap_read);}
	    kprobe:zswap_compress { @start_zswap_comp=nsecs; @zsz=arg1;} kretprobe:zswap_compress { printf (\"ZC %d\\nZCSZ %d\\nZCR %d\\n\", nsecs-@start_zswap_comp, *(@zsz+8), retval&0x1);}
	    kprobe:zswap_decompress { @start_zswap_decomp=nsecs; } kretprobe:zswap_decompress { printf (\"ZD %d\\n\", nsecs-@start_zswap_decomp);}
	    END { clear(@pf); delete(@start); delete(@sz);}"`

perf stat -o perf_${COMP}.log bpftrace -e "${PROG}" -c "${CMD}" -o ${COMP}_output
echo "Script completed successfully."
