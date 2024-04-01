#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""Utility module"""
import os
import os.path
import platform
import sys
import re
import pandas

def kernel_version():
    """returns the kernel version"""
    version = re.match(r'(\d+.\d+)', platform.release()).group(1)
    major, minor = version.split('.')
    # Try to handle the case like kernel 5.4 > 5.12
    if len(minor) == 1:
        minor = '0' + minor
    version = major + '.' + minor

    try:
        return float(version)
    except ImportError:
        print(f'ERROR: cannot determine the kernel version by {version}')
        sys.exit(0)

def to_int(value):
    """convert to integer"""
    try:
        return int(float(value))
    except ImportError:
        value = value.lower()

    if value[-1] == 't':
        units = 1 << 40
    elif value[-1] == 'g':
        units = 1 << 30
    elif value[-1] == 'm':
        units = 1 << 20
    elif value[-1] == 'k':
        units = 1 << 10
    else:
        print(f'ERROR: invalid memory size value {value}')
        sys.exit(0)

    return int(float(value[:-1]) * units)

def unique_dir(orig):
    """Created the unique dir"""
    path = orig
    index = 1
    while os.path.exists(path):
        path = f'{orig}.{index}'
        index += 1
    os.mkdir(path)
    return path

def get_file_sum(df):
    """returns the file sum"""
    return df.cgroup_memory_stat_active_file + df.cgroup_memory_stat_inactive_file

def get_cgroup_total(df):
    """returns cgroup total memory"""
    if 'cgroup_memory_current' in df.columns:
        cgroup_total = df.cgroup_memory_stat_active_anon +\
                         df.cgroup_memory_stat_inactive_anon +\
                         df.cgroup_memory_swap_current +\
                         df.cgroup_memory_stat_active_file + \
                         df.cgroup_memory_stat_inactive_file + \
                         df.cgroup_memory_stat_unevictable
    else:
        cgroup_total = df.cgroup_memory_stat_total_active_anon +\
                         df.cgroup_memory_stat_total_inactive_anon  +\
                         df.cgroup_memory_stat_total_swap  +\
                         df.cgroup_memory_stat_total_active_file  +\
                         df.cgroup_memory_stat_total_inactive_file +\
                         df.cgroup_memory_stat_total_unevictable
    return cgroup_total

def cold_hot_total(df, gb=True, dataframe=False):
    """returns the hot and cold memory
    active: Amount of memory usage excluding page_cache, zpool, and zram. For cgroup v2,
     memory.current includes page_cache, so exclude it while calculating active memory.
     Ref: https://facebookmicrosites.github.io/cgroup2/docs/memory-controller.html
    swap: Total memory swapped out (to zswap and/or zram) is swap. We are getting it from
     memory.swap.current of cgroup v2.
    page_cache (filesystem page_cache): We get it from memory.stat.file of cgroup v2.
    total: sum of active, swap, and page_cache. Based on the experimental results,
     memory.current, which is used to calculate active, includes zpool_size.
     So, there is no need to include it in the total.
    """
    scale = (1 << 30) if gb else 1
    if dataframe:
        if 'cgroup_memory_current' in df.columns:
            swap = df.cgroup_memory_swap_current  / scale
            active = (df.cgroup_memory_current - df.cgroup_memory_stat_file) / scale
            page_cache = df.cgroup_memory_stat_file / scale
        else:
            swap = df.cgroup_memory_stat_total_swap / scale
            active = (df.cgroup_memory_usage_in_bytes - df.cgroup_memory_stat_cache) / scale
            page_cache = df.cgroup_memory_stat_cache / scale

        zpool_size = df.zswap_pool_total_size / scale
        active -= zpool_size # Adjust for zpool size included in memory.current
        total = swap + active + page_cache
    else:
        zpool_size = df.zswap_pool_total_size.max() / scale
        total_df_tmp = df.cgroup_memory_swap_current - df.zswap_pool_total_size
        if 'cgroup_memory_current' in df.columns:
            swap = df.cgroup_memory_swap_current.max() / scale
            active = (df.cgroup_memory_current - df.cgroup_memory_stat_file -\
                      df.zswap_pool_total_size).max() / scale
            page_cache = df.cgroup_memory_stat_file.max() / scale
            total_df = df.cgroup_memory_current + total_df_tmp
            total = total_df.max() / scale
        else:
            swap = df.cgroup_memory_stat_total_swap.max() / scale
            active = (df.cgroup_memory_usage_in_bytes - df.cgroup_memory_stat_cache -\
                      df.zswap_pool_total_size).max() / scale
            page_cache = df.cgroup_memory_stat_cache.max() / scale
            total_df = df.cgroup_memory_usage_in_bytes  + total_df_tmp
            total = total_df.max() / scale
    return swap, active, page_cache, total

def calculate_savings(df):
    """return memory savings"""
    max_memory_with_cache = max_memory_usage(df, dataframe=True)
    # Maximum memory savings
    total_max_idx=df.total.idxmax()
    total_max=df.total.max()
    memory_with_cache_for_total_max_idx=max_memory_with_cache[total_max_idx]
    memory_savings_bytes = total_max -memory_with_cache_for_total_max_idx
    memory_savings_percent = memory_savings_bytes / total_max * 100
    # Median memory savings
    total_median=df.total.median()
    memory_with_cache_median=max_memory_with_cache.median()
    memory_savings_bytes_median = total_median -memory_with_cache_median
    memory_savings_percent_median = memory_savings_bytes_median / total_median * 100
    return memory_savings_bytes, memory_savings_percent,memory_savings_percent_median

def compression_ratio(df, dataframe=False):
    """Return compression ratio of zswap pages excluding and including same filled pages
    Zram parameters were parsed from /sys/block/zram<id>/mm_stat file.
    The parameter zram_mem_used_total is used to calculate ratio instead of zram_compr_data_size.
    The definition of mem_used_total and compr_data_size  are as follow (1):

    mem_used_total: the amount of memory allocated for this disk. This
                  includes allocator fragmentation and metadata overhead
                  allocated for this disk. So, allocator space efficiency
                  can be calculated using compr_data_size and this statistic.
                  Unit: bytes

    compr_data_size: the compressed size of data stored in this disk

    Reference: https://www.kernel.org/doc/Documentation/blockdev/zram.txt
               https://www.kernel.org/doc/Documentation/cgroup-v2.txt

    The equation for ratio calculation is:
    # We are not considering the median as we see huge variation in data. This approach is
    # deprecated, and we are using the ratio of cdf.
    #                               4096 *(zswap_stored_pages - zswap_same_filled_pages) +
    #                               (zram_orig_data_size - 4096 * zram_same_pages)
    # ratio_without_same_filled = median(----------------------------------------------)
	# 								    zswap_pool_total_size + zram_mem_used_total

	# 			                        4096 * df.zswap_stored_pages + zram_orig_data_size
    # ratio_without_same_filled = median(---------------------------------------------------)
    #                                        zswap_pool_total_size + zram_mem_used_total
    
    """
    if dataframe:
        ratio_without_same_filled = (4096 * (df.zswap_stored_pages - df.zswap_same_filled_pages) +
                                     (df.zram_orig_data_size - 4096 * df.zram_same_pages)) /\
                                     (df.zswap_pool_total_size + df.zram_mem_used_total)
        ratio_with_same_filled = (4096 * df.zswap_stored_pages + df.zram_orig_data_size) /\
                                    (df.zswap_pool_total_size + df.zram_mem_used_total)
    else:
        ratio_with_same_filled = ((4096 * df.zswap_stored_pages.sum() +\
                                   df.zram_orig_data_size.sum()) /
                                   (df.zswap_pool_total_size.sum() + df.zram_mem_used_total.sum()))
        ratio_without_same_filled = ((4096 * (df.zswap_stored_pages.sum() -\
                                    df.zswap_same_filled_pages.sum()) +\
                                (df.zram_orig_data_size.sum() - 4096 * df.zram_same_pages.sum()))/\
                                (df.zswap_pool_total_size.sum() + df.zram_mem_used_total.sum()))
    return ratio_without_same_filled, ratio_with_same_filled

def max_memory_usage(df, gb=True, dataframe=False):
    """calculates max memory usage"""
    scale = (1 << 30) if gb else 1
    if 'cgroup_memory_current' in df.columns:
        max_memory = (df.cgroup_memory_current
                      + df.zram_mem_used_total
                     ) / scale
    else:
        #need to check if page cache has already been included in memory_usage_in_bytes
        max_memory = (df.cgroup_memory_usage_in_bytes
                      + df.zram_mem_used_total
                     ) / scale
    if dataframe:
        return max_memory
    return max_memory.max()

def avg_memory_usage(df, gb=True):
    """returns the average memory"""
    scale = (1 << 30) if gb else 1
    if 'cgroup_memory_current' in df.columns:
        avg_memory = (df.cgroup_memory_current + df.zswap_pool_total_size -\
                      df.cgroup_memory_stat_file).mean() / scale
    else:
        avg_memory = (df.cgroup_memory_usage_in_bytes + df.zswap_pool_total_size -\
                      df.cgroup_memory_stat_cache).mean() / scale
    return avg_memory

def read_stats_df(filename):
    """
    hot -> active : memory.current - available memory for workloads as zpool/zram shares
    the same memory
    cold -> swap : cgroup_memory_swap_current
    zswap_pool_total_size -> zpool_size: cgroup_memory.zswap.current or zswap_pool_total_size 
    cache -> page-cache:  cgroup_memory.stat.file
    saved/compression_savings: Savings in the swap = current swap (in swap) - compressed swap
    (in zswap and zram)
    compressed swap: Sum of the space occupied in zswap and zram.
    compressed total: Total memory including the compressed tier (zswap, zram),
    active+zpool_size+zram.
    total -> active+swap
    """
    df = pandas.read_csv(filename)
    df['t'] = (df.time - df.time[0]) / 60
    swap, active, page_cache, total = cold_hot_total(df, gb=True, dataframe=True)

    df['swap'] = swap
    df['zpool_size+zram'] = (df.zswap_pool_total_size + df.zram_mem_used_total) / (1 << 30)
    df['active'] = active
    df['total'] = total
    df['page_cache'] = page_cache
    df['saved'] = df.swap - df["zpool_size+zram"]

    if 'cgroup_memory_current' in df.columns:
        df['active + zpool_size + zram'] = (df.cgroup_memory_current + df.zram_mem_used_total)\
                                            / (1<<30)
    else:
        df['active + zpool_size + zram'] = (df.cgroup_memory_usage_in_bytes +\
                                            df.zram_mem_used_total) / (1<<30)
    return df
