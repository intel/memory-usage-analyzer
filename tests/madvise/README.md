# Introduction
zswap performance benchmarking with IAA uses madvise() system call with MADV_PAGEOUT. It loads the entire dataset (silesia.tar for example) to memory, swap-out all the pages and swap-in all the pages, monitoring the time spent in swap-in and swap-out and other key metrics. There are two benchmarking scenarios

1. benchmark single page
2. benchmark with IAA batching to take advantage of parallel processing in IAA.

## Prerequisites
1. Platform with Intel Xeon 4th generation (or higher) processor and IAA.
2. [Memory Usage Analyzer Framework](https://github.com/intel/memory-usage-analyzer/tree/main?tab=readme-ov-file#install_)
3. Kernel with IAA RFC patches. Please see instructions on building the kernel [here](https://github.com/intel/memory-usage-analyzer/wiki/Integration-of-IAA-RFC-patches-to-6.12-upstream-kernel).

## Run single-page Microbenchmarks

Collect data and generate reports for all the compressors for single-page. Depending on the number of IAA devices on the system, the setup scripts needs to be modified. The list of compressors and datasets can be modified as needed.
```
    # For all 4 devices` per socket
    ./collect_single_page.sh  | tee single_page.txt

    # For SKUs with only 1 IAA device per socket
    ./collect_single_page.sh  -d 1  | tee single_page.txt

``` 
This will generate a summary of the key metrics for each dataset. In addition to that more detailed data points like CDFs and a summary .xls will be generated under the results_* directory

## Run Microbenchmarks with IAA batching
Collect data and generate reports for all the compressors for batch processing. The list of compressors, datasets and batch sweep can be modifed as needed.
```
    # For all 4 devices` per socket
    ./collect_batch.sh | tee batch.txt
    # For SKUs with only 1 IAA device per socket
    ./collect_batch.sh -d 1 | tee batch.txt
```
This will generate swap-in and swap-out latency reports for different batches for IAA along with software compressors.

## Additional details
For running individual compressors low-level script can be utilized.

```
    echo 'lz4' > /sys/module/zswap/parameters/compressor
    ./collect_bpftraces.sh
    echo 'deflate-iaa-canned' > /sys/module/zswap/parameters/compressor
    ./collect_bpftraces.sh
   ``` 
... and so on. This will generate a <compressor>_output file for each run

Once all runs are collected, run the post-processing Python script:
```
    ./process_bpftraces.py
```


