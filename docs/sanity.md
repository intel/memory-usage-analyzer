# Sanity Tests

This section provides details on running Sanity checks before code changes are submitted. This checks
the basic functionality of the memory-usage-analyzer.

```
./sanity_test.py -o <unique_output_folder>
#Sample results, actual results may vary
Running baseline example workload test
iteration = 0
iteration = 1
iteration = 2
out/baseline/analyze.out
Maximum active+swap memory           = 8.018 GiB

Max swap memory                = 0.0 GiB

      69.724181134 seconds time elapsed

out.1/baseline/analyze.out
Maximum active+swap memory           = 8.018 GiB

Max swap memory                = 0.0 GiB

      68.730653563 seconds time elapsed

out.2/baseline/analyze.out
Maximum active+swap memory           = 8.018 GiB

Max swap memory                = 0.0 GiB

      69.448344388 seconds time elapsed

Baseline max_mem is less than 1% limit of ref and test is passed
Baseline avg_exec_time = 69.301059695
Running static squeezer with 10% memory limit
iteration = 0
iteration = 1
iteration = 2
out_static/staticsweep/memory_10/analyze.out
Maximum active+swap memory           = 7.216 GiB

Max swap memory                = 1.6 GiB

     102.502291517 seconds time elapsed

out_static.1/staticsweep/memory_10/analyze.out
Maximum active+swap memory           = 7.217 GiB

Max swap memory                = 1.6 GiB

     103.233065381 seconds time elapsed

out_static.2/staticsweep/memory_10/analyze.out
Maximum active+swap memory           = 7.216 GiB

Max swap memory                = 1.6 GiB

     103.079867010 seconds time elapsed

Static max_mem is less than 1% limit of ref and test is passed
Static max_swap is less than 1% limit of ref and test is passed
Static avg_exec_time = 102.93840796933334
Running dynamic squeezer
iteration = 0
iteration = 1
iteration = 2
Maximum active+swap memory           = 8.017 GiB

Max swap memory                = 4.0 GiB

Maximum zram memory            = 0.000019 GiB

      84.444676912 seconds time elapsed

Maximum active+swap memory           = 8.016 GiB

Max swap memory                = 4.0 GiB

Maximum zram memory            = 0.000019 GiB

      84.679450599 seconds time elapsed

Maximum active+swap memory           = 8.016 GiB

Max swap memory                = 4.5 GiB

Maximum zram memory            = 0.000019 GiB

      86.858831169 seconds time elapsed

Dynamic max_mem is less than 1% limit of ref and test is passed
Dynamic max_swap is less than 5% limit of ref and test is passed
Dynamic avg_max_zram is 1.9e-05
Dynamic avg_exec_time is 85.32765289333334

```

