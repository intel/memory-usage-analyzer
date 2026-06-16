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
from pathlib import Path
from typing import Dict, List, Any

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

Row = Dict[str, Any]


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
        "CR(x)": ("cr_x", str),
        "Tput(KOPS)": ("tput_kops", _to_float),
        "ΔTput%": ("dtput_pct", _to_float),
        "p99(ms)": ("p99_ms", _to_float),
        "Δp99(ms)": ("dp99", _to_float),
        "Δp99%": ("dp99", _to_float),
        "PreCPU%": ("pre_cpu_pct", _to_float),
        "ΔPreCPU": ("dpre_cpu", _to_float),
        "PreUsr%": ("pre_user_pct", _to_float),
        "ΔPreUsr": ("dpre_user", _to_float),
        "PreSys%": ("pre_sys_pct", _to_float),
        "ΔPreSys": ("dpre_sys", _to_float),
        "RunCPU%": ("run_cpu_pct", _to_float),
        "ΔRunCPU": ("drun_cpu", _to_float),
        "RunUsr%": ("run_user_pct", _to_float),
        "ΔRunUsr": ("drun_user", _to_float),
        "RunSys%": ("run_sys_pct", _to_float),
        "ΔRunSys": ("drun_sys", _to_float),
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
            "cr_x": "-",
            "tput_kops": 0.0,
            "dtput_pct": 0.0,
            "p99_ms": 0.0,
            "dp99": 0.0,
            "memmax": "-",
            "pre_cpu_pct": 0.0,
            "dpre_cpu": 0.0,
            "pre_user_pct": 0.0,
            "dpre_user": 0.0,
            "pre_sys_pct": 0.0,
            "dpre_sys": 0.0,
            "run_cpu_pct": 0.0,
            "drun_cpu": 0.0,
            "run_user_pct": 0.0,
            "drun_user": 0.0,
            "run_sys_pct": 0.0,
            "drun_sys": 0.0,
        }

        for metric, values in metrics.items():
            if metric not in metric_to_key:
                continue
            key, caster = metric_to_key[metric]
            row[key] = caster(values[idx])

        rows.append(row)

    return rows


def parse_lines(lines: List[str]) -> List[Row]:
    rows = _parse_transposed(lines)
    if rows:
        return rows
    return _parse_row_oriented(lines)


def rows_to_cds_dict(rows: List[Row]) -> Dict[str, List[Any]]:
    keys = rows[0].keys()
    return {k: [r[k] for r in rows] for k in keys}


def make_table_transposed(rows: List[Row], title: str):
    """Generate HTML table with scenarios as columns and metrics as rows."""
    if not rows:
        return Div(text="<p>No data</p>", sizing_mode="stretch_width")

    metrics_order = [
        ("MemMax", lambda r: r["memmax"]),
        ("Peak(GiB)", lambda r: f"{r['peak_gib']:.2f}"),
        ("Save(GiB)", lambda r: f"{r['save_gib']:.2f}"),
        ("Save%", lambda r: f"{r['save_pct']:.2f}"),
        ("Swap(GiB)", lambda r: f"{r['swap_gib']:.2f}"),
        ("Swap%", lambda r: f"{r['swap_pct']:.2f}"),
        ("Zpool(GiB)", lambda r: r["zpool_gib"]),
        ("CR(x)", lambda r: r["cr_x"]),
        ("Tput(KOPS)", lambda r: f"{r['tput_kops']:.2f}"),
        ("ΔTput%", lambda r: f"{r['dtput_pct']:.2f}"),
        ("p99(ms)", lambda r: f"{r['p99_ms']:.3f}"),
        ("Δp99(ms)", lambda r: f"{r['dp99']:.2f}"),
        ("PreCPU%", lambda r: f"{r['pre_cpu_pct']:.2f}"),
        ("ΔPreCPU", lambda r: f"{r['dpre_cpu']:.2f}"),
        ("PreUsr%", lambda r: f"{r['pre_user_pct']:.2f}"),
        ("ΔPreUsr", lambda r: f"{r['dpre_user']:.2f}"),
        ("PreSys%", lambda r: f"{r['pre_sys_pct']:.2f}"),
        ("ΔPreSys", lambda r: f"{r['dpre_sys']:.2f}"),
        ("RunCPU%", lambda r: f"{r['run_cpu_pct']:.2f}"),
        ("ΔRunCPU", lambda r: f"{r['drun_cpu']:.2f}"),
        ("RunUsr%", lambda r: f"{r['run_user_pct']:.2f}"),
        ("ΔRunUsr", lambda r: f"{r['drun_user']:.2f}"),
        ("RunSys%", lambda r: f"{r['run_sys_pct']:.2f}"),
        ("ΔRunSys", lambda r: f"{r['drun_sys']:.2f}"),
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
    return Div(text=html_text, sizing_mode="stretch_width")


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
        help="Regression threshold in percent (default: 5). Threshold line at ΔTput% = -threshold.",
    )
    ap.add_argument(
        "--label-series",
        action="store_true",
        help="Label every point with scenario names for ALL series (can get cluttered). Default: label only first series.",
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
        src = ColumnDataSource(rows_to_cds_dict(rows))
        series.append(dict(file=rf, name=rf.stem, rows=rows, source=src))

    if not series:
        raise SystemExit("No valid series found in input files.")

    colors = pick_palette(len(series))

    all_x: List[float] = []
    for s in series:
        all_x.extend(s["source"].data["save_pct"])

    # ---- Plot 1: Save% vs ΔTput% ----
    p_tput = figure(
        title="Memory Savings vs Throughput Change (ΔTput%: negative = regression)",
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
            ("p99(ms)", "@p99_ms{0.000}"),
        ],
    )
    p_tput.add_tools(hover_tput)

    # Labels: default only first series
    if series:
        p_tput.add_layout(
            LabelSet(
                x="save_pct",
                y="dtput_pct",
                text="scenario",
                x_offset=6,
                y_offset=6,
                source=series[0]["source"],
                text_font_size="8pt",
                text_alpha=0.8,
            )
        )
    if args.label_series:
        for s in series[1:]:
            p_tput.add_layout(
                LabelSet(
                    x="save_pct",
                    y="dtput_pct",
                    text="scenario",
                    x_offset=6,
                    y_offset=6,
                    source=s["source"],
                    text_font_size="8pt",
                    text_alpha=0.8,
                )
            )

    # ---- Plot 2: Save% vs p99(ms) ----
    p_p99 = figure(
        title="Memory Savings vs p99 Latency",
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

    if series:
        p_p99.add_layout(
            LabelSet(
                x="save_pct",
                y="p99_ms",
                text="scenario",
                x_offset=6,
                y_offset=6,
                source=series[0]["source"],
                text_font_size="8pt",
                text_alpha=0.8,
            )
        )
    if args.label_series:
        for s in series[1:]:
            p_p99.add_layout(
                LabelSet(
                    x="save_pct",
                    y="p99_ms",
                    text="scenario",
                    x_offset=6,
                    y_offset=6,
                    source=s["source"],
                    text_font_size="8pt",
                    text_alpha=0.8,
                )
            )

    # ---- Plot 3: Save% vs ΔRunCPU ----
    p_runCPU = figure(
        title="Memory Savings vs Run CPU Change (ΔRunCPU)",
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
            ("RunCPU%", "@run_cpu_pct{0.00}"),
            ("ΔRunCPU", "@drun_cpu{0.00}"),
        ],
    )
    p_runCPU.add_tools(hover_runCPU)

    if series:
        p_runCPU.add_layout(
            LabelSet(
                x="save_pct",
                y="drun_cpu",
                text="scenario",
                x_offset=6,
                y_offset=6,
                source=series[0]["source"],
                text_font_size="8pt",
                text_alpha=0.8,
            )
        )
    if args.label_series:
        for s in series[1:]:
            p_runCPU.add_layout(
                LabelSet(
                    x="save_pct",
                    y="drun_cpu",
                    text="scenario",
                    x_offset=6,
                    y_offset=6,
                    source=s["source"],
                    text_font_size="8pt",
                    text_alpha=0.8,
                )
            )

    # ---- Header + Summary + Tables ----
    header = Div(
        text=f"""
        <div style="display:flex; flex-wrap:wrap; gap:12px; align-items:flex-end;">
          <div style="flex: 1 1 520px;">
            <h2 style="margin: 0 0 6px 0;">Tradeoff Report</h2>
            <div style="color:#374151;">
              Plot 1: Save% vs ΔTput% &nbsp;|&nbsp;
              Plot 2: Save% vs p99(ms) &nbsp;|&nbsp;
              Plot 3: Save% vs ΔRunCPU &nbsp;|&nbsp;
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

    table_blocks = []
    for s in series:
        t = make_table_transposed(s["rows"], f"Table: {s['file'].name}")
        table_blocks.append(t)

    layout = column(
        header,
        p_tput,
        p_p99,
        p_runCPU,
        summary_header,
        *summaries,
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
