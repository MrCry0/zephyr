/*
 * Copyright (c) 2017 Intel Corporation
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <ztest.h>
#include "test_sched.h"

#define NUM_THREAD 3

BUILD_ASSERT(NUM_THREAD <= MAX_NUM_THREAD);

/* slice size in millisecond*/
#define SLICE_SIZE 200
/* busy for more than one slice*/
#define BUSY_MS (SLICE_SIZE + 20)
/* a half timeslice*/
#define HALF_SLICE_SIZE (SLICE_SIZE >> 1)

K_SEM_DEFINE(sema, 0, NUM_THREAD);
/*elapsed_slice taken by last thread*/
static s64_t elapsed_slice;
static int thread_idx;

static void thread_tslice(void *p1, void *p2, void *p3)
{
	s64_t t = k_uptime_delta(&elapsed_slice);
	s64_t expected_slice_min, expected_slice_max;

	if (thread_idx == 0) {
		/*thread number 0 releases CPU after HALF_SLICE_SIZE*/
		expected_slice_min = HALF_SLICE_SIZE;
		expected_slice_max = HALF_SLICE_SIZE;
	} else {
		/*other threads are sliced with tick granulity*/
		expected_slice_min = __ticks_to_ms(z_ms_to_ticks(SLICE_SIZE));
		expected_slice_max = __ticks_to_ms(z_ms_to_ticks(SLICE_SIZE)+1);
	}

	#ifdef CONFIG_DEBUG
	TC_PRINT("thread[%d] elapsed slice: %lld, expected: <%lld, %lld>\n",
		thread_idx, t, expected_slice_min, expected_slice_max);
	#endif

	/** TESTPOINT: timeslice should be reset for each preemptive thread*/
#ifndef CONFIG_COVERAGE
	zassert_true(t >= expected_slice_min,
		     "timeslice too small, expected %u got %u",
		     expected_slice_min, t);
	zassert_true(t <= expected_slice_max,
		     "timeslice too big, expected %u got %u",
		     expected_slice_max, t);
#else
	(void)t;
#endif /* CONFIG_COVERAGE */
	thread_idx = (thread_idx + 1) % NUM_THREAD;

	/* Keep the current thread busy for more than one slice, even though,
	 * when timeslice used up the next thread should be scheduled in.
	 */
	spin_for_ms(BUSY_MS);
	k_sem_give(&sema);
}

/*test cases*/
/**
 * @brief Check the behavior of preemptive threads when the
 * time slice is disabled and enabled
 *
 * @details Create multiple preemptive threads with few different
 * priorities and few with same priorities and enable the time slice.
 * Ensure that each thread is given the time slice period to execute.
 *
 * @see k_sched_time_slice_set(), k_sem_reset(), k_uptime_delta(),
 * k_uptime_get_32()
 *
 * @ingroup kernel_sched_tests
 */
void test_slice_reset(void)
{
	u32_t t32;
	k_tid_t tid[NUM_THREAD];
	struct k_thread t[NUM_THREAD];
	int old_prio = k_thread_priority_get(k_current_get());

	thread_idx = 0;
	/*disable timeslice*/
	k_sched_time_slice_set(0, K_PRIO_PREEMPT(0));

	for (int j = 0; j < 2; j++) {
		k_sem_reset(&sema);
		/* update priority for current thread*/
		k_thread_priority_set(k_current_get(), K_PRIO_PREEMPT(j));
		/* create delayed threads with equal preemptive priority*/
		for (int i = 0; i < NUM_THREAD; i++) {
			tid[i] = k_thread_create(&t[i], tstacks[i], STACK_SIZE,
						 thread_tslice, NULL, NULL, NULL,
						 K_PRIO_PREEMPT(j), 0, 0);
		}
		/* enable time slice*/
		k_sched_time_slice_set(SLICE_SIZE, K_PRIO_PREEMPT(0));
		k_uptime_delta(&elapsed_slice);

		/* current thread (ztest native) consumed a half timeslice*/
		t32 = k_uptime_get_32();
		while (k_uptime_get_32() - t32 < HALF_SLICE_SIZE) {
#if defined(CONFIG_ARCH_POSIX)
			k_busy_wait(50);
#else
			;
#endif
		}

		/* relinquish CPU and wait for each thread to complete*/
		for (int i = 0; i < NUM_THREAD; i++) {
			k_sem_take(&sema, K_FOREVER);
		}

		/* test case teardown*/
		for (int i = 0; i < NUM_THREAD; i++) {
			k_thread_abort(tid[i]);
		}
		/* disable time slice*/
		k_sched_time_slice_set(0, K_PRIO_PREEMPT(0));
	}
	k_thread_priority_set(k_current_get(), old_prio);
}
