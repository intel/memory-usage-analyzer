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
#include <errno.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <time.h>

#ifndef MADV_PAGEOUT
#define MADV_PAGEOUT 21
#endif

#define PAGE_SIZE 4096

/* Keep a short settle window by default; can be overridden with PAGEOUT_SETTLE_USEC. */
static useconds_t g_pageout_settle_usec = 50000;
/* By default, include async reclaim completion in swap-out timing. */
static int g_pageout_wait_complete = 1;
static useconds_t g_pageout_poll_usec = 100;
static long g_pageout_timeout_msec = 30000;

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
            if (fscanf(fp, "%ld %*d %ld", orig_data, mem_used) != 2) {
                *orig_data = 0;
                *mem_used = 0;
            }
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
        if (fscanf(fp, "%ld", &stored) != 1)
            stored = 0;
        fclose(fp);
        *orig_data = stored * 4096;
    }
    fp = fopen("/sys/kernel/debug/zswap/pool_total_size", "r");
    if (fp) {
        if (fscanf(fp, "%ld", mem_used) != 1)
            *mem_used = 0;
        fclose(fp);
    }
}

struct thread_args {
    int thread_id;
    int cpu_id;
    int nr_pages;
    const unsigned char *dataset_buf;
    size_t dataset_len;
    long swap_out_ns;
    long swap_in_ns;
    long swap_out_sys_ns;
    long swap_in_sys_ns;
};

static void fill_pages_from_dataset(char *dst, int nr_pages,
                                    const unsigned char *dataset,
                                    size_t dataset_len,
                                    int thread_id)
{
    size_t total_bytes = (size_t)nr_pages * PAGE_SIZE;

    if (!dataset || dataset_len == 0) {
        for (int i = 0; i < nr_pages; i++) {
            memset(dst + (size_t)i * PAGE_SIZE, (i * 7 + thread_id) & 0xFF, PAGE_SIZE);
        }
        return;
    }

    size_t start = ((size_t)thread_id * total_bytes) % dataset_len;
    size_t copied = 0;
    size_t pos = start;

    while (copied < total_bytes) {
        size_t chunk = dataset_len - pos;
        size_t remain = total_bytes - copied;
        if (chunk > remain)
            chunk = remain;

        memcpy(dst + copied, dataset + pos, chunk);
        copied += chunk;
        pos += chunk;
        if (pos == dataset_len)
            pos = 0;
    }
}

static int load_dataset_ro(const char *path,
                           const unsigned char **out_buf,
                           size_t *out_len,
                           int *out_fd)
{
    struct stat st;
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return -1;

    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        return -1;
    }

    void *map = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        return -1;
    }

    *out_buf = (const unsigned char *)map;
    *out_len = (size_t)st.st_size;
    *out_fd = fd;
    return 0;
}

/*
 * Wait until all pages in [addr, len) are non-resident, indicating pageout
 * and compression have completed. Returns 0 on success, -1 on error/timeout.
 */
static int wait_for_pageout_complete(void *addr, size_t len, int nr_pages)
{
    unsigned char *vec;
    long deadline_ns;

    if (nr_pages <= 0)
        return 0;

    vec = malloc((size_t)nr_pages);
    if (!vec)
        return -1;

    deadline_ns = now_ns() + g_pageout_timeout_msec * 1000000L;
    while (1) {
        int resident = 0;

        if (mincore(addr, len, vec) != 0) {
            free(vec);
            return -1;
        }

        for (int i = 0; i < nr_pages; i++) {
            if (vec[i] & 0x1)
                resident++;
        }

        if (resident == 0) {
            free(vec);
            return 0;
        }

        if (now_ns() >= deadline_ns) {
            free(vec);
            return -1;
        }

        if (g_pageout_poll_usec > 0)
            usleep(g_pageout_poll_usec);
    }
}

/* Barriers to synchronize swap-out completion and swap-in start */
static pthread_barrier_t barrier_swapout_done;
static pthread_barrier_t barrier_swapin_start;

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

    /* Fill with a thread-specific dataset slice without per-thread file I/O. */
    fill_pages_from_dataset(addr, nr_pages, ta->dataset_buf, ta->dataset_len, ta->thread_id);

    /* Barrier: wait for all threads to be ready (handled by pthread_barrier in main) */

    /* === Swap Out === */
    struct rusage ru0_out, ru1_out;
    getrusage(RUSAGE_THREAD, &ru0_out);
    long t0 = now_ns();
    int ret = madvise(addr, (size_t)nr_pages * PAGE_SIZE, MADV_PAGEOUT);
    if (ret == 0) {
        if (g_pageout_wait_complete) {
            if (wait_for_pageout_complete(addr, (size_t)nr_pages * PAGE_SIZE, nr_pages) != 0) {
                /* Fall back to timed settle if completion detection fails. */
                if (g_pageout_settle_usec > 0)
                    usleep(g_pageout_settle_usec);
            }
        } else if (g_pageout_settle_usec > 0) {
            usleep(g_pageout_settle_usec);
        }
    }
    long t1 = now_ns();
    getrusage(RUSAGE_THREAD, &ru1_out);
    ta->swap_out_ns = t1 - t0;
    ta->swap_out_sys_ns = tv_to_ns(&ru1_out.ru_stime) - tv_to_ns(&ru0_out.ru_stime);

    if (ret != 0) {
        perror("madvise MADV_PAGEOUT");
    }

    /* All threads wait here after swap-out; main reads zpool stats */
    pthread_barrier_wait(&barrier_swapout_done);
    /* Wait for main to finish reading stats before starting swap-in */
    pthread_barrier_wait(&barrier_swapin_start);

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
    const char *settle_env = getenv("PAGEOUT_SETTLE_USEC");
    const char *wait_complete_env = getenv("PAGEOUT_WAIT_COMPLETE");
    const char *poll_env = getenv("PAGEOUT_POLL_USEC");
    const char *timeout_env = getenv("PAGEOUT_TIMEOUT_MSEC");

    if (settle_env && *settle_env) {
        long settle = strtol(settle_env, NULL, 10);
        if (settle >= 0)
            g_pageout_settle_usec = (useconds_t)settle;
    }

    if (wait_complete_env && *wait_complete_env) {
        long v = strtol(wait_complete_env, NULL, 10);
        g_pageout_wait_complete = (v != 0) ? 1 : 0;
    }

    if (poll_env && *poll_env) {
        long poll_us = strtol(poll_env, NULL, 10);
        if (poll_us >= 0)
            g_pageout_poll_usec = (useconds_t)poll_us;
    }

    if (timeout_env && *timeout_env) {
        long timeout_ms = strtol(timeout_env, NULL, 10);
        if (timeout_ms > 0)
            g_pageout_timeout_msec = timeout_ms;
    }

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
    const unsigned char *dataset_buf = NULL;
    size_t dataset_len = 0;
    int dataset_fd = -1;

    if (load_dataset_ro(datafile, &dataset_buf, &dataset_len, &dataset_fd) != 0) {
        fprintf(stderr, "Warning: failed to memory-map dataset '%s'; using generated pattern\n", datafile);
    }

    /* Assign each thread to a CPU in a round-robin manner. */
    for (int i = 0; i < num_threads; i++) {
        args[i].thread_id = i;
        args[i].cpu_id = i % num_cpus;
        args[i].nr_pages = nr_pages;
        args[i].dataset_buf = dataset_buf;
        args[i].dataset_len = dataset_len;
    }

    /* Initialize barriers: num_threads + 1 (main thread participates) */
    pthread_barrier_init(&barrier_swapout_done, NULL, num_threads + 1);
    pthread_barrier_init(&barrier_swapin_start, NULL, num_threads + 1);

    /* Launch all threads */
    for (int i = 0; i < num_threads; i++) {
        if (pthread_create(&threads[i], NULL, worker, &args[i]) != 0) {
            perror("pthread_create");
            return 1;
        }
    }

    /* Wait for all threads to complete swap-out phase */
    pthread_barrier_wait(&barrier_swapout_done);

    /* Read zpool stats now — all pages are compressed, none swapped in yet */
    long orig_data = 0, mem_used = 0;
    read_zpool_stats(&orig_data, &mem_used);

    /* Release threads to proceed with swap-in */
    pthread_barrier_wait(&barrier_swapin_start);

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

    long stored_pages = orig_data / 4096;
    double comp_ratio = (mem_used > 0) ? (double)orig_data / mem_used : 0;
    printf("zpool_stored_pages=%ld\n", stored_pages);
    printf("zpool_total_size=%ld\n", mem_used);
    printf("zpool_comp_ratio=%.2f\n", comp_ratio);

    /* Per-thread detail */
    if (getenv("MT_VERBOSE")) {
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
    }

    if (dataset_buf)
        munmap((void *)dataset_buf, dataset_len);
    if (dataset_fd >= 0)
        close(dataset_fd);

    free(args);
    free(threads);
    pthread_barrier_destroy(&barrier_swapout_done);
    pthread_barrier_destroy(&barrier_swapin_start);
    return 0;
}
