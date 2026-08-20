/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef __SPRDWL_COMPAT_H__
#define __SPRDWL_COMPAT_H__

#include <linux/ktime.h>
#include <linux/timekeeping.h>
#include <linux/version.h>

#if KERNEL_VERSION(5, 6, 0) <= LINUX_VERSION_CODE
typedef struct timespec64 sprdwl_timespec;
#define sprdwl_get_time(ts) ktime_get_real_ts64(ts)
#define sprdwl_get_boottime(ts) ktime_get_boottime_ts64(ts)
#define sprdwl_time_to_ns(ts) timespec64_to_ns(ts)
#else
typedef struct timespec sprdwl_timespec;
#define sprdwl_get_time(ts) getnstimeofday(ts)
#define sprdwl_get_boottime(ts) get_monotonic_boottime(ts)
#define sprdwl_time_to_ns(ts) timespec_to_ns(ts)
#endif

#endif
