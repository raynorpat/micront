/*
 * k32_loader.c — LoadLibrary / FreeLibrary / GetProcAddress /
 * GetModuleHandle, all thin wrappers around ntdll's Ldr* surface.
 *
 * GetModuleHandleA walks PEB->Ldr matching on base-name; ASCII-only
 * case-insensitive comparison is fine for the "KERNEL32.DLL" /
 * "kernel32.dll" cases real consumers pass.
 */

#include "k32_internal.h"

extern NTSTATUS NTAPI LdrLoadDll(PCWSTR SearchPath, PULONG DllCharacteristics,
                                 PUNICODE_STRING DllName, HANDLE *DllHandle);
extern NTSTATUS NTAPI LdrUnloadDll(HANDLE DllHandle);
extern NTSTATUS NTAPI LdrGetProcedureAddress(HANDLE DllHandle,
                                             PANSI_STRING Name,
                                             ULONG Ordinal, PVOID *Address);
extern void NTAPI RtlInitUnicodeString(PUNICODE_STRING, PCWSTR);
extern void NTAPI RtlInitAnsiString   (PANSI_STRING, const char *);

HMODULE WINAPI LoadLibraryA(LPCSTR name)
{
    return LoadLibraryExA(name, 0, 0);
}

HMODULE WINAPI LoadLibraryExA(LPCSTR name, HANDLE file, DWORD flags)
{
    unsigned short wname[260];
    UNICODE_STRING us;
    HANDLE h = 0;
    NTSTATUS st;
    (void)file; (void)flags;
    if (!name) { SetLastError(87 /* ERROR_INVALID_PARAMETER */); return 0; }

    _k32_ascii_to_wide(name, wname, sizeof(wname)/sizeof(wname[0]));
    RtlInitUnicodeString(&us, wname);

    st = LdrLoadDll(0, 0, &us, &h);
    if (!NT_SUCCESS(st)) { SetLastError(126 /* ERROR_MOD_NOT_FOUND */); return 0; }
    return (HMODULE)h;
}

BOOL WINAPI FreeLibrary(HMODULE h)
{
    NTSTATUS st = LdrUnloadDll((HANDLE)h);
    if (!NT_SUCCESS(st)) { SetLastError(87); return FALSE; }
    return TRUE;
}

PVOID WINAPI GetProcAddress(HMODULE h, LPCSTR name)
{
    ANSI_STRING as;
    PVOID p = 0;
    NTSTATUS st;
    /* Pure-ordinal lookups aren't used by LuaJIT — name is always a string. */
    if (!name) { SetLastError(127 /* ERROR_PROC_NOT_FOUND */); return 0; }
    RtlInitAnsiString(&as, name);
    st = LdrGetProcedureAddress((HANDLE)h, &as, 0, &p);
    if (!NT_SUCCESS(st) || !p) { SetLastError(127); return 0; }
    return p;
}

HMODULE WINAPI GetModuleHandleA(LPCSTR name)
{
    PPEB_LDR_DATA ldr = nt_peb()->Ldr;
    PLIST_ENTRY head, cur;
    unsigned short wname[260];

    if (!ldr) { SetLastError(126); return 0; }
    head = &ldr->InLoadOrderModuleList;
    if (!name) {
        /* EXE is the first InLoadOrder entry. */
        PLDR_DATA_TABLE_ENTRY e = (PLDR_DATA_TABLE_ENTRY)head->Flink;
        return (HMODULE)e->DllBase;
    }
    _k32_ascii_to_wide(name, wname, sizeof(wname)/sizeof(wname[0]));
    for (cur = head->Flink; cur != head; cur = cur->Flink) {
        PLDR_DATA_TABLE_ENTRY e = (PLDR_DATA_TABLE_ENTRY)cur;
        if (e->BaseDllName.Buffer &&
            _k32_wcsicmp_ascii(e->BaseDllName.Buffer, wname) == 0)
            return (HMODULE)e->DllBase;
    }
    SetLastError(126);
    return 0;
}

BOOL WINAPI GetModuleHandleExA(DWORD flags, LPCSTR name, HMODULE *out)
{
    (void)flags;
    if (!out) { SetLastError(87); return FALSE; }
    /* UNCHANGED_REFCOUNT — no-op; we don't refcount bases.
     * FROM_ADDRESS — LuaJIT only uses this to find the module containing
     * its own .text, which equals the exe, so treat it as NULL-name. */
    if (flags & GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS) {
        *out = GetModuleHandleA(0);
        return *out ? TRUE : FALSE;
    }
    *out = GetModuleHandleA(name);
    return *out ? TRUE : FALSE;
}
