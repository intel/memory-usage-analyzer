# Introduction
This is a microbenchmark for zram using dd tool. It measures dd bandwidth when zram is configured with different compression algorithms. zram is mounted as a drive at /mnt/zram_disk and dd try to read and write file from it. silesia.tar is used a the data content. Metrics reported by dd is monitored. direct mode is selected for IO to by pass page cache to get zram stats.

# Prerequisite
1. **Kernel Configuration**: Ensure your kernel has IAA enabled for zram
2. **Install Dependencies**: Install the applications.benchmarking.iax-memcomp package following the [Install](https://github.com/intel-innersource/applications.benchmarking.iax-memcomp/#install)

# Setting up Environment
Follow the [iax-memcomp install instructions](https://github.com/intel-innersource/applications.benchmarking.iax-memcomp/#install) to set up the environment, if not already done.

# Build dd

```
./build_dd.sh
```

# Run Test

```
./run_dd.sh [-s]
```
# Expected Results
Provided as an example from GNR-AP. Actual numbers may vary based on the platforms. 

```
Compressor                      Block_Size      WR_BW(MB/s)     RD_BW(MB/s)     Compression_Ratio
-------------------------       ----------      ----------      ----------      ---------------
lz4                             4K              229             1740.8          1.68
zstd                            4K              130             519             2.28
deflate-iaa                     4K              260             1331.2          1.9
deflate-iaa-dynamic             4K              241             1228.8          2.25
lz4                             8K              309             2048            1.68
zstd                            8K              154             547             2.28
deflate-iaa                     8K              521             2048            1.9
deflate-iaa-dynamic             8K              432             1945.6          2.25
lz4                             16K             368             2252.8          1.68
zstd                            16K             168             562             2.28
deflate-iaa                     16K             842             3072            1.9
deflate-iaa-dynamic             16K             763             2867.2          2.25
lz4                             32K             410             2355.2          1.68
zstd                            32K             176             571             2.28
deflate-iaa                     32K             1433.6          3788.8          1.9
deflate-iaa-dynamic             32K             1126.4          3686.4          2.25
lz4                             64K             431             2355.2          1.68
zstd                            64K             181             575             2.28
deflate-iaa                     64K             1638.4          3993.6          1.9
deflate-iaa-dynamic             64K             1331.2          3891.2          2.25
lz4                             128K            443             2457.6          1.68
zstd                            128K            183             579             2.28
deflate-iaa                     128K            1843.2          4198.4          1.9
deflate-iaa-dynamic             128K            1433.6          3891.2          2.25
lz4                             256K            448             2457.6          1.68
zstd                            256K            184             579             2.28
deflate-iaa                     256K            1945.6          4300.8          1.9
deflate-iaa-dynamic             256K            1638.4          4096            2.25
lz4                             512K            453             2457.6          1.68
zstd                            512K            185             580             2.28
deflate-iaa                     512K            1945.6          4300.8          1.9
deflate-iaa-dynamic             512K            1536            4198.4          2.25
lz4                             1024K           450             2457.6          1.68
zstd                            1024K           184             579             2.28
deflate-iaa                     1024K           1945.6          4403.2          1.9
deflate-iaa-dynamic             1024K           1638.4          4198.4          2.25
lz4                             2048K           450             2457.6          1.68
zstd                            2048K           184             583             2.28
deflate-iaa                     2048K           1945.6          4608            1.9
deflate-iaa-dynamic             2048K           1740.8          4403.2          2.25

```
