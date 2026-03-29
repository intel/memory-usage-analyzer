#!/usr/bin/env python3
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Parse the results from bpftraces and generate reports

import argparse
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt
from scipy import stats
import bokeh.resources as resources
from bokeh.plotting import figure, gridplot, save
from bokeh.models import PanTool, ResetTool, HoverTool, BoxZoomTool, SaveTool
import glob
import os
import re

def transform_test_column(value):
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
    #keys=['C','D','P','R', 'SR', 'SW', 'ZC', 'ZD']
    keys=['C','D', 'R', 'SR', 'SW', 'SRU', 'SWU', 'ZC', 'ZD' ]
    try:
        df = pd.read_csv(fl, sep=' ', engine='python', skiprows=1, skipfooter=3, header=None)
    except IOError:
        print(f'{fl} cannot be loaded into dataframe as csv file')
        exit(1)

    
    pd.options.display.float_format = '{:,.0f}'.format

    # Extract zswap_compress size and zswa_compress return code
    # Handle the case when there are no valid compression ratio values
    if filter_col == 'R':
        comp_size_df = df[df[0] == "R"]
        if comp_size_df.empty:
            comp_size = 0
        else:
            # Get valid values from comp_size_df directly without using df as reference
            valid_indices = comp_size_df[1] >= 0
            comp_size = comp_size_df.loc[valid_indices, 1].sum() if valid_indices.any() else 0
    else:
        comp_size = df.loc[(df[0] == "R") & (df[1] >= 0), 1].sum()

    # Filter the dataframe
    df = df[df[0] == filter_col]
    df = df[df[1] >= 0]

    if df.empty:
        print(f'DataFrame is empty for {filter_col}!')
        return None 


    if filter_col == 'R':
        df[1] = 4096.0 / df[1]

    max_len = 10000
    if len(df) > max_len:
        df = df.sample(max_len, random_state=42)

    # Safe transformation to avoid NaN issues
    df = df.copy()
    df[1] = np.sort(df[1].values)
    df = df.reset_index(drop=True)

    


    # Safely calculate quantiles to avoid NumPy warnings
    if len(df) > 0:
        total_p99 = df[df.columns[-1]].quantile(0.99)
        # filtering only for large values
        if filter_col != 'BC' and filter_col != 'BD':
            df = df[df[df.columns[-1]] < total_p99]
    else:
        # Handle empty dataframe case
        return None

    df['percentile'] = df.index / len(df)


    if filter_col == 'R':
        # Handle potential NaN values when calculating compression ratio
        valid_values = df[1].dropna()
        if valid_values.empty:
            p50 = np.nan
            p99 = np.nan
        else:
            p50 = valid_values.quantile(0.50)
            p99 = valid_values.quantile(0.99)
    else:
        p50 = df[1].quantile(0.50)
        p99 = df[1].quantile(0.99)

    PERF_LOG=str(f"perf_{label_name}.log")
    sys_time=0 
    if os.path.exists(PERF_LOG):
        with open(PERF_LOG, "r") as file:
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
        'sys_time':sys_time
         }
        
        # Format output based on filter_col and handle NaN values
        if filter_col == 'R':
            if np.isnan(p50) or np.isnan(p99):
                print(f'{label_name} {filter_col} N/A N/A {comp_size:.1f} {sys_time:.2f}')
            else:
                print(f'{label_name} {filter_col} {p50:.1f} {p99:.1f} {comp_size:.1f} {sys_time:.2f}')
        else:
            print(f'{label_name} {filter_col} {p50:.0f} {p99:.0f} {comp_size:.1f} {sys_time:.2f}')
    
    label_name = transform_test_column(label_name)
    
    # Handle different cases for plotting
    if log_scale and filter_col != 'R':
        # For log scale, handle values that might be negative or zero
        valid_values = df[1][df[1] > 0]  # Only positive values can be logged
        if valid_values.empty:
            return dicts  # Return without plotting if no valid values
            
        df_valid = df.copy()
        df_valid[1] = np.log(valid_values)
        df_valid = df_valid.replace([np.inf, -np.inf], np.nan).dropna()
        
        fig.line(df_valid[1], df_valid['percentile'], line_width=4, color=color, 
                legend_label=f'{label_name} (p50: {p50:.0f}, p99: {p99:.0f})', name=label_name, line_dash=line_style)
    else:
        if filter_col == 'R':
            if np.isnan(p50) or np.isnan(p99):
                label_text = f'{label_name} (No valid ratio data)'
            else:
                label_text = f'{label_name} (p50: {p50:.2f}, p99: {p99:.2f})'
            
            # Only plot if we have valid data
            if not df[1].isna().all():
                fig.line(df[1], df['percentile'], line_width=4, color=color, 
                        legend_label=label_text, name=label_name, line_dash=line_style)
        else:
            fig.line(df[1], df['percentile'], line_width=4, color=color, 
                    legend_label=f'{label_name} (p50: {p50:.0f}, p99: {p99:.0f})', name=label_name, line_dash=line_style)

    return dicts

def create_figure(title, x_axis_label, y_axis_label, log_scale):
    fig = figure(
        title=title,
        x_axis_label=x_axis_label,
        x_axis_type='log' if log_scale else 'linear',
        y_axis_label=y_axis_label,
        width=960,
        height=768,
        tools=[HoverTool(tooltips=[("name", "$name")]), BoxZoomTool(), PanTool(), SaveTool(), ResetTool()])
    return fig

def plot_df(files, log_scale=False):
    line_styles = ["solid", "dashed", "dotdash", "dotted"]
    colors = ["blue", "red", "green", "orange", "magenta", "cyan", "lime", "darkorange", "cornsilk", "chartreuse", "aqua",
              "salmon", "fuchsia", "hotpink", "tomato", "olivedrab", "aquamarine", "olive", "wheat", "darkolivegreen", "violet",
              "darkseagreen", "paleturquoise", "goldenrod", "skyblue", "silver", "gold", "azure", "slateblue", "firebrick",
              "orchid", "greenyellow", "teal", "maroon", "cornflowerblue", "tan", "forestgreen", "lightcoral", "mistyrose",
              "lavenderblush", "lavender", "mediumvioletred"]

    if log_scale:
        xlabel = "Latency (ns) in logarithmic scale"
    else:
        xlabel = "Latency (ns)"

    figures = {
        "C": create_figure("Compress",xlabel, "CDF", log_scale),
        "D": create_figure("Decompress",xlabel, "CDF", log_scale),
        "R": create_figure("Compression Ratio", "Compression Ratio", "CDF", log_scale),
        "SW": create_figure("swap_writepage()", xlabel, "CDF", log_scale),
        "SR": create_figure("swap_read_folio()", xlabel, "CDF", log_scale),
    }

    results = []
    figures_cp = figures.copy()
    print(f'compressor field p50 p99 zpsize sys_time ') 
    print(f'------------------------------------ ') 
    
    # Check if we have any output files
    if not files:
        print("No output files found. Skipping analysis.")
        return
        
    for fl in files:
        label = fl.replace('_output', '')
        for key, fig in figures.items():
            try:
                line_style = line_styles[files.index(fl) % len(line_styles)]
                # Add header
                df_dict=draw_cdf(fig, fl, colors[files.index(fl) % len(colors)], label, key,line_style, log_scale)
                
                if ( df_dict is not None ):
                    # Only add valid entries
                    results.append(df_dict)
                else:
                    # Remove entries that are not valid
                    if key in figures_cp:
                        del figures_cp[key]
            except Exception as e:
                print(f"Error processing {fl} for {key}: {e}")
                continue


    for key, fig in figures_cp.items():
        fig.legend.location = 'bottom_right'
        fig.legend.click_policy = 'hide'
        fig.legend.label_text_font_size = '14pt'
        fig.xaxis.axis_label_text_font_size = "18pt"
        fig.yaxis.axis_label_text_font_size = "18pt"
        fig.xaxis.major_label_text_font_size = "10pt"  # Adjust this value as needed for larger xticks
        save(fig, filename=f'{key.lower()}_{"log_scale_" if log_scale else ""}cdf.html', title=fig.title.text, resources=resources.INLINE)


    if (log_scale == False):
        try:
            if results:
                results_df = pd.DataFrame(results)
                results_df = results_df.sort_values(by=['var', 'compressor'])
                results_df = results_df.reset_index(drop=True)
                print('Saving summary results at summary.xlsx')
                results_df.to_excel('summary.xlsx')
            else:
                print("No valid results to save to Excel")
        except Exception as e:
            print(f"Error saving results to Excel: {e}")

# Main script
try:
    files = glob.glob('*_output')
    files.sort()
    plot_df(files, log_scale=False)
    #plot_df(files, log_scale=True)
except Exception as e:
    print(f"An error occurred during script execution: {e}")
