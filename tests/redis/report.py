#!/usr/bin/env python3
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
import argparse
import re
import sys

GiB = 1024**3


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
    if name == "baseline":
        return (0, 0)
    m = re.match(r"memlimit-(\d+)$", name)
    if m:
        pct = int(m.group(1))
        return (1, -pct)
    return (2, name)


def parse_input(lines):
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


def enrich_rows(data):
    for r in data:
        r["swap_mode"] = r.get("swap_mode", "zswap").strip()
        r["memory_max"] = r.get("memory_max", "").strip()
        r["memory_peak"] = to_int(r.get("memory_peak", 0))
        r["memory_swap_peak"] = to_int(r.get("memory_swap_peak", 0))
        r["throughput_ops"] = to_float(r.get("throughput", 0))
        r["throughput_kops"] = r["throughput_ops"] / 1000.0
        r["p99"] = to_float(r.get("p99", 0))

        zpool = r.get("zswap_pool_size", "").strip()
        r["zswap_pool_size"] = to_float(zpool, None) if zpool else None
        cr = r.get("comp_ratio", "").strip()
        r["comp_ratio"] = to_float(cr, None) if cr else None

        r["prefill_cpu_pct"] = to_float(r.get("prefill_cpu_pct", 0))
        r["prefill_user_pct"] = to_float(r.get("prefill_user_pct", 0))
        r["prefill_sys_pct"] = to_float(r.get("prefill_sys_pct", 0))
        r["run_cpu_pct"] = to_float(r.get("run_cpu_pct", 0))
        r["run_user_pct"] = to_float(r.get("run_user_pct", 0))
        r["run_sys_pct"] = to_float(r.get("run_sys_pct", 0))

    data.sort(key=lambda r: scenario_key(r.get("scenario", "unknown")))

    baseline = next((r for r in data if r["scenario"] == "baseline"), None)
    if baseline is None:
        print("Missing scenario:baseline in input.")
        sys.exit(1)

    base_peak = baseline["memory_peak"] / GiB
    if baseline["swap_mode"] == "zram" and baseline["zswap_pool_size"] is not None:
        base_peak += baseline["zswap_pool_size"]
    base_tput_kops = baseline["throughput_kops"]
    base_p99 = baseline["p99"]
    base_prefill_cpu = baseline["prefill_cpu_pct"]
    base_prefill_user = baseline["prefill_user_pct"]
    base_prefill_sys = baseline["prefill_sys_pct"]
    base_run_cpu = baseline["run_cpu_pct"]
    base_run_user = baseline["run_user_pct"]
    base_run_sys = baseline["run_sys_pct"]

    for r in data:
        name = r["scenario"]
        peak_gib = r["memory_peak"] / GiB
        swap_gib = r["memory_swap_peak"] / GiB

        # For zram mode: memory.peak does NOT include zram's physical memory
        # usage (zram is a block device outside cgroup memory accounting).
        # Add zram pool size to get true physical memory, matching the parent
        # project's formula: max_memory = cgroup_memory_current + zram_mem_used_total
        # For zswap mode: memory.peak already includes the zswap pool (kernel
        # accounts zpool inside memory.current), so no adjustment needed.
        if r["swap_mode"] == "zram" and r["zswap_pool_size"] is not None:
            peak_gib += r["zswap_pool_size"]

        r["peak_gib"] = peak_gib
        r["save_gib"] = base_peak - peak_gib
        r["save_pct"] = (r["save_gib"] / base_peak * 100.0) if name != "baseline" else 0.0
        r["swap_gib"] = swap_gib
        r["swap_pct"] = (swap_gib / peak_gib * 100.0) if peak_gib > 0 else 0.0
        r["tput_delta"] = ((r["throughput_kops"] - base_tput_kops) / base_tput_kops * 100.0) if name != "baseline" else 0.0
        r["p99_delta"] = (r["p99"] - base_p99) if name != "baseline" else 0.0

        r["prefill_cpu_delta"] = r["prefill_cpu_pct"] - base_prefill_cpu if name != "baseline" else 0.0
        r["prefill_user_delta"] = r["prefill_user_pct"] - base_prefill_user if name != "baseline" else 0.0
        r["prefill_sys_delta"] = r["prefill_sys_pct"] - base_prefill_sys if name != "baseline" else 0.0
        r["run_cpu_delta"] = r["run_cpu_pct"] - base_run_cpu if name != "baseline" else 0.0
        r["run_user_delta"] = r["run_user_pct"] - base_run_user if name != "baseline" else 0.0
        r["run_sys_delta"] = r["run_sys_pct"] - base_run_sys if name != "baseline" else 0.0

    return data


def print_rows(data):
    print(f"{'Scenario':<15} "
          f"{'Peak(GiB)':>10} "
          f"{'Save(GiB)':>10} "
          f"{'Save%':>7} "
          f"{'Swap(GiB)':>10} "
          f"{'Swap%':>7} "
          f"{'Zpool(GiB)':>11} "
          f"{'CR(x)':>6} "
          f"{'Tput(KOPS)':>12} "
          f"{'ΔTput%':>8} "
          f"{'p99(ms)':>9} "
          f"{'Δp99(ms)':>10} "
          f"{'MemMax':>10} "
          f"{'PreCPU%':>8} "
          f"{'ΔPreCPU':>9} "
          f"{'PreUsr%':>8} "
          f"{'ΔPreUsr':>9} "
          f"{'PreSys%':>8} "
          f"{'ΔPreSys':>9} "
          f"{'RunCPU%':>8} "
          f"{'ΔRunCPU':>9} "
          f"{'RunUsr%':>8} "
          f"{'ΔRunUsr':>9} "
          f"{'RunSys%':>8} "
          f"{'ΔRunSys':>9}")
    print("-" * 280)

    for r in data:
        memmax = r["memory_max"] if r["memory_max"] else "-"
        zpool_str = f"{r['zswap_pool_size']:.2f}" if r["zswap_pool_size"] is not None else "-"
        cr_str = f"{r['comp_ratio']:.2f}" if r["comp_ratio"] is not None else "-"
        print(f"{r['scenario']:<15} "
              f"{r['peak_gib']:>10.2f} "
              f"{r['save_gib']:>10.2f} "
              f"{r['save_pct']:>7.2f} "
              f"{r['swap_gib']:>10.2f} "
              f"{r['swap_pct']:>7.2f} "
              f"{zpool_str:>11} "
              f"{cr_str:>6} "
              f"{r['throughput_kops']:>12.2f} "
              f"{r['tput_delta']:>8.2f} "
              f"{r['p99']:>9.2f} "
              f"{r['p99_delta']:>10.2f} "
              f"{memmax:>10} "
              f"{r['prefill_cpu_pct']:>8.2f} "
              f"{r['prefill_cpu_delta']:>9.2f} "
              f"{r['prefill_user_pct']:>8.2f} "
              f"{r['prefill_user_delta']:>9.2f} "
              f"{r['prefill_sys_pct']:>8.2f} "
              f"{r['prefill_sys_delta']:>9.2f} "
              f"{r['run_cpu_pct']:>8.2f} "
              f"{r['run_cpu_delta']:>9.2f} "
              f"{r['run_user_pct']:>8.2f} "
              f"{r['run_user_delta']:>9.2f} "
              f"{r['run_sys_pct']:>8.2f} "
              f"{r['run_sys_delta']:>9.2f}")


def print_columns(data):
    scenarios = [r["scenario"] for r in data]
    scenario_widths = [max(12, len(s)) for s in scenarios]
    metric_width = 14

    def fmt_val(val, width):
        return f"{val:>{width}}"

    header = fmt_val("Metric", metric_width) + " " + " ".join(
        fmt_val(s, w) for s, w in zip(scenarios, scenario_widths)
    )
    print(header)
    print("-" * len(header))

    metric_rows = [
        ("MemMax", lambda r: (r["memory_max"] if r["memory_max"] else "-")),
        ("Peak(GiB)", lambda r: f"{r['peak_gib']:.2f}"),
        ("Save(GiB)", lambda r: f"{r['save_gib']:.2f}"),
        ("Save%", lambda r: f"{r['save_pct']:.2f}"),
        ("Swap(GiB)", lambda r: f"{r['swap_gib']:.2f}"),
        ("Swap%", lambda r: f"{r['swap_pct']:.2f}"),
        ("Zpool(GiB)", lambda r: (f"{r['zswap_pool_size']:.2f}" if r["zswap_pool_size"] is not None else "-")),
        ("CR(x)", lambda r: (f"{r['comp_ratio']:.2f}" if r["comp_ratio"] is not None else "-")),
        ("Tput(KOPS)", lambda r: f"{r['throughput_kops']:.2f}"),
        ("ΔTput%", lambda r: f"{r['tput_delta']:.2f}"),
        ("p99(ms)", lambda r: f"{r['p99']:.2f}"),
        ("Δp99(ms)", lambda r: f"{r['p99_delta']:.2f}"),
        ("PreCPU%", lambda r: f"{r['prefill_cpu_pct']:.2f}"),
        ("ΔPreCPU", lambda r: f"{r['prefill_cpu_delta']:.2f}"),
        ("PreUsr%", lambda r: f"{r['prefill_user_pct']:.2f}"),
        ("ΔPreUsr", lambda r: f"{r['prefill_user_delta']:.2f}"),
        ("PreSys%", lambda r: f"{r['prefill_sys_pct']:.2f}"),
        ("ΔPreSys", lambda r: f"{r['prefill_sys_delta']:.2f}"),
        ("RunCPU%", lambda r: f"{r['run_cpu_pct']:.2f}"),
        ("ΔRunCPU", lambda r: f"{r['run_cpu_delta']:.2f}"),
        ("RunUsr%", lambda r: f"{r['run_user_pct']:.2f}"),
        ("ΔRunUsr", lambda r: f"{r['run_user_delta']:.2f}"),
        ("RunSys%", lambda r: f"{r['run_sys_pct']:.2f}"),
        ("ΔRunSys", lambda r: f"{r['run_sys_delta']:.2f}"),
    ]

    for metric, getter in metric_rows:
        line = fmt_val(metric, metric_width) + " " + " ".join(
            fmt_val(getter(r), w) for r, w in zip(data, scenario_widths)
        )
        print(line)


def main():
    parser = argparse.ArgumentParser(description="Generate redis benchmark report table")
    parser.add_argument("input", nargs="?", help="Input file path. Defaults to stdin.")
    parser.add_argument(
        "--format",
        choices=["columns", "rows"],
        default="columns",
        help="Output format: columns (scenario as columns) or rows (scenario as rows).",
    )
    args = parser.parse_args()

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
    if args.format == "rows":
        print_rows(data)
    else:
        print_columns(data)


if __name__ == "__main__":
    main()
