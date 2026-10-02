#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2026, Intel Corporation
import argparse
import csv
import html
from datetime import datetime, timezone
from pathlib import Path

from bokeh.io import output_file, save
from bokeh.layouts import column
from bokeh.models import ColumnDataSource, Div, HoverTool, NumeralTickFormatter
from bokeh.plotting import figure
from bokeh.resources import INLINE

GIB = 1024**3
SERIES = {
    "memory_current_bytes": ("Total memory", "#0072B2"),
    "swap_current_bytes": ("Swap", "#D55E00"),
    "anon_bytes": ("Anonymous", "#009E73"),
    "page_cache_bytes": ("Page cache", "#E69F00"),
    "kernel_bytes": ("Kernel", "#CC79A7"),
    "slab_bytes": ("Slab", "#56B4E9"),
    "zswap_bytes": ("Zswap pool", "#6B7280"),
}

STACK_FIELDS = {
    "resident_excluding_zswap_gib": ("Resident excluding zswap", "#0072B2"),
    "zswap_gib": ("Zswap", "#E69F00"),
    "zram_gib": ("Zram pool", "#009E73"),
}

PSI_FIELDS = {
    "pressure_some_seconds": ("Some stall", "#D55E00"),
    "pressure_full_seconds": ("Full stall", "#CC79A7"),
}

EFFECTIVE_MEMORY_NOTES = """
<h2>Effective physical memory</h2>
<ul>
  <li><b>Resident excluding zswap:</b> cgroup v2 <code>memory.current</code> minus
      <code>memory.stat:zswap</code>, clamped to zero.</li>
  <li><b>Zswap:</b> compressed pool memory charged to this cgroup, from
      <code>memory.stat:zswap</code>. It is already included in
      <code>memory.current</code>.</li>
  <li><b>Zram pool:</b> physical memory used by the external zram block device,
      from <code>/sys/block/zram0/mm_stat</code> via the optional zram CSV. It is
      outside the workload cgroup.</li>
</ul>
<p>The stack total is <code>(memory.current - zswap) + zswap + zram</code>.</p>
"""

COMPOSITION_NOTES = """
<h2>Memory composition</h2>
<ul>
  <li><b>Anonymous:</b> cgroup anonymous memory from
      <code>memory.stat:anon</code>.</li>
  <li><b>Page cache:</b> derived as
      <code>max(memory.stat:file - memory.stat:shmem, 0)</code>.</li>
  <li><b>Kernel:</b> cgroup kernel memory from
      <code>memory.stat:kernel</code>.</li>
  <li><b>Slab:</b> cgroup slab memory from <code>memory.stat:slab</code>; this is
      already included in Kernel.</li>
  <li><b>Zswap pool:</b> cgroup-charged compressed pool memory from
      <code>memory.stat:zswap</code>.</li>
</ul>
<p>These lines are independent counters and are not an additive stack.</p>
"""

PSI_NOTES = """
<h2>Memory pressure stalls</h2>
<ul>
  <li><b>Some stall:</b> cumulative time since sampling began when at least one
      task in the cgroup was stalled on memory, derived from
      <code>memory.pressure:some total</code>.</li>
  <li><b>Full stall:</b> cumulative time since sampling began when all non-idle
      tasks in the cgroup were stalled on memory, derived from
      <code>memory.pressure:full total</code>.</li>
</ul>
<p>Both values are cgroup v2 PSI counters converted from microseconds to seconds
after subtracting the first sample.</p>
"""


def timestamp_seconds(value):
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value).timestamp()


def load_zram_pool(path, timestamps):
    with path.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    samples = []
    for row_number, row in enumerate(rows, start=2):
        try:
            sample_time = datetime.strptime(
                row["timestamp"], "%Y-%m-%d %H:%M:%S"
            ).replace(tzinfo=timezone.utc).timestamp()
            samples.append((sample_time, float(row["pool_bytes"]) / GIB))
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"invalid zram sample on CSV row {row_number}") from error
    samples.sort()

    result = []
    sample_index = 0
    current_pool = 0.0
    for timestamp in timestamps:
        current_time = timestamp_seconds(timestamp)
        while sample_index < len(samples) and samples[sample_index][0] <= current_time:
            current_pool = samples[sample_index][1]
            sample_index += 1
        result.append(current_pool)
    return result


def load_csv(path, zram_path=None):
    with path.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))
    if not rows:
        raise ValueError("input contains no samples")
    required = {"timestamp_utc", "elapsed_seconds", *SERIES}
    missing = required.difference(rows[0])
    if missing:
        raise ValueError(f"missing columns: {', '.join(sorted(missing))}")

    data = {"timestamp_utc": [], "elapsed_seconds": []}
    data.update({field: [] for field in SERIES})
    pressure_some_usec = []
    pressure_full_usec = []
    for row_number, row in enumerate(rows, start=2):
        try:
            data["timestamp_utc"].append(row["timestamp_utc"])
            data["elapsed_seconds"].append(float(row["elapsed_seconds"]))
            for field in SERIES:
                data[field].append(float(row[field]) / GIB)
            pressure_some_usec.append(float(row.get("pressure_some_total_usec", 0) or 0))
            pressure_full_usec.append(float(row.get("pressure_full_total_usec", 0) or 0))
        except (TypeError, ValueError) as error:
            raise ValueError(f"invalid numeric value on CSV row {row_number}") from error
    some_start = pressure_some_usec[0]
    full_start = pressure_full_usec[0]
    data["pressure_some_seconds"] = [
        max(value - some_start, 0) / 1_000_000 for value in pressure_some_usec
    ]
    data["pressure_full_seconds"] = [
        max(value - full_start, 0) / 1_000_000 for value in pressure_full_usec
    ]
    zswap = data["zswap_bytes"]
    current = data["memory_current_bytes"]
    data["resident_excluding_zswap_gib"] = [max(resident - pool, 0) for resident, pool in zip(current, zswap)]
    data["zswap_gib"] = zswap
    if zram_path is not None:
        data["zram_gib"] = load_zram_pool(zram_path, data["timestamp_utc"])
    else:
        data["zram_gib"] = [0.0] * len(current)
    return data


def make_effective_memory_plot(source):
    plot = figure(
        title="Effective physical memory",
        x_axis_label="Elapsed time (seconds)",
        y_axis_label="Memory (GiB)",
        height=400,
        sizing_mode="stretch_width",
        tools="pan,wheel_zoom,box_zoom,reset,save",
    )
    fields = list(STACK_FIELDS)
    labels = [STACK_FIELDS[field][0] for field in fields]
    colors = [STACK_FIELDS[field][1] for field in fields]
    plot.varea_stack(fields, x="elapsed_seconds", source=source, color=colors,
                     legend_label=labels, alpha=0.75)
    lines = []
    for field, label, color in zip(fields, labels, colors):
        lines.append(plot.line("elapsed_seconds", field, source=source, color=color,
                               line_width=1.5, name=label))
    plot.yaxis.formatter = NumeralTickFormatter(format="0.000")
    plot.legend.location = "top_right"
    plot.legend.click_policy = "hide"
    plot.add_tools(HoverTool(
        renderers=lines,
        tooltips=[
            ("Series", "$name"),
            ("Elapsed", "@elapsed_seconds{0.000} s"),
            ("Value", "$y{0.000} GiB"),
            ("UTC", "@timestamp_utc"),
        ],
        mode="vline",
    ))
    return plot


def make_plot(source, fields, title):
    plot = figure(
        title=title,
        x_axis_label="Elapsed time (seconds)",
        y_axis_label="Memory (GiB)",
        height=350,
        sizing_mode="stretch_width",
        tools="pan,wheel_zoom,box_zoom,reset,save",
    )
    renderers = []
    for field in fields:
        label, color = SERIES[field]
        renderers.append(plot.line(
            "elapsed_seconds", field, source=source, line_width=2,
            color=color, legend_label=label, name=label,
        ))
    plot.yaxis.formatter = NumeralTickFormatter(format="0.000")
    plot.legend.location = "top_right"
    plot.legend.click_policy = "hide"
    plot.add_tools(HoverTool(
        renderers=renderers,
        tooltips=[
            ("Series", "$name"),
            ("Elapsed", "@elapsed_seconds{0.000} s"),
            ("Memory", "$y{0.000} GiB"),
            ("UTC", "@timestamp_utc"),
        ],
        mode="vline",
    ))
    return plot


def make_psi_plot(source):
    plot = figure(
        title="Cgroup memory PSI",
        x_axis_label="Elapsed time (seconds)",
        y_axis_label="Cumulative stall time (seconds)",
        height=350,
        sizing_mode="stretch_width",
        tools="pan,wheel_zoom,box_zoom,reset,save",
    )
    renderers = []
    for field, (label, color) in PSI_FIELDS.items():
        renderers.append(plot.line(
            "elapsed_seconds", field, source=source, line_width=2,
            color=color, legend_label=label, name=label,
        ))
    plot.yaxis.formatter = NumeralTickFormatter(format="0.000")
    plot.legend.location = "top_right"
    plot.legend.click_policy = "hide"
    plot.add_tools(HoverTool(
        renderers=renderers,
        tooltips=[
            ("Series", "$name"),
            ("Elapsed", "@elapsed_seconds{0.000} s"),
            ("Stall time", "$y{0.000000} s"),
            ("UTC", "@timestamp_utc"),
        ],
        mode="vline",
    ))
    return plot


def main():
    parser = argparse.ArgumentParser(description="Plot a cgroup memory timeline CSV")
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--title", default="Cgroup memory timeline")
    parser.add_argument("--zram-csv", type=Path,
                        help="zram pool samples to add above cgroup memory")
    args = parser.parse_args()
    output = args.output or args.input.with_suffix(".html")

    try:
        source = ColumnDataSource(load_csv(args.input, args.zram_csv))
    except (OSError, ValueError) as error:
        parser.error(str(error))

    safe_title = html.escape(args.title)
    safe_source = html.escape(args.input.name)
    layout = column(
        Div(text=f"<h1>{safe_title}</h1><p>Source: {safe_source}</p>"),
        Div(text=EFFECTIVE_MEMORY_NOTES, sizing_mode="stretch_width"),
        make_effective_memory_plot(source),
        Div(text=COMPOSITION_NOTES, sizing_mode="stretch_width"),
        make_plot(
            source,
            ["anon_bytes", "page_cache_bytes", "kernel_bytes", "slab_bytes", "zswap_bytes"],
            "Memory composition",
        ),
        Div(text=PSI_NOTES, sizing_mode="stretch_width"),
        make_psi_plot(source),
        sizing_mode="stretch_width",
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output_file(str(output), title=args.title)
    save(layout, resources=INLINE)
    print(f"Memory timeline: {output}")


if __name__ == "__main__":
    main()