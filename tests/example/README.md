# Example Workload
This section provides usage scenarios of memory-usage-analyzer with an example workloads

## Prepare the example workload
This example workload prepares a large memory segment. A portion of this memory segment is accessed (50% or 75% of the total) to create the memory regions which are the more frequently accessed (hot) and less frequently accessed (cold).
```shell
cd tests/example
make
./workload
# Sample output
usage ./workload: total_memory(GiB) hot_timer loops
```

The parameters:
* `total_memory` : amount of memory used by the workload in GiB
* `hot_timer` : time period spend in 50% and 75% hot memory modes in seconds
* `loops` : controls the amount of work done, if 0 the workload runs forever

Here's an example run of the workload:
```shell

./workload 8 10 1000
# Sample output
[INFO] (main:34) : pid       = 20141
[INFO] (main:35) : memory    = 8 GiB = 2097152 pages
[INFO] (main:36) : hot timer = 10 sec
[INFO] (main:37) : loops     = 1000
[INFO] (main:51) : Done with setup in 3 seconds.
[INFO] (sigalrm_handler:17) : hot pages = 75%
[INFO] (sigalrm_handler:17) : hot pages = 50%
[INFO] (main:68) : Done with test in 21 seconds.
```

## Profile the Example Workload
There are three different scenarios that are provided here

1. Baseline - Running baseline without any memory pressure and collecting the memory usage statistics
1. Dynamic Squeezer - Running workload under a Cgroup to create memory pressure,  where the memory limit is adjusted dynamically to limit the page fault rate
1. Static Squeezer - Running workload under a Cgroup to create memory pressure, where the memory limit to fixed 

### Simple Workload - Baseline

This is an example of running baseline workload. Before running the workload, system configuration should be performed to enable the data collection.
For system configuration details, please refer [config](../../docs/README.md)

```shell
cd tests/example
# Configure the system for data collection
config.py
# Configuration ZSWAP compressor
zswapcompconfig.py -c lzo-rle
memory-usage-analyzer.py -- ./workload 8 60 10000

# Sample results, actual results may vary
2024-04-01 22:31:19,322 - memoryusageanalyzer - INFO - args = Namespace(cgname='memoryusageanalyzer', cgpath='/sys/fs/cgroup', cmd='./workload', docker=None, options=['8', '60', '10000'], output='profile', outputforce=None, reclaimerconfig=None, sampleperiod=5, verbose=False)
2024-04-01 22:31:19,322 - memoryusageanalyzer - INFO - **** Storing profiling results in profile
2024-04-01 22:31:19,326 - memoryusageanalyzer - INFO - cgroup v2 enabled and memory controller detected
2024-04-01 22:31:19,330 - memoryusageanalyzer - INFO - **** Starting job in cgroup
2024-04-01 22:31:19,332 - memoryusageanalyzer - INFO - **** Starting stats
[INFO] (main:43) : pid       = 26557
[INFO] (main:44) : memory    = 8 GiB = 2097152 pages
[INFO] (main:45) : hot timer = 60 sec
[INFO] (main:46) : loops     = 10000
[INFO] (main:60) : Done with setup in 2 seconds.
[INFO] (sigalrm_handler:25) : hot pages = 75%
[INFO] (sigalrm_handler:25) : hot pages = 50%
[INFO] (sigalrm_handler:25) : hot pages = 75%
[INFO] (main:77) : Done with test in 215 seconds.
2024-04-01 22:34:56,845 - memoryusageanalyzer - INFO - **** Job finished
2024-04-01 22:34:56,846 - memoryusageanalyzer - INFO - **** Stopping stats
**** Closing profile/baseline/stats.csv.gz
profile/baseline
Generating plots profile/baseline/memoryusageanalyzer-plots.html
Loading stats from profile/baseline/stats.csv.gz
Loading stats from profile/baseline/stats.csv.gz
*** Totals without page cache ***
Maximum active+swap memory           = 8.051 GiB
Max active memory                 = 8.0 GiB
Max swap memory                = 0.0 GiB
Max page cache                 = 0.014 GiB
Swap memory                    = 0.3%
Max inactive anon              = 8.005 GiB
Maximum zpool memory           = 0.027439 GiB
Maximum zram memory            = 0.000011 GiB
incompressible data ratio(zram)= 0.0%
full total memory pressure            = 0 us
Average swap memory comp ratio = 1.01
Potential maximum compression savings in percent =                  0.0%
Potential median compression savings in percent =                  0.0%
Potential compression savings in bytes =                  0.000 GiB
Average swap memory comp ratio = 1.01                  (including same filled pages)
Major PFs/sec (median, avg, max) = 0.00 0.00              0.00
Total PFs/sec (median, avg, max) = 0.00 9130.44          392608.59
Total PFs (Major+Minor) = 1964235
Major PFs = 0
sampling period = 5.003033671268197
```
The analyzer output is also saved at profile/baseline/analyze.out. The visualization of the memory usage will be at profile/baseline/memoryusageanalyzer-plots.html as shown below.

![Memoryusage](ref_results/Baselinememoryusage.png "MemoryUsage")

###  Example Workload with dynamic squeezer
This is an example where dynamic memory-limit is applied to workload through cgroup with page-fault rate as the metric. The memory limit is applied gradually to the workload till the page-fault-rate reaches the threshold. After that, dynamic squeezer adjusts the memory limit to keep the page-fault-rate within the threshold by relaxing the memory-limit.
Please refer to the config file for dynamic squeezer in the repo memory-usage-analyzer/src/reclaimer/

With dynamic squeezer
```shell
cd tests/example
config.py
zswapcompconfig.py -c lzo-rle
memory-usage-analyzer.py -r ../../src/reclaimer/squeezerdynamicconfig.json -- ./workload 8 60 10000
# Sample results, actual results may vary
2024-04-01 22:12:13,171 - memoryusageanalyzer - INFO - args = Namespace(cgname='memoryusageanalyzer', cgpath='/sys/fs/cgroup', cmd='./workload', docker=None, options=['8', '60', '10000'], output='profile', outputforce=None, reclaimerconfig='../../src/reclaimer/squeezerdynamicconfig.json', sampleperiod=5, verbose=False)
2024-04-01 22:12:13,171 - memoryusageanalyzer - INFO - **** Storing profiling results in profile.6
2024-04-01 22:12:13,227 - memoryusageanalyzer - INFO - cgroup v2 enabled and memory controller detected
2024-04-01 22:12:13,231 - memoryusageanalyzer - INFO - **** Starting job in cgroup
2024-04-01 22:12:13,234 - memoryusageanalyzer - INFO - **** Starting stats
2024-04-01 22:12:13,237 - memoryusageanalyzer - INFO - **** Starting reclaimer
memory usage = 46,280,704 pf_rate = 0.2 =>                  squeeze percent = 1%
   squeeze to 45,817,896 -- ok
[INFO] (main:43) : pid       = 18834
[INFO] (main:44) : memory    = 8 GiB = 2097152 pages
[INFO] (main:45) : hot timer = 60 sec
[INFO] (main:46) : loops     = 10000
[INFO] (main:60) : Done with setup in 2 seconds.
memory usage = 8,645,734,400 pf_rate = 0.0 =>                  squeeze percent = 2%
   squeeze to 8,472,819,712 -- ok
memory usage = 8,463,917,056 pf_rate = 16.2 =>                  squeeze percent = 3%
   squeeze to 8,209,999,544 -- ok
memory usage = 8,208,674,816 pf_rate = 0.0 =>                  squeeze percent = 4%
   squeeze to 7,880,327,823 -- ok
memory usage = 7,880,237,056 pf_rate = 0.0 =>                  squeeze percent = 5%
   squeeze to 7,486,225,203 -- ok
memory usage = 7,486,009,344 pf_rate = 0.0 =>                  squeeze percent = 6%
   squeeze to 7,036,848,783 -- ok
memory usage = 7,036,510,208 pf_rate = 0.0 =>                  squeeze percent = 7%
   squeeze to 6,543,954,493 -- ok
memory usage = 6,543,728,640 pf_rate = 0.0 =>                  squeeze percent = 8%
   squeeze to 6,020,230,348 -- ok
memory usage = 6,410,338,304 pf_rate = 43918.6 =>                  squeeze percent = 0%
memory usage = 6,409,936,896 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 6,345,837,527 -- ok
memory usage = 6,409,601,024 pf_rate = 5169.2 =>                  squeeze percent = 2%
   squeeze to 6,281,409,003 -- ok
memory usage = 6,409,342,976 pf_rate = 11181.2 =>                  squeeze percent = 0%
memory usage = 6,409,342,976 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 6,345,249,546 -- ok
[INFO] (sigalrm_handler:25) : hot pages = 75%
memory usage = 7,516,831,744 pf_rate = 110002.8 =>                  squeeze percent = 0%
memory usage = 7,516,831,744 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 7,441,663,426 -- ok
memory usage = 7,516,459,008 pf_rate = 6201.4 =>                  squeeze percent = 2%
   squeeze to 7,366,129,827 -- ok
memory usage = 7,516,676,096 pf_rate = 16208.0 =>                  squeeze percent = 0%
memory usage = 7,516,622,848 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 7,441,456,619 -- ok
memory usage = 7,516,762,112 pf_rate = 6273.8 =>                  squeeze percent = 2%
   squeeze to 7,366,426,869 -- ok
memory usage = 7,516,549,120 pf_rate = 15865.8 =>                  squeeze percent = 0%
memory usage = 7,516,549,120 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 7,441,383,628 -- ok
memory usage = 7,516,581,888 pf_rate = 6191.6 =>                  squeeze percent = 2%
   squeeze to 7,366,250,250 -- ok
memory usage = 7,516,581,888 pf_rate = 15659.6 =>                  squeeze percent = 0%
memory usage = 7,516,581,888 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 7,441,416,069 -- ok
memory usage = 7,516,712,960 pf_rate = 6257.4 =>                  squeeze percent = 2%
   squeeze to 7,366,378,700 -- ok
[INFO] (sigalrm_handler:25) : hot pages = 50%
memory usage = 7,516,700,672 pf_rate = 15766.8 =>                  squeeze percent = 0%
memory usage = 7,516,700,672 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 7,441,533,665 -- ok
memory usage = 7,441,297,408 pf_rate = 0.0 =>                  squeeze percent = 2%
   squeeze to 7,292,471,459 -- ok
memory usage = 7,291,830,272 pf_rate = 0.0 =>                  squeeze percent = 3%
   squeeze to 7,073,075,363 -- ok
memory usage = 7,138,152,448 pf_rate = 7081.8 =>                  squeeze percent = 4%
   squeeze to 6,852,626,350 -- ok
memory usage = 6,911,389,696 pf_rate = 4600.8 =>                  squeeze percent = 5%
   squeeze to 6,565,820,211 -- ok
memory usage = 6,565,621,760 pf_rate = 0.0 =>                  squeeze percent = 6%
   squeeze to 6,171,684,454 -- ok
memory usage = 6,409,621,504 pf_rate = 21559.4 =>                  squeeze percent = 0%
memory usage = 6,409,515,008 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 6,345,419,857 -- ok
memory usage = 6,409,342,976 pf_rate = 5136.4 =>                  squeeze percent = 2%
   squeeze to 6,281,156,116 -- ok
memory usage = 6,409,166,848 pf_rate = 11203.6 =>                  squeeze percent = 0%
memory usage = 6,409,166,848 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 6,345,075,179 -- ok
[INFO] (sigalrm_handler:25) : hot pages = 75%
memory usage = 7,516,372,992 pf_rate = 109975.2 =>                  squeeze percent = 0%
memory usage = 7,516,372,992 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 7,441,209,262 -- ok
memory usage = 7,516,700,672 pf_rate = 6243.2 =>                  squeeze percent = 2%
   squeeze to 7,366,366,658 -- ok
memory usage = 7,516,553,216 pf_rate = 13308.0 =>                  squeeze percent = 0%
memory usage = 7,516,323,840 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 7,441,160,601 -- ok
memory usage = 7,516,733,440 pf_rate = 6277.2 =>                  squeeze percent = 2%
   squeeze to 7,366,398,771 -- ok
memory usage = 7,516,246,016 pf_rate = 14325.8 =>                  squeeze percent = 0%
memory usage = 7,516,241,920 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 7,441,079,500 -- ok
memory usage = 7,516,504,064 pf_rate = 6300.6 =>                  squeeze percent = 2%
   squeeze to 7,366,173,982 -- ok
memory usage = 7,516,651,520 pf_rate = 13345.0 =>                  squeeze percent = 0%
memory usage = 7,516,651,520 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 7,441,485,004 -- ok
memory usage = 7,516,610,560 pf_rate = 6166.6 =>                  squeeze percent = 2%
   squeeze to 7,366,278,348 -- ok
[INFO] (sigalrm_handler:25) : hot pages = 50%
memory usage = 7,516,684,288 pf_rate = 14280.6 =>                  squeeze percent = 0%
memory usage = 7,516,479,488 pf_rate = 0.0 =>                  squeeze percent = 1%
   squeeze to 7,441,314,693 -- ok
[INFO] (main:77) : Done with test in 251 seconds.
2024-04-01 22:16:27,252 - memoryusageanalyzer - INFO - **** Job finished
2024-04-01 22:16:27,252 - memoryusageanalyzer - INFO - **** Stopping stats
memory usage = 29,151,232 pf_rate = 50.2 =>                  squeeze percent = 2%
   squeeze to 28,568,207 -- ok
**** Closing profile.6/dynamic/stats.csv.gz
2024-04-01 22:16:28,527 - memoryusageanalyzer - INFO - **** Stopping squeezer
Generating plots profile.6/dynamic/memoryusageanalyzer-plots.html
**** Squeezer exiting
profile.6/dynamic
Loading stats from profile.6/dynamic/stats.csv.gz
Loading stats from profile.6/dynamic/stats.csv.gz
*** Totals without page cache ***
Maximum active+swap memory           = 8.044 GiB
Max active memory                 = 8.0 GiB
Max swap memory                = 4.3 GiB
Max page cache                 = 0.014 GiB
Swap memory                    = 53.1%
Max inactive anon              = 8.005 GiB
Maximum zpool memory           = 4.187023 GiB
Maximum zram memory            = 0.000011 GiB
incompressible data ratio(zram)= 0.0%
full total memory pressure            = 5578899 us
Average swap memory comp ratio = 1.00
Potential maximum compression savings in percent =                  0.0%
Potential median compression savings in percent =                  0.1%
Potential compression savings in bytes =                  0.000 GiB
Average swap memory comp ratio = 1.00                  (including same filled pages)
Major PFs/sec (median, avg, max) = 6254.82 11343.99              107242.28
Total PFs/sec (median, avg, max) = 7407.01 19192.46          392421.31
Total PFs (Major+Minor) = 4800634
Major PFs = 2837486
sampling period = 5.002625856399536
```
#### Visualizations
![Memoryusage](ref_results/Dynamicmemoryusage.png "MemoryUsage")
![Memorypressure](ref_results/Dynamicmemorypressure.png "Memorypressure")
![Pagefaultrate](ref_results/DynamicpageFaultrate.png "Pagefaultrate")

A memory usage report is generated after the profiling runs are complete.
The default results path is profile* and we can also override the default path using the -o option.

###  Example Workload with static squeezer
This is an example where static  memory-limit is applied to workload through cgroup. The fixed memory limit on Cgroup can be a percentage of the maximum baseline memory usage.

Please refer to the static squeezer config file in  memory-usage-analyzer/src/reclaimer/squeezerstaticconfig.json. In this example, there are multiple runs - baseline runs followed by memory-limit runs with memory-limit set as 2%, 4%, 8% and 16% of the maximum baseline memory usage.

With static squeezer
```shell
cd tests/example
config.py
zswapcompconfig.py -c lzo-rle
memory-usage-analyzer.py -r ../../src/reclaimer/squeezerstaticconfig.json -- ./workload 8 60 10000

# Sample results for baseline
2024-04-01 21:44:48,272 - memoryusageanalyzer - INFO - args = Namespace(cgname='memoryusageanalyzer', cgpath='/sys/fs/cgroup', cmd='./workload', docker=None, options=['8', '60', '10000'], output='profile', outputforce=None, reclaimerconfig='../../src/reclaimer/squeezerstaticconfig.json', sampleperiod=5, verbose=False)
2024-04-01 21:44:48,273 - memoryusageanalyzer - INFO - **** Storing profiling results in profile.5
2024-04-01 21:44:48,328 - memoryusageanalyzer - INFO - cgroup v2 enabled and memory controller detected
2024-04-01 21:44:48,332 - memoryusageanalyzer - INFO - **** Starting job in cgroup
2024-04-01 21:44:48,334 - memoryusageanalyzer - INFO - **** Starting stats
2024-04-01 21:44:48,337 - memoryusageanalyzer - INFO - **** Starting reclaimer
[INFO] (main:43) : pid       = 9787
[INFO] (main:44) : memory    = 8 GiB = 2097152 pages
[INFO] (main:45) : hot timer = 60 sec
[INFO] (main:46) : loops     = 10000
[INFO] (main:60) : Done with setup in 2 seconds.
[INFO] (sigalrm_handler:25) : hot pages = 75%
[INFO] (sigalrm_handler:25) : hot pages = 50%
[INFO] (sigalrm_handler:25) : hot pages = 75%
[INFO] (main:77) : Done with test in 225 seconds.
2024-04-01 21:48:36,162 - memoryusageanalyzer - INFO - **** Job finished
2024-04-01 21:48:36,162 - memoryusageanalyzer - INFO - **** Stopping stats
**** Closing profile.5/staticsweep/stats.csv.gz
2024-04-01 21:48:38,648 - memoryusageanalyzer - INFO - **** Stopping squeezer
Generating plots profile.5/staticsweep/memoryusageanalyzer-plots.html
2024-04-01 21:58:57,581 - memoryusageanalyzer - INFO - cgroup v2 enabled and memory controller detected
2024-04-01 21:58:57,585 - memoryusageanalyzer - INFO - **** Starting job in cgroup
2024-04-01 21:58:57,587 - memoryusageanalyzer - INFO - **** Starting stats
2024-04-01 21:58:57,589 - memoryusageanalyzer - INFO - **** Starting reclaimer
[INFO] (main:43) : pid       = 14857
[INFO] (main:44) : memory    = 8 GiB = 2097152 pages
[INFO] (main:45) : hot timer = 60 sec
[INFO] (main:46) : loops     = 10000
[INFO] (main:60) : Done with setup in 5 seconds.
[INFO] (sigalrm_handler:25) : hot pages = 75%
[INFO] (sigalrm_handler:25) : hot pages = 50%
[INFO] (sigalrm_handler:25) : hot pages = 75%
[INFO] (main:77) : Done with test in 238 seconds.
2024-04-01 22:03:00,810 - memoryusageanalyzer - INFO - **** Job finished
2024-04-01 22:03:00,811 - memoryusageanalyzer - INFO - **** Stopping stats
**** Closing profile.5/staticsweep/memory_8/stats.csv.gz
2024-04-01 22:03:02,872 - memoryusageanalyzer - INFO - **** Stopping squeezer
Generating plots profile.5/staticsweep/memory_8/memoryusageanalyzer-plots.html
**** Squeezer exiting
profile.5/staticsweep
Loading stats from profile.5/staticsweep/stats.csv.gz
Loading stats from profile.5/staticsweep/stats.csv.gz
*** Totals without page cache ***
Maximum active+swap memory           = 8.038 GiB
Max active memory                 = 8.0 GiB
Max swap memory                = 0.0 GiB
Max page cache                 = 0.014 GiB
Swap memory                    = 0.0%
Max inactive anon              = 8.005 GiB
Maximum zpool memory           = 0.000000 GiB
Maximum zram memory            = 0.000011 GiB
incompressible data ratio(zram)= 0.0%
full total memory pressure            = 0 us
Major PFs/sec (median, avg, max) = 0.00 0.00              0.00
Total PFs/sec (median, avg, max) = 0.00 8636.03          388621.24
Total PFs (Major+Minor) = 1944351
Major PFs = 0
sampling period = 5.003200546900431
**** Using max_limit from baseline run: 8630243328.0 =                      8.038 GiB
**** Initial memory limit = 7939823861
**** Squeezer exiting

# Sample output from 8% memory reduction as a reference. Other memory limit runs will have similar outputs

profile.5/staticsweep/memory_8
Loading stats from profile.5/staticsweep/memory_8/stats.csv.gz
Loading stats from profile.5/staticsweep/memory_8/stats.csv.gz
*** Totals without page cache ***
Maximum active+swap memory           = 7.395 GiB
Max active memory                 = 6.1 GiB
Max swap memory                = 1.3 GiB
Max page cache                 = 0.014 GiB
Swap memory                    = 17.3%
Max inactive anon              = 6.751 GiB
Maximum zpool memory           = 1.277714 GiB
Maximum zram memory            = 0.000011 GiB
incompressible data ratio(zram)= 0.0%
full total memory pressure            = 1204429 us
Average swap memory comp ratio = 1.00
Potential maximum compression savings in percent =                  0.1%
Potential median compression savings in percent =                  0.1%
Potential compression savings in bytes =                  0.005 GiB
Average swap memory comp ratio = 1.00                  (including same filled pages)
Major PFs/sec (median, avg, max) = 0.00 6550.13              130470.80
Total PFs/sec (median, avg, max) = 0.00 14762.16          415849.90
Total PFs (Major+Minor) = 3544846
Major PFs = 1572886
sampling period = 5.002720882495244
```

#### Visualizations
There are multiple directories that are created for each memory-limit runs. Here is one example from 8% memory-limit run.

![Memoryusage](ref_results/Staticmemoryusage.png "MemoryUsage")
![Memorypressure](ref_results/Staticmemorypressure.png "Memorypressure")
![Pagefaultrate](ref_results/StaticpageFaultrate.png "Pagefaultrate")

A memory usage report is generated after the profiling runs are complete.
The default results path is profile* and we can also override the default path using the -o option.

### To run a workload in a docker container:
1. Give the workload's docker container a name on the docker command line (`--name NAME`)
2. For convenience, have docker automatically remove the container when it exits, so the container name can be reused (`--rm`)
3. Add the `--docker NAME` to the `memory-usage-analyzer.py` command.

If cgroup v2 is enabled, do specify the cgroup parent by `--cgroup-parent <memoryusageanalyzer.slice>`, otherwise stats won't be collected correctly.

```shell
docker info
# Sample output
Cgroup Version: 2

```
Example:
```shell
sudo docker run --rm --name memoryusageanalyzer -v $PWD:/memoryusageanalyzer ubuntu /memoryusageanalyzer/example/workload 4 30 1000
memory-usage-analyzer.py --docker memoryusageanalyzer ./docker.sh

# Sample results, actual results may vary
2024-01-17 00:03:09,703 - memoryusageanalyzer - INFO - args = Namespace(verbose=False, output='profile', output_force=None, sample_period=5, compaction_period=0, docker='memoryusageanalyzer', skip_stats=0, cgpath='/sys/fs/cgroup', cgname='memoryusageanalyzer', reclaimer_config=None, cmd='./docker.sh', options=[])
2024-01-17 00:03:09,703 - memoryusageanalyzer - INFO - **** Storing profiling results in profile
2024-01-17 00:03:09,708 - memoryusageanalyzer - INFO - cgroup v2 enabled and memory controller detected
2024-01-17 00:03:09,713 - memoryusageanalyzer - INFO - **** Starting job in docker
2024-01-17 00:03:09,715 - memoryusageanalyzer - INFO - **** Waiting for container "memoryusageanalyzer"
[INFO] (main:56) : pid       = 1
[INFO] (main:57) : memory    = 4 GiB = 1048576 pages
[INFO] (main:58) : hot timer = 30 sec
[INFO] (main:59) : loops     = 1000
[INFO] (main:73) : Done with setup in 0 seconds.
2024-01-17 00:03:10,879 - memoryusageanalyzer - INFO - **** Found container "memoryusageanalyzer" = 659881870e44e57696553cd1c19ac0710c43bfa7ed94bb917c6db328b468b72f
2024-01-17 00:03:10,895 - memoryusageanalyzer - INFO - **** Starting stats
[INFO] (main:90) : Done with test in 10 seconds.
2024-01-17 00:06:41,304 - memoryusageanalyzer - INFO - **** Job finished
2024-01-17 00:06:41,304 - memoryusageanalyzer - INFO - **** Stopping stats
**** Closing profile/baseline/stats.csv.gz
```
