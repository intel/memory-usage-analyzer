#!/usr/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Wrapper which runs madvise workload and collect bpftraces

# Define the location of the swap file
SWAP="silesia.tar"
COMP=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null)
CORE_FREQUENCY=2500
CBATCH=1
DBATCH=0
MTHP="4kB"


while getopts "f:t:c:d:m:" opt; do
  case $opt in
    f) CORE_FREQUENCY="$OPTARG" ;;
    t) SWAP="$OPTARG" ;;
    c) CBATCH="$OPTARG" ;;
    d) DBATCH="$OPTARG" ;;
    m) MTHP="$OPTARG" ;;
    \?) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
  esac
done

# Function to handle errors
handle_error() {
    echo "Error: $1"
    #exit 1
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
        "4300_all")
             echo "using  $SWAP locally" ;;
          *) echo "Invalid file $SWAP" ;  exit 1 ;;
	     
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
#echo 0 > /proc/sys/vm/page-cluster || handle_error "Failed to set page-cluster"


if [[ $COMP == 'deflate-iaa-canned' || $COMP == 'deflate-iaa-dynamic'||$COMP == 'deflate-iaa' ]]; then
    echo "true" > /sys/kernel/mm/swap/singlemapped_ra_enabled
else
    echo "false" > /sys/kernel/mm/swap/singlemapped_ra_enabled
    #CBATCH=1
    #DBATCH=0
fi

echo ${DBATCH} > /proc/sys/vm/page-cluster || handle_error "Failed to set page-cluster"

# Note: This is a temporary solution as we transition the parameter names.
PARAM_VALUE=$(sysctl -n  vm.compress-batchsize 2>/dev/null)
EXIT_CODE=$?
if  [ ${EXIT_CODE} -eq 0 ]; then
    sysctl vm.compress-batchsize=${CBATCH}  || handle_error "Failed to set compress-batchsize"
fi

PARAM_VALUE=$(sysctl -n  vm.reclaim-batchsize 2>/dev/null)
EXIT_CODE=$?
if  [ ${EXIT_CODE} -eq 0 ]; then
    sysctl vm.reclaim-batchsize=${CBATCH}  || handle_error "Failed to set compress-batchsize"
fi

# Clear transparent huge pages configuration
echo 'never' > /sys/kernel/mm/transparent_hugepage/hugepages-2048kB/enabled || handle_error "Failed to clear hugepages-2048kB configuration"
echo 'never' > /sys/kernel/mm/transparent_hugepage/enabled || handle_error "Failed to clear transparent_hugepage configuration"



# Set mTHP
mthp_sizes=('16kB' '32kB' '64kB' '128kB' '256kB' '512kB' '1024kB' '2048kB')
IFS=',' read -a mthp_list <<< "$MTHP"
#echo ${mthp_list[@]}

for mthp in "${mthp_sizes[@]}"; do
    echo 'never'> /sys/kernel/mm/transparent_hugepage/hugepages-${mthp}/enabled
done

max_mthp=0
for mthp in "${mthp_list[@]}"; do
    mthp=`echo $mthp | tr -d ' '`
    if [[ ${mthp_sizes[@]} =~ ($mthp) ]] ; then
        if [ $mthp != '4kB' ]; then
            echo "configuring mthp ${mthp}"
            echo 'always' > /sys/kernel/mm/transparent_hugepage/hugepages-${mthp}/enabled
	fi
    fi
done


# Calculate swap size and pages
SZ=$(ls -s "$SWAP" | awk '{print $1}')
PAGE_SIZE=${mthp_list[0]}
PAGE_SIZE=4kB
echo "page-size:${PAGE_SIZE}"
PAGE_SIZE=$(echo ${PAGE_SIZE} | awk '{print substr($1,1,length($1)-2)}' )
NPGS=$(echo "scale=0; $SZ/${PAGE_SIZE}" | bc -l)
# change it to bytes
PAGE_SIZE=$(( PAGE_SIZE * 1024))

QAT_ENABLED=`bpftrace -l | grep qat_comp_alg_compress | wc -l`

CMD="./madvise_test ${SWAP} ${NPGS} ${PAGE_SIZE}"
echo ${CMD}
if [[ $COMP == 'deflate-iaa-canned' || $COMP == 'deflate-iaa-dynamic'||$COMP == 'deflate-iaa' ]];then
    COMP_STR="iaa_comp_acompress"
    DCOMP_STR="iaa_comp_adecompress"
    SZ_STR="arg0+68"
    #SZ_STR="((struct acomp_req*)arg0)->dlen"
elif [ $COMP == 'lzo-rle' ]; then
    COMP_STR="lzorle_scompress"
    DCOMP_STR="lzorle_sdecompress"
    SZ_STR="arg4"
elif [ $COMP == 'qat_deflate' ] &&  [ ${QAT_ENABLED} -gt 0 ]; then
    COMP_STR="qat_comp_alg_compress"
    DCOMP_STR="qat_comp_alg_decompress"
    SZ_STR="arg4"
else
    COMP_STR="${COMP}_scompress"
    DCOMP_STR="${COMP}_sdecompress"
    SZ_STR="arg4"
fi


# TODO:  count errors from swap_crypto_acomp_compress_batch

PROG=`echo "kprobe:${COMP_STR} { @start=nsecs; @sz=${SZ_STR}; } kretprobe:${COMP_STR} { printf (\"C %d\\nR %d\\n\", nsecs-@start, *@sz); } 
            kprobe:${DCOMP_STR} { @start=nsecs; } kretprobe:${DCOMP_STR} { printf (\"D %d\\n\", nsecs-@start); } 

	    kprobe:swap_writepage { @start_swap_write=nsecs; } kretprobe:swap_writepage { printf (\"SW %d\\n\", nsecs-@start_swap_write); } 
	    kprobe:swap_read_folio { @start_swap_read=nsecs; } kretprobe:swap_read_folio { printf (\"SR %d\\n\", nsecs-@start_swap_read);} 

	    END { delete(@start); delete(@sz);}"`

perf stat -o perf_${COMP}.log bpftrace -e "${PROG}" -c "${CMD}" -o ${COMP}_output
echo "Script completed successfully."


