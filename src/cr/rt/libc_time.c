/*
 * libc_time.c — time() and clock(), backed by NtQuerySystemTime and
 * (when HAL supports it) NtQueryPerformanceCounter.
 */

#include "libc_internal.h"

LARGE_INTEGER _libc_clock_start;
LARGE_INTEGER _libc_clock_freq;

/* NT system time is 100ns intervals since 1601-01-01; Unix epoch is
 * 11,644,473,600 seconds later. */
#define EPOCH_BIAS_SEC  11644473600LL

time_t time(time_t *tp)
{
    LARGE_INTEGER t;
    long long     ns100;
    long long     secs;
    NtQuerySystemTime(&t);
    ns100 = ((long long)t.HighPart << 32) | t.LowPart;
    secs  = ns100 / 10000000LL - EPOCH_BIAS_SEC;
    if (tp) *tp = (time_t)secs;
    return (time_t)secs;
}

clock_t clock(void)
{
    LARGE_INTEGER now;
    long long delta;
    long long freq;
    /* MicroNT's custom HAL stubs out NtQueryPerformanceCounter (it's an
     * HAL primitive in NT 3.5) so freq comes back 0. Fall back to
     * NtQuerySystemTime in 100ns ticks — millisecond-ish precision. */
    freq = ((long long)_libc_clock_freq.HighPart << 32) | _libc_clock_freq.LowPart;
    if (freq == 0) {
        LARGE_INTEGER t;
        NtQuerySystemTime(&t);
        delta = (((long long)t.HighPart << 32) | t.LowPart)
              - (((long long)_libc_clock_start.HighPart << 32) | _libc_clock_start.LowPart);
        /* 100ns ticks → µs: divide by 10 (CLOCKS_PER_SEC is 1e6). */
        return (clock_t)(delta / 10);
    }
    NtQueryPerformanceCounter(&now, 0);
    delta = (((long long)now.HighPart << 32) | now.LowPart)
          - (((long long)_libc_clock_start.HighPart << 32) | _libc_clock_start.LowPart);
    return (clock_t)((delta * CLOCKS_PER_SEC) / freq);
}
