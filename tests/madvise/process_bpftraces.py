#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation
"""process bpf traces"""

import glob
import os
import re
import sys
import numpy as np
import pandas as pd
from bokeh import resources
from bokeh.plotting import figure, save
from bokeh.models import PanTool, ResetTool, HoverTool, BoxZoomTool, SaveTool

def transform_test_column(value):
    """transform the test column"""
    transformation_map = {
        'canned': 'iaa-canned',
        'dynamic': 'iaa-dynamic',
        'lzo-rle': 'lzo-rle',
        'deflate-iaa': 'iaa-fixed',
        'deflate-iaa-canned': 'iaa-canned',
        'deflate-iaa-dynamic': 'iaa-dynamic'
    }
    return transformation_map.get(value, value)

def draw_cdf(fig, fl, color, label_name, filter_col,line_style,log_scale=False):
    """draw cdf"""
    keys=['C','D','P','R', 'SR', 'SW', 'ZC', 'ZD']
    try:
        df = pd.read_csv(fl, sep=' ', engine='python', skiprows=1, skipfooter=3, header=None)
    except IOError:
        print(f'{fl} cannot be loaded into dataframe as csv file')
        sys.exit(1)

    pd.options.display.float_format = '{:,.0f}'.format

    # Extract zswap_compress size and zswap_compress return code
    zswap_compsize_series = df[1][(df[0] == "ZCSZ")]
    zswap_compsize_series.reset_index(drop=True,inplace=True)

    zswap_compret_series = df[1][(df[0] == "ZCR")]
    zswap_compret_series.reset_index(drop=True,inplace=True)

    zswap_compsize_ret_df = pd.DataFrame({'compsize': zswap_compsize_series, 'ret':\
                            zswap_compret_series})
    zswap_compsize_ret_df = zswap_compsize_ret_df.reset_index(drop=True)

    ret_eqone = zswap_compsize_ret_df['ret'] == 1
    ret_eqzero = zswap_compsize_ret_df['ret'] == 0
    zswap_size=zswap_compsize_ret_df[ret_eqone ]['compsize'].sum()
    zswap_success_cnt=zswap_compsize_ret_df[ret_eqone].shape[0]
    zswap_failure_cnt=zswap_compsize_ret_df[ret_eqzero].shape[0]

    comp_size=df[1][(df[0] == "R") & (df[1] >= 0)].sum()

    df = df[df[0] == filter_col]
    df = df[df[1] >= 0]

    if filter_col == 'R':
        df[1] = 4096.0 / df[1]

    max_len = 10000
    if len(df) > max_len:
        df = df.sample(max_len, random_state=42)

    df = df.transform(np.sort)
    df = df.reset_index(drop=True)

    total_p99 = df[df.columns[-1]].quantile(0.99)
    df = df[df[df.columns[-1]] < total_p99]

    df['percentile'] = df.index / len(df)

    p50 = df[1].quantile(0.50) #if not log_scale else df['numbers'].quantile(0.50)
    p99 = df[1].quantile(0.99) #if not log_scale else df['numbers'].quantile(0.99)

    perf_log=str(f"perf_{label_name}.log")
    sys_time=0
    if os.path.exists(perf_log):
        with open(perf_log, "r") as file:
            content = file.read()
            # Extract values using regular expressions
            matches = re.findall(r"(\d+\.\d+) seconds (user|sys|time elapsed)", content)
            times = {key: float(value) for value, key in matches}
            sys_time = float(times["sys"])
            df['sys_time'] = sys_time

    if filter_col in keys:
        dicts={
        'compressor': label_name,
        'var':filter_col,
        'p50':p50,
        'p99':p99,
        'comp_size':comp_size,
        'zswap_size': zswap_size,
        'zswap_success_cnt':zswap_success_cnt,
        'zswap_failure_cnt':zswap_failure_cnt,
        'sys_time':sys_time
         }
        print(f'{label_name} {filter_col} {p50:.1f} {p99:.1f} {comp_size:.1f} {zswap_size:.1f}\
            {zswap_success_cnt:.1f} {zswap_failure_cnt:.1f} {sys_time:.2f} ' if filter_col ==\
            'R' else f'{label_name} {filter_col} {p50:.0f} {p99:.0f} {comp_size:.1f}\
            {zswap_size:.1f} {zswap_success_cnt:.1f} {zswap_failure_cnt:.1f} {sys_time:.2f}')

    label_name = transform_test_column(label_name)
    if log_scale and filter_col != 'R':
        df[1] = np.log(df[1])
        df = df.replace([np.inf, -np.inf], np.nan).dropna()
        fig.line(df[1], df['percentile'], line_width=4, color=color,
                 legend_label=f'{label_name} (p50: {p50:.0f}, p99: {p99:.0f})', name=label_name,\
                    line_dash=line_style)
    else:
        if filter_col == 'R':
            fig.line(df[1], df['percentile'], line_width=4, color=color, legend_label=\
            f'{label_name} (p50: {p50:.2f}, p99: {p99:.2f})', name=label_name,line_dash=line_style)

        else:
            fig.line(df[1], df['percentile'], line_width=4, color=color, legend_label=\
            f'{label_name} (p50: {p50:.0f}, p99: {p99:.0f})', name=label_name, line_dash=line_style)

        return dicts

def create_figure(title, x_axis_label, y_axis_label, log_scale):
    """create figure"""
    fig = figure(
        title=title,
        x_axis_label=x_axis_label,
        x_axis_type='log' if log_scale else 'linear',
        y_axis_label=y_axis_label,
        width=960,
        height=768,
        tools=[HoverTool(tooltips=[("name", "$name")]), BoxZoomTool(), PanTool(), SaveTool(),\
            ResetTool()])
    return fig

def plot_df(infiles, log_scale=False):
    """plot df"""
    line_styles = ["solid", "dashed", "dotdash", "dotted"]
    colors = ["blue", "red", "green", "orange", "magenta", "cyan", "lime", "darkorange",\
        "cornsilk", "chartreuse", "aqua", "salmon", "fuchsia", "hotpink", "tomato", "olivedrab",\
        "aquamarine", "olive", "wheat", "darkolivegreen", "violet", "darkseagreen",\
        "paleturquoise", "goldenrod", "skyblue", "silver", "gold", "azure", "slateblue",\
        "firebrick", "orchid", "greenyellow", "teal", "maroon", "cornflowerblue", "tan",\
        "forestgreen", "lightcoral", "mistyrose", "lavenderblush", "lavender", "mediumvioletred"]

    if log_scale:
        xlabel = "Latency (ns) in logarithmic scale"
    else:
        xlabel = "Latency (ns)"

    figures = {
        "C": create_figure("Compress",xlabel, "CDF", log_scale),
        "D": create_figure("Decompress",xlabel, "CDF", log_scale),
        "P": create_figure("Page Fault",xlabel, "CDF", log_scale),
        "R": create_figure("Compression Ratio", "Compression Ratio", "CDF", log_scale),
        "SW": create_figure("swap_writepage()", xlabel, "CDF", log_scale),
        "SR": create_figure("swap_read_folio()", xlabel, "CDF", log_scale),
        "ZC": create_figure("zswap_compress()", xlabel, "CDF", log_scale),
        "ZD": create_figure("zswap_decompress()", xlabel, "CDF", log_scale)
    }

    results = []
    for fl in infiles:
        label = fl.replace('_output', '')
        for key, fig in figures.items():
            line_style = line_styles[infiles.index(fl) % len(line_styles)]
            df_dict=draw_cdf(fig, fl, colors[infiles.index(fl) % len(colors)], label, key,\
                line_style, log_scale)
            results.append(df_dict)


    for key, fig in figures.items():
        fig.legend.location = 'bottom_right'
        fig.legend.click_policy = 'hide'
        fig.legend.label_text_font_size = '14pt'
        fig.xaxis.axis_label_text_font_size = "18pt"
        fig.yaxis.axis_label_text_font_size = "18pt"
        fig.xaxis.major_label_text_font_size = "10pt"  # Adjust this value as needed for larger\
                                                       # xticks
        save(fig, filename=f'{key.lower()}_{"log_scale_" if log_scale else ""}cdf.html',\
            title=fig.title.text, resources=resources.INLINE)

    if log_scale is False:
        results_df = pd.DataFrame(results)
        results_df = results_df.sort_values(by=['var', 'compressor'])
        results_df = results_df.reset_index(drop=True)
        print('Saving summary results at summary.xlsx')
        results_df.to_excel('summary.xlsx')
# Main script
files = glob.glob('*_output')
plot_df(files, log_scale=False)
