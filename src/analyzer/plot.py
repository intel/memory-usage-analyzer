#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""plotter to draw different memory analysis plots in the html file"""
import argparse
import subprocess
import bokeh

from bokeh.io import save
from bokeh.layouts import column
from bokeh.plotting import figure
from bokeh.models import ColumnDataSource, Div, Legend
from bokeh.palettes import Category10_10
from src.core.util import read_stats_df, compression_ratio, cold_hot_total, get_cgroup_total

parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
parser.add_argument('-v', '--view', action='store_true', help='view in firefox')
parser.add_argument('-t', '--title', default='memoryusageanalyzer plot', help='plot title')
parser.add_argument('--height', type=int, default=250, help='plot height')
parser.add_argument('-statfile', nargs='?', default='stats.csv.gz',\
       help='memoryusageanalyzer stats file')
parser.add_argument('-respath', nargs='?', default='./', help='output result path')
args = parser.parse_args()

# generate colors from a palette
COLOR_INDEX = 0
COLOR_DICT = {}
COLOR_PALETTE = Category10_10

def next_color(name=None):
    """function for line color"""
    global COLOR_INDEX
    if name in COLOR_DICT:
        return COLOR_DICT[name]

    result = COLOR_PALETTE[COLOR_INDEX]
    COLOR_INDEX = 0 if COLOR_INDEX == (len(COLOR_PALETTE) - 1) else COLOR_INDEX + 1

    if name is not None:
        COLOR_DICT[name] = result

    return result

# read data
df = read_stats_df(f'{args.statfile}')
df['zswap_swap'] = df.zswap_pool_total_size / (1 << 30)
df['zram_swap'] = df.zram_mem_used_total / (1 << 30)
t_sample = df.time.diff().mean()
source = ColumnDataSource(df)

# ----------------------------------------------------------------
# add plots
# ----------------------------------------------------------------
WIDTH = 3
ALPHA = 0.5
TOOLS = 'xwheel_zoom,xbox_zoom,box_zoom,reset'
PLOT_TEXT_SPACE = "&nbsp; &nbsp; &nbsp; &nbsp &nbsp; &nbsp; &nbsp; &nbsp &nbsp; &nbsp; &nbsp; &nbsp"
plots = []
plots.append(Div(text=f'<h1>{args.title}</h1>'))

# ----------------------------------------------------------------
# staked Hot/Cold Memory Usage plot
# ----------------------------------------------------------------
p = figure(
    height=args.height * 2,
    title='Memory Usage',
    x_axis_label='time (min)',
    y_axis_label='Memory (GiB)',
    tools=TOOLS,
    x_range=[0, max(df.t)],)

p.add_layout(Legend(), 'right')

p.varea_stack(['active', 'zswap_swap','zram_swap','saved', 'page_cache'], x='t',\
              color=['red', 'blue','aqua', 'grey', 'purple'], \
              legend_label=['active', 'zpool size', 'zram memused total', 'compression savings',\
                            'page_cache'],
              alpha=[ALPHA, ALPHA, ALPHA, ALPHA/2, ALPHA/2],\
              source=source)

x_range = p.x_range
p.legend.click_policy = 'hide'
plots.append(p)

TXT1=" <b> zpool_size + zram </b> = zswap_pool_total_size + zram_mem_used_total"
TXT2=" <b> swap </b> = cgroup_memory_swap_current"
TXT3=" <b> active </b> = cgroup_memory_current"
TXT4=" <b> active_swap </b> = swap + active"
TXT5=" <b> compression savings </b> = swap  - zpool_size - zram"
TXT6=" <b> page_cache </b> = cgroup_memory_stat_page_cache"
plots.append(Div(text=f'{PLOT_TEXT_SPACE} {TXT1}; {TXT2}; {TXT3}; {TXT4}; {TXT5}; {TXT6}'))

# ----------------------------------------------------------------
# Hot/Cold Memory Usage summary line plot
# ----------------------------------------------------------------

p = figure(
    height=args.height * 2,
    title='Memory Usage Line Plot',
    x_axis_label='time (min)',
    y_axis_label='Memory (GiB)',
    tools=TOOLS,
    x_range=x_range,)

p.add_layout(Legend(), 'right')
p.line(df.t, df.swap, color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='swap')
p.line(df.t, (df.zswap_pool_total_size  + df.zram_mem_used_total) / (1<<30), color=next_color(),\
       alpha=ALPHA, line_width=WIDTH, legend_label='zpool_size + zram')
p.line(df.t, df.active , color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='active')
p.line(df.t, df.page_cache, color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='page_cache')
p.line(df.t, df.total, color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='active_swap')
p.line(df.t, df.saved, color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='compression savings')

p.line(df.t, df["active + zpool_size + zram"], color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='active + zpool_size + zram')

p.legend.click_policy = 'hide'
plots.append(p)

# ----------------------------------------------------------------
#  LRUs line plot
# ----------------------------------------------------------------

p = figure(
    height=args.height * 2,
    title='LRUs',
    x_axis_label='time (min)',
    y_axis_label='Memory (GiB)',
    tools=TOOLS,
    x_range=x_range,)

cgroup_total = get_cgroup_total(df)

p.add_layout(Legend(), 'right')
p.line(df.t, cgroup_total / (1<<30), color=next_color(), alpha=ALPHA, line_width=WIDTH,\
       legend_label='cgroup active_swap')
p.line(df.t, df.total, color=next_color(), alpha=ALPHA, line_width=WIDTH,\
       legend_label='active_swap')

if 'cgroup_memory_current' in df.columns:
    p.line(df.t, df.cgroup_memory_stat_active_anon / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='active-anon')
    p.line(df.t, df.cgroup_memory_stat_inactive_anon / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='inactive-anon')
    p.line(df.t, df.cgroup_memory_swap_current / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='cgroup_total_swap')
    p.line(df.t, df.cgroup_memory_stat_active_file / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='active-file')
    p.line(df.t, df.cgroup_memory_stat_inactive_file / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='inactive-file')
    p.line(df.t, df.cgroup_memory_stat_file / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='page_cache')
    p.line(df.t, df.cgroup_memory_stat_unevictable / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='unevictable')
else:
    p.line(df.t, df.cgroup_memory_stat_active_swap_active_anon / (1<<30), color=next_color(),\
           alpha=ALPHA, line_width=WIDTH, legend_label='active-anon')
    p.line(df.t, df.cgroup_memory_stat_active_swap_inactive_anon / (1<<30), color=next_color(),\
           alpha=ALPHA, line_width=WIDTH, legend_label='inactive-anon')
    p.line(df.t, df.cgroup_memory_stat_active_swap_swap / (1<<30), color=next_color(),\
           alpha=ALPHA, line_width=WIDTH, legend_label='cgroup_total_swap')
    p.line(df.t, df.cgroup_memory_stat_active_swap_active_file / (1<<30), color=next_color(),\
           alpha=ALPHA, line_width=WIDTH, legend_label='active-file')
    p.line(df.t, df.cgroup_memory_stat_active_swap_inactive_file / (1<<30), color=next_color(),\
           alpha=ALPHA, line_width=WIDTH, legend_label='inactive-file')
    p.line(df.t, df.cgroup_memory_stat_active_swap_page_cache / (1<<30), color=next_color(),\
           alpha=ALPHA, line_width=WIDTH, legend_label='page_cache')
    p.line(df.t, df.cgroup_memory_stat_active_swap_unevictable / (1<<30), color=next_color(),\
           alpha=ALPHA, line_width=WIDTH, legend_label='unevictable')
    p.line(df.t, df.cgroup_memory_stat_anon / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='anon')
p.legend.click_policy = 'hide'
plots.append(p)

TXT = "<b> active_swap </b> = active + swap; <b> cgroup active_swap </b> = sum of all cgroup\
    statistics"
plots.append(Div(text=f'{PLOT_TEXT_SPACE} {TXT}'))

# ----------------------------------------------------------------
# Cold memory usage line plot
# ----------------------------------------------------------------
p = figure(
    height=args.height * 2,
    title='swap memory usage',
    x_axis_label='time (min)',
    y_axis_label='Memory (GiB)',
    tools=TOOLS,
    x_range=x_range,)

p.add_layout(Legend(), 'right')
p.line(df.t, df.zram_orig_data_size / (1<<30), color=next_color(), alpha=ALPHA, line_width=WIDTH,\
       legend_label='zram orig data size')
p.line(df.t, df.zram_compr_data_size / (1<<30), color=next_color(), alpha=ALPHA, line_width=WIDTH,\
       legend_label='zram compressed data size')
p.line(df.t, df.zram_mem_used_total / (1<<30), color=next_color(), alpha=ALPHA, line_width=WIDTH,\
       legend_label='zram active_swap memory used')
p.line(df.t, df.zram_huge_pages * 4096 / (1<<30), color=next_color(), alpha=ALPHA,\
       line_width=WIDTH, legend_label='zram incompressible data size')
p.line(df.t, df.zswap_pool_total_size / (1<<30), color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='zswap pool active_swap size')
p.line(df.t, df.swap, color=next_color(), alpha=ALPHA,
        line_width=WIDTH, legend_label='swap')
p.line(df.t, df["zpool_size+zram"], color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='zpool_size + zram')

p.legend.click_policy = 'hide'
plots.append(p)
TXT1=" <b> zpool_size + zram </b> =  zswap_pool_total_size + zram_mem_used_total"
TXT2=" <b> swap </b> = cgroup_memory_stat_active_swap_swap"
plots.append(Div(text=f'{PLOT_TEXT_SPACE} {TXT1}; {TXT2}'))

#--------------------------------------------------------------------
# Ratio Analysis
#--------------------------------------------------------------------
p = figure(
    height=args.height * 2,
    title='ratio analysis',
    x_axis_label='time (min)',
    y_axis_label='Ratio',
    tools=TOOLS,
    x_range=[0, max(df.t)],)

ratio_without_same_filled, ratio_with_same_filled = compression_ratio(df, dataframe=True)
p.add_layout(Legend(), 'right')
p.line(df.t, ratio_without_same_filled, color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='ratio_without_same_filled')
p.line(df.t, ratio_with_same_filled, color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='ratio_with_same_filled')
p.legend.click_policy = 'hide'
plots.append(p)
#--------------------------------------------------------------------
# ratio component analysis
#--------------------------------------------------------------------

p = figure(
    height=args.height * 2,
    title='ratio component analysis',
    x_axis_label='time (min)',
    y_axis_label='Memory (GiB)',
    tools=TOOLS,
    x_range=[0, max(df.t)],)

ratio_without_same_filled, ratio_with_same_filled = compression_ratio(df,dataframe=True)
swap, active, _, active_swap = cold_hot_total(df)
ratio, ratio_ = compression_ratio(df)
savings = swap - swap / ratio
Potential_compression_savings=100 * savings / active_swap
savings_proposed=(df.saved/df.total).median()*100
savings_proposed_1=(df.saved.median()/df.total.median())*100
p.add_layout(Legend(), 'right')
p.line(df.t, df.zram_orig_data_size / (1 << 30), color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='zram_orig_data_size')
p.line(df.t, df.zram_compr_data_size/ (1 << 30), color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='zram_compr_data_size')
p.line(df.t, 4096 * df.zram_same_pages/ (1 << 30), color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='4096 * zram_same_pages')
p.line(df.t, df.zswap_pool_total_size / (1 << 30), color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='zpool_size')
p.line(df.t, 4096 * df.zswap_stored_pages/ (1 << 30), color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='4096 * zswap_stored_pages')
p.line(df.t, 4096 * df.zswap_same_filled_pages/ (1 << 30), color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='4096 * zswap_same_filled_pages')
p.line(df.t, (df.zswap_pool_total_size + df.zram_mem_used_total) / (1<<30), color=next_color(),\
       alpha=ALPHA, line_width=WIDTH, legend_label='zpool_size + zram')

p.line(df.t, df.zram_mem_used_total/ (1 << 30), color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='zram_mem_used_total')

p.legend.click_policy = 'hide'
plots.append(p)

#--------------------------------------------------------------------
# Zram analysis
#--------------------------------------------------------------------
p = figure(
    height=args.height * 2,
    title='zram analysis',
    x_axis_label='time (min)',
    y_axis_label='Memory (GiB)',
    tools=TOOLS,
    x_range=[0, max(df.t)],)

ratio_without_same_filled, ratio_with_same_filled = compression_ratio(df, dataframe=True)
p.add_layout(Legend(), 'right')
p.line(df.t, df.zram_orig_data_size / (1 << 30) , color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='zram_orig_data_size')
p.line(df.t, df.zram_compr_data_size / (1 << 30), color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='zram_compr_data_size')
p.line(df.t, 4096 * df.zram_same_pages / (1 << 30), color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='4096 * zram_same_pages')
p.line(df.t, df.zram_mem_used_total/ (1 << 30), color=next_color(), alpha=ALPHA,
       line_width=WIDTH, legend_label='zram_mem_used_total')
p.legend.click_policy = 'hide'
plots.append(p)

# ----------------------------------------------------------------
# CPU Usage (stacked) plot
# ----------------------------------------------------------------

p = figure(
    height=args.height * 2,
    title='CPU Usage (stacked)',
    x_axis_label='time (min)',
    y_axis_label='usage',
    tools=TOOLS,
    x_range=x_range,)

p.add_layout(Legend(), 'right')

if 'cgroup_memory_current' in df.columns:
    df['y_user'] = df.cgroup_cpu_stat_user_usec.diff() / 1000000 / t_sample * 100
    df['y_system'] = df.cgroup_cpu_stat_system_usec.diff() / 1000000 / t_sample * 100
else:
    df['y_user'] = df.cgroup_cpu_cpuacct_stat_user.diff() / t_sample
    df['y_system'] = df.cgroup_cpu_cpuacct_stat_system.diff() / t_sample
source = ColumnDataSource(df)
p.varea_stack(['y_user', 'y_system'], x='t', color=('blue', 'green'), alpha=0.1,\
              legend_label=('user', 'system'), source=source)
p.vline_stack(['y_user', 'y_system'], x='t', color=('blue', 'green'),\
              legend_label=('user', 'system'), source=source)

p.legend.click_policy = 'hide'
p.y_range.start=0
plots.append(p)

# ----------------------------------------------------------------
# Memory Pressure line plot
# ----------------------------------------------------------------
if 'cgroup_memory_pressure_some_total' in df.columns:
    p = figure(
    height=args.height * 2,
    title='Memory Pressure',
    x_axis_label='time (min)',
    y_axis_label='stalled (msec)',
    tools=TOOLS,
    x_range=x_range,)

    p.add_layout(Legend(), 'right')

    p.line(df.t, df.cgroup_memory_pressure_some_total.diff() / 1000 / t_sample, color='red',\
           alpha=ALPHA, line_width=WIDTH, legend_label='some pressure')
    p.line(df.t, df.cgroup_memory_pressure_full_total.diff() / 1000 / t_sample, color='blue',\
           alpha=ALPHA, line_width=WIDTH, legend_label='full pressure')
    p.legend.click_policy = 'hide'
    plots.append(p)
else:
    print('cgroup_memory_pressure_some_total not exist in the stats dump')

# ----------------------------------------------------------------
# Page Faults line plot
# ----------------------------------------------------------------
p = figure(
    height=args.height,
    title='Page Fault Rate',
    x_axis_label='time (min)',
    y_axis_label='PF/sec',
    tools=TOOLS,
    x_range=x_range,)

p.add_layout(Legend(), 'right')
p.line(df.t, df.cgroup_memory_stat_pgmajfault.diff() / t_sample, color='red', alpha=ALPHA,\
       line_width=WIDTH, legend_label='Major Page fault')
p.line(df.t, df.cgroup_memory_stat_pgfault.diff() / t_sample, color='blue', alpha=ALPHA,\
       line_width=WIDTH, legend_label='Total Page Fault(Major+Minor)')
if 'cgroup_memory_stat_active_swap_pgfault' in df.columns:
    p.line(df.t, df.cgroup_memory_stat_active_swap_pgfault.diff() / t_sample, color='green',\
           alpha=ALPHA, line_width=WIDTH, legend_label='Total Page Fault(Major+Minor)')
p.legend.click_policy = 'hide'
plots.append(p)

# ----------------------------------------------------------------
# Compression decompression call rate line plot
# ----------------------------------------------------------------
#zswap_secondary_decompressions
# zswap_primary_decompressions
# zswap_secondary_compressions
# zswap_primary_compressions

if 'zswap_primary_decompressions' in df.columns:
    p = figure(
        height=args.height,
        title='Compression/decompression call rate',
        x_axis_label='time (min)',
        y_axis_label='call rate',
        tools=TOOLS,
        x_range=x_range,)

    p.add_layout(Legend(), 'right')
    p.line(df.t, df.zswap_primary_compressions.diff() / t_sample, color='red', alpha=ALPHA,\
           line_width=WIDTH, legend_label='primary_compressions')
    p.line(df.t, df.zswap_secondary_compressions.diff() / t_sample, color='blue', alpha=ALPHA,\
           line_width=WIDTH, legend_label='secondary_compressions')
    p.line(df.t, df.zswap_primary_decompressions.diff() / t_sample, color='green', alpha=ALPHA,\
           line_width=WIDTH, legend_label='primary_decompressions')
    p.line(df.t, df.zswap_secondary_decompressions.diff() / t_sample, color='black', alpha=ALPHA,\
           line_width=WIDTH, legend_label='secondary_decompressions')
    p.legend.click_policy = 'hide'
    plots.append(p)

if 'zswap_decompressions' in df.columns:
    p = figure(
        height=args.height,
        title='Compression/decompression call rate',
        x_axis_label='time (min)',
        y_axis_label='call rate',
        tools=TOOLS,
        x_range=x_range,)

    p.add_layout(Legend(), 'right')
    p.line(df.t, df.zswap_compressions.diff() / t_sample, color='red', alpha=ALPHA,\
           line_width=WIDTH, legend_label='compressions')
    p.line(df.t, df.zswap_decompressions.diff() / t_sample, color='green', alpha=ALPHA,\
           line_width=WIDTH, legend_label='decompressions')
    p.legend.click_policy = 'hide'
    plots.append(p)

# ----------------------------------------------------------------
# Compression decompression calls line plot
# ----------------------------------------------------------------
# zswap_secondary_decompressions
# zswap_primary_decompressions
# zswap_secondary_compressions
# zswap_primary_compressions

if 'zswap_primary_decompressions' in df.columns:
    p = figure(
        height=args.height,
        title='Compression/decompression calls',
        x_axis_label='time (min)',
        y_axis_label='call count',
        tools=TOOLS,
        x_range=x_range,)

    p.add_layout(Legend(), 'right')
    p.line(df.t, df.zswap_primary_compressions - df.zswap_primary_compressions.min(), color='red',\
           alpha=ALPHA, line_width=WIDTH, legend_label='primary_compressions')
    p.line(df.t, df.zswap_secondary_compressions - df.zswap_secondary_compressions.min(),\
           color='blue',alpha=ALPHA, line_width=WIDTH, legend_label='secondary_compressions')
    p.line(df.t, df.zswap_primary_decompressions - df.zswap_primary_decompressions.min(),\
           color='green', alpha=ALPHA, line_width=WIDTH, legend_label='primary_decompressions')
    p.line(df.t, df.zswap_secondary_decompressions - df.zswap_secondary_decompressions.min(),\
            color='black', alpha=ALPHA, line_width=WIDTH, legend_label='secondary_decompressions')
    p.legend.click_policy = 'hide'
    plots.append(p)

if 'zswap_decompressions' in df.columns:
    p = figure(
        height=args.height,
        title='Compression/decompression calls',
        x_axis_label='time (min)',
        y_axis_label='call count',
        tools=TOOLS,
        x_range=x_range,)

    p.add_layout(Legend(), 'right')
    p.line(df.t, df.zswap_compressions - df.zswap_compressions.min(), color='green', alpha=ALPHA,\
           line_width=WIDTH, legend_label='compressions')
    p.line(df.t, df.zswap_decompressions - df.zswap_decompressions.min(), color='blue',
           alpha=ALPHA, line_width=WIDTH, legend_label='decompressions')
    p.legend.click_policy = 'hide'
    plots.append(p)

# ----------------------------------------------------------------
# Memory footprint of the following events:
# memory.stat.anon-memory.stat.slab_unreclaimable
# (in https://www.kernel.org/doc/Documentation/cgroup-v2.txt)
# ----------------------------------------------------------------
p = figure(
    height=args.height * 2,
    title='Memory Footprint of various kernel events',
    x_axis_label='time (min)',
    y_axis_label='Memory (GiB)',
    tools=TOOLS,
    x_range=x_range,)

p.add_layout(Legend(), 'right')
if 'cgroup_memory_current' in df.columns:
    p.line(df.t, df.cgroup_memory_stat_anon / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='anon')
    p.line(df.t, df.cgroup_memory_stat_file / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='file')
    p.line(df.t, df.cgroup_memory_stat_kernel_stack / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='kernel_stack')

    if 'cgroup_memory_stat_slab' in df.columns:
        p.line(df.t, df.cgroup_memory_stat_slab / (1<<30), color=next_color(), alpha=ALPHA,\
               line_width=WIDTH, legend_label='slab')
        p.line(df.t, df.cgroup_memory_stat_slab_reclaimable / (1<<30), color=next_color(),\
               alpha=ALPHA, line_width=WIDTH, legend_label='slab_reclaimable')
        p.line(df.t, df.cgroup_memory_stat_slab_unreclaimable / (1<<30), color=next_color(),\
               alpha=ALPHA, line_width=WIDTH, legend_label='slab_unreclaimabl')

    p.line(df.t, df.cgroup_memory_stat_sock / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='sock')
    p.line(df.t, df.cgroup_memory_stat_shmem / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='shmem')
    p.line(df.t, df.cgroup_memory_stat_file_mapped / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='file_mapped')
    p.line(df.t, df.cgroup_memory_stat_file_dirty / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='file_dirty')
    p.line(df.t, df.cgroup_memory_stat_file_writeback / (1<<30), color=next_color(), alpha=ALPHA,\
           line_width=WIDTH, legend_label='file_writeback')

    p.legend.click_policy = 'hide'
    plots.append(p)

# ----------------------------------------------------------------
# generate the report
# ----------------------------------------------------------------
FILENAME = f'{args.respath}/memoryusageanalyzer-plots.html'
print(f'Generating plots {FILENAME}')
grid = column(plots, sizing_mode='stretch_width')
save(grid, FILENAME, bokeh.resources.INLINE, args.title)
if args.view:
    subprocess.run(f'firefox {FILENAME} &', shell=True, check=False)
