# Zram vs Zswap Memory Accounting — Findings

## Problem

`report.py` had no awareness of swap mode (zswap vs zram). It always calculated `Peak(GiB)` as:

```python
peak_gib = memory_peak / GiB   # memory.peak from cgroup
```

This was correct for **zswap** but wrong for **zram** due to how the Linux kernel accounts memory differently.

## Root Cause — Kernel Memory Accounting Difference

| Mode | `memory.current` includes compressed pool? | Reason |
|------|---|---|
| **zswap** | **Yes** | zswap is a kernel-internal frontswap backend; pool pages are charged to the cgroup |
| **zram** | **No** | zram is a block device (`/dev/zram0`); kernel only tracks pages *swapped out* via `memory.swap.current`, not zram's physical RAM usage |

### Impact

For **zram mode**, `memory.peak` (kernel's high-water mark of `memory.current`) only captures RSS + page cache. The actual physical memory used by zram's compressed store (`mem_used_total` from `/sys/block/zram0/mm_stat`) is **outside** cgroup memory accounting.

This means **Peak(GiB) was under-reported** by the entire zram pool size.

## Parent Project Reference (iax-memcomp)

The parent project (`applications.benchmarking.iax-memcomp`) handles this in `memcomp/util.py`:

```python
def max_memory_usage(df, gb=True, dataframe=False):
    scale = (1 << 30) if gb else 1
    if 'cgroup_memory_current' in df.columns:
        max_memory = (df.cgroup_memory_current
                      # + df.zswap_pool_total_size  # commented out: memory.current already includes zpool
                      + df.zram_mem_used_total       # zram IS added because it's outside cgroup
                     ) / scale
```

## Changes Made

### 1. `benchmark.sh`

Added `swap_mode:$swap_mode` to the log output so `report.py` can distinguish which mode was used:

```bash
echo "scenario:$scenario, swap_mode:$swap_mode, memory_max:$memory_max, ..."
```

### 2. `report.py`

- Parses `swap_mode` from log input (defaults to `"zswap"` for backward compatibility)
- For **zram mode**: adds `zswap_pool_size` (GiB) to `peak_gib`
- For **zswap mode** and **legacy logs**: no adjustment

```python
if r["swap_mode"] == "zram" and r["zswap_pool_size"] is not None:
    peak_gib += r["zswap_pool_size"]
```

## Verification Results

### Zswap Mode — `Peak(GiB) = memory.peak / GiB` (no adjustment)

| Scenario | Peak(GiB) | Save(GiB) | Save% | Zpool(GiB) |
|----------|-----------|-----------|-------|------------|
| baseline | 10.00 | 0.00 | 0.00 | 0.00 |
| memlimit-95 | 9.50 | 0.50 | 5.00 | 0.15 |
| memlimit-90 | 9.00 | 1.00 | 10.00 | 0.35 |
| memlimit-85 | 8.50 | 1.50 | 15.00 | 0.52 |

### Zram Mode — `Peak(GiB) = memory.peak / GiB + zram_pool_size`

| Scenario | Raw(GiB) | +Zpool(GiB) | Peak(GiB) | Save(GiB) | Save% |
|----------|----------|-------------|-----------|-----------|-------|
| baseline | 10.00 | 0.00 | 10.00 | 0.00 | 0.00 |
| memlimit-95 | 9.00 | 0.50 | 9.50 | 0.50 | 5.00 |
| memlimit-90 | 8.00 | 0.70 | 8.70 | 1.30 | 13.00 |
| memlimit-85 | 7.00 | 1.00 | 8.00 | 2.00 | 20.00 |

### Legacy Mode (no `swap_mode` field) — defaults to zswap, backward compatible

## Memory Pressure Application — Limit Setting

### How Parent Project Sets Limits

```python
# 1. Baseline peak (includes zram):
max_limit = max_memory_usage(df, gb=False)
# = (cgroup_memory_current + zram_mem_used_total).max()

# 2. Apply pressure:
init_limit = int((100.0 - memory_pct) / 100.0 * max_limit)
# Written to: echo $init_limit > memory.max
```

### How benchmark.sh Sets Limits

```bash
# 1. Baseline peak (cgroup-only):
baseline_max=$(memory.peak from baseline run)

# 2. Apply pressure:
limit=$((baseline_max * 95 / 100))
echo "$limit" > "$cg/memory.max"
```

### Key Insight

`memory.max` only controls `memory.current` — it does NOT limit zram's physical memory allocation.

| Aspect | Parent (zram) | benchmark.sh (zram) |
|--------|---------------|---------------------|
| Baseline reference | `cgroup_current + zram_pool` | `memory.peak` (cgroup only) |
| What `memory.max` controls | Only `memory.current` | Only `memory.current` |
| 95% limit value | 95% × (cgroup + zram) — inflated | 95% × cgroup — exact |
| Effective pressure | Weaker than intended | Correct |

**For zswap**: Both approaches are equivalent since `memory.peak` already includes zswap pool.

**For zram**: `benchmark.sh` is more correct for limit-setting because it uses the actual cgroup peak (what `memory.max` controls) as the basis for percentage calculations.

## Summary

| Area | Zswap | Zram |
|------|-------|------|
| Limit setting (benchmark.sh) | Correct | Correct |
| Reporting Peak(GiB) — before fix | Correct | **Under-reported** |
| Reporting Peak(GiB) — after fix | Correct | Correct (adds zram pool) |
| Backward compatibility | Maintained | N/A (new feature) |
