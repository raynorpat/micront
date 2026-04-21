/*
 * libc_init.c — once-per-process runtime bootstrap and teardown.
 *
 * ntshim_init() captures PEB->ProcessHeap (malloc's backing heap) and
 * seeds the clock() epoch. exit/abort are here because they terminate
 * the process — the counterpart to init.
 */

#include "libc_internal.h"

extern NTSTATUS NTAPI NtTerminateProcess(HANDLE, NTSTATUS);

void ntshim_init(void)
{
    PPEB peb = nt_peb();
    _libc_heap = peb->ProcessHeap;

    NtQueryPerformanceCounter(&_libc_clock_start, &_libc_clock_freq);
    /* Perf counter absent on MicroNT's custom HAL — fall back to system
     * time as the clock() epoch so monotonic deltas still work. */
    if (_libc_clock_freq.HighPart == 0 && _libc_clock_freq.LowPart == 0)
        NtQuerySystemTime(&_libc_clock_start);
}

void exit(int status)
{
    NtTerminateProcess(NT_CURRENT_PROCESS, (NTSTATUS)status);
    for (;;) { }
}

void abort(void)
{
    __asm__ volatile("int3");
    NtTerminateProcess(NT_CURRENT_PROCESS, (NTSTATUS)0xC0000005);
    for (;;) { }
}
