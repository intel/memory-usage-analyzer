#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Intel Corporation
"""
instance_sweep_reporter.py

Analyzes Redis instance sweep results and generates:
  - A text report table (to stdout) when fed log lines via stdin
  - An interactive Bokeh HTML report when invoked with --plot and .report files

The script operates in two modes:

1) Report mode (stdin): Parse instance sweep log lines and print a summary table.
   cat logdir/instances-*.log | python instance_sweep_reporter.py

2) Plot mode (--plot): Read one or more .report files and produce an HTML report
   with interactive Bokeh plots showing performance vs instance count.
   python instance_sweep_reporter.py --plot comp1.report comp2.report --output-dir ./logdir

"""

import argparse
import re
import statistics
import sys
from pathlib import Path
from typing import List

# Allow importing from src/core when running from tests/redis/
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
from core.util import find_crossing_point

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GiB = 1024**3

# Fields to parse with to_float (key -> raw source key, default)
_FLOAT_FIELDS = [
    ("prefill_cpu_pct", "prefill_cpu_pct", 0),
    ("prefill_user_pct", "prefill_user_pct", 0),
    ("prefill_sys_pct", "prefill_sys_pct", 0),
    ("prefill_sys_total_pct", "prefill_sys_total_pct", 0),
    ("run_cpu_pct", "run_cpu_pct", 0),
    ("run_user_pct", "run_user_pct", 0),
    ("run_sys_pct", "run_sys_pct", 0),
    ("run_sys_total_pct", "run_sys_total_pct", 0),
]

_INT_FIELDS = [
    ("configured_instances", "configured_instances", 0),
    ("actual_instances", "actual_instances", 0),
]

# Report file column layout (index -> key, converter)
_REPORT_COLUMNS = [
    ("scenario", str),
    ("configured_instances", int),
    ("actual_instances", int),
    ("peak_gib", float),
    ("swap_gib", float),
    ("swap_pct", float),
    ("zpool_gib", float),  # special: "-" -> None
    ("comp_ratio", float),  # special: "-" -> None
    ("tput_kops", float),
    ("tput_agg_kops", float),
    ("perf_regression_pct", float),
    ("tput_delta_pct", float),
    ("p99_ms", float),
    ("p99_delta", float),
    ("run_cpu_pct", float),
    ("run_sys_total_pct", float),
]

# Shared HTML styles
_CELL_STYLE = "padding:4px 6px; border:1px solid #ccc;"
_CELL_STYLE_RIGHT = f"{_CELL_STYLE} text-align:right;"
_CARD_STYLE = (
    "border:1px solid #e5e7eb; border-radius:10px; padding:14px 18px; "
    "background:#fafafa; min-width:220px;"
)

# Hover tooltips shared by all Bokeh plots
HOVER_TOOLTIPS = [
    ("Compressor", "@compressor"),
    ("Instances (configured)", "@instances"),
    ("Instances (actual)", "@actual"),
    ("Performance %", "@perf{0.00}"),
    ("Throughput (KOPS)", "@tput{0.00}"),
    ("Agg Throughput (KOPS)", "@agg_tput{0.00}"),
    ("p99 (ms)", "@p99{0.000}"),
    ("Active Memory (GiB)", "@active_mem{0.00}"),
    ("Peak Memory (GiB)", "@peak_mem{0.00}"),
    ("Swap (GiB)", "@swap_gib{0.00}"),
    ("Zram (GiB)", "@zram_gib{0.00}"),
    ("CR (x)", "@comp_ratio{0.00}"),
]


# ---------------------------------------------------------------------------
# Utility Helpers
# ---------------------------------------------------------------------------


def to_int(val, default=0):
    try:
        return int(val)
    except (TypeError, ValueError):
        return default


def to_float(val, default=0.0):
    try:
        return float(str(val).replace("x", "").strip())
    except (TypeError, ValueError):
        return default


def scenario_key(name: str):
    """Sort key: baseline first, then instances-N by N ascending."""
    if name == "baseline":
        return (0, 0)
    m = re.match(r"instances-(\d+)$", name)
    if m:
        return (1, int(m.group(1)))
    return (2, name)


def percent_variation(values):
    """Calculate percentage variation of a numeric series.

    Returns (color, variation_pct) where color is 'red' when variation > 5%,
    otherwise 'black'.
    """
    cleaned = [v for v in values if v is not None and v == v]
    if not cleaned:
        return "black", 0.0
    max_val = max(cleaned)
    if max_val == 0:
        return "black", 0.0
    min_val = min(cleaned)
    variation = round(100.0 * (max_val - min_val) / max_val, 2)
    color = "red" if variation > 5 else "black"
    return color, variation


# ---------------------------------------------------------------------------
# HTML Helpers (reduce repeated inline style strings)
# ---------------------------------------------------------------------------


def _html_stat_card(title: str, value_str: str, color: str, detail: str) -> str:
    """Render a single stat card div."""
    return (
        f'<div style="{_CARD_STYLE}">'
        f'<div style="font-size:12px; color:#6b7280; margin-bottom:4px;">{title}</div>'
        f'<div style="font-size:22px; font-weight:700; color:{color};">{value_str}</div>'
        f'<div style="font-size:11px; color:#9ca3af; margin-top:4px;">{detail}</div>'
        f"</div>"
    )


def _td(value: str, bold: bool = False, color: str = "") -> str:
    """Render a table cell with standard styling."""
    style = _CELL_STYLE_RIGHT
    extra = ""
    if bold:
        extra += " font-weight:bold;"
    if color:
        extra += f" color:{color};"
    if bold and not color:
        style = f"{_CELL_STYLE} font-weight:bold;"
    elif extra:
        style = f"{_CELL_STYLE_RIGHT}{extra}"
    return f"<td style='{style}'>{value}</td>"


def _th(label: str, align: str = "right") -> str:
    """Render a table header cell."""
    return (
        f"<th style='padding:6px 10px; text-align:{align}; "
        f"border-right:1px solid #ccc;'>{label}</th>"
    )


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------


def parse_input(lines):
    """Parse scenario log lines into a list of row dicts."""
    data = []
    for line in lines:
        line = line.strip()
        if not line or not line.startswith("scenario:"):
            continue
        parts = [p.strip() for p in line.split(",")]
        row = {}
        for p in parts:
            if p.startswith("scenario:"):
                row["scenario"] = p.split(":", 1)[1].strip()
            elif ":" in p:
                k, v = p.split(":", 1)
                row[k.strip()] = v.strip()
            elif "=" in p:
                k, v = p.split("=", 1)
                row[k.strip()] = v.strip()
        data.append(row)
    return data


def parse_report_file(filepath):
    """Parse a .report file into a series dict with name, rows, and swap_mode."""
    name = Path(filepath).stem
    if name.endswith("_l0_s0"):
        name = "baseline"
    rows = []
    swap_mode = "zswap"
    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("-"):
                continue
            if line.startswith("Scenario"):
                if "Zram(GiB)" in line:
                    swap_mode = "zram"
                elif "Zpool(GiB)" in line:
                    swap_mode = "zswap"
                continue
            parts = line.split()
            if len(parts) < len(_REPORT_COLUMNS):
                continue
            try:
                row = {}
                for idx, (key, _converter) in enumerate(_REPORT_COLUMNS):
                    raw = parts[idx]
                    if key in ("zpool_gib", "comp_ratio"):
                        row[key] = to_float(raw) if raw != "-" else None
                    elif _converter is int:
                        row[key] = to_int(raw)
                    elif _converter is float:
                        row[key] = to_float(raw)
                    else:
                        row[key] = raw
                rows.append(row)
            except (IndexError, ValueError):
                continue
    return {"name": name, "rows": rows, "swap_mode": swap_mode}


# ---------------------------------------------------------------------------
# Data Enrichment
# ---------------------------------------------------------------------------


def enrich_rows(data):
    """Compute derived metrics and performance regression relative to baseline."""
    for r in data:
        r["swap_mode"] = r.get("swap_mode", "zram").strip()
        r["memory_max"] = r.get("memory_max", "").strip()
        r["memory_peak"] = to_int(r.get("memory_peak", 0))
        r["memory_swap_peak"] = to_int(r.get("memory_swap_peak", 0))
        r["throughput_ops"] = to_float(r.get("throughput", 0))
        r["throughput_kops"] = r["throughput_ops"] / 1000.0
        r["throughput_agg_ops"] = to_float(r.get("throughput_agg", 0))
        r["throughput_agg_kops"] = r["throughput_agg_ops"] / 1000.0
        r["p99"] = to_float(r.get("p99", 0))

        zpool = r.get("zswap_pool_size", "").strip()
        r["zswap_pool_size"] = to_float(zpool, None) if zpool else None
        cr = r.get("comp_ratio", "").strip()
        r["comp_ratio"] = to_float(cr, None) if cr else None

        for dest_key, src_key, default in _FLOAT_FIELDS:
            r[dest_key] = to_float(r.get(src_key, default))
        for dest_key, src_key, default in _INT_FIELDS:
            r[dest_key] = to_int(r.get(src_key, default))

    data.sort(key=lambda r: scenario_key(r.get("scenario", "unknown")))

    baseline = data[0] if data else None
    if baseline is None:
        print("No data rows found.")
        sys.exit(1)

    base_peak = baseline["memory_peak"] / GiB
    if baseline["swap_mode"] == "zram" and baseline["zswap_pool_size"] is not None:
        base_peak += baseline["zswap_pool_size"]
    base_tput_kops = baseline["throughput_kops"]
    base_tput_agg_kops = baseline["throughput_agg_kops"]
    base_p99 = baseline["p99"]

    for r in data:
        peak_gib = r["memory_peak"] / GiB
        swap_gib = r["memory_swap_peak"] / GiB

        if r["swap_mode"] == "zram" and r["zswap_pool_size"] is not None:
            peak_gib += r["zswap_pool_size"]

        r["peak_gib"] = peak_gib
        r["swap_gib"] = swap_gib
        r["swap_pct"] = (swap_gib / peak_gib * 100.0) if peak_gib > 0 else 0.0

        if r is baseline or base_tput_kops == 0:
            r["perf_regression_pct"] = 100.0
            r["tput_delta_pct"] = 0.0
            r["tput_agg_delta_pct"] = 0.0
            r["p99_delta"] = 0.0
        else:
            r["perf_regression_pct"] = (r["throughput_kops"] / base_tput_kops) * 100.0
            r["tput_delta_pct"] = (
                (r["throughput_kops"] - base_tput_kops) / base_tput_kops * 100.0
            )
            r["tput_agg_delta_pct"] = (
                (r["throughput_agg_kops"] - base_tput_agg_kops)
                / base_tput_agg_kops
                * 100.0
                if base_tput_agg_kops > 0
                else 0.0
            )
            r["p99_delta"] = r["p99"] - base_p99

    return data


# ---------------------------------------------------------------------------
# Text Report (stdout)
# ---------------------------------------------------------------------------


def print_report(data, accept_kpi=95.0):
    """Print a text table summarizing instance sweep results."""
    baseline = data[0] if data else None
    if baseline:
        pool_label = "Zram Size" if baseline.get("swap_mode", "zswap") == "zram" else "Zpool Size"
        zpool_str = f"{baseline['zswap_pool_size']:.2f} GiB" if baseline["zswap_pool_size"] is not None else "-"
        cr_str = f"{baseline['comp_ratio']:.2f}x" if baseline["comp_ratio"] is not None else "-"
        print("\n### Baseline Variation")
        print(f"  Scenario:           {baseline['scenario']}")
        print(f"  Instances:          {baseline['configured_instances']} configured, {baseline['actual_instances']} actual")
        print(f"  Peak Memory:        {baseline['peak_gib']:.2f} GiB")
        print(f"  Throughput:         {baseline['throughput_kops']:.2f} KOPS (per instance)")
        print(f"  Agg Throughput:     {baseline['throughput_agg_kops']:.2f} KOPS")
        print(f"  p99 Latency:        {baseline['p99']:.3f} ms")
        print(f"  {pool_label}:         {zpool_str}")
        print(f"  Compression Ratio:  {cr_str}")
        print(f"  RunCPU%:            {baseline['run_cpu_pct']:.2f}")
        print(f"  RunSysTot%:         {baseline['run_sys_total_pct']:.2f}")
        print()

    swap_mode = baseline.get("swap_mode", "zswap") if baseline else "zswap"
    pool_col_label = "Zram(GiB)" if swap_mode == "zram" else "Zpool(GiB)"
    header = (f"{'Scenario':<16} "
              f"{'CfgInst':>8} "
              f"{'ActInst':>8} "
              f"{'Peak(GiB)':>10} "
              f"{'Swap(GiB)':>10} "
              f"{'Swap%':>7} "
              f"{pool_col_label:>11} "
              f"{'CR(x)':>6} "
              f"{'Tput(KOPS)':>12} "
              f"{'AggTput':>12} "
              f"{'Perf%':>7} "
              f"{'ΔTput%':>8} "
              f"{'p99(ms)':>9} "
              f"{'Δp99(ms)':>10} "
              f"{'RunCPU%':>8} "
              f"{'RunSysTot%':>11}")
    print(header)
    print("-" * len(header))

    for r in data:
        zpool_str = f"{r['zswap_pool_size']:.2f}" if r["zswap_pool_size"] is not None else "-"
        cr_str = f"{r['comp_ratio']:.2f}" if r["comp_ratio"] is not None else "-"
        print(f"{r['scenario']:<16} "
              f"{r['configured_instances']:>8} "
              f"{r['actual_instances']:>8} "
              f"{r['peak_gib']:>10.2f} "
              f"{r['swap_gib']:>10.2f} "
              f"{r['swap_pct']:>7.2f} "
              f"{zpool_str:>11} "
              f"{cr_str:>6} "
              f"{r['throughput_kops']:>12.2f} "
              f"{r['throughput_agg_kops']:>12.2f} "
              f"{r['perf_regression_pct']:>7.2f} "
              f"{r['tput_delta_pct']:>8.2f} "
              f"{r['p99']:>9.2f} "
              f"{r['p99_delta']:>10.2f} "
              f"{r['run_cpu_pct']:>8.2f} "
              f"{r['run_sys_total_pct']:>11.2f}")

    x_vals = [r["configured_instances"] for r in data]
    y_vals = [r["perf_regression_pct"] for r in data]
    crossing, status = find_crossing_point(x_vals, y_vals, accept_kpi, return_status=True)

    print()
    print(f"### KPI Crossing X-Points (threshold: {accept_kpi}%)")
    print(f"  Crossing Point:  {int(round(crossing))} instances")
    print(f"  Status:          {status}")


# ---------------------------------------------------------------------------
# Crossing Points
# ---------------------------------------------------------------------------


def compute_crossing_points(series_list, accept_kpi):
    """Compute the instance count at which performance drops below accept_kpi."""
    results = []
    for s in series_list:
        rows = s["rows"]
        if len(rows) < 2:
            results.append({"name": s["name"], "crossing_point": None, "status": "Insufficient data"})
            continue
        x_vals = [r["configured_instances"] for r in rows]
        y_vals = [r["perf_regression_pct"] for r in rows]
        crossing, status = find_crossing_point(x_vals, y_vals, accept_kpi, return_status=True)
        results.append({"name": s["name"], "crossing_point": crossing, "status": status})
    return results


# ---------------------------------------------------------------------------
# HTML Report Sections
# ---------------------------------------------------------------------------


def make_baseline_variation_section(series_list):
    """Build HTML for baseline variation analysis across all series."""
    baselines = []
    for s in series_list:
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

    tput_mean = statistics.mean(tput_values) if tput_values else 0.0
    tput_stdev = statistics.stdev(tput_values) if len(tput_values) > 1 else 0.0
    mem_mean = statistics.mean(mem_values) if mem_values else 0.0
    mem_stdev = statistics.stdev(mem_values) if len(mem_values) > 1 else 0.0
    p99_mean = statistics.mean(p99_values) if p99_values else 0.0
    p99_stdev = statistics.stdev(p99_values) if len(p99_values) > 1 else 0.0
    agg_tput_values = [b["row"]["tput_agg_kops"] for b in baselines]
    agg_tput_mean = statistics.mean(agg_tput_values) if agg_tput_values else 0.0
    agg_tput_stdev = statistics.stdev(agg_tput_values) if len(agg_tput_values) > 1 else 0.0

    html = []
    html.append('<div style="margin: 24px 0;">')
    html.append('<h3 style="margin: 0 0 12px 0;">Baseline Variation Analysis</h3>')
    html.append('<div style="display:flex; flex-wrap:wrap; gap:12px; margin-bottom:16px;">')

    # Stat cards
    html.append(_html_stat_card(
        "Baseline Performance Variation", f"{perf_var:.2f}%", perf_color,
        f"Mean: {tput_mean:.2f} KOPS &nbsp;|&nbsp; Std Dev: {tput_stdev:.2f}",
    ))
    html.append(_html_stat_card(
        "Baseline Total Memory Variation", f"{mem_var:.2f}%", mem_color,
        f"Mean: {mem_mean:.2f} GiB &nbsp;|&nbsp; Std Dev: {mem_stdev:.4f}",
    ))
    html.append(_html_stat_card(
        "Baseline p99 Latency Variation", f"{p99_var:.2f}%", p99_color,
        f"Mean: {p99_mean:.3f} ms &nbsp;|&nbsp; Std Dev: {p99_stdev:.4f}",
    ))

    html.append("</div>")  # close flex container

    html.append(
        '<p style="font-size:11px; color:#6b7280; margin:0 0 12px 0;">'
        "Variation &le; 5% is shown in <b>black</b> (stable). "
        'Variation &gt; 5% is shown in <b style="color:red;">red</b> (unstable, investigate).'
        "</p>"
    )

    # Baseline comparison table
    table_headers = [
        "Compressor", "Tput (KOPS)", "Agg Tput (KOPS)",
        "Peak Memory (GiB)", "p99 Latency (ms)", "Swap Peak (GiB)", "Instances",
    ]
    html.append(
        '<table style="border-collapse:collapse; font-family:monospace; font-size:12px; '
        'border:1px solid #ccc; width:100%; max-width:900px;">'
    )
    html.append("<thead>")
    html.append('<tr style="background:#f0f0f0; border-bottom:2px solid #999;">')
    html.append(_th(table_headers[0], align="left"))
    for h in table_headers[1:]:
        html.append(_th(h))
    html.append("</tr>")
    html.append("</thead><tbody>")

    for b in baselines:
        row = b["row"]
        cells = [
            _td(b["name"], bold=True),
            _td(f"{row['tput_kops']:.2f}"),
            _td(f"{row['tput_agg_kops']:.2f}"),
            _td(f"{row['peak_gib']:.2f}"),
            _td(f"{row['p99_ms']:.3f}"),
            _td(f"{row['swap_gib']:.2f}"),
            _td(str(row.get("actual_instances", 0))),
        ]
        html.append(
            f'<tr style="border-bottom:1px solid #ddd;">'
            + "".join(cells)
            + "</tr>"
        )

    # Statistics rows
    stats_rows = [
        ("Mean", f"{tput_mean:.2f}", f"{agg_tput_mean:.2f}",
         f"{mem_mean:.2f}", f"{p99_mean:.3f}", "-", "-"),
        ("Std Dev", f"{tput_stdev:.2f}", f"{agg_tput_stdev:.2f}",
         f"{mem_stdev:.4f}", f"{p99_stdev:.4f}", "-", "-"),
    ]
    for label, *vals in stats_rows:
        html.append(f'<tr style="border-top:1px solid #999; background:#f9fafb;">')
        html.append(_td(label, bold=True))
        for v in vals:
            html.append(_td(v))
        html.append("</tr>")

    # Variation row with colors
    html.append(f'<tr style="background:#f9fafb;">')
    html.append(_td("Variation %", bold=True))
    html.append(_td(f"{perf_var:.2f}%", bold=True, color=perf_color))
    html.append(_td("-"))
    html.append(_td(f"{mem_var:.2f}%", bold=True, color=mem_color))
    html.append(_td(f"{p99_var:.2f}%", bold=True, color=p99_color))
    html.append(_td("-"))
    html.append(_td("-"))
    html.append("</tr>")

    html.append("</tbody></table>")
    html.append("</div>")

    return "\n".join(html)


def make_crossing_point_section(crossing_data, accept_kpi):
    """Build HTML for KPI crossing points with summary cards and table."""
    if not crossing_data:
        return "<p>No crossing point data available.</p>"

    html = []
    html.append('<div style="margin: 24px 0;">')
    html.append('<h3 style="margin: 0 0 12px 0;">KPI Crossing X-Points</h3>')
    html.append(
        f'<p style="font-size:12px; color:#6b7280; margin:0 0 12px 0;">'
        f"The crossing point is the approximate instance count at which "
        f"performance drops below {accept_kpi}% of baseline throughput. "
        f"Higher values indicate a compressor that tolerates more instance density.</p>"
    )

    # Summary cards
    html.append('<div style="display:flex; flex-wrap:wrap; gap:12px; margin-bottom:16px;">')
    for cp in crossing_data:
        val = cp["crossing_point"]
        color = "#16a34a" if val is not None and val > 0 else "#dc2626"
        val_str = f"{int(round(val))}" if val is not None else "N/A"
        html.append(_html_stat_card(
            cp["name"], f"{val_str} instances", color, f"Status: {cp['status']}",
        ))
    html.append("</div>")

    # Detailed table
    html.append(
        '<table style="border-collapse:collapse; font-family:monospace; font-size:12px; '
        'border:1px solid #ccc; width:100%; max-width:700px;">'
    )
    html.append("<thead>")
    html.append('<tr style="background:#f0f0f0; border-bottom:2px solid #999;">')
    html.append(_th("Compressor", align="left"))
    html.append(_th("Crossing Point (instances)"))
    html.append("</tr>")
    html.append("</thead><tbody>")

    for cp in crossing_data:
        val = f"{int(round(cp['crossing_point']))}" if cp["crossing_point"] is not None else "N/A"
        html.append(
            f'<tr style="border-bottom:1px solid #ddd;">'
            f"{_td(cp['name'], bold=True)}"
            f"{_td(val)}"
            f"</tr>"
        )

    html.append("</tbody></table>")
    html.append("</div>")
    return "\n".join(html)


# ---------------------------------------------------------------------------
# Bokeh Plot Generation
# ---------------------------------------------------------------------------


def _get_plot_rows(series):
    """Filter rows to only those where configured == actual instances."""
    return [r for r in series["rows"] if r["configured_instances"] == r["actual_instances"]]


def _make_source(name, plot_rows):
    """Build a Bokeh ColumnDataSource with all hover fields from plot_rows."""
    from bokeh.models import ColumnDataSource

    return ColumnDataSource(data=dict(
        compressor=[name] * len(plot_rows),
        instances=[r["configured_instances"] for r in plot_rows],
        actual=[r["actual_instances"] for r in plot_rows],
        perf=[r["perf_regression_pct"] for r in plot_rows],
        tput=[r["tput_kops"] for r in plot_rows],
        agg_tput=[r["tput_agg_kops"] for r in plot_rows],
        p99=[r["p99_ms"] for r in plot_rows],
        active_mem=[
            r["peak_gib"] - (r["zpool_gib"] if r.get("zpool_gib") is not None else 0.0)
            for r in plot_rows
        ],
        peak_mem=[r["peak_gib"] for r in plot_rows],
        swap_gib=[r["swap_gib"] for r in plot_rows],
        zram_gib=[
            r["zpool_gib"] if r.get("zpool_gib") is not None else 0.0
            for r in plot_rows
        ],
        comp_ratio=[
            r["comp_ratio"] if r.get("comp_ratio") is not None else 0.0
            for r in plot_rows
        ],
    ))


def _create_line_plot(series_list, colors, y_field, title, y_label, height=400,
                      legend_loc="top_left", spans=None):
    """Create a Bokeh line+scatter plot for a given y-field across all series.

    Args:
        series_list: List of series dicts.
        colors: Color palette list.
        y_field: The field name in the data source to plot on y-axis.
        title: Plot title.
        y_label: Y-axis label.
        height: Plot height.
        legend_loc: Legend location.
        spans: Optional list of (location, color, dash, width) for reference lines.
    """
    from bokeh.models import HoverTool, Span
    from bokeh.plotting import figure

    p = figure(
        title=title,
        x_axis_label="Number of Redis Instances",
        y_axis_label=y_label,
        sizing_mode="stretch_width",
        height=height,
        tools="pan,wheel_zoom,box_zoom,reset,save",
    )
    p.title.text_font_size = "14pt"

    for idx, s in enumerate(series_list):
        if not s["rows"]:
            continue
        color = colors[idx % len(colors)]
        plot_rows = _get_plot_rows(s)
        if not plot_rows:
            continue
        source = _make_source(s["name"], plot_rows)
        p.line("instances", y_field, source=source,
               legend_label=s["name"], color=color, line_width=2)
        p.scatter("instances", y_field, source=source,
                  legend_label=s["name"], color=color, size=8)

    if spans:
        for location, line_color, line_dash, line_width in spans:
            p.add_layout(Span(
                location=location, dimension="width",
                line_color=line_color, line_dash=line_dash, line_width=line_width,
            ))

    p.add_tools(HoverTool(tooltips=HOVER_TOOLTIPS))
    p.legend.click_policy = "hide"
    p.legend.location = legend_loc

    return p


def _build_crossing_bar_chart(crossing_data, accept_kpi):
    """Build a horizontal bar chart for KPI crossing points."""
    from bokeh.models import ColumnDataSource, HoverTool, NumeralTickFormatter
    from bokeh.plotting import figure

    cp_names = [cp["name"] for cp in crossing_data]
    cp_values = [
        int(round(cp["crossing_point"])) if cp["crossing_point"] is not None else 0
        for cp in crossing_data
    ]
    cp_statuses = [cp["status"] for cp in crossing_data]

    p = figure(
        title=(
            f"KPI Crossing Points \u2013 Instance Count at Acceptable Performance "
            f"(threshold={accept_kpi}%)"
        ),
        x_axis_label="Crossing Point (Instance Count)",
        y_range=cp_names,
        height=max(200, 80 * len(cp_names)),
        sizing_mode="stretch_width",
        tools="pan,wheel_zoom,box_zoom,reset,save",
        toolbar_location="right",
    )
    p.title.text_font_size = "14pt"

    source = ColumnDataSource(data=dict(
        names=cp_names, values=cp_values, statuses=cp_statuses,
    ))
    p.hbar(y="names", right="values", height=0.7, source=source,
           line_color="white", fill_color="#3b82f6", fill_alpha=0.85)
    p.x_range.start = 0
    p.xaxis.formatter = NumeralTickFormatter(format="0")
    p.add_tools(HoverTool(tooltips=[
        ("Compressor", "@names"),
        ("Crossing Point (instances)", "@values"),
        ("Status", "@statuses"),
    ]))

    return p


def _build_summary_table_html(series_list):
    """Build the HTML summary data table for all series."""
    pool_modes = {s.get("swap_mode", "zswap") for s in series_list}
    pool_col_label = "Zram(GiB)" if "zram" in pool_modes else "Zpool(GiB)"

    columns = [
        "Compressor", "Scenario", "CfgInst", "ActInst", "Peak(GiB)",
        "Swap(GiB)", "Swap%", pool_col_label, "CR(x)", "Tput(KOPS)",
        "AggTput(KOPS)", "Perf%", "&Delta;Tput%", "p99(ms)",
        "&Delta;p99(ms)", "RunCPU%", "RunSysTot%",
    ]

    # Column definitions legend
    legend_items = [
        f"<b>{columns[0]}</b>: Compression algorithm configuration name",
        f"<b>{columns[1]}</b>: Instance count scenario (e.g. instances-50)",
        f"<b>{columns[2]}</b>: Configured number of Redis instances",
        f"<b>{columns[3]}</b>: Actual running instances (may differ if OOM)",
        f"<b>{columns[4]}</b>: Peak physical memory usage including zram",
        f"<b>{columns[5]}</b>: Peak swap usage",
        f"<b>{columns[6]}</b>: Swap as percentage of peak memory",
        f"<b>{pool_col_label}</b>: Compressed pool size",
        f"<b>{columns[8]}</b>: Compression ratio",
        f"<b>{columns[9]}</b>: Average per-instance throughput (thousand ops/sec)",
        f"<b>{columns[10]}</b>: Aggregate throughput across all instances",
        f"<b>{columns[11]}</b>: Performance as % of baseline throughput",
        f"<b>{columns[12]}</b>: Throughput change vs baseline",
        f"<b>{columns[13]}</b>: 99th percentile latency",
        f"<b>{columns[14]}</b>: p99 latency change vs baseline",
        f"<b>{columns[15]}</b>: Cgroup CPU utilization during run phase",
        f"<b>{columns[16]}</b>: System-wide CPU utilization during run phase",
    ]

    html = "<h3>Summary Data</h3>"
    html += (
        '<div style="font-size:11px; color:#555; margin-bottom:8px; line-height:1.6;">'
        + " &nbsp;|&nbsp; ".join(legend_items)
        + "</div>"
    )

    # Table header
    html += (
        '<table style="border-collapse:collapse; font-family:monospace; font-size:11px; '
        'border:1px solid #ccc; width:100%;">'
        "<thead><tr style='background:#f0f0f0;'>"
    )
    for col in columns:
        html += f"<th style='{_CELL_STYLE}'>{col}</th>"
    html += "</tr></thead><tbody>"

    # Sort rows by compressor name then scenario
    sorted_rows = []
    for s in series_list:
        for r in s["rows"]:
            sorted_rows.append((s["name"], r))
    sorted_rows.sort(key=lambda x: (x[0], scenario_key(x[1]["scenario"])))

    for comp_name, r in sorted_rows:
        zpool_str = f"{r['zpool_gib']:.2f}" if r.get("zpool_gib") is not None else "-"
        cr_str = f"{r['comp_ratio']:.2f}" if r.get("comp_ratio") is not None else "-"
        cells = [
            comp_name, r["scenario"],
            f"{r['configured_instances']}", f"{r['actual_instances']}",
            f"{r['peak_gib']:.2f}", f"{r['swap_gib']:.2f}",
            f"{r['swap_pct']:.2f}", zpool_str, cr_str,
            f"{r['tput_kops']:.2f}", f"{r['tput_agg_kops']:.2f}",
            f"{r['perf_regression_pct']:.2f}", f"{r['tput_delta_pct']:.2f}",
            f"{r['p99_ms']:.3f}", f"{r['p99_delta']:.3f}",
            f"{r['run_cpu_pct']:.2f}", f"{r['run_sys_total_pct']:.2f}",
        ]
        html += "<tr>"
        for cell in cells:
            html += f"<td style='{_CELL_STYLE_RIGHT}'>{cell}</td>"
        html += "</tr>"

    html += "</tbody></table>"
    return html


def generate_plot(series_list, accept_kpi, output_dir):
    """Generate an interactive Bokeh HTML report."""
    from bokeh.io import output_file, save
    from bokeh.layouts import column
    from bokeh.models import Div
    from bokeh.resources import INLINE
    from bokeh.palettes import Category10, Category20

    output_path = Path(output_dir) / "instance_sweep_report.html"
    output_file(str(output_path), title="Redis Instance Sweep Report")

    colors = Category10[10] if len(series_list) <= 10 else Category20[20]

    # Performance plot (with reference lines)
    p_perf = _create_line_plot(
        series_list, colors, y_field="perf",
        title="Average Throughput vs Instance Count",
        y_label="Performance (% of baseline)",
        height=500, legend_loc="top_right",
        spans=[
            (100, "red", "dashed", 2),
            (accept_kpi, "orange", "dotted", 2),
        ],
    )

    # Aggregate throughput plot
    p_tput = _create_line_plot(
        series_list, colors, y_field="agg_tput",
        title="Aggregate Throughput vs Instance Count",
        y_label="Aggregate Throughput (KOPS)",
    )

    # p99 latency plot
    p_lat = _create_line_plot(
        series_list, colors, y_field="p99",
        title="p99 Latency vs Instance Count",
        y_label="p99 Latency (ms)",
    )

    # Crossing points
    crossing_data = compute_crossing_points(series_list, accept_kpi)
    p_crossing = _build_crossing_bar_chart(crossing_data, accept_kpi)

    # HTML sections
    baseline_variation_html = make_baseline_variation_section(series_list)
    crossing_section_html = make_crossing_point_section(crossing_data, accept_kpi)
    summary_html = _build_summary_table_html(series_list)

    # Header
    div_header = Div(text=(
        "<h2>Redis Instance Sweep Report</h2>"
        f"<p>Acceptable KPI threshold: {accept_kpi}% of baseline</p>"
        '<div style="font-size:11px; color:#555; margin:8px 0; line-height:1.6; '
        'border:1px solid #e5e7eb; border-radius:6px; padding:10px 14px; background:#f9fafb;">'
        '<b>Hover Info Definitions:</b><br>'
        '<b>Compressor</b>: Compression algorithm configuration &nbsp;|&nbsp; '
        '<b>Instances (configured)</b>: Target number of Redis instances &nbsp;|&nbsp; '
        '<b>Instances (actual)</b>: Actually running instances &nbsp;|&nbsp; '
        '<b>Performance %</b>: Throughput as % of baseline &nbsp;|&nbsp; '
        '<b>Throughput (KOPS)</b>: Average per-instance ops/sec (thousands) &nbsp;|&nbsp; '
        '<b>Agg Throughput (KOPS)</b>: Total throughput across all instances &nbsp;|&nbsp; '
        '<b>p99 (ms)</b>: 99th percentile latency &nbsp;|&nbsp; '
        '<b>Active Memory (GiB)</b>: Cgroup physical memory (excluding zram) &nbsp;|&nbsp; '
        '<b>Peak Memory (GiB)</b>: Total memory including zram pool &nbsp;|&nbsp; '
        '<b>Swap (GiB)</b>: Peak swap usage &nbsp;|&nbsp; '
        '<b>Zram (GiB)</b>: Compressed pool size &nbsp;|&nbsp; '
        '<b>CR (x)</b>: Compression ratio'
        '</div>'
    ), sizing_mode="stretch_width")

    div_baseline = Div(text=baseline_variation_html, sizing_mode="stretch_width")
    div_crossing = Div(text=crossing_section_html, sizing_mode="stretch_width")
    div_summary = Div(text=summary_html, sizing_mode="stretch_width")

    layout = column(
        div_header, p_perf, p_tput, p_lat,
        div_baseline, p_crossing, div_crossing, div_summary,
        sizing_mode="stretch_width",
    )
    save(layout, resources=INLINE)
    print(f"Report saved to: {output_path}")


# ---------------------------------------------------------------------------
# CLI Entry Point
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="Redis instance sweep reporter")
    parser.add_argument(
        "--plot", nargs="+", metavar="REPORT_FILE",
        help="Generate HTML plot from .report files",
    )
    parser.add_argument(
        "--output-dir", default=".",
        help="Output directory for HTML report (default: current directory)",
    )
    parser.add_argument(
        "--accept-kpi", type=float, default=95.0,
        help="Acceptable KPI threshold %% (default: 95.0)",
    )
    parser.add_argument(
        "input", nargs="?",
        help="Input file path. Defaults to stdin (for report mode).",
    )
    args = parser.parse_args()

    if args.plot:
        series_list = []
        for report_file in args.plot:
            s = parse_report_file(report_file)
            if s["rows"]:
                series_list.append(s)
            else:
                print(f"WARNING: no data parsed from {report_file}", file=sys.stderr)

        if not series_list:
            print("ERROR: no valid report data found.", file=sys.stderr)
            sys.exit(1)

        generate_plot(series_list, args.accept_kpi, args.output_dir)
    else:
        if args.input:
            with open(args.input, "r") as f:
                lines = f.readlines()
        else:
            lines = sys.stdin.readlines()

        data = parse_input(lines)
        if not data:
            print("No scenario lines found.")
            sys.exit(1)

        data = enrich_rows(data)
        print_report(data, args.accept_kpi)


if __name__ == "__main__":
    main()
