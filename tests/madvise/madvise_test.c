/*
* SPDX-License-Identifier: BSD-3-Clause
* Copyright (c) 2023, Intel Corporation
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <linux/mman.h>
#include <sys/resource.h>
#include <time.h>

#ifndef MADV_PAGEOUT
#define MADV_PAGEOUT    21      /* force pages out immediately */
#endif

#define PAGE_SIZE 4096

extern inline long _now() {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    return now.tv_sec * 1000000000 + now.tv_nsec;
}

static inline long tv_to_ns(const struct timeval *tv) {
	return tv->tv_sec * 1000000000L + tv->tv_usec * 1000L;
}

long read_sysfs_long(const char *path) {
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    char buf[64];
    if (!fgets(buf, sizeof(buf), fp)) { fclose(fp); return 0; }
    fclose(fp);
    return atol(buf);
}

/*
 * Read zram mm_stat: "orig_data_size compr_data_size mem_used_total ..."
 * Also try zswap sysfs as fallback.
 */
void read_zpool_stats(long *orig_data, long *mem_used) {
    *orig_data = 0;
    *mem_used = 0;

	const char *zpool_source = getenv("ZPOOL_SOURCE");
	int force_zswap = (zpool_source && strcmp(zpool_source, "zswap") == 0);
	int force_zram = (zpool_source && strcmp(zpool_source, "zram") == 0);

	if (!force_zswap) {
		/* Try zram first unless zswap is explicitly requested. */
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
    long stored = read_sysfs_long("/sys/kernel/debug/zswap/stored_pages");
    long pool = read_sysfs_long("/sys/kernel/debug/zswap/pool_total_size");
    *orig_data = stored * 4096;
    *mem_used = pool;
}

int main(int argc, char **argv)
{
	int i, nr_pages = 1;
	int64_t *dump_ptr;
	char *addr, *a;
	FILE *fp;

	if (argc > 2)
		nr_pages = atoi(argv[2]);

	printf("Allocating %d pages to swap in/out\n", nr_pages);
	/* allocate pages */
	addr = mmap(NULL, nr_pages * PAGE_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	/* fill data into pages from provided file, use zero if not */
	fp = fopen((argc>1)?argv[1]:"/dev/zero", "r");

	if (fp) {
		if (fread(addr, PAGE_SIZE, nr_pages, fp) != (size_t)nr_pages && ferror(fp))
			perror("fread");
		fclose(fp);
	}

	/* Tell kernel to swap it out */
        struct rusage ru0_out, ru1_out;
        getrusage(RUSAGE_SELF, &ru0_out);
        long time_ns = _now();
        int status = madvise(addr, nr_pages * PAGE_SIZE, MADV_PAGEOUT);
	long swap_out_time_total_ns=_now() - time_ns;
	getrusage(RUSAGE_SELF, &ru1_out);
	long swap_out_sys_total_ns = tv_to_ns(&ru1_out.ru_stime) - tv_to_ns(&ru0_out.ru_stime);
	long swap_out_time_avg_ns= swap_out_time_total_ns/nr_pages;
	long swap_out_sys_avg_ns = swap_out_sys_total_ns/nr_pages;
	printf("Swapping out %d pages from %lx, ret = %d\n", nr_pages, (unsigned long)addr, status);
	printf("swap_out: total=%ld average=%ld\n", swap_out_time_total_ns, swap_out_time_avg_ns);
	printf("swap_out_sys: total=%ld average=%ld\n", swap_out_sys_total_ns, swap_out_sys_avg_ns);

	/* Wait for swap out to finish */
	sleep(2);

	/* Report zpool stats while pages are still compressed */
	long orig_data = 0, mem_used = 0;
	read_zpool_stats(&orig_data, &mem_used);
	long stored_pages = orig_data / 4096;
	double comp_ratio = (mem_used > 0) ? (double)orig_data / mem_used : 0;
	printf("zpool_stored_pages: %ld\n", stored_pages);
	printf("zpool_total_size: %ld\n", mem_used);
	printf("zpool_comp_ratio: %.2f\n", comp_ratio);

	printf("Swapping in %d pages\n", nr_pages);

	struct rusage ru0_in, ru1_in;
	getrusage(RUSAGE_SELF, &ru0_in);
        time_ns = _now();
	a = addr;
	/* Access the page ... this will swap it back in again */
	for (i = 0; i < nr_pages; i++) {
		volatile char v;
		v = a[0];
		a += PAGE_SIZE;
	}
	long swap_in_time_total_ns=_now() - time_ns;
	getrusage(RUSAGE_SELF, &ru1_in);
	long swap_in_sys_total_ns = tv_to_ns(&ru1_in.ru_stime) - tv_to_ns(&ru0_in.ru_stime);
	long swap_in_time_avg_ns= swap_in_time_total_ns/nr_pages;
	long swap_in_sys_avg_ns = swap_in_sys_total_ns/nr_pages;
	printf("swap_in: total=%ld average=%ld\n", swap_in_time_total_ns, swap_in_time_avg_ns);
	printf("swap_in_sys: total=%ld average=%ld\n", swap_in_sys_total_ns, swap_in_sys_avg_ns);

}
