# Instructions
There are two microbenchmarks provided here for checking the functionality and performance of zswap and zram with IAA. The microbenchmark uses "madvise" Linux system call to force swap-out and then swap-in the pages to exercise the path and measure the swap-out and swap-in latencies. Different compression algorithms are compared in these scenarios. silesia.tar dataset is used to fill the memory pages to have a compressible memory contents.

## zswap Microbenchmark
```
./zswap_microbench.sh
```
### Expected Results
Actual results may change depending platforms.
```
 threads=1T (single-threaded), pages_per_thread=51746, total_pages=51,746, test_workset_mb=202

Compressor                    Ratio  Zpool(MB) PgOut(ns/pg)  PgIn(ns/pg)    PgOut(ms)     PgIn(ms)   PgOut-Sys(ms)    PgIn-Sys(ms)
──────────────────────────── ────── ──────── ────────── ────────── ────────── ────────── ────────────── ──────────────
lzo-rle_r1_p3                  1.70      118.6        9,320        4,469        482.3        231.3           480.6           223.2
lz4_r1_p3                      1.67      120.9        9,148        3,441        473.4        178.1           472.0           169.0
zstd_r1_p3                     2.27       88.9       25,158       10,970       1301.9        567.7          1298.7           558.9
deflate-iaa_r1_p3              1.89      106.8        5,448        2,472        281.9        127.9           281.5           115.3
deflate-iaa-dynamic_r1_p3      2.24       90.2        8,842        2,468        457.6        127.7           456.7           121.2
deflate-iaa_r64_p1             1.89      106.8        2,548        3,414        131.9        176.7           131.5           168.2
deflate-iaa_r64_p5             1.89      106.8        2,473        2,556        128.0        132.3           127.5           125.7
deflate-iaa-dynamic_r64_p1     2.24       90.2        2,905        3,515        150.4        181.9           149.7           175.3
deflate-iaa-dynamic_r64_p5     2.24       90.2        2,874        2,514        148.8        130.1           148.3           117.5

```
## zram Microbenchmark
```
./zram_microbench.sh
```
### Expected Results
```
 threads=1T (single-threaded), pages_per_thread=51746, total_pages=51,746, test_workset_mb=202

Compressor                    Ratio  Zpool(MB) PgOut(ns/pg)  PgIn(ns/pg)    PgOut(ms)     PgIn(ms)   PgOut-Sys(ms)    PgIn-Sys(ms)
──────────────────────────── ────── ──────── ────────── ────────── ────────── ────────── ────────────── ──────────────
lzo-rle_r1_p3                  1.70      118.6        9,055        4,195        468.6        217.1           466.9           211.1
lz4_r1_p3                      1.67      120.9        9,028        3,219        467.2        166.6           465.7           161.6
zstd_r1_p3                     2.27       88.9       21,686        8,298       1122.2        429.4          1119.3           424.7
deflate-iaa_r1_p3              1.89      106.8        5,508        2,486        285.0        128.7           284.4           119.2
deflate-iaa-dynamic_r1_p3      2.24       90.2        9,011        2,472        466.3        128.0           464.9           120.6
deflate-iaa_r64_p1             1.89      106.8        2,581        3,283        133.6        169.9           133.1           166.4
deflate-iaa_r64_p5             1.89      106.8        2,561        2,422        132.5        125.3           132.1           119.9
deflate-iaa-dynamic_r64_p1     2.24       90.2        2,881        3,629        149.1        187.8           148.7           179.0
deflate-iaa-dynamic_r64_p5     2.24       90.2        3,083        2,552        159.5        132.1           159.2           127.5
```
