# Run a workload in a docker container:
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
memory_usage_analyzer.py --docker memoryusageanalyzer ./docker.sh

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
