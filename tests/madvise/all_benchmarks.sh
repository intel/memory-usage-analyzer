#!/usr/bin/env bash

mode=${1:-zswap}
reps=${2:-3}
mthp=${3:-"4kB,64kB,2048kB"}
kernel=$(uname -r)
echo $kernel
if [ "$kernel" == "7.2.0-rc1-dc59+" ];then
    kernel_str="upstream"
elif [ "$kernel" == "7.2.0-rc1-01d7+" ];then
    kernel_str="zram-backend"
elif [ "$kernel" == "7.2.0-rc1-5627+" ];then
    kernel_str="all_patches"
elif [ "$kernel" == "7.2.0-rc6-4b5c+" ];then
    kernel_str="zswap-base"
elif [ "$kernel" == "7.2.0-rc6-55ac+" ];then
    kernel_str="zswap-mthp-v1"
else
    echo "Kernel not found"
    exit
fi

# Split comma-separated mTHP sizes into individual runs
IFS=',' read -ra mthp_list <<< "$mthp"

for mthp_size in "${mthp_list[@]}"; do
    mthp_tag="_mthp_${mthp_size}"
    mthp_flag="--mthp $mthp_size"

    dir_name="${mode}_${kernel_str}${mthp_tag}"
    mkdir -p "${dir_name}"
    rm -rf "${dir_name:?}"/*

    echo ""
    echo "========================================="
    echo " Mode: $mode | Kernel: $kernel_str | mTHP: $mthp_size"
    echo "========================================="

    for rep in $(seq 1 "$reps"); do
        cmd="./${mode}_microbench.sh ${mthp_flag} | tee ${dir_name}/${dir_name}_${rep}.txt"
        echo "$cmd"; eval "$cmd"
    done
done
