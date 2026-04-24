/*
 * k32_memory.c — Virtual* allocator + Tls* slots.
 *
 * Virtual* wraps Nt{Allocate,Free,Protect,Query}VirtualMemory.
 * Tls* uses a process-global slot array — fine while LuaJIT is
 * single-threaded; promoting to real TEB slots is a small change when
 * we grow multi-threaded.
 */

#include "k32_internal.h"

extern NTSTATUS NTAPI NtAllocateVirtualMemory(HANDLE ProcessHandle,
                                              PVOID *BaseAddress,
                                              ULONG ZeroBits,
                                              PSIZE_T RegionSize,
                                              ULONG AllocationType,
                                              ULONG Protect);
extern NTSTATUS NTAPI NtFreeVirtualMemory(HANDLE ProcessHandle,
                                          PVOID *BaseAddress,
                                          PSIZE_T RegionSize,
                                          ULONG FreeType);
extern NTSTATUS NTAPI NtProtectVirtualMemory(HANDLE ProcessHandle,
                                             PVOID *BaseAddress,
                                             PSIZE_T RegionSize,
                                             ULONG NewProtect,
                                             PULONG OldProtect);
extern NTSTATUS NTAPI NtQueryVirtualMemory(HANDLE ProcessHandle,
                                           PVOID BaseAddress,
                                           ULONG InformationClass,
                                           PVOID Buffer,
                                           SIZE_T Length,
                                           PSIZE_T ReturnLength);

LPVOID WINAPI VirtualAlloc(LPVOID addr, SIZE_T size, DWORD type, DWORD prot)
{
    PVOID  base = addr;
    SIZE_T rsize = size;
    NTSTATUS st = NtAllocateVirtualMemory(NT_CURRENT_PROCESS,
                                          &base, 0, &rsize, type, prot);
    if (!NT_SUCCESS(st)) { SetLastError(8 /* ERROR_NOT_ENOUGH_MEMORY */); return 0; }
    return base;
}

BOOL WINAPI VirtualFree(LPVOID addr, SIZE_T size, DWORD type)
{
    PVOID  base = addr;
    SIZE_T rsize = size;
    NTSTATUS st = NtFreeVirtualMemory(NT_CURRENT_PROCESS, &base, &rsize, type);
    if (!NT_SUCCESS(st)) { SetLastError(487 /* ERROR_INVALID_ADDRESS */); return FALSE; }
    return TRUE;
}

BOOL WINAPI VirtualProtect(LPVOID addr, SIZE_T size, DWORD newp, LPDWORD oldp)
{
    PVOID  base = addr;
    SIZE_T rsize = size;
    ULONG  old = 0;
    NTSTATUS st = NtProtectVirtualMemory(NT_CURRENT_PROCESS,
                                         &base, &rsize, newp, &old);
    if (!NT_SUCCESS(st)) { SetLastError(487); return FALSE; }
    if (oldp) *oldp = old;
    return TRUE;
}

SIZE_T WINAPI VirtualQuery(LPCVOID addr, PMEMORY_BASIC_INFORMATION buf,
                           SIZE_T buflen)
{
    SIZE_T returned = 0;
    NTSTATUS st = NtQueryVirtualMemory(NT_CURRENT_PROCESS, (PVOID)addr,
                                       0 /* MemoryBasicInformation */,
                                       buf, buflen, &returned);
    if (!NT_SUCCESS(st)) { SetLastError(487); return 0; }
    return returned;
}

/* ---------- TLS ------------------------------------------------------ */
/*
 * Allocation bitmap is process-global (TlsAlloc must hand out unique
 * indices across all threads); per-thread slot storage lives in the
 * TEB at +0xE10, directly indexed via fs:. Kernel zeroes the slot
 * array on thread creation, so TlsGetValue returns NULL for a
 * freshly-allocated index without init work on our side.
 *
 * We don't coordinate with PEB.TlsBitmap: on NT 3.5, ntdll itself
 * doesn't call TlsAlloc (TlsAlloc is a kernel32 function we're
 * implementing), so a local bitmap is sufficient. If a future consumer
 * needs to coexist with system-allocated slots, initialise this bitmap
 * from PEB.TlsBitmapBits[] at startup.
 */

static UCHAR g_tls_used[TEB_TLS_SLOT_COUNT];

DWORD WINAPI TlsAlloc(void)
{
    int i;
    for (i = 0; i < TEB_TLS_SLOT_COUNT; i++) {
        if (!g_tls_used[i]) {
            g_tls_used[i] = 1;
            _k32_tls_set((unsigned)i, 0);    /* clear our thread's slot */
            return (DWORD)i;
        }
    }
    return TLS_OUT_OF_INDEXES;
}

/* Per MSDN: TlsFree doesn't clear slots in other threads. Our thread's
 * slot is cleared; other threads keep their stale values until the
 * index is reallocated (at which point readers should be expecting
 * a NULL from the fresh allocation anyway). */
BOOL WINAPI TlsFree(DWORD idx)
{
    if (idx >= TEB_TLS_SLOT_COUNT || !g_tls_used[idx]) return FALSE;
    g_tls_used[idx] = 0;
    _k32_tls_set(idx, 0);
    return TRUE;
}

LPVOID WINAPI TlsGetValue(DWORD idx)
{
    if (idx >= TEB_TLS_SLOT_COUNT) { SetLastError(87); return 0; }
    SetLastError(0);
    return _k32_tls_get(idx);
}

BOOL WINAPI TlsSetValue(DWORD idx, LPVOID v)
{
    if (idx >= TEB_TLS_SLOT_COUNT) { SetLastError(87); return FALSE; }
    _k32_tls_set(idx, v);
    return TRUE;
}
