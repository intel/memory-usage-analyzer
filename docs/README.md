## System Configuration

Run the command below to configure the system. This config script help to configure
zram, zswap, memory and frequency related kernel parameters. The [config.py](../tests/config_script/config.py) file is located in [tests/config_script](../tests/config_script)

```shell
$ config.py
[OK] Linux kernel version >= 5.0
[OK] cgroup enabled
[OK] swap accounting enabled
[OK] zswap enabled
[OK] perf tool available (/usr/bin/perf)


$ config.py -h -a
usage: config.py [-h] [-a] [-c] [-m MAX_POOL] [-v] [-f FREQ] [-D] [-R ZRAM_COMPRESSOR] [-p CGPATH] [-n CGNAME] [-u CGUSER]
                 [-s] [-z RATIO]

optional arguments:
  -h, --help            show this help message and exit
  -a, --all             show help message for all args and exit
  -c, --check           check requirements and exit (default: False)
  -m MAX_POOL, --max-pool MAX_POOL
                        max size of compressed memory pool (% total memory) (default: 35)
  -v, --verbose         verbose output (default: False)
  -f FREQ, --freq FREQ  CPU frequency for cpupower command (MHz) (default: None)
  -D, --disable-zswap   disable zswap (default: False)
  -R ZRAM_COMPRESSOR, --zram-compressor ZRAM_COMPRESSOR
                        zram compression algorithm (default: lzo)
  -p CGPATH, --cgpath CGPATH
                        path to cgroup mount point (default: /sys/fs/cgroup)
  -n CGNAME, --cgname CGNAME
                        name of cgroup to be created (default: memoryusageanalyzer)
  -u CGUSER, --cguser CGUSER
                        username of cgroup owner (default: root)
  -s, --swap            use existing swap device instead of zram (default: False)
  -z RATIO, --ratio RATIO
                        compression ratio used to size zram.If 0, zram is disabled. (default: 1.0)

$ config.py -v
system info
Linux 6.7.0-rc1-upstream #2 SMP PREEMPT_DYNAMIC Wed Dec 13 23:51:06 PST 2023 x86_64 x86_64 x86_64 GNU/Linux
BOOT_IMAGE=(hd0,gpt2)/vmlinuz-6.7.0-rc1-upstream root=UUID=bf84de04-aabd-4861-9eeb-12597e8fc54d ro earlyprintk=ttyS0,115200 console=ttyS0,115200 intel_iommu=igfx_off kvm-intel.nested=1 no_timer_check noreplace-smp rcupdate.rcu_expedited=1 rootfstype=ext4,btrfs,xfs,f2fs tsc=reliable intel_iommu=off cryptomgr.notests quiet selinux=0 _no_cet_shstk _no_cet_ibt psi=1 swapaccount=1 systemd.unified_cgroup_hierarchy=1
NAME="CentOS Linux"
PRETTY_NAME="CentOS Linux 8"
CPE_NAME="cpe:/o:centos:centos:8"
Architecture:        x86_64
CPU op-mode(s):      32-bit, 64-bit
Byte Order:          Little Endian
CPU(s):              224
On-line CPU(s) list: 0-223
Thread(s) per core:  2
Core(s) per socket:  56
Socket(s):           2
NUMA node(s):        2
Vendor ID:           GenuineIntel
BIOS Vendor ID:      Intel(R) Corporation
CPU family:          6
Model:               143
Model name:          Genuine Intel(R) CPU 0000%@
BIOS Model name:     Genuine Intel(R) CPU 0000%@
Stepping:            5
CPU MHz:             3400.000
CPU max MHz:         3400.0000
CPU min MHz:         800.0000
BogoMIPS:            3400.00
Virtualization:      VT-x
L1d cache:           48K
L1i cache:           32K
L2 cache:            2048K
L3 cache:            107520K
NUMA node0 CPU(s):   0-55,112-167
NUMA node1 CPU(s):   56-111,168-223
Flags:               fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts acpi mmx fxsr sse sse2 ss ht tm pbe syscall nx pdpe1gb rdtscp lm constant_tsc art arch_perfmon pebs bts rep_good nopl xtopology nonstop_tsc cpuid aperfmperf tsc_known_freq pni pclmulqdq dtes64 monitor ds_cpl vmx smx est tm2 ssse3 sdbg fma cx16 xtpr pdcm pcid dca sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand lahf_lm abm 3dnowprefetch cpuid_fault epb cat_l3 cat_l2 cdp_l3 intel_ppin cdp_l2 ssbd mba ibrs ibpb stibp ibrs_enhanced tpr_shadow flexpriority ept vpid ept_ad fsgsbase tsc_adjust bmi1 avx2 smep bmi2 erms invpcid cqm rdt_a avx512f avx512dq rdseed adx smap avx512ifma clflushopt clwb intel_pt avx512cd sha_ni avx512bw avx512vl xsaveopt xsavec xgetbv1 xsaves cqm_llc cqm_occup_llc cqm_mbm_total cqm_mbm_local split_lock_detect avx_vnni avx512_bf16 wbnoinvd dtherm ida arat pln pts hwp hwp_act_window hwp_epp hwp_pkg_req hfi vnmi avx512vbmi umip pku ospke waitpkg avx512_vbmi2 gfni vaes vpclmulqdq avx512_vnni avx512_bitalg tme avx512_vpopcntdq la57 rdpid bus_lock_detect cldemote movdiri movdir64b enqcmd fsrm md_clear serialize tsxldtrk pconfig arch_lbr ibt amx_bf16 avx512_fp16 amx_tile amx_int8 flush_l1d arch_capabilities
analyzing CPU 0:
  driver: intel_pstate
  CPUs which run at the same hardware frequency: 0
  CPUs which need to have their frequency coordinated by software: 0
  maximum transition latency:  Cannot determine or is not supported.
  hardware limits: 800 MHz - 3.40 GHz
  available cpufreq governors: performance powersave
  current policy: frequency should be within 800 MHz and 3.40 GHz.
                  The governor "performance" may decide which speed to use
                  within this range.
  current CPU frequency: Unable to call hardware
  current CPU frequency: 3.40 GHz (asserted by call to kernel)
  boost state support:
    Supported: yes
    Active: yes

cgroup
/sys/fs/cgroup/memoryusageanalyzer/cgroup.events:populated 0
/sys/fs/cgroup/memoryusageanalyzer/cgroup.events:frozen 0
/sys/fs/cgroup/memoryusageanalyzer/memory.events:low 0
/sys/fs/cgroup/memoryusageanalyzer/memory.events:high 0
/sys/fs/cgroup/memoryusageanalyzer/memory.events:max 0
/sys/fs/cgroup/memoryusageanalyzer/memory.events:oom 0
/sys/fs/cgroup/memoryusageanalyzer/memory.events:oom_kill 0
/sys/fs/cgroup/memoryusageanalyzer/memory.events:oom_group_kill 0
/sys/fs/cgroup/memoryusageanalyzer/io.pressure:some avg10=0.00 avg60=0.00 avg300=0.00 total=0
/sys/fs/cgroup/memoryusageanalyzer/io.pressure:full avg10=0.00 avg60=0.00 avg300=0.00 total=0
/sys/fs/cgroup/memoryusageanalyzer/memory.events.local:low 0
/sys/fs/cgroup/memoryusageanalyzer/memory.events.local:high 0
/sys/fs/cgroup/memoryusageanalyzer/memory.events.local:max 0
/sys/fs/cgroup/memoryusageanalyzer/memory.events.local:oom 0
/sys/fs/cgroup/memoryusageanalyzer/memory.events.local:oom_kill 0
/sys/fs/cgroup/memoryusageanalyzer/memory.events.local:oom_group_kill 0
/sys/fs/cgroup/memoryusageanalyzer/memory.swap.peak:0
/sys/fs/cgroup/memoryusageanalyzer/memory.swap.current:0
/sys/fs/cgroup/memoryusageanalyzer/memory.swap.max:max
/sys/fs/cgroup/memoryusageanalyzer/memory.zswap.current:0
/sys/fs/cgroup/memoryusageanalyzer/cpu.weight:100
/sys/fs/cgroup/memoryusageanalyzer/memory.swap.events:high 0
/sys/fs/cgroup/memoryusageanalyzer/memory.swap.events:max 0
/sys/fs/cgroup/memoryusageanalyzer/memory.swap.events:fail 0
/sys/fs/cgroup/memoryusageanalyzer/cgroup.max.descendants:max
/sys/fs/cgroup/memoryusageanalyzer/cpu.stat:usage_usec 0
/sys/fs/cgroup/memoryusageanalyzer/cpu.stat:user_usec 0
/sys/fs/cgroup/memoryusageanalyzer/cpu.stat:system_usec 0
/sys/fs/cgroup/memoryusageanalyzer/cpu.stat:nr_periods 0
/sys/fs/cgroup/memoryusageanalyzer/cpu.stat:nr_throttled 0
/sys/fs/cgroup/memoryusageanalyzer/cpu.stat:throttled_usec 0
/sys/fs/cgroup/memoryusageanalyzer/cpu.stat:nr_bursts 0
/sys/fs/cgroup/memoryusageanalyzer/cpu.stat:burst_usec 0
/sys/fs/cgroup/memoryusageanalyzer/cpu.weight.nice:0
/sys/fs/cgroup/memoryusageanalyzer/memory.pressure:some avg10=0.00 avg60=0.00 avg300=0.00 total=0
/sys/fs/cgroup/memoryusageanalyzer/memory.pressure:full avg10=0.00 avg60=0.00 avg300=0.00 total=0
/sys/fs/cgroup/memoryusageanalyzer/memory.current:0
/sys/fs/cgroup/memoryusageanalyzer/pids.current:0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:anon 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:file 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:kernel 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:kernel_stack 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pagetables 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:sec_pagetables 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:percpu 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:sock 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:vmalloc 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:shmem 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:zswap 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:zswapped 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:file_mapped 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:file_dirty 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:file_writeback 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:swapcached 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:anon_thp 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:file_thp 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:shmem_thp 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:inactive_anon 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:active_anon 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:inactive_file 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:active_file 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:unevictable 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:slab_reclaimable 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:slab_unreclaimable 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:slab 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:workingset_refault_anon 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:workingset_refault_file 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:workingset_activate_anon 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:workingset_activate_file 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:workingset_restore_anon 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:workingset_restore_file 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:workingset_nodereclaim 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgscan 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgsteal 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgscan_kswapd 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgscan_direct 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgscan_khugepaged 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgsteal_kswapd 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgsteal_direct 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgsteal_khugepaged 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgfault 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgmajfault 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgrefill 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgactivate 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pgdeactivate 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pglazyfree 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:pglazyfreed 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:zswpin 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:zswpout 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:thp_fault_alloc 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:thp_collapse_alloc 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:thp_swpout 0
/sys/fs/cgroup/memoryusageanalyzer/memory.stat:thp_swpout_fallback 0
/sys/fs/cgroup/memoryusageanalyzer/pids.events:max 0
/sys/fs/cgroup/memoryusageanalyzer/memory.low:0
/sys/fs/cgroup/memoryusageanalyzer/cpu.pressure:some avg10=0.00 avg60=0.00 avg300=0.00 total=0
/sys/fs/cgroup/memoryusageanalyzer/cpu.pressure:full avg10=0.00 avg60=0.00 avg300=0.00 total=0
/sys/fs/cgroup/memoryusageanalyzer/cgroup.type:domain
/sys/fs/cgroup/memoryusageanalyzer/io.bfq.weight:default 100
/sys/fs/cgroup/memoryusageanalyzer/cgroup.stat:nr_descendants 0
/sys/fs/cgroup/memoryusageanalyzer/cgroup.stat:nr_dying_descendants 0
/sys/fs/cgroup/memoryusageanalyzer/memory.swap.high:max
/sys/fs/cgroup/memoryusageanalyzer/cpu.idle:0
/sys/fs/cgroup/memoryusageanalyzer/cpu.stat.local:throttled_usec 0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:anon N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:file N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:kernel_stack N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:pagetables N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:sec_pagetables N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:shmem N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:file_mapped N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:file_dirty N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:file_writeback N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:swapcached N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:anon_thp N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:file_thp N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:shmem_thp N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:inactive_anon N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:active_anon N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:inactive_file N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:active_file N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:unevictable N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:slab_reclaimable N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:slab_unreclaimable N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:workingset_refault_anon N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:workingset_refault_file N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:workingset_activate_anon N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:workingset_activate_file N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:workingset_restore_anon N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:workingset_restore_file N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.numa_stat:workingset_nodereclaim N0=0 N1=0
/sys/fs/cgroup/memoryusageanalyzer/memory.peak:0
/sys/fs/cgroup/memoryusageanalyzer/cpuset.cpus.partition:member
/sys/fs/cgroup/memoryusageanalyzer/cpuset.cpus.effective:0-223
/sys/fs/cgroup/memoryusageanalyzer/cgroup.freeze:0
/sys/fs/cgroup/memoryusageanalyzer/irq.pressure:full avg10=0.00 avg60=0.00 avg300=0.00 total=0
/sys/fs/cgroup/memoryusageanalyzer/memory.min:0
/sys/fs/cgroup/memoryusageanalyzer/cpu.max.burst:0
/sys/fs/cgroup/memoryusageanalyzer/cgroup.controllers:cpuset cpu io memory pids
/sys/fs/cgroup/memoryusageanalyzer/cpu.max:max 100000
/sys/fs/cgroup/memoryusageanalyzer/memory.oom.group:0
/sys/fs/cgroup/memoryusageanalyzer/memory.max:max
/sys/fs/cgroup/memoryusageanalyzer/memory.high:max
/sys/fs/cgroup/memoryusageanalyzer/pids.max:max
/sys/fs/cgroup/memoryusageanalyzer/memory.zswap.max:max
/sys/fs/cgroup/memoryusageanalyzer/cpuset.mems.effective:0-1
/sys/fs/cgroup/memoryusageanalyzer/pids.peak:0
/sys/fs/cgroup/memoryusageanalyzer/cgroup.max.depth:max
/sys/fs/cgroup/memoryusageanalyzer/cgroup.pressure:1

vm
/sys/kernel/mm/transparent_hugepage/enabled:always madvise [never]
/proc/sys/vm/admin_reserve_kbytes:8192
/proc/sys/vm/compaction_proactiveness:20
/proc/sys/vm/compact_unevictable_allowed:1
/proc/sys/vm/dirty_background_bytes:0
/proc/sys/vm/dirty_background_ratio:5
/proc/sys/vm/dirty_bytes:0
/proc/sys/vm/dirty_expire_centisecs:3000
/proc/sys/vm/dirty_ratio:50
/proc/sys/vm/dirtytime_expire_seconds:43200
/proc/sys/vm/dirty_writeback_centisecs:1500
/proc/sys/vm/extfrag_threshold:100
/proc/sys/vm/hugetlb_optimize_vmemmap:0
/proc/sys/vm/hugetlb_shm_group:0
/proc/sys/vm/laptop_mode:0
/proc/sys/vm/legacy_va_layout:0
/proc/sys/vm/lowmem_reserve_ratio:256   256     32      0       0
/proc/sys/vm/max_map_count:65530
/proc/sys/vm/memfd_noexec:0
/proc/sys/vm/memory_failure_early_kill:0
/proc/sys/vm/memory_failure_recovery:1
/proc/sys/vm/min_free_kbytes:91820
/proc/sys/vm/min_slab_ratio:5
/proc/sys/vm/min_unmapped_ratio:1
/proc/sys/vm/mmap_min_addr:65536
/proc/sys/vm/mmap_rnd_bits:28
/proc/sys/vm/mmap_rnd_compat_bits:8
/proc/sys/vm/nr_hugepages:0
/proc/sys/vm/nr_hugepages_mempolicy:0
/proc/sys/vm/nr_overcommit_hugepages:0
/proc/sys/vm/numa_stat:1
/proc/sys/vm/numa_zonelist_order:Node
/proc/sys/vm/oom_dump_tasks:1
/proc/sys/vm/oom_kill_allocating_task:0
/proc/sys/vm/overcommit_kbytes:0
/proc/sys/vm/overcommit_memory:1
/proc/sys/vm/overcommit_ratio:50
/proc/sys/vm/page-cluster:3
/proc/sys/vm/page_lock_unfairness:5
/proc/sys/vm/panic_on_oom:0
/proc/sys/vm/percpu_pagelist_high_fraction:0
/proc/sys/vm/stat_interval:1
/proc/sys/vm/swappiness:100
/proc/sys/vm/unprivileged_userfaultfd:0
/proc/sys/vm/user_reserve_kbytes:131072
/proc/sys/vm/vfs_cache_pressure:100
/proc/sys/vm/watermark_boost_factor:15000
/proc/sys/vm/watermark_scale_factor:10
/proc/sys/vm/zone_reclaim_mode:0

zram
/sys/block/zram0/disksize:189266722816
/sys/block/zram0/comp_algorithm:[lzo] lzo-rle lz4 zstd
orig_data_size compr_data_size mem_used_total mem_limit mem_used_max same_pages pages_compacted huge_pages
    4096       83    12288 189266722816    12288        0        0        0        0

zswap
/sys/module/zswap/parameters/same_filled_pages_enabled:Y
/sys/module/zswap/parameters/enabled:Y
/sys/module/zswap/parameters/max_pool_percent:35
/sys/module/zswap/parameters/compressor:lzo-rle
/sys/module/zswap/parameters/non_same_filled_pages_enabled:Y
/sys/module/zswap/parameters/zpool:zbud
/sys/module/zswap/parameters/exclusive_loads:N
/sys/module/zswap/parameters/accept_threshold_percent:90
/sys/kernel/debug/zswap/same_filled_pages:0
/sys/kernel/debug/zswap/stored_pages:0
/sys/kernel/debug/zswap/pool_total_size:0
/sys/kernel/debug/zswap/duplicate_entry:2
/sys/kernel/debug/zswap/written_back_pages:0
/sys/kernel/debug/zswap/reject_compress_poor:0
/sys/kernel/debug/zswap/reject_compress_fail:0
/sys/kernel/debug/zswap/reject_kmemcache_fail:0
/sys/kernel/debug/zswap/reject_alloc_fail:0
/sys/kernel/debug/zswap/reject_reclaim_fail:0
/sys/kernel/debug/zswap/pool_limit_hit:0

block devices
NAME            MAJ:MIN RM   SIZE RO TYPE MOUNTPOINT
sda               8:0    0 372.6G  0 disk
├─sda1            8:1    0   200M  0 part
├─sda2            8:2    0     1G  0 part
└─sda3            8:3    0 371.4G  0 part
  ├─centos-swap 253:0    0   7.8G  0 lvm
  ├─centos-home 253:1    0 313.7G  0 lvm  /home
  └─centos-root 253:2    0    50G  0 lvm
sdb               8:16   0 447.1G  0 disk
├─sdb1            8:17   0   553M  0 part /boot/efi
├─sdb2            8:18   0   4.7G  0 part /boot
└─sdb4            8:20   0   442G  0 part /
zram0           252:0    0 176.3G  0 disk [SWAP]
nvme0n1         259:0    0   1.8T  0 disk
└─nvme0n1p1     259:1    0   1.8T  0 part /mnt/nvme1
nvme1n1         259:2    0   1.8T  0 disk
└─nvme1n1p1     259:3    0   1.8T  0 part /mnt/nvme0

memory
              total        used        free      shared  buff/cache   available
Mem:          503Gi       8.5Gi       369Gi        54Mi       125Gi       491Gi
Swap:         176Gi          0B       176Gi
Total:        679Gi       8.5Gi       546Gi
[OK] Linux kernel version 6.7 >= 4.18
[OK] cgroup enabled
[OK] swap accounting enabled
[OK] zswap enabled
[OK] perf tool available (/usr/bin/perf)
sudo bash /mnt/nvme1/pg3/python/bin/config.sh lzo 189266720563 189266720563 zsmalloc 35 1 /sys/fs/cgroup memoryusageanalyzer root 100
```

Run the below command to configure the type of compression algo

```shell
$ zswapcompconfig.py -c lzo-rle
contents 0, /sys/module/zswap/parameters/enabled
contents lzo-rle, /sys/module/zswap/parameters/compressor
contents 1, /sys/module/zswap/parameters/enabled
Compressor = lzo-rle

$ zswapcompconfig.py -h
usage: zswapcompconfig.py [-h] [-r] [-c {lzo-rle,zstd,rle1a}] [-v]

config zswap compressor

optional arguments:
  -h, --help            show this help message and exit
  -r, --report          report config and stats only (default: False)
  -c {lzo-rle,zstd,rle1a}, --compressor {lzo-rle,zstd,rle1a}
                        compression engine (software) (default: lzo-rle)
  -v, --verbose         verbose output (default: False)

$ zswapcompconfig.py -v
DEBUG    2024-03-04 21:26:49,748 : args = Namespace(report=False, compressor='lzo-rle', verbose=True)
DEBUG    2024-03-04 21:26:49,748 : Disable swap
contents 0, /sys/module/zswap/parameters/enabled
DEBUG    2024-03-04 21:26:49,749 :   shell: echo 0 > /sys/module/zswap/parameters/enabled
DEBUG    2024-03-04 21:26:49,751 :   shell: swapoff -a
contents lzo-rle, /sys/module/zswap/parameters/compressor
DEBUG    2024-03-04 21:26:49,779 :   shell: echo lzo-rle > /sys/module/zswap/parameters/compressor
DEBUG    2024-03-04 21:26:49,782 : Enable swap
DEBUG    2024-03-04 21:26:49,782 :   shell: swapon /dev/zram0
contents 1, /sys/module/zswap/parameters/enabled
DEBUG    2024-03-04 21:26:49,805 :   shell: echo 1 > /sys/module/zswap/parameters/enabled
DEBUG    2024-03-04 21:26:49,807 : Check for swap device
DEBUG    2024-03-04 21:26:49,807 :   shell: swapon --noheadings | wc -l
DEBUG    2024-03-04 21:26:49,810 :     result: 1
DEBUG    2024-03-04 21:26:49,811 : found 1 swap devices
DEBUG    2024-03-04 21:26:49,811 :   shell: cat /sys/module/zswap/parameters/compressor
DEBUG    2024-03-04 21:26:49,813 :     result: lzo-rle
INFO     2024-03-04 21:26:49,813 : Compressor = lzo-rle
```
