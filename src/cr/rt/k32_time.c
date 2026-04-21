/*
 * k32_time.c — Win32 time APIs + Sleep, backed by NtQuerySystemTime
 * and NtQueryPerformanceCounter. FILETIME and LARGE_INTEGER have the
 * same on-disk layout so we splat one onto the other.
 */

#include "k32_internal.h"

extern NTSTATUS NTAPI NtQuerySystemTime(PLARGE_INTEGER);
extern NTSTATUS NTAPI NtQueryPerformanceCounter(PLARGE_INTEGER, PLARGE_INTEGER);
extern NTSTATUS NTAPI NtDelayExecution(UCHAR Alertable, PLARGE_INTEGER);

void WINAPI GetSystemTimeAsFileTime(LPFILETIME ft)
{
    LARGE_INTEGER t;
    NtQuerySystemTime(&t);
    ft->dwLowDateTime  = t.LowPart;
    ft->dwHighDateTime = (DWORD)t.HighPart;
}

/* Real Win32 reads KUSER_SHARED_DATA for a pre-scaled tick count; our
 * minimal HAL doesn't populate that, so fall back to system time /
 * 10000 (100ns ticks → ms). Monotonic enough. */
DWORD WINAPI GetTickCount(void)
{
    LARGE_INTEGER t;
    long long     ns100;
    NtQuerySystemTime(&t);
    ns100 = ((long long)t.HighPart << 32) | t.LowPart;
    return (DWORD)((ns100 / 10000) & 0xFFFFFFFF);
}

BOOL WINAPI QueryPerformanceCounter(FILETIME *counter)
{
    LARGE_INTEGER t;
    NTSTATUS st = NtQueryPerformanceCounter(&t, 0);
    if (!NT_SUCCESS(st)) return FALSE;
    counter->dwLowDateTime  = t.LowPart;
    counter->dwHighDateTime = (DWORD)t.HighPart;
    return TRUE;
}

BOOL WINAPI QueryPerformanceFrequency(FILETIME *freq)
{
    LARGE_INTEGER dummy, f;
    NTSTATUS st = NtQueryPerformanceCounter(&dummy, &f);
    if (!NT_SUCCESS(st)) return FALSE;
    freq->dwLowDateTime  = f.LowPart;
    freq->dwHighDateTime = (DWORD)f.HighPart;
    return TRUE;
}

void WINAPI Sleep(DWORD ms)
{
    LARGE_INTEGER d;
    /* NtDelayExecution takes a negative 100ns relative interval. */
    long long ticks = -((long long)ms * 10000LL);
    d.LowPart  = (ULONG)(ticks & 0xFFFFFFFF);
    d.HighPart = (LONG)(ticks >> 32);
    NtDelayExecution(0, &d);
}
