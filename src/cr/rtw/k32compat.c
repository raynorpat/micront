/*
 * k32compat.c — kernel32 functions added in NT 4+ that we provide
 * locally so runc.exe / runw.exe load on NT 3.5.
 *
 * mingw-w64's kernel32.lib is built against modern Windows; LuaJIT (and
 * librt's CRT helpers) call functions that mingw resolves to kernel32
 * imports. NT 3.5's kernel32.dll doesn't export the post-3.5 additions,
 * so the loader fails with STATUS_ENTRYPOINT_NOT_FOUND when it walks
 * our IAT.
 *
 * Defining them statically here makes the linker prefer our local
 * symbols over kernel32 imports — the failed imports never appear in
 * the PE import table at all, and the loader is happy. Each function
 * here mirrors the behaviour of the matching one in librt's k32_*.c
 * (used by native run.exe), implemented against ntdll only.
 *
 * Add a stub to this file when:
 *   - rebuilding shows a "STATUS_ENTRYPOINT_NOT_FOUND" boot error
 *     naming a kernel32 function, AND
 *   - that function exists in librt's k32_*.c (proves it's
 *     implementable on top of ntdll alone).
 */

#include "nt.h"
#include "kernel32.h"

extern NTSTATUS NTAPI NtQuerySystemTime(PLARGE_INTEGER);

/* GetSystemTimeAsFileTime — added in NT 4. Splat NtQuerySystemTime's
 * LARGE_INTEGER straight into FILETIME (same on-disk layout). */
void WINAPI GetSystemTimeAsFileTime(LPFILETIME ft)
{
    LARGE_INTEGER t;
    NtQuerySystemTime(&t);
    ft->dwLowDateTime  = t.LowPart;
    ft->dwHighDateTime = (DWORD)t.HighPart;
}

/* mingw-w64's kernel32.lib provides BOTH `_FuncName@N` (the import
 * stub function) and `__imp__FuncName@N` (the IAT indirection slot
 * for dllimport-decorated calls). Our static def above replaces the
 * stub, but LuaJIT calls these with `__declspec(dllimport)` which
 * goes through the `__imp__*` indirection — not satisfied by the
 * stub override alone. So we also emit the IAT slots ourselves,
 * pointing at our impls. With both symbols local, the linker drops
 * the kernel32 imports entirely from runc/runw's PE IAT and the
 * NT 3.5 loader stops failing. */
asm(".section .data, \"dw\"\n"
    ".globl  __imp__GetSystemTimeAsFileTime@4\n"
    "__imp__GetSystemTimeAsFileTime@4: .long _GetSystemTimeAsFileTime@4\n"
    ".globl  __imp__GetModuleHandleExA@12\n"
    "__imp__GetModuleHandleExA@12: .long _GetModuleHandleExA@12\n");

/* GetModuleHandleExA — added in NT 4. We only support two of the
 * documented flag combinations here: the NULL-name case (returns the
 * EXE base — first PEB->Ldr entry), and FROM_ADDRESS treated as
 * NULL-name (LuaJIT only uses FROM_ADDRESS to find the module
 * containing its own .text, which equals the EXE for our static
 * link). UNCHANGED_REFCOUNT is a no-op since we don't refcount.
 * Anything else returns FALSE. Mirrors librt/k32_loader.c. */
BOOL WINAPI GetModuleHandleExA(DWORD flags, LPCSTR name, HMODULE *out)
{
    PPEB_LDR_DATA ldr = nt_peb()->Ldr;
    PLIST_ENTRY head;
    PLDR_DATA_TABLE_ENTRY exe;

    if (!out) { SetLastError(87 /* ERROR_INVALID_PARAMETER */); return FALSE; }
    if (!ldr) { SetLastError(126 /* ERROR_MOD_NOT_FOUND */);    return FALSE; }

    head = &ldr->InLoadOrderModuleList;
    /* FROM_ADDRESS → return the EXE; treat NULL-name the same way. */
    if (!name || (flags & GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS)) {
        exe  = (PLDR_DATA_TABLE_ENTRY)head->Flink;
        *out = (HMODULE)exe->DllBase;
        return TRUE;
    }
    /* Named lookup: defer to GetModuleHandleA (kernel32-provided on
     * NT 3.5; only the Ex form is missing). */
    *out = GetModuleHandleA(name);
    return *out ? TRUE : FALSE;
}
