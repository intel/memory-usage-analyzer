<!-- SPDX-License-Identifier: BSD-3-Clause -->
<!-- Copyright (c) 2023, Intel Corporation -->

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
* Supported Linux distributions: CentOS/RHEL and Ubuntu/Debian. The workload
  setup and benchmark scripts under [tests/](tests/) auto-detect the available
  package manager (`dnf`/`yum` on CentOS/RHEL, `apt-get` on Ubuntu/Debian), so
  the same commands work on both.
* Linux kernel version >= v6.8
  * zswap support 
  * swap accounting enabled - add kernel parameter  `swapaccount=1` 
  * cgroup v2 - add kernel parameter "systemd.unified_cgroup_hierarchy=1"
  * enable pressure stall information - add kernel parameter "psi=1"
* Linux perf tool
* Python = 3.11

## Install

Clone the repository and run the dependency installer. It installs the OS
packages, accel-config, the pinned Python, and this repository (editable
install inside an isolated virtualenv), then puts the helper scripts on PATH.

```bash
git clone https://github.com/intel/memory-usage-analyzer.git
cd memory-usage-analyzer
sudo ./tests/scripts/install_dependencies.sh
```

## Documentation

* [Example workload walk-through](tests/example/README.md)

## Debugging

The scripts in [tests/scripts/](tests/scripts/) below are **not** part of the
normal install or benchmark flow. The standard setup and workload scripts
already configure IAA and the Python environment automatically. These helpers
are kept only for manual troubleshooting when a run misbehaves.

### Verify IAA setup (`verify_iaa_setup.sh`)

Confirms that the Intel® In-Memory Analytics Accelerator (IAA) is ready to use. It checks the kernel version (>= 6.8), the IAA PCI devices, the `iaa_crypto` module, the per-device state, and the registered `deflate-iaa` crypto algorithms. If the crypto module is not loaded, it first tries `enable_iaa.sh`. Must be run as root.

```bash
# Run the checks
sudo ./tests/scripts/verify_iaa_setup.sh

# Verbose output: list devices and modules
sudo ./tests/scripts/verify_iaa_setup.sh -v
```

It prints a PASS/WARN/FAIL summary and exits non-zero if any check fails. Run it to confirm IAA is usable before using the `deflate-iaa` compressor profiles.

### Manual dependency install fallback

If `./tests/scripts/install_dependencies.sh` fails to install the Python dependencies and you cannot resolve the issue, create a virtualenv with Python 3.11 or newer and install this repo in editable mode instead:

```bash
python3.11 -m venv penv
source penv/bin/activate
pip install -e memory-usage-analyzer
```

## License
* All code is licensed under BSD 3-Clause

## Reference

[^1]: ELC: How much memory are applications really using?, LWN.net, April 18, 2007, by Jonathan Corbet.
[^2]: Control Groups, https://docs.kernel.org/admin-guide/cgroup-v1/cgroups.html, 2004, by  Paul Menage 
[^3]: Johannes Weiner, Niket Agarwal, Dan Schatzberg, Leon Yang, Hao Wang,Blaise Sanouillet, Bikash Sharma, Tejun Heo, Mayank Jain, Chunqiang Tang,
and Dimitrios Skarlatos. 2022. TMO: transparent memory offloading in datacenters. In Proceedings of the 27th ACM International Conference on Architectural Support for Programming Languages and Operating Systems (ASPLOS). https://doi.org/10.1145/3503222.3507731
[^4]: Andres Lagar-Cavilla, Junwhan Ahn, Suleiman Souhlal, Neha Agarwal, Radoslaw Burny, Shakeel Butt, Jichuan Chang, Ashwin Chaugule, Nan Deng, Junaid Shahid, Greg Thelen, Kamil Adam Yurtsever, Yu Zhao, and Parthasarathy Ranganathan. 2019. Software-Defined Far Memory in Warehouse-Scale Computers. In Proceedings of the 24th International Conference on Architectural Support for Programming Languages and Operating Systems (ASPLOS). https://doi.org/10.1145/3297858.3304053
[^5]: SeongJae Park. 2020. Introduce Data Access MONitor (DAMON). https://lwn.net/Articles/834721/.

