# Shared workload scripts

## Cgroup memory monitoring

`memstats_log.sh` samples cgroup v2 memory accounting into CSV. It accepts
either the cgroup directory or its `memory.stat` path:

```bash
./memstats_log.sh /sys/fs/cgroup/redisbench 1 results/memstats.csv &
memstats_pid=$!

# Run the measured workload.

kill -TERM "$memstats_pid" 2>/dev/null || true
wait "$memstats_pid" 2>/dev/null || true
```

The process only needs read access to `memory.stat`; use elevated privileges
only when the cgroup permissions require them. Use `--once` to take one sample:

```bash
./memstats_log.sh --once /sys/fs/cgroup/envoybench 1 memstats.csv
```

Each row starts with a nanosecond-resolution UTC timestamp and monotonic
`elapsed_seconds`, followed by total and peak memory, swap, anonymous memory,
page cache, kernel memory, slab, THP, zswap, active/inactive lists, faults,
reclaim activity, workingset activity, and memory pressure/OOM events. Fields
not exposed by a particular kernel are recorded as zero. Plot
`elapsed_seconds` against `memory_current_bytes`, `anon_bytes`,
`page_cache_bytes`, or another byte-valued column to create a memory timeline.
`page_cache_bytes` is derived as `max(file - shmem, 0)` so tmpfs and
shared-memory pages are excluded.

Fault, reclaim, workingset, and event fields are cumulative counters. Subtract
the first sample from the last sample to measure activity during a workload
phase.

Generate a self-contained Bokeh timeline from the CSV with:

```bash
python ./memstats_plot.py results/memstats.csv \
	--zram-csv results/zram.csv --output results/memory-timeline.html \
	--title "Workload memory timeline"
```

The effective-memory stack is `(memory.current - zswap) + zswap + zram`, with
the first layer clamped to zero. Pass `--zram-csv` whenever a zram device backs
swap, including during zswap runs.

There is no cgroup v2 peak counter for page cache. Compute peak and average
usage from the sampled `page_cache_bytes` values. For virtual-machine workloads,
host cgroup values describe the VM process and host-side caching; collect the
guest cgroup's `memory.stat` for application-level page-cache accounting.