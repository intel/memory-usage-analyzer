# Analyzing multiple workloads with multiple cgroups in parallel

In some scenarios, workloads are run under different cgroups to allow different resource constraints. This section provides details on how to monitor memory usage with multiple Cgroups running concurrently. multiconfig.json, as provided in the example below, allows monitoring of 2 Cgroups. This can be further extended to more number of Cgrups. In the example below, the first ( memoryusageanalyzer1) run the baseline runs and the second Cgroup (memoryusageanalyzer2)
 run the dynamic squeezer
```
multiconfig.json:
[
        {
                "cmd":"./workload 8 60 1000",
                "cgroupname":"memoryusageanalyzer1",
                "output":"./profile_workload1",
                "reclaimerconfig":""
        },
        {
                "cmd":"./workload 8 60 1000",
                "cgroupname":"memoryusageanalyzer2",
                "output":"./profile_workload2",
                "reclaimerconfig":"../../src/reclaimer/squeezerdynamicconfig.json"
        }
]
```

```
memory_usage_analyzer.py -m ./multiconfig.json
#Sample results, actual results may vary
2024-05-22 03:34:12,471 - memoryusageanalyzer - INFO - args = Namespace(verbose=False, output='profile', outputforce=None, sampleperiod=5, docker=None, cgpath='/sys/fs/cgroup', cgname='memoryusageanalyzer', reclaimerconfig=None, multiconfig='multiconfig.json', cmdoptions=[])
cgroup_path_create start
cgroup_path_create CompletedProcess(args='sudo bash /mnt/nvme1/pg3/applications.benchmarking.memory-usage-analyzer/src/core/cgroup_config.sh /sys/fs/cgroup memoryusageanalyzer1 root ', returncode=0)
2024-05-22 03:34:12,492 - memoryusageanalyzer - INFO - **** Storing profiling results in ./profile_workload1.9
2024-05-22 03:34:12,496 - memoryusageanalyzer - INFO - cgroup v2 enabled and memory controller detected
2024-05-22 03:34:12,496 - memoryusageanalyzer - INFO - **** In run Starting
workload start
2024-05-22 03:34:12,500 - memoryusageanalyzer - INFO - **** Starting job in cgroup
2024-05-22 03:34:12,502 - memoryusageanalyzer - INFO - **** Starting stats
cgroup_path_create start
cgroup_path_create CompletedProcess(args='sudo bash /mnt/nvme1/pg3/applications.benchmarking.memory-usage-analyzer/src/core/cgroup_config.sh /sys/fs/cgroup memoryusageanalyzer2 root ', returncode=0)
2024-05-22 03:34:12,529 - memoryusageanalyzer - INFO - **** Storing profiling results in ./profile_workload2.9
2024-05-22 03:34:12,605 - memoryusageanalyzer - INFO - cgroup v2 enabled and memory controller detected
2024-05-22 03:34:12,605 - memoryusageanalyzer - INFO - **** In run Starting
workload start
2024-05-22 03:34:12,608 - memoryusageanalyzer - INFO - **** Starting job in cgroup
2024-05-22 03:34:12,611 - memoryusageanalyzer - INFO - **** Starting stats
2024-05-22 03:34:12,613 - memoryusageanalyzer - INFO - **** Starting reclaimer
memory usage = 864,256 pf_rate = 0.0 =>                  squeeze percent = 1%
[INFO] (main:43) : pid       = 7717
[INFO] (main:44) : memory    = 8 GiB = 2097152 pages
[INFO] (main:45) : hot timer = 60 sec
[INFO] (main:46) : loops     = 1000
   squeeze to 855,613 -- ok
[INFO] (main:43) : pid       = 7724
[INFO] (main:44) : memory    = 8 GiB = 2097152 pages
[INFO] (main:45) : hot timer = 60 sec
[INFO] (main:46) : loops     = 1000
[INFO] (main:60) : Done with setup in 3 seconds.
[INFO] (main:60) : Done with setup in 3 seconds.
memory usage = 8,608,489,472 pf_rate = 14.8 =>                  squeeze percent = 2%
   squeeze to 8,436,319,682 -- ok
memory usage = 8,607,981,568 pf_rate = 16119.4 =>                  squeeze percent = 0%
memory usage = 8,607,981,568 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 8,521,901,752 -- ok
memory usage = 8,521,850,880 pf_rate = 0.0 =>                  squeeze percent = 2%
   squeeze to 8,351,413,862 -- ok
memory usage = 8,351,191,040 pf_rate = 0.0 =>                  squeeze percent = 3%
   squeeze to 8,100,655,308 -- ok
memory usage = 8,100,462,592 pf_rate = 0.0 =>                  squeeze percent = 4%
   squeeze to 7,776,444,088 -- ok
memory usage = 7,776,321,536 pf_rate = 0.0 =>                  squeeze percent = 5%
   squeeze to 7,387,505,459 -- ok
[INFO] (main:77) : Done with test in 37 seconds.
memory usage = 7,387,156,480 pf_rate = 0.0 =>                  squeeze percent = 6%
2024-05-22 03:34:52,774 - memoryusageanalyzer - INFO - **** Job finished
2024-05-22 03:34:52,774 - memoryusageanalyzer - INFO - **** Stopping stats
**** Closing ./profile_workload1.9/baseline/stats.csv.gz
   squeeze to 6,943,927,091./profile_workload1.9/baseline
Generating plots ./profile_workload1.9/baseline/memoryusageanalyzer-plots.html
Loading stats from ./profile_workload1.9/baseline/stats.csv.gz
Loading stats from ./profile_workload1.9/baseline/stats.csv.gz
*** Totals without page cache ***
Maximum active+swap memory           = 8.029 GiB
Max active memory                 = 8.0 GiB
Max swap memory                = 0.0 GiB
Max page cache                 = 0.010 GiB
Swap memory                    = 0.0%
Max inactive anon              = 8.002 GiB
Maximum zpool memory           = 0.831486 GiB
Maximum zram memory            = 0.000019 GiB
incompressible data ratio(zram)= 66.7%
full total memory pressure            = 0 us
Average swap memory comp ratio = 2.00
Potential maximum compression savings in percent =                  -0.0%
Potential median compression savings in percent =                  -3.0%
Potential compression savings in bytes =                  -0.001 GiB
Average swap memory comp ratio = 2.00                  (including same filled pages)
Major PFs/sec (median, avg, max) = 0.00 0.00              0.00
Total PFs/sec (median, avg, max) = 0.00 51639.35          361475.42
Total PFs (Major+Minor) = 1814311
Major PFs = 0
sampling period = 5.01918227331979
 -- ok

[INFO] (main:77) : Done with test in 40 seconds.
2024-05-22 03:34:56,111 - memoryusageanalyzer - INFO - **** Job finished
2024-05-22 03:34:56,111 - memoryusageanalyzer - INFO - **** Stopping stats
memory usage = 393,216 pf_rate = 25.0 =>                  squeeze percent = 7%
   squeeze to 365,690 -- ok
**** Closing ./profile_workload2.9/dynamic/stats.csv.gz
2024-05-22 03:34:58,161 - memoryusageanalyzer - INFO - **** Stopping reclaimer
**** Squeezer exiting
./profile_workload2.9/dynamic
Generating plots ./profile_workload2.9/dynamic/memoryusageanalyzer-plots.html
Loading stats from ./profile_workload2.9/dynamic/stats.csv.gz
Loading stats from ./profile_workload2.9/dynamic/stats.csv.gz
*** Totals without page cache ***
Maximum active+swap memory           = 8.017 GiB
Max active memory                 = 8.0 GiB
Max swap memory                = 2.5 GiB
Max page cache                 = 0.000 GiB
Swap memory                    = 30.7%
Max inactive anon              = 7.576 GiB
Maximum zpool memory           = 1.210579 GiB
Maximum zram memory            = 0.000019 GiB
incompressible data ratio(zram)= 66.7%
full total memory pressure            = 671112 us
Average swap memory comp ratio = 2.00
Potential maximum compression savings in percent =                  2.8%
Potential median compression savings in percent =                  4.5%
Potential compression savings in bytes =                  0.226 GiB
Average swap memory comp ratio = 2.00                  (including same filled pages)
Major PFs/sec (median, avg, max) = 0.00 2293.66              18349.26
Total PFs/sec (median, avg, max) = 0.00 47318.79          360200.84
Total PFs (Major+Minor) = 1899099
Major PFs = 92054
sampling period = 5.016767889261246
```
