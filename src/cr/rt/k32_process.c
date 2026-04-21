/*
 * k32_process.c — ExitProcess + GetCurrent* + RaiseException.
 *
 * Pseudo-handles for GetCurrentProcess/Thread follow the Win32
 * convention (-1 / -2). ExitProcess routes to NtTerminateProcess with
 * a spin-forever guard in case NtTerminateProcess returns.
 * RaiseException packages its arguments into an EXCEPTION_RECORD and
 * forwards to RtlRaiseException — LuaJIT's longjmp-based error path
 * matches on ExceptionCode only.
 */

#include "k32_internal.h"

extern NTSTATUS NTAPI NtTerminateProcess(HANDLE, NTSTATUS);

HANDLE WINAPI GetCurrentProcess(void) { return (HANDLE)(long)-1; }
HANDLE WINAPI GetCurrentThread (void) { return (HANDLE)(long)-2; }
DWORD  WINAPI GetCurrentProcessId(void) { return 0; }   /* TODO: TEB ClientId */
DWORD  WINAPI GetCurrentThreadId(void)  { return 0; }

void WINAPI ExitProcess(DWORD code)
{
    NtTerminateProcess(NT_CURRENT_PROCESS, (NTSTATUS)code);
    for (;;) { }
}

/* ---------- RaiseException ------------------------------------------ */

typedef struct _EXCEPTION_RECORD {
    DWORD                     ExceptionCode;
    DWORD                     ExceptionFlags;
    struct _EXCEPTION_RECORD *ExceptionRecord;
    PVOID                     ExceptionAddress;
    DWORD                     NumberParameters;
    ULONG                     ExceptionInformation[15];
} EXCEPTION_RECORD;

extern void NTAPI RtlRaiseException(EXCEPTION_RECORD *);

void WINAPI RaiseException(DWORD code, DWORD flags,
                           DWORD argc, const unsigned long *argv)
{
    EXCEPTION_RECORD er;
    DWORD i;
    er.ExceptionCode    = code;
    er.ExceptionFlags   = flags;
    er.ExceptionRecord  = 0;
    er.ExceptionAddress = 0;
    er.NumberParameters = argc > 15 ? 15 : argc;
    for (i = 0; i < er.NumberParameters && argv; i++)
        er.ExceptionInformation[i] = argv[i];
    RtlRaiseException(&er);
}
