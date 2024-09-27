# Instructions
madvise-test suite allows benchmarking of zswap with different compression algorithms. It loads a data corpus (silesia.tar for example), swap-out all the pages, swap-in all the pages in the meanwhile monitoring the swap-in and swap-out latency along with the compressed size using bpftool.

## Prerequisite
#### Hardware
* Intel 4th Gen Intel® Xeon® Scalable Processors or later with IAA enebled. Please see [IAA user guide](https://cdrdv2-public.intel.com/780887/354834_IAA_UserGuide_June23.pdf)for more details about IAA configuration.
#### Software
This framework has dependencies on IAA RFC kernel patches. Please see [instructions on building the kernel right patch sets](https://github.com/intel/memory-usage-analyzer/wiki/Integration-of-IAA-RFC-patches-to-upstream-kernel)

## Run in Baremetal
1. Run
   ```
    ./make_swap_space.sh
   ```
   Additional details of make_swap_space.sh script:
	Command Line Arguments: The script now accepts -l for specifying the swap file location and -s for specifying the swap size in GB.
	Default Values: If no arguments are provided, it defaults to /mnt/nvme1/swapfile for the location and 1GB for the size.
	Dynamic Path Handling: It dynamically checks the available space in the directory derived from the provided or default swap file location.
	Example of creating 4GB swap space at /mnt/nvme1/swapfile
	```
	./make_swap_space.sh  [-l <path_to_swap_file>] [-s <swap_size_in_GBi>]
	```
2. Configure IAA device
    ```
    ./enable_kernel_iaa
    ```
3. Active zswap by runnig
   ```
   ./enable_zswap.sh
   ```
4. Collect data and generate reports for all the compressors.
   ```
   ./collect_all.sh
   ```
 This will generate html files for CDFs of compress, decompress, compression ratio and page fault latencies and a summary.xlsx file. This will also generate (to stdout) P50 & P99 values.

## Additional details
For running individual compressors

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
This will generate html files for CDFs of compress, decompress, compression ratio and page fault latencies and a summary.xlsx file.
This will also generate (to stdout) P50 & P99 values.


