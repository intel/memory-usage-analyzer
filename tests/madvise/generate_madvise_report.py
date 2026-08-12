#!/usr/bin/env python3
"""Generate averaged madvise benchmark CSVs for zram/zswap variants.

Parses the single-thread benchmark block:
threads=1T, pages_per_thread=51746, total_pages=51,746, test_workset_mb=202

Examples:
  python3 generate_madvise_report.py -m zram
  python3 generate_madvise_report.py -m zswap
  python3 generate_madvise_report.py -m both
"""

from __future__ import annotations

import argparse
import csv
import math
import re
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Tuple

TARGET_HEADER = (
    "threads=1T (single-threaded), pages_per_thread=51746, "
    "total_pages=51,746, test_workset_mb=202"
)

ROW_RE = re.compile(
    r"^\s*(?P<compressor>\S+)\s+"
    r"(?P<ratio>[\d.,]+)\s+"
    r"(?P<zpool_mb>[\d.,]+)\s+"
    r"(?P<pgout_ns_pg>[\d.,]+)\s+"
    r"(?P<pgin_ns_pg>[\d.,]+)\s+"
    r"(?P<pgout_ms>[\d.,]+)\s+"
    r"(?P<pgin_ms>[\d.,]+)\s+"
    r"(?P<pgout_sys_ms>[\d.,]+)\s+"
    r"(?P<pgin_sys_ms>[\d.,]+)\s*$"
)

METRICS = [
    "ratio",
    "zpool_mb",
    "pgout_ns_pg",
    "pgin_ns_pg",
    "pgout_ms",
    "pgin_ms",
    "pgout_sys_ms",
    "pgin_sys_ms",
]

MAX_ITERATIONS = 10

COMPRESSOR_ORDER = [
    "lzo-rle_r1_p3",
    "lz4_r1_p3",
    "zstd_r1_p3",
    "deflate-iaa_r1_p3",
    "deflate-iaa-dynamic_r1_p3",
    "deflate-iaa_r64_p1",
    "deflate-iaa_r64_p5",
    "deflate-iaa-dynamic_r64_p1",
    "deflate-iaa-dynamic_r64_p5",
]

COMPRESSOR_RANK = {name: idx for idx, name in enumerate(COMPRESSOR_ORDER)}

SUMMARY_DIR_RANK = {
    "upstream": 0,
    "zram_backend": 1,
    "zram-backend": 1,
    "zswap-base": 2,
    "zswap-mthp-v1": 3,
    "all_patches": 4,
}

MODE_DIRS = {
    "zram": ["zram_all_patches", "zram_upstream", "zram_zram_backend"],
    "zswap": ["zswap_all_patches", "zswap_upstream", "zswap_zram_backend", "zswap_zswap-base", "zswap_zswap-mthp-v1"],
}

DIRECTORY_ALIASES = {
    "zram_zram_backend": "zram_zram-backend",
    "zram_zram-backend": "zram_zram-backend",
    "zswap_zram_backend": "zswap_zram-backend",
    "zswap_zram-backend": "zswap_zram-backend",
    "zswap_zswap_base": "zswap_zswap-base",
    "zswap_zswap-base": "zswap_zswap-base",
    "zswap_zswap_mthp_v1": "zswap_zswap-mthp-v1",
    "zswap_zswap-mthp-v1": "zswap_zswap-mthp-v1",
}

# mTHP size ordering for consistent sort
MTHP_SIZE_ORDER = ["4kB", "16kB", "32kB", "64kB", "128kB", "256kB", "512kB", "1024kB", "2048kB"]
MTHP_RANK = {s: i for i, s in enumerate(MTHP_SIZE_ORDER)}

# Regex to detect mthp-tagged directories: <mode>_<kernel>_mthp_<size>
MTHP_DIR_RE = re.compile(r"^(?P<mode>zram|zswap)_(?P<kernel>.+?)_mthp_(?P<mthp>.+)$")


def parse_num(value: str) -> float:
    return float(value.replace(",", ""))


def iteration_sort_key(path: Path) -> Tuple[int, str]:
    m = re.search(r"_(\d+)\.txt$", path.name)
    if m:
        return (int(m.group(1)), path.name)
    return (10**9, path.name)


def compressor_sort_key(name: str) -> Tuple[int, str]:
    return (COMPRESSOR_RANK.get(name, 10**9), name)


def summary_dir_sort_key(name: str) -> Tuple[int, int, str]:
    """Sort directories by kernel variant then mTHP size."""
    m = MTHP_DIR_RE.match(name)
    if m:
        kernel = m.group("kernel")
        mthp = m.group("mthp")
        kernel_rank = SUMMARY_DIR_RANK.get(kernel, 10**9)
        mthp_rank = MTHP_RANK.get(mthp, 10**9)
        return (kernel_rank, mthp_rank, name)
    suffix = name.split("_", 1)[1] if "_" in name else name
    return (SUMMARY_DIR_RANK.get(suffix, 10**9), 0, name)


def resolve_dirs(base: Path, user_dirs: Iterable[str]) -> List[Tuple[str, Path]]:
    resolved: List[Tuple[str, Path]] = []
    for d in user_dirs:
        mapped = DIRECTORY_ALIASES.get(d, d)
        path = base / mapped
        if not path.is_dir():
            print(f"  Skipping (not found): {path}")
            continue
        resolved.append((d, path))
    return resolved


def discover_mthp_dirs(base: Path, mode: str) -> List[str]:
    """Auto-discover mTHP-tagged directories for a given mode.

    Finds directories matching pattern: <mode>_<kernel>_mthp_<size>
    e.g. zswap_zswap-base_mthp_64kB, zswap_all_patches_mthp_4kB
    """
    pattern = f"{mode}_*_mthp_*"
    dirs = sorted(base.glob(pattern))
    return [d.name for d in dirs if d.is_dir()]


def find_target_rows(text: str) -> Dict[str, Dict[str, float]]:
    lines = text.splitlines()
    start_idx = -1
    for i, line in enumerate(lines):
        if TARGET_HEADER in line:
            start_idx = i
            break
    if start_idx < 0:
        return {}

    rows: Dict[str, Dict[str, float]] = {}
    for line in lines[start_idx + 1 :]:
        if "TSV saved:" in line:
            break
        m = ROW_RE.match(line)
        if not m:
            continue
        compressor = m.group("compressor")
        rows[compressor] = {k: parse_num(m.group(k)) for k in METRICS}
    return rows


def collect_runs(dir_label: str, dir_path: Path) -> Dict[str, List[Dict[str, float]]]:
    by_compressor: Dict[str, List[Dict[str, float]]] = defaultdict(list)
    txt_files = sorted(dir_path.glob("*.txt"), key=iteration_sort_key)
    if not txt_files:
        raise FileNotFoundError(f"No .txt files in {dir_path}")

    for f in txt_files:
        rows = find_target_rows(f.read_text(encoding="utf-8", errors="replace"))
        if not rows:
            continue
        for compressor, metrics in rows.items():
            if dir_label == "zram_upstream" and compressor.startswith("deflate-iaa"):
                continue
            by_compressor[compressor].append(metrics)
    return by_compressor


def average(values: List[float]) -> float:
    return sum(values) / len(values) if values else math.nan


def compute_averages(
    runs_by_dir: Dict[str, Dict[str, List[Dict[str, float]]]]
) -> Dict[str, Dict[str, Dict[str, float]]]:
    out: Dict[str, Dict[str, Dict[str, float]]] = {}
    for dir_name, by_comp in runs_by_dir.items():
        out[dir_name] = {}
        for comp, rows in by_comp.items():
            out[dir_name][comp] = {m: average([r[m] for r in rows]) for m in METRICS}
            out[dir_name][comp]["runs"] = float(len(rows))
    return out


def write_iterations_csv(
    output: Path,
    runs_by_dir: Dict[str, Dict[str, List[Dict[str, float]]]],
) -> None:
    fields = ["directory", "compressor", "iteration"] + METRICS
    for metric in METRICS:
        fields.extend(
            [
                f"{metric}_average",
                f"{metric}_min_delta_pct_vs_avg",
                f"{metric}_max_delta_pct_vs_avg",
            ]
        )

    with output.open("w", newline="", encoding="utf-8") as fp:
        w = csv.DictWriter(fp, fieldnames=fields)
        w.writeheader()
        for directory in sorted(runs_by_dir, key=summary_dir_sort_key):
            for comp in sorted(runs_by_dir[directory], key=compressor_sort_key):
                rows = runs_by_dir[directory][comp]
                metric_stats: Dict[str, Tuple[float, float, float]] = {}
                for metric in METRICS:
                    values = [r[metric] for r in rows]
                    avg_val = average(values)
                    min_val = min(values)
                    max_val = max(values)
                    min_delta_pct = (
                        ((min_val - avg_val) / avg_val * 100.0)
                        if avg_val != 0
                        else math.nan
                    )
                    max_delta_pct = (
                        ((max_val - avg_val) / avg_val * 100.0)
                        if avg_val != 0
                        else math.nan
                    )
                    metric_stats[metric] = (avg_val, min_delta_pct, max_delta_pct)

                for idx, iteration_row in enumerate(rows, start=1):
                    row = {
                        "directory": directory,
                        "compressor": comp,
                        "iteration": idx,
                    }
                    for metric in METRICS:
                        row[metric] = round(iteration_row[metric], 2)
                        avg_val, min_delta_pct, max_delta_pct = metric_stats[metric]
                        row[f"{metric}_average"] = round(avg_val, 2)
                        row[f"{metric}_min_delta_pct_vs_avg"] = (
                            round(min_delta_pct, 2) if not math.isnan(min_delta_pct) else ""
                        )
                        row[f"{metric}_max_delta_pct_vs_avg"] = (
                            round(max_delta_pct, 2) if not math.isnan(max_delta_pct) else ""
                        )
                    w.writerow(row)


def write_averages_csv(
    output: Path,
    averages: Dict[str, Dict[str, Dict[str, float]]],
) -> None:
    fields = ["directory", "compressor", "runs"]
    for metric in METRICS:
        fields.append(f"{metric}_average")

    with output.open("w", newline="", encoding="utf-8") as fp:
        w = csv.DictWriter(fp, fieldnames=fields)
        w.writeheader()
        for directory in sorted(averages, key=summary_dir_sort_key):
            for comp in sorted(averages[directory], key=compressor_sort_key):
                row = {
                    "directory": directory,
                    "compressor": comp,
                    "runs": int(averages[directory][comp]["runs"]),
                }
                for metric in METRICS:
                    row[f"{metric}_average"] = round(averages[directory][comp][metric], 2)
                w.writerow(row)


def write_summary_csv(
    output: Path,
    averages: Dict[str, Dict[str, Dict[str, float]]],
) -> None:
    fields = [
        "directory",
        "compressor",
        "runs",
        "ratio",
        "zpool_mb",
        "pgout_ns_pg",
        "pgin_ns_pg",
        "pgout_ms",
        "pgin_ms",
        "pgout_sys_ms",
        "pgin_sys_ms",
    ]

    with output.open("w", newline="", encoding="utf-8") as fp:
        w = csv.DictWriter(fp, fieldnames=fields)
        w.writeheader()
        for directory in sorted(averages, key=summary_dir_sort_key):
            for comp in sorted(averages[directory], key=compressor_sort_key):
                row = {
                    "directory": directory,
                    "compressor": comp,
                    "runs": int(averages[directory][comp]["runs"]),
                }
                row.update({m: round(averages[directory][comp][m], 2) for m in METRICS})
                w.writerow(row)


def write_deltas_csv(
    output: Path,
    averages: Dict[str, Dict[str, Dict[str, float]]],
    baseline_dir: str,
) -> None:
    fields = ["baseline_dir", "compare_dir", "compressor"]
    for metric in METRICS:
        fields.extend(
            [
                f"{metric}_baseline",
                f"{metric}_compare",
            ]
        )
    for metric in METRICS:
        fields.append(f"{metric}_delta_pct_vs_baseline")

    if baseline_dir not in averages:
        raise KeyError(f"Baseline directory not found in averages: {baseline_dir}")

    compare_dirs = [d for d in sorted(averages, key=summary_dir_sort_key) if d != baseline_dir]
    with output.open("w", newline="", encoding="utf-8") as fp:
        w = csv.DictWriter(fp, fieldnames=fields)
        w.writeheader()

        for cmp_dir in compare_dirs:
            common_compressors = sorted(
                set(averages[baseline_dir]).intersection(averages[cmp_dir])
            )
            for comp in common_compressors:
                out_row = {
                    "baseline_dir": baseline_dir,
                    "compare_dir": cmp_dir,
                    "compressor": comp,
                }
                for metric in METRICS:
                    base_val = averages[baseline_dir][comp][metric]
                    cmp_val = averages[cmp_dir][comp][metric]
                    pct = ((cmp_val - base_val) / base_val * 100.0) if base_val != 0 else math.nan
                    out_row[f"{metric}_baseline"] = round(base_val, 2)
                    out_row[f"{metric}_compare"] = round(cmp_val, 2)
                    out_row[f"{metric}_delta_pct_vs_baseline"] = (
                        round(pct, 2) if not math.isnan(pct) else ""
                    )
                w.writerow(out_row)


def run_mode(
    base: Path, mode: str, custom_dirs: List[str] | None = None, mthp: bool = False
) -> None:
    if mthp:
        # mTHP mode: auto-discover mthp-tagged directories
        dirs = custom_dirs if custom_dirs else discover_mthp_dirs(base, mode)
        if not dirs:
            print(f"[{mode}] No mTHP directories found under {base}")
            return
    else:
        dirs = custom_dirs if custom_dirs else MODE_DIRS[mode]

    resolved_dirs = resolve_dirs(base, dirs)
    if not resolved_dirs:
        print(f"[{mode}] No result directories found under {base}; skipping")
        return

    runs_by_dir: Dict[str, Dict[str, List[Dict[str, float]]]] = {}
    for label, path in resolved_dirs:
        runs_by_dir[label] = collect_runs(label, path)

    averages = compute_averages(runs_by_dir)

    suffix = "_mthp" if mthp else ""
    iter_path = base / f"{mode}_madvise{suffix}_iterations.csv"
    avg_path = base / f"{mode}_madvise{suffix}_averages.csv"
    delta_path = base / f"{mode}_madvise{suffix}_deltas.csv"
    write_iterations_csv(iter_path, runs_by_dir)
    write_averages_csv(avg_path, averages)

    # Determine baseline for deltas: prefer upstream, fall back to first directory
    baseline_candidates = [f"{mode}_upstream", sorted(runs_by_dir, key=summary_dir_sort_key)[0]]
    baseline_dir = next((b for b in baseline_candidates if b in averages), None)
    if baseline_dir:
        write_deltas_csv(delta_path, averages, baseline_dir)
        print(f"[{mode}] Wrote: {delta_path} (baseline: {baseline_dir})")
    else:
        print(f"[{mode}] Skipped deltas (no baseline found)")

    print(f"[{mode}] Wrote: {iter_path}")
    print(f"[{mode}] Wrote: {avg_path}")

    for d in sorted(runs_by_dir, key=summary_dir_sort_key):
        total = sum(len(v) for v in runs_by_dir[d].values())
        print(f"[{mode}] {d}: parsed_rows={total}, compressors={len(runs_by_dir[d])}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-m",
        "--mode",
        choices=["zram", "zswap", "both"],
        default="both",
        help="Report mode: zram, zswap, or both",
    )
    parser.add_argument(
        "--base-dir",
        default=".",
        help="Base path that contains zram_* and/or zswap_* result directories",
    )
    parser.add_argument(
        "--dirs",
        nargs="+",
        default=None,
        help="Optional explicit directory list (valid with -m zram or -m zswap)",
    )
    parser.add_argument(
        "--mthp",
        action="store_true",
        default=False,
        help="Auto-discover and report on mTHP-tagged directories (e.g. zswap_*_mthp_*)",
    )
    args = parser.parse_args()

    base = Path(args.base_dir).resolve()

    if args.mode == "both":
        if args.dirs:
            raise ValueError("--dirs cannot be used with -m both")
        run_mode(base, "zram", mthp=args.mthp)
        run_mode(base, "zswap", mthp=args.mthp)
    else:
        run_mode(base, args.mode, args.dirs, mthp=args.mthp)


if __name__ == "__main__":
    main()
