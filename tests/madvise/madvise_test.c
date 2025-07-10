/*
 * * SPDX-License-Identifier: BSD-3-Clause
 * * Copyright (c) 2025, Intel Corporation
 * * Description: madvise workload generate swap-outs and swap-ins. This takes a dataset as input
 * *  and fills the memory region with it contents. All memory pages are swapped out using MADV_PAGEOUT
 * *  and then swapped in to create zswap traffic.  
 * */



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

#define PAGE_SIZE (4096)

extern inline long _now() {
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    return now.tv_sec * 1000000000 + now.tv_nsec;
}

long read_sysfs(char *path ){
  
    FILE* fp = fopen(path, "r");
    char buf[128];
    if (!fp) {
        perror("Couldn't open file");
        return EXIT_FAILURE;
    }
    fgets(buf, sizeof(buf), fp);
    fclose(fp);
    long value = atol (buf);
    return value;
}

long read_sysfs_str(char *path , char *str, int size){
  
    FILE* fp = fopen(path, "r");
    if (!fp) {
        perror("Couldn't open file");
        return EXIT_FAILURE;
    }
    fgets(str, size, fp);
    fclose(fp);
    return 0;
}

long read_vmstat(char * str){
    FILE *fp;
    char buf[1035];
    char line[1035];

    /* Open the command for reading. */
    sprintf(buf,"gawk '{ if ( $1 ~ /%s/ ) { print $2 } }' /proc/vmstat", str);
    fp = popen(buf, "r");
    if (fp == NULL) {
        printf("Failed to run command\n" );
        exit(1);
    }
    fgets(buf, sizeof(buf), fp);
    pclose(fp);
    long value = atol (buf);
    return value;
}





int main(int argc, char **argv)
{
	int i, nr_pages = 1, page_size=PAGE_SIZE;
	int64_t *dump_ptr;
	char *addr, *a;
	FILE *fp;

	
	if (argc > 2)
		nr_pages = atoi(argv[2]);
		page_size = atoi(argv[3]);

	printf("Allocating %d pages to swap in/out with page_size %d\n", nr_pages, page_size);
	/* allocate pages */
	addr = mmap(NULL, nr_pages * page_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	/* fill data into pages from provided file, use zero if not */
	fp = fopen((argc>1)?argv[1]:"/dev/zero", "r");

	if (fp) {
		fread(addr, page_size, nr_pages, fp);
		fclose(fp);
	}

      
        long reject_compress_fail = read_sysfs("/sys/kernel/debug/zswap/reject_compress_fail");
        long reject_compress_poor = read_sysfs("/sys/kernel/debug/zswap/reject_compress_poor");
        long reject_alloc_fail    = read_sysfs("/sys/kernel/debug/zswap/reject_alloc_fail");
	long zswpout              = read_vmstat("zswpout");
	long swpout_zero          = read_vmstat("swpout_zero");

	/* Tell kernel to swap it out */
        long time_ns = _now();
        int status = madvise(addr, nr_pages * page_size, MADV_PAGEOUT);
	long swap_out_time_total_ns=_now() - time_ns;

        zswpout              = read_vmstat("zswpout") - zswpout;
        swpout_zero         = read_vmstat("swpout_zero") - swpout_zero;

	long swap_out_time_avg_ns= swap_out_time_total_ns/nr_pages;
	char compressor[128];
        read_sysfs_str("/sys/module/zswap/parameters/compressor", compressor, 128);
	// Find the position of the first newline character
	size_t newline_pos = strcspn(compressor, "\n");
	// Replace the newline character with a null terminator
	compressor[newline_pos] = '\0';
        int cbatch = read_sysfs("/proc/sys/vm/compress-batchsize");
        // NOTE: This is a temporary solution as we transition to the new kernel
	if ( cbatch == EXIT_FAILURE ) {
                cbatch = read_sysfs("/proc/sys/vm/reclaim-batchsize");
	}
        int dbatch = read_sysfs("/proc/sys/vm/page-cluster");
        // Add compress and decompress batch setting
	sprintf(compressor, "%s-c%d-d%d", compressor, cbatch, dbatch);
        
	printf("[%s] Swapped out %d pages from %lx, ret = %d\n", compressor,  zswpout, addr, status);
	printf("[%s] Swapped out %d zero pages\n", compressor,  swpout_zero);
	printf("[%s] swap_out time: count=%d total=%d average=%d\n", compressor, nr_pages, swap_out_time_total_ns, swap_out_time_avg_ns);
	/* Wait for swap out to finish */
	sleep(2);

        reject_compress_fail = read_sysfs("/sys/kernel/debug/zswap/reject_compress_fail") - reject_compress_fail;
        reject_compress_poor = read_sysfs("/sys/kernel/debug/zswap/reject_compress_poor") - reject_compress_poor;
        reject_alloc_fail    = read_sysfs("/sys/kernel/debug/zswap/reject_alloc_fail") - reject_alloc_fail;

	long total_comp_errors    = reject_compress_fail + reject_compress_poor + reject_alloc_fail;
	printf("[%s] compress_errors: %ld\n", compressor, total_comp_errors);

        long zpool_stored_pages = read_sysfs("/sys/kernel/debug/zswap/stored_pages");
        long zpool_total_size = read_sysfs("/sys/kernel/debug/zswap/pool_total_size");
	printf("[%s] zpool_stored_pages: %ld\n", compressor,zpool_stored_pages);
	printf("[%s] zpool_total_size: %ld\n", compressor, zpool_total_size);
	printf("[%s] zpool_comp_ratio: %.2f\n", compressor, (zpool_stored_pages*4096.0)/zpool_total_size);
	printf("[%s] swapped out total pages (zpool_stored+errors+zero): %ld\n", compressor, zpool_stored_pages+total_comp_errors+swpout_zero);


	long zswpin               = read_vmstat("zswpin"); 
	long swpin_zero           = read_vmstat("swpin_zero");

        time_ns = _now();
	a = addr;
	/* Access the page ... this will swap it back in again */
	for (i = 0; i < nr_pages; i++) {
		volatile char v;
		v = a[0];
		a += page_size;
	}

	long swap_in_time_total_ns=_now() - time_ns;
	zswpin               = read_vmstat("zswpin") - zswpin;
	swpin_zero          = read_vmstat("swpin_zero") - swpin_zero;
	long swap_in_time_avg_ns= swap_in_time_total_ns/nr_pages;


	printf("[%s] Swapped in %d pages\n", compressor, zswpin);
	printf("[%s] Swapped in %d zero pages\n", compressor, swpin_zero);
	printf("[%s] swap_in time: count=%d total=%d average=%d\n", compressor, nr_pages, swap_in_time_total_ns, swap_in_time_avg_ns);
	fflush(stdout);

}
