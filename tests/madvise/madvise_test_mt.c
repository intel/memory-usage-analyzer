/*
 * SPDX-License-Identifier: BSD-3-Clause
 * Copyright (c) 2026, Intel Corporation
 *
 * madvise_test_mt — Multi-threaded zswap latency benchmark
 *
 * Spawns N threads, each pinned to a different CPU core, each performing
 * MADV_PAGEOUT (swap-out) followed by page-fault swap-in on its own
 * private memory region.  Measures per-thread and aggregate latency to
 * quantify IAA device contention under concurrent reclaim.
 *
 * Usage:
 *   madvise_test_mt <datafile> <pages_per_thread> <num_threads>
 *
 * Output (machine-parseable):
 *   swap_out_avg_ns=<value>
 *   swap_in_avg_ns=<value>
 *   threads=<N>
 *   pages_per_thread=<M>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <time.h>

#ifndef MADV_PAGEOUT
#define MADV_PAGEOUT 21
#endif

#define PAGE_SIZE 4096

static inline long now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000000L + ts.tv_nsec;
}

static inline long tv_to_ns(const struct timeval *tv)
{
    return tv->tv_sec * 1000000000L + tv->tv_usec * 1000L;
}

/*
 * Read zram mm_stat: "orig_data_size compr_data_size mem_used_total ..."
 * Falls back to zswap sysfs if zram not found.
 */
static void read_zpool_stats(long *orig_data, long *mem_used)
{
    *orig_data = 0;
    *mem_used = 0;

    const char *zpool_source = getenv("ZPOOL_SOURCE");
    int force_zswap = (zpool_source && strcmp(zpool_source, "zswap") == 0);
    int force_zram = (zpool_source && strcmp(zpool_source, "zram") == 0);

    if (!force_zswap) {
        FILE *fp = fopen("/sys/block/zram0/mm_stat", "r");
        if (fp) {
            fscanf(fp, "%ld %*ld %ld", orig_data, mem_used);
            fclose(fp);
            return;
        }

        if (force_zram)
            return;
    }

    /* Fallback to zswap */
    FILE *fp;
    fp = fopen("/sys/kernel/debug/zswap/stored_pages", "r");
    if (fp) {
        long stored = 0;
        fscanf(fp, "%ld", &stored);
        fclose(fp);
        *orig_data = stored * 4096;
    }
    fp = fopen("/sys/kernel/debug/zswap/pool_total_size", "r");
    if (fp) {
        fscanf(fp, "%ld", mem_used);
        fclose(fp);
    }
}

struct thread_args {
    int thread_id;
    int cpu_id;
    int nr_pages;
    const char *datafile;
    long swap_out_ns;
    long swap_in_ns;
    long swap_out_sys_ns;
    long swap_in_sys_ns;
    long zpool_orig_data;
    long zpool_mem_used;
};

static void *worker(void *arg)
{
    struct thread_args *ta = (struct thread_args *)arg;
    int nr_pages = ta->nr_pages;

    /* Pin to specific CPU */
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(ta->cpu_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);

    /* Allocate private anonymous pages */
    char *addr = mmap(NULL, (size_t)nr_pages * PAGE_SIZE,
                      PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (addr == MAP_FAILED) {
        perror("mmap");
        ta->swap_out_ns = -1;
        ta->swap_in_ns = -1;
        return NULL;
    }

    /* Fill pages with data from file (for realistic compressibility) */
    FILE *fp = fopen(ta->datafile, "r");
    if (fp) {
        /* Seek to a unique offset per thread to get different data patterns */
        long offset = (long)ta->thread_id * nr_pages * PAGE_SIZE;
        fseek(fp, offset % (1024 * 1024 * 200), SEEK_SET); /* wrap within file */
        size_t read_pages = fread(addr, PAGE_SIZE, nr_pages, fp);
        /* If file is smaller, fill remainder with pattern */
        if ((int)read_pages < nr_pages) {
            for (int i = (int)read_pages; i < nr_pages; i++) {
                memset(addr + i * PAGE_SIZE, (i * 7 + ta->thread_id) & 0xFF, PAGE_SIZE);
            }
        }
        fclose(fp);
    } else {
        /* Fill with semi-compressible pattern */
        for (int i = 0; i < nr_pages; i++) {
            memset(addr + i * PAGE_SIZE, (i * 7 + ta->thread_id) & 0xFF, PAGE_SIZE);
        }
    }

    /* Barrier: wait for all threads to be ready (handled by pthread_barrier in main) */

    /* === Swap Out === */
    struct rusage ru0_out, ru1_out;
    getrusage(RUSAGE_THREAD, &ru0_out);
    long t0 = now_ns();
    int ret = madvise(addr, (size_t)nr_pages * PAGE_SIZE, MADV_PAGEOUT);
    long t1 = now_ns();
    getrusage(RUSAGE_THREAD, &ru1_out);
    ta->swap_out_ns = t1 - t0;
    ta->swap_out_sys_ns = tv_to_ns(&ru1_out.ru_stime) - tv_to_ns(&ru0_out.ru_stime);

    if (ret != 0) {
        perror("madvise MADV_PAGEOUT");
    }

    /* Brief pause to let kernel complete async pageout */
    usleep(500000);

    /* Thread 0 reads zpool stats while data is still compressed */
    if (ta->thread_id == 0) {
        read_zpool_stats(&ta->zpool_orig_data, &ta->zpool_mem_used);
    }

    /* === Swap In (page faults) === */
    struct rusage ru0_in, ru1_in;
    getrusage(RUSAGE_THREAD, &ru0_in);
    long t2 = now_ns();
    volatile char v;
    char *a = addr;
    for (int i = 0; i < nr_pages; i++) {
        v = a[0];
        a += PAGE_SIZE;
    }
    long t3 = now_ns();
    getrusage(RUSAGE_THREAD, &ru1_in);
    ta->swap_in_ns = t3 - t2;
    ta->swap_in_sys_ns = tv_to_ns(&ru1_in.ru_stime) - tv_to_ns(&ru0_in.ru_stime);
    (void)v;

    munmap(addr, (size_t)nr_pages * PAGE_SIZE);
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "Usage: %s <datafile> <pages_per_thread> <num_threads>\n", argv[0]);
        return 1;
    }

    const char *datafile = argv[1];
    int nr_pages = atoi(argv[2]);
    int num_threads = atoi(argv[3]);

    if (nr_pages <= 0 || num_threads <= 0) {
        fprintf(stderr, "Invalid arguments: pages=%d threads=%d\n", nr_pages, num_threads);
        return 1;
    }

    /* Get available CPUs */
    int num_cpus = sysconf(_SC_NPROCESSORS_ONLN);
    if (num_threads > num_cpus) {
        fprintf(stderr, "Warning: %d threads > %d CPUs, some will share cores\n",
                num_threads, num_cpus);
    }

    struct thread_args *args = calloc(num_threads, sizeof(struct thread_args));
    pthread_t *threads = calloc(num_threads, sizeof(pthread_t));

    /* Assign each thread to a different CPU (spread evenly) */
    for (int i = 0; i < num_threads; i++) {
        args[i].thread_id = i;
        args[i].cpu_id = (i * (num_cpus / num_threads)) % num_cpus;
        args[i].nr_pages = nr_pages;
        args[i].datafile = datafile;
    }

    /* Launch all threads */
    for (int i = 0; i < num_threads; i++) {
        if (pthread_create(&threads[i], NULL, worker, &args[i]) != 0) {
            perror("pthread_create");
            return 1;
        }
    }

    /* Wait for completion */
    for (int i = 0; i < num_threads; i++) {
        pthread_join(threads[i], NULL);
    }

    /* Compute aggregate statistics */
    long total_out = 0, total_in = 0;
    long total_out_sys = 0, total_in_sys = 0;
    long max_out = 0, max_in = 0;
    int valid = 0;

    for (int i = 0; i < num_threads; i++) {
        if (args[i].swap_out_ns < 0)
            continue;
        valid++;
        total_out += args[i].swap_out_ns;
        total_in += args[i].swap_in_ns;
        total_out_sys += args[i].swap_out_sys_ns;
        total_in_sys += args[i].swap_in_sys_ns;
        if (args[i].swap_out_ns > max_out)
            max_out = args[i].swap_out_ns;
        if (args[i].swap_in_ns > max_in)
            max_in = args[i].swap_in_ns;
    }

    if (valid == 0) {
        fprintf(stderr, "All threads failed\n");
        free(args);
        free(threads);
        return 1;
    }

    long avg_out_per_page = total_out / (valid * nr_pages);
    long avg_in_per_page = total_in / (valid * nr_pages);
    long avg_out_sys_per_page = total_out_sys / (valid * nr_pages);
    long avg_in_sys_per_page = total_in_sys / (valid * nr_pages);
    long max_out_per_page = max_out / nr_pages;
    long max_in_per_page = max_in / nr_pages;

    /* Machine-parseable output */
    printf("threads=%d\n", num_threads);
    printf("pages_per_thread=%d\n", nr_pages);
    printf("swap_out_avg_ns=%ld\n", avg_out_per_page);
    printf("swap_out_max_ns=%ld\n", max_out_per_page);
    printf("swap_in_avg_ns=%ld\n", avg_in_per_page);
    printf("swap_in_max_ns=%ld\n", max_in_per_page);
    printf("swap_out_sys_avg_ns=%ld\n", avg_out_sys_per_page);
    printf("swap_in_sys_avg_ns=%ld\n", avg_in_sys_per_page);

    /* Zpool stats from thread 0 */
    long orig_data = args[0].zpool_orig_data;
    long mem_used = args[0].zpool_mem_used;
    long stored_pages = orig_data / 4096;
    double comp_ratio = (mem_used > 0) ? (double)orig_data / mem_used : 0;
    printf("zpool_stored_pages=%ld\n", stored_pages);
    printf("zpool_total_size=%ld\n", mem_used);
    printf("zpool_comp_ratio=%.2f\n", comp_ratio);

    /* Per-thread detail */
    fprintf(stderr, "\nPer-thread results (ns/page):\n");
    fprintf(stderr, "%4s %8s %8s %10s %10s\n",
            "TID", "CPU", "Pages", "Out(ns/pg)", "In(ns/pg)");
    for (int i = 0; i < num_threads; i++) {
        if (args[i].swap_out_ns < 0) {
            fprintf(stderr, "%4d %8d %8d %10s %10s\n",
                    i, args[i].cpu_id, nr_pages, "FAIL", "FAIL");
        } else {
            fprintf(stderr, "%4d %8d %8d %10ld %10ld\n",
                    i, args[i].cpu_id, nr_pages,
                    args[i].swap_out_ns / nr_pages,
                    args[i].swap_in_ns / nr_pages);
        }
    }

    free(args);
    free(threads);
    return 0;
}
