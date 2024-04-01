/*
* SPDX-License-Identifier: BSD-3-Clause
* Copyright (c) 2023, Intel Corporation
*/

#include <signal.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include "workload.h"

#define PAGE_SHIFT 12

int hot = 50;
int hot_timer = 30;

/* Handler to switch between the two different memory-swapping
 * scenarios (50% of the allocated memory or 75% of the allocated memory
 */
void
sigalrm_handler(int sig) {
	alarm(hot_timer);
	hot = hot == 50 ? 75 : 50;
	INFO("hot pages = %d%%", hot);
}

int
main(int argc, char** argv) 
{
	if (argc != 4) {
		printf("usage %s: total_memory(GiB) hot_timer loops\n", argv[0]);
		return 1;
	}
	
        int memory = atoi(argv[1]);
        hot_timer = atoi(argv[2]);
        int loops = atoi(argv[3]);

	// Get the number of pages - 4K bytes -> 2** PAGE_SHIFT.
        long pages = memory << (30 - PAGE_SHIFT);
	
	INFO("pid       = %d", getpid());
        INFO("memory    = %d GiB = %ld pages", memory, pages);
        INFO("hot timer = %d sec", hot_timer);
        INFO("loops     = %d", loops);

	//------------------------------------------------------------
	// allocate and fill memory
	//------------------------------------------------------------
	time_t start = time(NULL);

	char *data = (char*)mmap(NULL, pages << PAGE_SHIFT, PROT_READ|PROT_WRITE,
				 MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	ASSERT(data != MAP_FAILED, "Failed to allocate memory.");
	
	for (long i = 0; i < pages; i++)
		memcpy(&data[i << PAGE_SHIFT], fill_data, 1 << PAGE_SHIFT);
	
	INFO("Done with setup in %ld seconds.", time(NULL) - start);

	//------------------------------------------------------------
	// do work
	//------------------------------------------------------------
	signal(SIGALRM, &sigalrm_handler);
	alarm(hot_timer);
	
	start = time(NULL);

        // loop forever when loops = 0
	for (int loop = 0; loop <= loops; loop += loops > 0 ? 1 : 0) {
		for (long i = 0; i < pages * hot / 100; i++) {
			data[i << PAGE_SHIFT]++;
		}
	}
	
	INFO("Done with test in %ld seconds.", time(NULL) - start);
}
