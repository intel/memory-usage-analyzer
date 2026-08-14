#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

"""Utility module"""
import os
import os.path
import platform
import sys
import re
import numpy as np
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
    except ValueError:
        print(f'ERROR: cannot determine the kernel version by {version}')
        sys.exit(0)


def to_int(value):
    """convert to integer"""
    try:
        return int(float(value))
    except ValueError:
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
            active = (df.cgroup_memory_current - df.cgroup_memory_stat_file -
                      df.zswap_pool_total_size).max() / scale
            page_cache = df.cgroup_memory_stat_file.max() / scale
            total_df = df.cgroup_memory_current + total_df_tmp
            total = total_df.max() / scale
        else:
            swap = df.cgroup_memory_stat_total_swap.max() / scale
            active = (df.cgroup_memory_usage_in_bytes - df.cgroup_memory_stat_cache -
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
    #                                     zswap_pool_total_size + zram_mem_used_total

    #                                     4096 * df.zswap_stored_pages + zram_orig_data_size
    # ratio_without_same_filled = median(---------------------------------------------------)
    #                                        zswap_pool_total_size + zram_mem_used_total

    """
    has_same_filled = 'zswap_same_filled_pages' in df.columns
    has_same_pages = 'zram_same_pages' in df.columns
    has_stored_pages = 'zswap_stored_pages' in df.columns

    same_filled_pages = df['zswap_same_filled_pages'] if has_same_filled else 0
    same_pages = df['zram_same_pages'] if has_same_pages else 0
    stored_pages = df['zswap_stored_pages'] if has_stored_pages else 0

    if dataframe:
        ratio_without_same_filled = (4096 * (stored_pages - same_filled_pages) +
                                     (df.zram_orig_data_size - 4096 * same_pages)) /\
                                     (df.zswap_pool_total_size + df.zram_mem_used_total)
        ratio_with_same_filled = (4096 * stored_pages + df.zram_orig_data_size) /\
                                    (df.zswap_pool_total_size + df.zram_mem_used_total)
    else:
        stored_sum = stored_pages.sum() if has_stored_pages else 0
        same_filled_sum = same_filled_pages.sum() if has_same_filled else 0
        same_pages_sum = same_pages.sum() if has_same_pages else 0
        denominator = df.zswap_pool_total_size.sum() + df.zram_mem_used_total.sum()
        ratio_with_same_filled = ((4096 * stored_sum + df.zram_orig_data_size.sum()) /
                                   denominator)
        ratio_without_same_filled = ((4096 * (stored_sum - same_filled_sum) +
                                (df.zram_orig_data_size.sum() - 4096 * same_pages_sum)) /
                                denominator)
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
        avg_memory = (df.cgroup_memory_current + df.zswap_pool_total_size -
                      df.cgroup_memory_stat_file).mean() / scale
    else:
        avg_memory = (df.cgroup_memory_usage_in_bytes + df.zswap_pool_total_size -
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
    swap, active, page_cache, total = cold_hot_total(df, gb=True, dataframe=True)

    t           = (df.time - df.time[0]) / 60
    zpool_zram  = (df.zswap_pool_total_size + df.zram_mem_used_total) / (1 << 30)
    saved       = swap - zpool_zram

    if 'cgroup_memory_current' in df.columns:
        active_zpool_zram = (df.cgroup_memory_current + df.zram_mem_used_total) / (1 << 30)
    else:
        active_zpool_zram = (df.cgroup_memory_usage_in_bytes + df.zram_mem_used_total) / (1 << 30)

    # Assign all derived columns at once to avoid DataFrame fragmentation
    new_cols = pandas.DataFrame({
        't'                        : t,
        'swap'                     : swap,
        'zpool_size+zram'          : zpool_zram,
        'active'                   : active,
        'total'                    : total,
        'page_cache'               : page_cache,
        'saved'                    : saved,
        'active + zpool_size + zram': active_zpool_zram,
    }, index=df.index)

    # .copy() consolidates all internal memory blocks into one contiguous layout,
    # preventing PerformanceWarning in callers that add further columns.
    return pandas.concat([df, new_cols], axis=1).copy()


def find_crossing_point(x_values, y_values, threshold, return_status=False):
    """Find where the performance curve crosses the acceptable KPI threshold.

    Uses linear interpolation on the (x, y) data to locate the x coordinate
    where y crosses the *threshold* value.  This is equivalent to the
    ``find_crossing_point`` function in the iax-memcomp reference project.

    Parameters
    ----------
    x_values : list[float]
        X-axis values (e.g. memory savings %).
    y_values : list[float]
        Y-axis values (e.g. throughput delta % or regression %).
    threshold : float
        The KPI threshold line value on the y-axis.
    return_status : bool, optional
        If True, return ``(crossing_point, status_string)`` instead of just
        the crossing point.

    Returns
    -------
    float or tuple[float, str]
        The interpolated x value where y crosses the threshold.  If
        *return_status* is True, also returns a status string describing
        the result: ``'Single x-point'``, ``'Multiple x-points'``, or
        ``'No x-point'``.
    """
    x = np.array(x_values, dtype=float)
    y = np.array(y_values, dtype=float)

    # Drop NaN pairs
    mask = np.isfinite(x) & np.isfinite(y)
    x, y = x[mask], y[mask]

    if len(x) < 2:
        result = float(x[0]) if len(x) == 1 else 0.0
        return (result, "Insufficient data") if return_status else result

    # Sort by x for proper interpolation
    order = np.argsort(x)
    x, y = x[order], y[order]

    # Interpolate to 1000 evenly-spaced points
    x_interp = np.linspace(x.min(), x.max(), 1000)
    y_interp = np.interp(x_interp, x, y)

    # Find sign changes relative to threshold
    kpi_line = np.full_like(y_interp, threshold)
    sign_changes = np.argwhere(np.diff(np.sign(y_interp - kpi_line))).flatten()

    if len(sign_changes) > 1:
        crossing = round(float(np.min(x_interp[sign_changes])), 2)
        status = "Multiple x-points"
    elif len(sign_changes) == 1:
        crossing = round(float(x_interp[sign_changes[0]]), 2)
        status = "Single x-point"
    else:
        crossing = round(float(x.max()), 2)
        status = "No x-point"

    return (crossing, status) if return_status else crossing
