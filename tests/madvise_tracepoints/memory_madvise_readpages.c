/*
 * * SPDX-License-Identifier: BSD-3-Clause
 * * Copyright (c) 2025, Intel Corporation
 * * Description: madvise workload that generates swap-outs and swap-ins. This takes a dataset as input
 * * and fills the memory region with it contents. All memory pages are swapped out using MADV_PAGEOUT
 * * and then swapped in to create zswap stores/loads.  
 * */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <linux/mman.h>

#ifndef MADV_PAGEOUT
#define MADV_PAGEOUT	21	/* force pages out immediately */
#endif

#define PG_SZ		4096

int main(int argc, char **argv)
{
	int i, nr_pages = 1;
        int64_t *dump_ptr;
	char *addr, *a;
        int loop = 1;
	char *fname;
        int fd;
        struct stat sb;
	size_t size;
	int ret = 0;
	int nr_paged_in = 0;
	int nr_swapped_in = 0;

	if (argc > 1)
		fname = argv[1];

	printf("Reading file of pages %s to swap in/out\n", fname);

	fd = open(fname, O_RDONLY);	
	if (fd < 0) {
		perror(fname);
		return -1;
        }

        if (fstat(fd, &sb) < 0) {
                perror(fname);
		goto error;
        }
        if (!S_ISREG(sb.st_mode)) {
                fprintf(stderr, "not a regular file: %s\n", fname);
		goto error;
        }

	size = sb.st_size;

	nr_pages = size / PG_SZ;

	printf("Paging in %d pages\n", nr_pages);
        addr = mmap(NULL, nr_pages * PG_SZ, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        *addr = 1;
	
	a = addr;

	/* Access the page to bring it in */
	for (i = 0; i < nr_pages; i++) {
		ssize_t n_read = read(fd, a, PG_SZ);
		//printf("a %p a[0] %d a[1000] %d\n", a, a[0], a[1000]);
		nr_paged_in++;

		a += PG_SZ;
	}

        printf("Paged in %d pages\n", nr_paged_in);
        printf("Swapping out %d pages\n", nr_pages);

        /* Tell kernel to swap it out */
        madvise(addr, nr_pages * PG_SZ, MADV_PAGEOUT);

        while (loop > 0) {
                /* Wait for swap out to finish */
                sleep(5);

		a = addr;

		printf("Swapping in %d pages\n", nr_pages);

                /* Access the page ... this will swap it back in again */
		for (i = 0; i < nr_pages; i++) {
			char c = a[0];
			if (c != '*' || c == '*')
				nr_swapped_in++;
			a += PG_SZ;
		}

                loop --;
        }
        printf("Swapped in %d pages\n", nr_swapped_in);
        printf("Swapped out and in %d pages\n", nr_pages);
out:
	return ret;
error:
        printf("Error, exiting\n");
	close(fd);
	ret = -1;

	goto out;
}

