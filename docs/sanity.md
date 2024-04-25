# Sanity Tests

This section provides details on running Sanity checks before code changes are submitted. This checks the
sure the basic functionality of the memory-usage-analyzer.

```
./sanity_test -o <output_folder>
#Sample results, actual results may vary
Running baseline example workload test
iteration = 0
iteration = 1
iteration = 2
output/baseline/analyze.out
Maximum active+swap memory           = 8.018 GiB

Max swap memory                = 0.0 GiB

     333.751453340 seconds time elapsed

output.1/baseline/analyze.out
Maximum active+swap memory           = 8.018 GiB
Max swap memory                = 0.0 GiB

     336.614511911 seconds time elapsed

output.2/baseline/analyze.out
Maximum active+swap memory           = 8.018 GiB

Max swap memory                = 0.0 GiB

     333.530823142 seconds time elapsed

Baseline max_mem is less than 1% limit of ref and test is passed
Baseline avg_exec_time = 334.07142835766666

Running static squeezer with 10% memory limit
iteration = 0
iteration = 1
iteration = 2
output_static/staticsweep/memory_10/analyze.out
Maximum active+swap memory           = 7.217 GiB

Max swap memory                = 1.6 GiB

     407.835192013 seconds time elapsed

output_static.1/staticsweep/memory_10/analyze.out
Maximum active+swap memory           = 7.217 GiB

Max swap memory                = 1.6 GiB

     408.547875633 seconds time elapsed

output_static.2/staticsweep/memory_10/analyze.out
Maximum active+swap memory           = 7.216 GiB

Max swap memory                = 1.6 GiB

     411.597475507 seconds time elapsed

Static max_mem is less than 1% limit of ref and test is passed
Static max_swap is less than 1% limit of ref and test is passed
Static avg_exec_time = 409.3268477176666
Running dynamic squeezer
iteration = 0
iteration = 1
iteration = 2
Maximum active+swap memory           = 8.017 GiB

Max swap memory                = 4.3 GiB

Maximum zram memory            = 0.000019 GiB

     372.675095471 seconds time elapsed

Maximum active+swap memory           = 8.017 GiB

Max swap memory                = 4.3 GiB

Maximum zram memory            = 0.000019 GiB

     369.093067576 seconds time elapsed

Maximum active+swap memory           = 8.017 GiB

Max swap memory                = 4.4 GiB

Maximum zram memory            = 0.000023 GiB

     365.854511618 seconds time elapsed

Dynamic max_mem is less than 1% limit of ref and test is passed
Dynamic max_swap is less than 5% limit of ref and test is passed
Dynamic avg_max_zram is 2.0333333333333334e-05
Dynamic avg_exec_time is 369.20755822166666

```

