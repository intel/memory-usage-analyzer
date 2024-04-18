#  Intel® Memory Usage Analyzer

Intel® Memory Usage Analyzer can visualize the memory usage patterns of the workloads and estimate the working set size[^1]. It provides a plug-in interface to different memory-reclaimers to analyze the workload sensitivity with memory-tiering solutions and changes in memory usage patterns under memory pressure across time.


## Background
DRAM being one of the significant cost contributor in the cloud infrastructure, cloud service providers are deploying different memory-tiering solutions[^2] [^3] [^4]. Given the  workload and infrastructure diversity, the challenge is to get a reasonable memory savings without a significant impact on the workload performance. Every workload may not benefit from memory-tiering. The workloads with large number of memory pages that are less frequently used (cold memory segments) and the high compressibility on these memory pages  are good candidates for memory-tiering to offload memory to a compressed tier or slower memory-tiers like SSD, NVMe etc.

The Intel® Memory Usage Analyzer runs workloads under a cgroup[^2] to collect Cgroup stats across the timeline to provide a visualization these stats and summarizes them.

## Features

Intel® Memory Usage Analyzer can 
 * run workloads under two scenarios
     * **Baseline** - no memory pressure - useful for analyzing the memory usage pattern
     * **Reclaimer** - workloads run with memory-pressure
        - static - Apply a fixed memory limit on Cgroup, which can be a percentage of the maximum baseline memory usage
        - dynamic - dynamically adjusts the memory limit on Cgroup using page fault rate as the control metric
 * plug-in interface to use other memory-reclaimers like Senpai[^3]
 * visualization of the collected stats (memory usage, memory pressure, page fault rate etc.)
 
## Requirements

* Linux system with sudo access for configuration scripts
* Linux kernel version >= v4.18
  * zswap support 
  * swap accounting enabled - add kernel parameter  `swapaccount=1` 
  * cgroup v2 - add kernel parameter "systemd.unified_cgroup_hierarchy=1"
  * enable pressure stall information - add kernel parameter "psi=1"
* Linux perf tool
* Python >= 3.7

## Install

Clone the repo and install in a python environment

Creating python virtual environment

```bash
python -m venv virtualenv
source virtualenv/bin/activate
```
Clone and install

```bash
git clone https://github.com/intel/memory-usage-analyzer.git
pip install -e memory-usage-analyzer
```

## Documentation

* [Example workload walk-through](tests/example/README.md)

## License
* All code is licensed under BSD 3-Clause

## Reference

[^1]: ELC: How much memory are applications really using?, LWN.net, April 18, 2007, by Jonathan Corbet.
[^2]: Control Groups, https://docs.kernel.org/admin-guide/cgroup-v1/cgroups.html, 2004, by  Paul Menage 
[^3]: Johannes Weiner, Niket Agarwal, Dan Schatzberg, Leon Yang, Hao Wang,Blaise Sanouillet, Bikash Sharma, Tejun Heo, Mayank Jain, Chunqiang Tang,
and Dimitrios Skarlatos. 2022. TMO: transparent memory offloading in datacenters. In Proceedings of the 27th ACM International Conference on Architectural Support for Programming Languages and Operating Systems (ASPLOS). https://doi.org/10.1145/3503222.3507731
[^4]: Andres Lagar-Cavilla, Junwhan Ahn, Suleiman Souhlal, Neha Agarwal, Radoslaw Burny, Shakeel Butt, Jichuan Chang, Ashwin Chaugule, Nan Deng, Junaid Shahid, Greg Thelen, Kamil Adam Yurtsever, Yu Zhao, and Parthasarathy Ranganathan. 2019. Software-Defined Far Memory in Warehouse-Scale Computers. In Proceedings of the 24th International Conference on Architectural Support for Programming Languages and Operating Systems (ASPLOS). https://doi.org/10.1145/3297858.3304053
[^5]: SeongJae Park. 2020. Introduce Data Access MONitor (DAMON). https://lwn.net/Articles/834721/.

