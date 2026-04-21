/*
 * libc_init.c — once-per-process runtime bootstrap and teardown.
 *
 * ntshim_init() captures PEB->ProcessHeap (malloc's backing heap),
 * seeds the clock() epoch, and wires stdio to any inherited stdio
 * handle (set by the kernel from Control\Init\Stdio). exit/abort are
 * here because they terminate the process — the counterpart to init.
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

    /* If the kernel handed us inherited stdio handles (via Control\Init\
     * Stdio → ZwCreateFile + OBJ_INHERIT + InheritHandles=TRUE), switch
     * the stdio FILEs off the DbgPrint fallback onto real NtReadFile/
     * NtWriteFile against those handles. */
    if (peb->ProcessParameters) {
        HANDLE in  = peb->ProcessParameters->StandardInput;
        HANDLE out = peb->ProcessParameters->StandardOutput;
        HANDLE err = peb->ProcessParameters->StandardError;
        if (in) {
            _libc_stdin.handle = in;
        }
        if (out) {
            _libc_stdout.handle = out;
            _libc_stdout.flags &= ~FFLAG_CONSOLE;
        }
        if (err) {
            _libc_stderr.handle = err;
            _libc_stderr.flags &= ~FFLAG_CONSOLE;
        }
    }
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
