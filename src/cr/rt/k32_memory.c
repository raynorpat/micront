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

#define MAX_TLS 64
static void *g_tls[MAX_TLS];
static UCHAR g_tls_used[MAX_TLS];

DWORD WINAPI TlsAlloc(void)
{
    int i;
    for (i = 0; i < MAX_TLS; i++) {
        if (!g_tls_used[i]) {
            g_tls_used[i] = 1;
            g_tls[i] = 0;
            return (DWORD)i;
        }
    }
    return TLS_OUT_OF_INDEXES;
}

BOOL WINAPI TlsFree(DWORD idx)
{
    if (idx >= MAX_TLS || !g_tls_used[idx]) return FALSE;
    g_tls_used[idx] = 0; g_tls[idx] = 0;
    return TRUE;
}

LPVOID WINAPI TlsGetValue(DWORD idx)
{
    if (idx >= MAX_TLS) { SetLastError(87); return 0; }
    SetLastError(0);
    return g_tls[idx];
}

BOOL WINAPI TlsSetValue(DWORD idx, LPVOID v)
{
    if (idx >= MAX_TLS) { SetLastError(87); return FALSE; }
    g_tls[idx] = v;
    return TRUE;
}
