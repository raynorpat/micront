/*
 * libc_internal.h — shared internals across the libc_*.c translation units.
 *
 * Not exposed to consumers of the runtime. Consumers see only ntshim.h's
 * public CRT-shape surface.
 */

#ifndef RT_LIBC_INTERNAL_H
#define RT_LIBC_INTERNAL_H

#include "nt.h"
#include "ntshim.h"

/* ---------- FILE (needed by stdio + printf) -------------------------- */

#define FFLAG_READ     0x0001
#define FFLAG_WRITE    0x0002
#define FFLAG_APPEND   0x0004
#define FFLAG_EOF      0x0010
#define FFLAG_ERR      0x0020
#define FFLAG_CONSOLE  0x0040   /* writes route through DbgPrint */
#define FFLAG_STATIC   0x0080   /* don't free on fclose */

struct FILE {
    HANDLE        handle;
    ULONG         flags;
    LARGE_INTEGER pos;
};

extern struct FILE _libc_stdin;
extern struct FILE _libc_stdout;
extern struct FILE _libc_stderr;

/* ---------- Cross-module state --------------------------------------- */

/* Captured in ntshim_init from PEB->ProcessHeap. Read by libc_heap.c. */
extern HANDLE        _libc_heap;

/* clock() epoch — populated in ntshim_init; both libc_time.c and
 * libc_init.c touch them. */
extern LARGE_INTEGER _libc_clock_start;
extern LARGE_INTEGER _libc_clock_freq;

/* Process-wide errno slot — _errno() returns &this. */
extern int           _ntshim_errno;

/* ---------- ntdll surface the libc files share ----------------------- */

extern int    _vsnprintf(char *, size_t, const char *, va_list);
extern ULONG  DbgPrint(PCSTR, ...);
extern NTSTATUS NTAPI NtQuerySystemTime(PLARGE_INTEGER);
extern NTSTATUS NTAPI NtQueryPerformanceCounter(PLARGE_INTEGER, PLARGE_INTEGER);

#endif /* RT_LIBC_INTERNAL_H */
