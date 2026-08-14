#!/usr/bin/env python3
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
"""
report_plot.py

Responsive Bokeh HTML report for 1..N .report files.

Plots:
  1) X = Save% (memory savings vs baseline)
     Y = ΔTput% (negative = regression)
     - Baseline line at 0
     - Regression threshold line at ΔTput% = -threshold (default 5)
     - Shades "bad" region below threshold

  2) X = Save% (memory savings vs baseline)
     Y = p99(ms)

Report includes:
  - Header + plots + per-series summary cards
    - Full parsed table per input file.
    - Accepts both legacy row-oriented reports and newer transposed reports
        where "Metric" is the first column and scenarios are column headers.
  - Self-contained HTML (INLINE resources)

Usage:
  python3 report_plot.py *.report
  python3 report_plot.py deflate-iaa.report lzo.report --threshold 3
"""

import argparse
import re
import statistics
import sys
from pathlib import Path
from typing import Dict, List, Any, Tuple

from bokeh.io import output_file, save
from bokeh.layouts import column
from bokeh.models import (
    ColumnDataSource,
    HoverTool,
    LabelSet,
    Div,
    Span,
    BoxAnnotation,
    NumeralTickFormatter,
)
from bokeh.models.widgets import DataTable, TableColumn
from bokeh.plotting import figure
from bokeh.resources import INLINE
from bokeh.palettes import Category10, Category20

# Allow importing from src/core when running from tests/redis/
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
from core.util import find_crossing_point

Row = Dict[str, Any]


def percent_variation(values: List[float]) -> tuple:
    """Calculate percentage variation of a numeric series.

    Returns (color, variation_pct) where color is 'red' when variation > 5%,
    otherwise 'black'. Mirrors the reference implementation in iax_plotter_v1.
    """
    cleaned = [v for v in values if v is not None and v == v]  # drop None/NaN
    if not cleaned:
        return "black", 0.0
    max_val = max(cleaned)
    if max_val == 0:
        return "black", 0.0
    min_val = min(cleaned)
    variation = round(100.0 * (max_val - min_val) / max_val, 2)
    color = "red" if variation > 5 else "black"
    return color, variation


def make_baseline_variation_section(series: List[Dict[str, Any]]) -> str:
    """Build HTML for baseline variation analysis across all series.

    Extracts the baseline row from each series and computes run-to-run
    variation in throughput (performance) and peak memory (total memory).
    Returns a self-contained HTML string.
    """
    baselines = []
    for s in series:
        bl_row = next((r for r in s["rows"] if r["scenario"] == "baseline"), None)
        if bl_row is not None:
            baselines.append({"name": s["name"], "row": bl_row})

    if not baselines:
        return (
            '<div style="margin:16px 0;">'
            "<h3>Baseline Variation Analysis</h3>"
            "<p>No baseline data available.</p>"
            "</div>"
        )

    tput_values = [b["row"]["tput_kops"] for b in baselines]
    mem_values = [b["row"]["peak_gib"] for b in baselines]
    p99_values = [b["row"]["p99_ms"] for b in baselines]

    perf_color, perf_var = percent_variation(tput_values)
    mem_color, mem_var = percent_variation(mem_values)
    p99_color, p99_var = percent_variation(p99_values)

    # Statistics
    tput_mean = statistics.mean(tput_values) if tput_values else 0.0
    tput_stdev = statistics.stdev(tput_values) if len(tput_values) > 1 else 0.0
    mem_mean = statistics.mean(mem_values) if mem_values else 0.0
    mem_stdev = statistics.stdev(mem_values) if len(mem_values) > 1 else 0.0
    p99_mean = statistics.mean(p99_values) if p99_values else 0.0
    p99_stdev = statistics.stdev(p99_values) if len(p99_values) > 1 else 0.0

    # Summary cards
    html = []
    html.append('<div style="margin: 24px 0;">')
    html.append('<h3 style="margin: 0 0 12px 0;">Baseline Variation Analysis</h3>')
    html.append('<div style="display:flex; flex-wrap:wrap; gap:12px; margin-bottom:16px;">')

    # Performance card
    html.append(
        f'<div style="border:1px solid #e5e7eb; border-radius:10px; padding:14px 18px; '
        f'background:#fafafa; min-width:220px;">'
        f'<div style="font-size:12px; color:#6b7280; margin-bottom:4px;">Baseline Performance Variation</div>'
        f'<div style="font-size:22px; font-weight:700; color:{perf_color};">{perf_var:.2f}%</div>'
        f'<div style="font-size:11px; color:#9ca3af; margin-top:4px;">'
        f'Mean: {tput_mean:.2f} KOPS &nbsp;|&nbsp; Std Dev: {tput_stdev:.2f}</div>'
        f'</div>'
    )

    # Memory card
    html.append(
        f'<div style="border:1px solid #e5e7eb; border-radius:10px; padding:14px 18px; '
        f'background:#fafafa; min-width:220px;">'
        f'<div style="font-size:12px; color:#6b7280; margin-bottom:4px;">Baseline Total Memory Variation</div>'
        f'<div style="font-size:22px; font-weight:700; color:{mem_color};">{mem_var:.2f}%</div>'
        f'<div style="font-size:11px; color:#9ca3af; margin-top:4px;">'
        f'Mean: {mem_mean:.2f} GiB &nbsp;|&nbsp; Std Dev: {mem_stdev:.4f}</div>'
        f'</div>'
    )

    # p99 latency card
    html.append(
        f'<div style="border:1px solid #e5e7eb; border-radius:10px; padding:14px 18px; '
        f'background:#fafafa; min-width:220px;">'
        f'<div style="font-size:12px; color:#6b7280; margin-bottom:4px;">Baseline p99 Latency Variation</div>'
        f'<div style="font-size:22px; font-weight:700; color:{p99_color};">{p99_var:.2f}%</div>'
        f'<div style="font-size:11px; color:#9ca3af; margin-top:4px;">'
        f'Mean: {p99_mean:.3f} ms &nbsp;|&nbsp; Std Dev: {p99_stdev:.4f}</div>'
        f'</div>'
    )

    html.append("</div>")  # close flex container

    # Variation indicator description
    html.append(
        '<p style="font-size:11px; color:#6b7280; margin:0 0 12px 0;">'
        "Variation &le; 5% is shown in <b>black</b> (stable). "
        'Variation &gt; 5% is shown in <b style="color:red;">red</b> (unstable, investigate).'
        "</p>"
    )

    # Baseline comparison table
    html.append(
        '<table style="border-collapse:collapse; font-family:monospace; font-size:12px; '
        'border:1px solid #ccc; width:100%; max-width:900px;">'
    )
    html.append("<thead>")
    html.append(
        '<tr style="background:#f0f0f0; border-bottom:2px solid #999;">'
        '<th style="padding:6px 10px; text-align:left; border-right:1px solid #ccc;">Compressor</th>'
        '<th style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">Tput (KOPS)</th>'
        '<th style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">Peak Memory (GiB)</th>'
        '<th style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">p99 Latency (ms)</th>'
        '<th style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">Swap Peak (GiB)</th>'
        '<th style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">Instances</th>'
        "</tr>"
    )
    html.append("</thead><tbody>")

    for b in baselines:
        row = b["row"]
        html.append(
            f'<tr style="border-bottom:1px solid #ddd;">'
            f'<td style="padding:6px 10px; font-weight:bold; border-right:1px solid #ccc;">{b["name"]}</td>'
            f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{row["tput_kops"]:.2f}</td>'
            f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{row["peak_gib"]:.2f}</td>'
            f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{row["p99_ms"]:.3f}</td>'
            f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{row["swap_gib"]:.2f}</td>'
            f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{row.get("actual_instances", 0)}</td>'
            f"</tr>"
        )

    # Statistics row
    html.append(
        f'<tr style="border-top:2px solid #999; background:#f9fafb;">'
        f'<td style="padding:6px 10px; font-weight:bold; border-right:1px solid #ccc;">Mean</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{tput_mean:.2f}</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{mem_mean:.2f}</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{p99_mean:.3f}</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">-</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">-</td>'
        f"</tr>"
    )
    html.append(
        f'<tr style="background:#f9fafb;">'
        f'<td style="padding:6px 10px; font-weight:bold; border-right:1px solid #ccc;">Std Dev</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{tput_stdev:.2f}</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{mem_stdev:.4f}</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{p99_stdev:.4f}</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">-</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">-</td>'
        f"</tr>"
    )
    html.append(
        f'<tr style="background:#f9fafb;">'
        f'<td style="padding:6px 10px; font-weight:bold; border-right:1px solid #ccc;">Variation %</td>'
        f'<td style="padding:6px 10px; text-align:right; font-weight:bold; color:{perf_color}; border-right:1px solid #ccc;">{perf_var:.2f}%</td>'
        f'<td style="padding:6px 10px; text-align:right; font-weight:bold; color:{mem_color}; border-right:1px solid #ccc;">{mem_var:.2f}%</td>'
        f'<td style="padding:6px 10px; text-align:right; font-weight:bold; color:{p99_color}; border-right:1px solid #ccc;">{p99_var:.2f}%</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">-</td>'
        f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">-</td>'
        f"</tr>"
    )

    html.append("</tbody></table>")
    html.append("</div>")

    return "\n".join(html)


def compute_crossing_points(
    series: List[Dict[str, Any]], threshold_pct: float,
    dtput_key: str = "dtput_pct", tput_key: str = "tput_kops",
) -> List[Dict[str, Any]]:
    """Compute the KPI crossing point for each series.

    For every compressor series, find the maximum memory savings (Save%)
    achievable before throughput regression exceeds the threshold.  Uses
    ``find_crossing_point`` from ``src/core/util.py``.

    Returns a list of dicts with keys: name, crossing_point, status,
    max_save_pct, baseline_tput.
    """
    thr_line = -abs(threshold_pct)
    results = []
    for s in series:
        rows = s.get("plot_rows", s["rows"])
        # Need non-baseline rows with save_pct data
        non_bl = [r for r in rows if r["scenario"] != "baseline"]
        bl_row = next((r for r in rows if r["scenario"] == "baseline"), None)

        if not non_bl or bl_row is None:
            results.append({
                "name": s["name"],
                "crossing_point": 0.0,
                "status": "No data",
                "max_save_pct": 0.0,
                "baseline_tput": bl_row[tput_key] if bl_row else 0.0,
            })
            continue

        # Include baseline origin (0, 0) so interpolation can find crossings
        # between baseline and the first memory-limited point
        x_vals = [0.0] + [r["save_pct"] for r in non_bl]
        y_vals = [0.0] + [r[dtput_key] for r in non_bl]

        crossing, status = find_crossing_point(
            x_vals, y_vals, thr_line, return_status=True
        )

        results.append({
            "name": s["name"],
            "crossing_point": crossing,
            "status": status,
            "max_save_pct": max(x_vals) if x_vals else 0.0,
            "baseline_tput": bl_row[tput_key],
        })

    # Sort by crossing point descending (best compressor first)
    results.sort(key=lambda r: r["crossing_point"], reverse=True)
    return results


def make_crossing_point_table(
    crossing_data: List[Dict[str, Any]], threshold_pct: float,
    heading: str = "KPI Crossing X-Points",
    metric_label: str = "&Delta;Tput%",
    tput_col_label: str = "Baseline Tput (KOPS)",
) -> str:
    """Build an HTML table summarising KPI crossing points per compressor."""
    if not crossing_data:
        return "<p>No crossing point data available.</p>"

    thr_line = -abs(threshold_pct)
    html = []
    html.append('<div style="margin: 24px 0;">')
    html.append(f'<h3 style="margin: 0 0 12px 0;">{heading}</h3>')
    html.append(
        f'<p style="font-size:12px; color:#6b7280; margin:0 0 12px 0;">'
        f'The crossing point is the maximum memory savings (Save%) achievable '
        f'before throughput regression exceeds the threshold '
        f'({metric_label} &lt; {thr_line:.1f}%). '
        f'Higher values indicate a compressor that tolerates more memory pressure.</p>'
    )

    # Summary cards row
    html.append('<div style="display:flex; flex-wrap:wrap; gap:12px; margin-bottom:16px;">')
    for cp in crossing_data:
        color = "#16a34a" if cp["crossing_point"] > 0 else "#dc2626"
        html.append(
            f'<div style="border:1px solid #e5e7eb; border-radius:10px; padding:14px 18px; '
            f'background:#fafafa; min-width:200px;">'
            f'<div style="font-size:12px; color:#6b7280; margin-bottom:4px;">{cp["name"]}</div>'
            f'<div style="font-size:22px; font-weight:700; color:{color};">'
            f'{cp["crossing_point"]:.2f}%</div>'
            f'<div style="font-size:11px; color:#9ca3af; margin-top:4px;">'
            f'Status: {cp["status"]}</div>'
            f'</div>'
        )
    html.append('</div>')

    # Detailed table
    html.append(
        '<table style="border-collapse:collapse; font-family:monospace; font-size:12px; '
        'border:1px solid #ccc; width:100%; max-width:900px;">'
    )
    html.append("<thead>")
    html.append(
        '<tr style="background:#f0f0f0; border-bottom:2px solid #999;">'
        '<th style="padding:6px 10px; text-align:left; border-right:1px solid #ccc;">Compressor</th>'
        '<th style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">Crossing Point (Save%)</th>'
        '<th style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">Max Save%</th>'
        f'<th style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{tput_col_label}</th>'
        '<th style="padding:6px 10px; text-align:left; border-right:1px solid #ccc;">Status</th>'
        "</tr>"
    )
    html.append("</thead><tbody>")

    for cp in crossing_data:
        html.append(
            f'<tr style="border-bottom:1px solid #ddd;">'
            f'<td style="padding:6px 10px; font-weight:bold; border-right:1px solid #ccc;">{cp["name"]}</td>'
            f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{cp["crossing_point"]:.2f}</td>'
            f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{cp["max_save_pct"]:.2f}</td>'
            f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{cp["baseline_tput"]:.2f}</td>'
            f'<td style="padding:6px 10px; text-align:left; border-right:1px solid #ccc;">{cp["status"]}</td>'
            f"</tr>"
        )

    html.append("</tbody></table>")
    html.append("</div>")
    return "\n".join(html)


def make_crossing_point_bar_chart(
    crossing_data: List[Dict[str, Any]], threshold_pct: float,
    chart_title: str = "KPI Crossing Points \u2013 Memory Savings at Acceptable Performance",
) -> figure:
    """Create a horizontal bar chart of KPI crossing points per compressor."""
    if not crossing_data:
        return Div(text="<p>No crossing point data for bar chart.</p>")

    names = [cp["name"] for cp in crossing_data]
    values = [cp["crossing_point"] for cp in crossing_data]

    source = ColumnDataSource(data=dict(
        names=names,
        values=values,
        status=[cp["status"] for cp in crossing_data],
    ))

    p = figure(
        title=f"{chart_title} "
              f"(threshold={threshold_pct:.1f}%)",
        x_axis_label="Memory Savings at Crossing Point (Save%)",
        y_range=names,
        height=max(200, 80 * len(names)),
        sizing_mode="stretch_width",
        tools="pan,wheel_zoom,box_zoom,reset,save",
        toolbar_location="right",
    )
    p.hbar(
        y="names", right="values", height=0.7,
        source=source,
        line_color="white",
        fill_color="#3b82f6",
        fill_alpha=0.85,
    )
    p.x_range.start = 0
    p.xaxis.formatter = NumeralTickFormatter(format="0.0")

    p.add_tools(HoverTool(tooltips=[
        ("Compressor", "@names"),
        ("Crossing Point (Save%)", "@values{0.00}"),
        ("Status", "@status"),
    ]))

    return p


def _to_float(value: str, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _parse_row_oriented(lines: List[str]) -> List[Row]:
    rows: List[Row] = []
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("-") or line.startswith("Scenario"):
            continue

        parts = re.split(r"\s+", line)
        if len(parts) < 11:
            continue

        memmax = parts[12] if len(parts) > 12 else "-"

        rows.append(
            dict(
                scenario=parts[0],
                peak_gib=_to_float(parts[1]),
                save_gib=_to_float(parts[2]),
                save_pct=_to_float(parts[3]),
                swap_gib=_to_float(parts[4]),
                swap_pct=_to_float(parts[5]),
                zpool_gib=parts[6],  # may be '-'
                cr_x=parts[7],       # may be '-'
                tput_kops=_to_float(parts[8]),
                dtput_pct=_to_float(parts[9]),  # negative = regression
                p99_ms=_to_float(parts[10]),
                dp99=(_to_float(parts[11]) if len(parts) > 11 else 0.0),
                memmax=memmax,
                pre_cpu_pct=(_to_float(parts[13]) if len(parts) > 13 else 0.0),
                dpre_cpu=(_to_float(parts[14]) if len(parts) > 14 else 0.0),
                pre_user_pct=(_to_float(parts[15]) if len(parts) > 15 else 0.0),
                dpre_user=(_to_float(parts[16]) if len(parts) > 16 else 0.0),
                pre_sys_pct=(_to_float(parts[17]) if len(parts) > 17 else 0.0),
                dpre_sys=(_to_float(parts[18]) if len(parts) > 18 else 0.0),
                run_cpu_pct=(_to_float(parts[19]) if len(parts) > 19 else 0.0),
                drun_cpu=(_to_float(parts[20]) if len(parts) > 20 else 0.0),
                run_user_pct=(_to_float(parts[21]) if len(parts) > 21 else 0.0),
                drun_user=(_to_float(parts[22]) if len(parts) > 22 else 0.0),
                run_sys_pct=(_to_float(parts[23]) if len(parts) > 23 else 0.0),
                drun_sys=(_to_float(parts[24]) if len(parts) > 24 else 0.0),
                configured_instances=(int(parts[25]) if len(parts) > 25 else 0),
                actual_instances=(int(parts[26]) if len(parts) > 26 else 0),
            )
        )
    return rows


def _parse_transposed(lines: List[str]) -> List[Row]:
    cleaned = [ln.strip() for ln in lines if ln.strip() and not ln.strip().startswith("-")]
    if not cleaned:
        return []

    header = re.split(r"\s+", cleaned[0])
    if len(header) < 2 or header[0] != "Metric":
        return []

    scenarios = header[1:]
    metrics: Dict[str, List[str]] = {}

    for line in cleaned[1:]:
        parts = re.split(r"\s+", line)
        if len(parts) < 2:
            continue
        metric = parts[0]
        values = parts[1:]
        if len(values) != len(scenarios):
            continue
        metrics[metric] = values

    if "Save%" not in metrics or "ΔTput%" not in metrics or "p99(ms)" not in metrics:
        return []

    metric_to_key = {
        "MemMax": ("memmax", str),
        "Peak(GiB)": ("peak_gib", _to_float),
        "Save(GiB)": ("save_gib", _to_float),
        "Save%": ("save_pct", _to_float),
        "Swap(GiB)": ("swap_gib", _to_float),
        "Swap%": ("swap_pct", _to_float),
        "Zpool(GiB)": ("zpool_gib", str),
        "CgroupPeak(GiB)": ("cgroup_peak_gib", _to_float),
        "Zram(GiB)": ("zram_gib", str),
        "Zpool(zswap)": ("zpool_zswap_gib", str),
        "CR(x)": ("cr_x", str),
        "Tput(KOPS)": ("tput_kops", _to_float),
        "ΔTput%": ("dtput_pct", _to_float),
        "AggTput(KOPS)": ("agg_tput_kops", _to_float),
        "ΔAggTput%": ("dagg_tput_pct", _to_float),
        "p99(ms)": ("p99_ms", _to_float),
        "Δp99(ms)": ("dp99", _to_float),
        "Δp99%": ("dp99", _to_float),
        "PreCPU%": ("pre_cpu_pct", _to_float),
        "ΔPreCPU": ("dpre_cpu", _to_float),
        "PreUsr%": ("pre_user_pct", _to_float),
        "ΔPreUsr": ("dpre_user", _to_float),
        "PreSys%": ("pre_sys_pct", _to_float),
        "ΔPreSys": ("dpre_sys", _to_float),
        "PreSysTot%": ("pre_sys_total_pct", _to_float),
        "ΔPreSysTot": ("dpre_sys_total", _to_float),
        "RunCPU%": ("run_cpu_pct", _to_float),
        "ΔRunCPU": ("drun_cpu", _to_float),
        "RunUsr%": ("run_user_pct", _to_float),
        "ΔRunUsr": ("drun_user", _to_float),
        "RunSys%": ("run_sys_pct", _to_float),
        "ΔRunSys": ("drun_sys", _to_float),
        "RunSysTot%": ("run_sys_total_pct", _to_float),
        "ΔRunSysTot": ("drun_sys_total", _to_float),
        "CfgInst": ("configured_instances", int),
        "ActInst": ("actual_instances", int),
    }

    rows: List[Row] = []
    for idx, scenario in enumerate(scenarios):
        row: Row = {
            "scenario": scenario,
            "peak_gib": 0.0,
            "save_gib": 0.0,
            "save_pct": 0.0,
            "swap_gib": 0.0,
            "swap_pct": 0.0,
            "zpool_gib": "-",
            "cgroup_peak_gib": 0.0,
            "zram_gib": "-",
            "zpool_zswap_gib": "-",
            "cr_x": "-",
            "tput_kops": 0.0,
            "dtput_pct": 0.0,
            "agg_tput_kops": 0.0,
            "dagg_tput_pct": 0.0,
            "p99_ms": 0.0,
            "dp99": 0.0,
            "memmax": "-",
            "pre_cpu_pct": 0.0,
            "dpre_cpu": 0.0,
            "pre_user_pct": 0.0,
            "dpre_user": 0.0,
            "pre_sys_pct": 0.0,
            "dpre_sys": 0.0,
            "pre_sys_total_pct": 0.0,
            "dpre_sys_total": 0.0,
            "run_cpu_pct": 0.0,
            "drun_cpu": 0.0,
            "run_user_pct": 0.0,
            "drun_user": 0.0,
            "run_sys_pct": 0.0,
            "drun_sys": 0.0,
            "run_sys_total_pct": 0.0,
            "drun_sys_total": 0.0,
            "configured_instances": 0,
            "actual_instances": 0,
        }

        for metric, values in metrics.items():
            if metric not in metric_to_key:
                continue
            key, caster = metric_to_key[metric]
            row[key] = caster(values[idx])

        rows.append(row)

    # Backward compatibility: old reports (e.g. zswap) may lack newer metrics.
    # Derive them from existing fields when missing.
    if "CgroupPeak(GiB)" not in metrics:
        # zswap mode: Peak(GiB) == memory.peak / 1024³ (no zram addition)
        for row in rows:
            row["cgroup_peak_gib"] = row["peak_gib"]

    if "Zpool(zswap)" not in metrics and "Zpool(GiB)" in metrics:
        # Old zswap reports use Zpool(GiB) for the zswap pool value
        for row in rows:
            row["zpool_zswap_gib"] = row["zpool_gib"]

    return rows


def parse_lines(lines: List[str]) -> List[Row]:
    rows = _parse_transposed(lines)
    if rows:
        return rows
    return _parse_row_oriented(lines)


def rows_to_cds_dict(rows: List[Row]) -> Dict[str, List[Any]]:
    keys = rows[0].keys()
    return {k: [r[k] for r in rows] for k in keys}


def invalid_rows(rows: List[Row]) -> List[Row]:
    return [
        r
        for r in rows
        if int(r.get("configured_instances", 0)) > 0
        and int(r.get("actual_instances", 0)) != int(r.get("configured_instances", 0))
    ]


def valid_rows(rows: List[Row]) -> List[Row]:
    """Rows suitable for plotting: exclude those where ActInst != CfgInst.
    Rows without instance accounting (cfg <= 0, e.g. legacy reports) are kept."""
    return [
        r
        for r in rows
        if int(r.get("configured_instances", 0)) <= 0
        or int(r.get("actual_instances", 0)) == int(r.get("configured_instances", 0))
    ]


def make_instance_completeness_section(series: List[Dict[str, Any]]) -> str:
    """Report configured vs. actually-successful instance counts per scenario.

    ``CfgInst`` = number of Redis instances the benchmark launched, ``ActInst``
    = instances that produced a valid result. When ActInst < CfgInst the
    aggregated metrics come from fewer instances than intended and should be
    treated with care. Returns an empty string when no report carries instance
    counts.
    """
    any_inst = False
    incomplete = []  # (compressor, scenario, act, cfg)
    for s in series:
        for r in s["rows"]:
            cfg = int(r.get("configured_instances", 0) or 0)
            act = int(r.get("actual_instances", 0) or 0)
            if cfg <= 0:
                continue
            any_inst = True
            if act < cfg:
                incomplete.append((s["name"], r.get("scenario", ""), act, cfg))

    if not any_inst:
        return ""  # no instance data recorded in these reports

    html = [
        '<div style="margin:24px 0;">',
        '<h3 style="margin:0 0 8px 0;">Configured vs. Successful Instances</h3>',
        '<p style="font-size:12px; color:#6b7280; margin:0 0 12px 0;">'
        "Each scenario aggregates metrics across all Redis instances. "
        "<b>CfgInst</b> is the number of instances launched; <b>ActInst</b> is the "
        "number that produced a valid result. Rows where ActInst &lt; CfgInst are "
        "flagged below (metrics are based on fewer instances than intended).</p>",
    ]

    if not incomplete:
        html.append(
            '<p style="font-size:13px; color:#065f46; font-weight:bold;">'
            "All scenarios completed on every configured instance.</p>"
        )
    else:
        html.append(
            '<table style="border-collapse:collapse; font-family:monospace; '
            'font-size:12px; border:1px solid #ccc;">'
        )
        html.append(
            '<tr style="background:#fef2f2;">'
            '<th style="padding:6px 10px; border:1px solid #ccc; text-align:left;">Compressor</th>'
            '<th style="padding:6px 10px; border:1px solid #ccc; text-align:left;">Scenario</th>'
            '<th style="padding:6px 10px; border:1px solid #ccc;">ActInst</th>'
            '<th style="padding:6px 10px; border:1px solid #ccc;">CfgInst</th></tr>'
        )
        for name, scen, act, cfg in incomplete:
            html.append(
                "<tr>"
                f'<td style="padding:6px 10px; border:1px solid #ccc; font-weight:bold;">{name}</td>'
                f'<td style="padding:6px 10px; border:1px solid #ccc;">{scen}</td>'
                f'<td style="padding:6px 10px; border:1px solid #ccc; text-align:right; color:red; font-weight:bold;">{act}</td>'
                f'<td style="padding:6px 10px; border:1px solid #ccc; text-align:right;">{cfg}</td></tr>'
            )
        html.append("</table>")
    html.append("</div>")
    return "\n".join(html)


def make_table_transposed(rows: List[Row], title: str) -> str:
    """Generate HTML table with scenarios as columns and metrics as rows.
    Returns raw HTML string (not a Bokeh widget) to avoid escaping issues."""
    if not rows:
        return "<p>No data</p>"

    metrics_order = [
        ("MemMax", lambda r: r["memmax"]),
        ("Peak(GiB)", lambda r: f"{r['peak_gib']:.2f}"),
        ("CgroupPeak(GiB)", lambda r: f"{r['cgroup_peak_gib']:.2f}"),
        ("Save(GiB)", lambda r: f"{r['save_gib']:.2f}"),
        ("Save%", lambda r: f"{r['save_pct']:.2f}"),
        ("Swap(GiB)", lambda r: f"{r['swap_gib']:.2f}"),
        ("Swap%", lambda r: f"{r['swap_pct']:.2f}"),
        ("Zram(GiB)", lambda r: r["zram_gib"]),
        ("Zpool(zswap)", lambda r: r["zpool_zswap_gib"]),
        ("CR(x)", lambda r: r["cr_x"]),
        ("Tput(KOPS)", lambda r: f"{r['tput_kops']:.2f}"),
            ("ΔTput%", lambda r: f"{r['dtput_pct']:.2f}"),
        ("AggTput(KOPS)", lambda r: f"{r['agg_tput_kops']:.2f}"),
        ("ΔAggTput%", lambda r: f"{r['dagg_tput_pct']:.2f}"),
        ("p99(ms)", lambda r: f"{r['p99_ms']:.3f}"),
        ("Δp99(ms)", lambda r: f"{r['dp99']:.2f}"),
        ("PreCPU%", lambda r: f"{r['pre_cpu_pct']:.2f}"),
        ("ΔPreCPU", lambda r: f"{r['dpre_cpu']:.2f}"),
        ("PreUsr%", lambda r: f"{r['pre_user_pct']:.2f}"),
        ("ΔPreUsr", lambda r: f"{r['dpre_user']:.2f}"),
        ("PreSys%", lambda r: f"{r['pre_sys_pct']:.2f}"),
        ("ΔPreSys", lambda r: f"{r['dpre_sys']:.2f}"),
        ("PreSysTot%", lambda r: f"{r['pre_sys_total_pct']:.2f}"),
        ("ΔPreSysTot", lambda r: f"{r['dpre_sys_total']:.2f}"),
        ("RunCPU%", lambda r: f"{r['run_cpu_pct']:.2f}"),
        ("ΔRunCPU", lambda r: f"{r['drun_cpu']:.2f}"),
        ("RunUsr%", lambda r: f"{r['run_user_pct']:.2f}"),
        ("ΔRunUsr", lambda r: f"{r['drun_user']:.2f}"),
        ("RunSys%", lambda r: f"{r['run_sys_pct']:.2f}"),
        ("ΔRunSys", lambda r: f"{r['drun_sys']:.2f}"),
        ("RunSysTot%", lambda r: f"{r['run_sys_total_pct']:.2f}"),
        ("ΔRunSysTot", lambda r: f"{r['drun_sys_total']:.2f}"),
        ("CfgInst", lambda r: str(r.get('configured_instances', 0))),
        ("ActInst", lambda r: str(r.get('actual_instances', 0))),
    ]

    scenarios = [r["scenario"] for r in rows]

    html_lines = [
        f"<h3 style='margin: 18px 0 8px 0;'>{title}</h3>",
        '<table style="border-collapse:collapse; font-family:monospace; font-size:12px; border:1px solid #ccc;">',
        "<thead>",
        '<tr style="background:#f0f0f0; border-bottom:2px solid #999;">',
        '<th style="padding:6px 10px; text-align:left; border-right:1px solid #ccc;">Metric</th>',
    ]

    for scenario in scenarios:
        html_lines.append(f'<th style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{scenario}</th>')

    html_lines.append("</tr>")
    html_lines.append("</thead>")
    html_lines.append("<tbody>")

    for metric_name, getter in metrics_order:
        html_lines.append('<tr style="border-bottom:1px solid #ddd;">')
        html_lines.append(f'<td style="padding:6px 10px; font-weight:bold; border-right:1px solid #ccc;">{metric_name}</td>')
        for row in rows:
            value = getter(row)
            html_lines.append(f'<td style="padding:6px 10px; text-align:right; border-right:1px solid #ccc;">{value}</td>')
        html_lines.append("</tr>")

    html_lines.append("</tbody>")
    html_lines.append("</table>")

    html_text = "\n".join(html_lines)
    return html_text


def summarize(rows: List[Row], threshold_pct: float, series_name: str) -> str:
    thr_line = -abs(threshold_pct)

    ok = [r for r in rows if r["dtput_pct"] >= thr_line]

    best = None
    if ok:
        best = sorted(ok, key=lambda r: (r["save_pct"], r["dtput_pct"]), reverse=True)[0]

    def fmt_row(r: Row) -> str:
        return (
            f"{r['scenario']}: Save%={r['save_pct']:.2f}, ΔTput%={r['dtput_pct']:.2f}, "
            f"Tput={r['tput_kops']:.2f} KOPS, p99={r['p99_ms']:.3f} ms, CR={r['cr_x']}"
        )

    best_html = (
        f"<div style='margin-top:6px;'><b>Best within threshold:</b> <code>{fmt_row(best)}</code></div>"
        if best is not None
        else "<div style='margin-top:6px;'><b>Best within threshold:</b> <i>none</i></div>"
    )

    return f"""
    <div style="
        border: 1px solid #e5e7eb;
        border-radius: 12px;
        padding: 12px 14px;
        background: #fafafa;
        margin-top: 10px;
    ">
      <div style="font-weight: 700; margin-bottom: 6px;">{series_name} summary</div>
      <div><b>Threshold:</b> ΔTput% ≥ {thr_line:.2f} (regression limit = {threshold_pct:.2f}%)</div>
      {best_html}
    </div>
    """


def pick_palette(n: int) -> List[str]:
    return list(Category10[10]) if n <= 10 else list(Category20[20])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reports", nargs="+", type=Path, help="One or more .report files (e.g., *.report)")
    ap.add_argument(
        "--threshold",
        type=float,
        default=5.0,
        help="Regression threshold in percent (default: 5). Threshold line at ΔTput%% = -threshold.",
    )
    ap.add_argument(
        "--no-labels",
        action="store_true",
        help="Suppress scenario labels on plot points. Default: label all series.",
    )
    ap.add_argument(
        "--output-dir",
        type=str,
        default=".",
        help="Output directory to save the results. Default: current directory.",
    )
    args = ap.parse_args()

    threshold_pct = float(args.threshold)
    thr_line = -abs(threshold_pct)

    series = []
    for rf in args.reports:
        rows = parse_lines(rf.read_text().splitlines(True))
        if not rows:
            print(f"WARNING: no valid rows parsed from {rf} (skipping)")
            continue
        rows = sorted(rows, key=lambda r: r["save_pct"])
        # Only plot data points where every configured instance produced a
        # result (ActInst == CfgInst). Incomplete rows stay in ``rows`` so the
        # tables / completeness section still report them, but are not plotted.
        plot_rows = valid_rows(rows)
        if not plot_rows:
            print(f"WARNING: all rows in {rf} have ActInst != CfgInst; nothing to plot for this series")
        cds = rows_to_cds_dict(plot_rows) if plot_rows else {k: [] for k in rows[0].keys()}
        src = ColumnDataSource(cds)
        series.append(dict(file=rf, name=rf.stem, rows=rows, plot_rows=plot_rows, source=src, invalid_source=None))

    if not series:
        raise SystemExit("No valid series found in input files.")

    colors = pick_palette(len(series))

    all_x: List[float] = []
    for s in series:
        all_x.extend(s["source"].data["save_pct"])

    # ---- Plot 1: Save% vs ΔTput% ----
    p_tput = figure(
        title="Throughput Change vs Memory Savings (ΔTput%: negative = regression)",
        x_axis_label="Memory savings vs baseline (Save%)",
        y_axis_label="Throughput change vs baseline (ΔTput%)",
        height=520,
        sizing_mode="stretch_width",
        tools="pan,wheel_zoom,box_zoom,reset,save",
        toolbar_location="right",
    )
    p_tput.xaxis.formatter = NumeralTickFormatter(format="0.0")
    p_tput.yaxis.formatter = NumeralTickFormatter(format="0.0")

    if all_x:
        p_tput.line([min(all_x), max(all_x)], [0, 0], line_width=1, line_alpha=0.35)

    p_tput.add_layout(
        Span(
            location=thr_line,
            dimension="width",
            line_dash="dashed",
            line_width=2,
            line_color="#111827",
            line_alpha=0.6,
        )
    )
    p_tput.add_layout(BoxAnnotation(top=thr_line, fill_alpha=0.08, fill_color="#ef4444"))

    tput_renderers = []
    for idx, s in enumerate(series):
        color = colors[idx % len(colors)]
        src = s["source"]
        name = s["name"]

        p_tput.line(
            x="save_pct",
            y="dtput_pct",
            source=src,
            line_width=3,
            color=color,
            alpha=0.9,
            legend_label=name,
            name=name,
        )
        r = p_tput.scatter(
            x="save_pct",
            y="dtput_pct",
            source=src,
            size=10,
            marker="circle",
            fill_color=color,
            line_color=color,
            fill_alpha=0.9,
            line_alpha=0.9,
            legend_label=name,
            name=name,
        )
        tput_renderers.append(r)

        if s["invalid_source"] is not None:
            p_tput.scatter(
                x="save_pct",
                y="dtput_pct",
                source=s["invalid_source"],
                size=18,
                marker="circle",
                fill_alpha=0.0,
                line_color="#dc2626",
                line_width=3,
                line_alpha=0.95,
            )

    p_tput.legend.location = "bottom_left"
    p_tput.legend.click_policy = "hide"
    p_tput.legend.label_text_font_size = "11pt"
    p_tput.legend.spacing = 6
    p_tput.legend.padding = 8
    p_tput.legend.background_fill_alpha = 0.75

    hover_tput = HoverTool(
        renderers=tput_renderers,
        tooltips=[
            ("Compressor", "$name"),
            ("Scenario", "@scenario"),
            ("Peak(GiB)", "@peak_gib{0.00}"),
            ("Save(GiB)", "@save_gib{0.00}"),
            ("Save%", "@save_pct{0.00}"),
            ("Swap(GiB)", "@swap_gib{0.00}"),
            ("Swap%", "@swap_pct{0.00}"),
            ("Zpool(GiB)", "@zpool_gib"),
            ("CR(x)", "@cr_x"),
            ("Tput(KOPS)", "@tput_kops{0.00}"),
            ("ΔTput%", "@dtput_pct{0.00}"),
            ("AggTput(KOPS)", "@agg_tput_kops{0.00}"),
            ("ΔAggTput%", "@dagg_tput_pct{0.00}"),
            ("p99(ms)", "@p99_ms{0.000}"),
        ],
    )
    p_tput.add_tools(hover_tput)

    # Labels: all series by default, suppressed with --no-labels
    # Linked to renderer visibility so legend click hides labels too
    if not args.no_labels:
        for idx, s in enumerate(series):
            ls = LabelSet(
                x="save_pct",
                y="dtput_pct",
                text="scenario",
                x_offset=6,
                y_offset=6,
                source=s["source"],
                text_font_size="8pt",
                text_alpha=0.8,
            )
            p_tput.add_layout(ls)
            tput_renderers[idx].js_link('visible', ls, 'visible')

    # ---- Plot 1b: Save% vs ΔAggTput% ----
    p_agg_tput = figure(
        title="Aggregate Throughput Change vs Memory Savings (ΔAggTput%: negative = regression)",
        x_axis_label="Memory savings vs baseline (Save%)",
        y_axis_label="Aggregate throughput change vs baseline (ΔAggTput%)",
        height=520,
        sizing_mode="stretch_width",
        tools="pan,wheel_zoom,box_zoom,reset,save",
        toolbar_location="right",
    )
    p_agg_tput.xaxis.formatter = NumeralTickFormatter(format="0.0")
    p_agg_tput.yaxis.formatter = NumeralTickFormatter(format="0.0")

    if all_x:
        p_agg_tput.line([min(all_x), max(all_x)], [0, 0], line_width=1, line_alpha=0.35)

    p_agg_tput.add_layout(
        Span(
            location=thr_line,
            dimension="width",
            line_dash="dashed",
            line_width=2,
            line_color="#111827",
            line_alpha=0.6,
        )
    )
    p_agg_tput.add_layout(BoxAnnotation(top=thr_line, fill_alpha=0.08, fill_color="#ef4444"))

    agg_tput_renderers = []
    for idx, s in enumerate(series):
        color = colors[idx % len(colors)]
        src = s["source"]
        name = s["name"]

        p_agg_tput.line(
            x="save_pct",
            y="dagg_tput_pct",
            source=src,
            line_width=3,
            color=color,
            alpha=0.9,
            legend_label=name,
            name=name,
        )
        r = p_agg_tput.scatter(
            x="save_pct",
            y="dagg_tput_pct",
            source=src,
            size=10,
            marker="circle",
            fill_color=color,
            line_color=color,
            fill_alpha=0.9,
            line_alpha=0.9,
            legend_label=name,
            name=name,
        )
        agg_tput_renderers.append(r)

        if s["invalid_source"] is not None:
            p_agg_tput.scatter(
                x="save_pct",
                y="dagg_tput_pct",
                source=s["invalid_source"],
                size=18,
                marker="circle",
                fill_alpha=0.0,
                line_color="#dc2626",
                line_width=3,
                line_alpha=0.95,
            )

    p_agg_tput.legend.location = "bottom_left"
    p_agg_tput.legend.click_policy = "hide"
    p_agg_tput.legend.label_text_font_size = "11pt"
    p_agg_tput.legend.spacing = 6
    p_agg_tput.legend.padding = 8
    p_agg_tput.legend.background_fill_alpha = 0.75

    hover_agg_tput = HoverTool(
        renderers=agg_tput_renderers,
        tooltips=[
            ("Compressor", "$name"),
            ("Scenario", "@scenario"),
            ("Peak(GiB)", "@peak_gib{0.00}"),
            ("Save(GiB)", "@save_gib{0.00}"),
            ("Save%", "@save_pct{0.00}"),
            ("Swap(GiB)", "@swap_gib{0.00}"),
            ("Swap%", "@swap_pct{0.00}"),
            ("Zpool(GiB)", "@zpool_gib"),
            ("CR(x)", "@cr_x"),
            ("AggTput(KOPS)", "@agg_tput_kops{0.00}"),
            ("ΔAggTput%", "@dagg_tput_pct{0.00}"),
            ("Tput(KOPS)", "@tput_kops{0.00}"),
            ("ΔTput%", "@dtput_pct{0.00}"),
            ("p99(ms)", "@p99_ms{0.000}"),
        ],
    )
    p_agg_tput.add_tools(hover_agg_tput)

    if not args.no_labels:
        for idx, s in enumerate(series):
            ls = LabelSet(
                x="save_pct",
                y="dagg_tput_pct",
                text="scenario",
                x_offset=6,
                y_offset=6,
                source=s["source"],
                text_font_size="8pt",
                text_alpha=0.8,
            )
            p_agg_tput.add_layout(ls)
            agg_tput_renderers[idx].js_link('visible', ls, 'visible')

    # ---- Plot 2: Save% vs p99(ms) ----
    p_p99 = figure(
        title="p99 Latency vs Memory Savings",
        x_axis_label="Memory savings vs baseline (Save%)",
        y_axis_label="p99 latency (ms)",
        height=520,
        sizing_mode="stretch_width",
        tools="pan,wheel_zoom,box_zoom,reset,save",
        toolbar_location="right",
    )
    p_p99.xaxis.formatter = NumeralTickFormatter(format="0.0")
    p_p99.yaxis.formatter = NumeralTickFormatter(format="0.000")

    p99_renderers = []
    for idx, s in enumerate(series):
        color = colors[idx % len(colors)]
        src = s["source"]
        name = s["name"]

        p_p99.line(
            x="save_pct",
            y="p99_ms",
            source=src,
            line_width=3,
            color=color,
            alpha=0.9,
            legend_label=name,
            name=name,
        )
        r = p_p99.scatter(
            x="save_pct",
            y="p99_ms",
            source=src,
            size=10,
            marker="circle",
            fill_color=color,
            line_color=color,
            fill_alpha=0.9,
            line_alpha=0.9,
            legend_label=name,
            name=name,
        )
        p99_renderers.append(r)

        if s["invalid_source"] is not None:
            p_p99.scatter(
                x="save_pct",
                y="p99_ms",
                source=s["invalid_source"],
                size=18,
                marker="circle",
                fill_alpha=0.0,
                line_color="#dc2626",
                line_width=3,
                line_alpha=0.95,
            )

    p_p99.legend.location = "bottom_left"
    p_p99.legend.click_policy = "hide"
    p_p99.legend.label_text_font_size = "11pt"
    p_p99.legend.spacing = 6
    p_p99.legend.padding = 8
    p_p99.legend.background_fill_alpha = 0.75

    hover_p99 = HoverTool(
        renderers=p99_renderers,
        tooltips=[
            ("Compressor", "$name"),
            ("Scenario", "@scenario"),
            ("Peak(GiB)", "@peak_gib{0.00}"),
            ("Save(GiB)", "@save_gib{0.00}"),
            ("Save%", "@save_pct{0.00}"),
            ("Swap(GiB)", "@swap_gib{0.00}"),
            ("Swap%", "@swap_pct{0.00}"),
            ("Zpool(GiB)", "@zpool_gib"),
            ("CR(x)", "@cr_x"),
            ("Tput(KOPS)", "@tput_kops{0.00}"),
            ("ΔTput%", "@dtput_pct{0.00}"),
            ("p99(ms)", "@p99_ms{0.000}"),
        ],
    )
    p_p99.add_tools(hover_p99)

    if not args.no_labels:
        for idx, s in enumerate(series):
            ls = LabelSet(
                x="save_pct",
                y="p99_ms",
                text="scenario",
                x_offset=6,
                y_offset=6,
                source=s["source"],
                text_font_size="8pt",
                text_alpha=0.8,
            )
            p_p99.add_layout(ls)
            p99_renderers[idx].js_link('visible', ls, 'visible')

    # ---- Plot 3: Save% vs ΔRunCPU ----
    p_runCPU = figure(
        title="Run CPU Change vs Memory Savings (ΔRunCPU)",
        x_axis_label="Memory savings vs baseline (Save%)",
        y_axis_label="Run CPU change vs baseline (ΔRunCPU)",
        height=520,
        sizing_mode="stretch_width",
        tools="pan,wheel_zoom,box_zoom,reset,save",
        toolbar_location="right",
    )
    p_runCPU.xaxis.formatter = NumeralTickFormatter(format="0.0")
    p_runCPU.yaxis.formatter = NumeralTickFormatter(format="0.0")

    if all_x:
        p_runCPU.line([min(all_x), max(all_x)], [0, 0], line_width=1, line_alpha=0.35)

    runCPU_renderers = []
    for idx, s in enumerate(series):
        color = colors[idx % len(colors)]
        src = s["source"]
        name = s["name"]

        p_runCPU.line(
            x="save_pct",
            y="drun_cpu",
            source=src,
            line_width=3,
            color=color,
            alpha=0.9,
            legend_label=name,
            name=name,
        )
        r = p_runCPU.scatter(
            x="save_pct",
            y="drun_cpu",
            source=src,
            size=10,
            marker="circle",
            fill_color=color,
            line_color=color,
            fill_alpha=0.9,
            line_alpha=0.9,
            legend_label=name,
            name=name,
        )
        runCPU_renderers.append(r)

        if s["invalid_source"] is not None:
            p_runCPU.scatter(
                x="save_pct",
                y="drun_cpu",
                source=s["invalid_source"],
                size=18,
                marker="circle",
                fill_alpha=0.0,
                line_color="#dc2626",
                line_width=3,
                line_alpha=0.95,
            )

    p_runCPU.legend.location = "bottom_left"
    p_runCPU.legend.click_policy = "hide"
    p_runCPU.legend.label_text_font_size = "11pt"
    p_runCPU.legend.spacing = 6
    p_runCPU.legend.padding = 8
    p_runCPU.legend.background_fill_alpha = 0.75

    hover_runCPU = HoverTool(
        renderers=runCPU_renderers,
        tooltips=[
            ("Compressor", "$name"),
            ("Scenario", "@scenario"),
            ("Peak(GiB)", "@peak_gib{0.00}"),
            ("Save(GiB)", "@save_gib{0.00}"),
            ("Save%", "@save_pct{0.00}"),
            ("Swap(GiB)", "@swap_gib{0.00}"),
            ("Swap%", "@swap_pct{0.00}"),
            ("Zpool(GiB)", "@zpool_gib"),
            ("CR(x)", "@cr_x"),
            ("Tput(KOPS)", "@tput_kops{0.00}"),
            ("ΔTput%", "@dtput_pct{0.00}"),
            ("AggTput(KOPS)", "@agg_tput_kops{0.00}"),
            ("ΔAggTput%", "@dagg_tput_pct{0.00}"),
            ("RunCPU%", "@run_cpu_pct{0.00}"),
            ("ΔRunCPU", "@drun_cpu{0.00}"),
        ],
    )
    p_runCPU.add_tools(hover_runCPU)

    if not args.no_labels:
        for idx, s in enumerate(series):
            ls = LabelSet(
                x="save_pct",
                y="drun_cpu",
                text="scenario",
                x_offset=6,
                y_offset=6,
                source=s["source"],
                text_font_size="8pt",
                text_alpha=0.8,
            )
            p_runCPU.add_layout(ls)
            runCPU_renderers[idx].js_link('visible', ls, 'visible')

    # ---- Header + Summary + Tables ----
    header = Div(
        text=f"""
        <div style="display:flex; flex-wrap:wrap; gap:12px; align-items:flex-end;">
          <div style="flex: 1 1 520px;">
            <h2 style="margin: 0 0 6px 0;">Tradeoff Report</h2>
            <div style="color:#374151;">
              Plot 1: ΔTput% vs Save% &nbsp;|&nbsp;
              Plot 2: ΔAggTput% vs Save% &nbsp;|&nbsp;
              Plot 3: p99(ms) vs Save% &nbsp;|&nbsp;
              Plot 4: ΔRunCPU vs Save% &nbsp;|&nbsp;
              Threshold: <b>{threshold_pct:.2f}%</b> (line at <b>ΔTput%={thr_line:.2f}</b>)
              &nbsp;|&nbsp; Legend click hides a series
            </div>
          </div>
        </div>
        """,
        sizing_mode="stretch_width",
    )

    summary_header = Div(text="<h3 style='margin: 16px 0 8px 0;'>Summary</h3>", sizing_mode="stretch_width")
    summaries = [Div(text=summarize(s["rows"], threshold_pct, s["name"]), sizing_mode="stretch_width") for s in series]

    # Bokeh Div renders text as innerHTML, so raw HTML tables work directly
    table_blocks = []
    for s in series:
        html_str = make_table_transposed(s["rows"], f"Table: {s['file'].name}")
        table_blocks.append(Div(text=html_str, sizing_mode="stretch_width"))

    # Baseline variation analysis section
    baseline_variation_html = make_baseline_variation_section(series)
    baseline_variation_div = Div(text=baseline_variation_html, sizing_mode="stretch_width")

    # Configured vs. successful instance completeness section
    instance_completeness_html = make_instance_completeness_section(series)
    instance_completeness_div = (
        Div(text=instance_completeness_html, sizing_mode="stretch_width")
        if instance_completeness_html
        else None
    )

    # Crossing point analysis section (per-instance throughput)
    crossing_data = compute_crossing_points(series, threshold_pct)
    crossing_table_html = make_crossing_point_table(crossing_data, threshold_pct)
    crossing_table_div = Div(text=crossing_table_html, sizing_mode="stretch_width")
    crossing_bar_chart = make_crossing_point_bar_chart(crossing_data, threshold_pct)

    # Crossing point analysis section (aggregate throughput)
    agg_crossing_data = compute_crossing_points(
        series, threshold_pct,
        dtput_key="dagg_tput_pct", tput_key="agg_tput_kops",
    )
    agg_crossing_table_html = make_crossing_point_table(
        agg_crossing_data, threshold_pct,
        heading="KPI Crossing X-Points (Aggregate Throughput)",
        metric_label="&Delta;AggTput%",
        tput_col_label="Baseline AggTput (KOPS)",
    )
    agg_crossing_table_div = Div(text=agg_crossing_table_html, sizing_mode="stretch_width")
    agg_crossing_bar_chart = make_crossing_point_bar_chart(
        agg_crossing_data, threshold_pct,
        chart_title="KPI Crossing Points (Aggregate Throughput) \u2013 Memory Savings at Acceptable Performance",
    )

    layout = column(
        header,
        p_tput,
        p_agg_tput,
        p_p99,
        p_runCPU,
        summary_header,
        *summaries,
        crossing_bar_chart,
        crossing_table_div,
        agg_crossing_bar_chart,
        agg_crossing_table_div,
        baseline_variation_div,
        *([instance_completeness_div] if instance_completeness_div is not None else []),
        *table_blocks,
        sizing_mode="stretch_width",
    )

    out = (
        f"{args.output_dir}/combined_{len(series)}_thr{threshold_pct:g}_report.html"
        if len(series) > 1
        else f"{args.output_dir}/{series[0]['name']}_thr{threshold_pct:g}_report.html"
    )
    output_file(out, title="Memory Savings Tradeoff Report")
    save(layout, resources=INLINE)

    print(f"Wrote: {out}")


if __name__ == "__main__":
    main()
