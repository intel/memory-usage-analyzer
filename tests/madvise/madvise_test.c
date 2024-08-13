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
		fread(addr, PAGE_SIZE, nr_pages, fp);
		fclose(fp);
	}

	/* Tell kernel to swap it out */
        long time_ns = _now();
        int status = madvise(addr, nr_pages * PAGE_SIZE, MADV_PAGEOUT);
	long swap_out_time_total_ns=_now() - time_ns;
	long swap_out_time_avg_ns= swap_out_time_total_ns/nr_pages;
	printf("Swapping out %d pages from %lx, ret = %d\n", nr_pages, addr, status);
	printf("swap_out: total=%d average=%d\n", swap_out_time_total_ns, swap_out_time_avg_ns);

	/* Wait for swap out to finish */
	sleep(2);

	printf("Swapping in %d pages\n", nr_pages);

        time_ns = _now();
	a = addr;
	/* Access the page ... this will swap it back in again */
	for (i = 0; i < nr_pages; i++) {
		volatile char v;
		v = a[0];
		a += PAGE_SIZE;
	}
	long swap_in_time_total_ns=_now() - time_ns;
	long swap_in_time_avg_ns= swap_in_time_total_ns/nr_pages;
	printf("swap_in: total=%d average=%d\n", swap_in_time_total_ns, swap_in_time_avg_ns);

}
