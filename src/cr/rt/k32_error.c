/*
 * k32_error.c — Win32 last-error storage + FormatMessageA +
 * GetModuleFileNameA. All three sit at the "error / diagnostics"
 * corner of the Win32 surface.
 *
 * LastError is a process-global here (NT stores it in TEB+0x34);
 * single-threaded safe, trivially promotable to TEB-backed when we
 * add threads.
 */

#include "k32_internal.h"

/* ntdll walking not needed here; GetModuleFileNameA walks PEB->Ldr. */

static DWORD g_last_error = 0;

DWORD WINAPI GetLastError(void)       { return g_last_error; }
void  WINAPI SetLastError(DWORD err)  { g_last_error = err; }

/* FormatMessageA — LuaJIT's package loader uses this to turn error
 * codes into human-readable strings. Real impl walks per-DLL per-locale
 * message-table resources. Ours substitutes a fixed "error 0x%X" so
 * callers get something non-empty to display. */
DWORD WINAPI FormatMessageA(DWORD flags, LPCVOID source, DWORD msgId,
                            DWORD lang, LPSTR buf, DWORD size, void *args)
{
    static const char prefix[] = "error 0x";
    DWORD n = 0;
    int shift;
    (void)flags; (void)source; (void)lang; (void)args;
    if (!buf || size < sizeof(prefix) + 9) return 0;
    for (n = 0; n < sizeof(prefix) - 1; n++) buf[n] = prefix[n];
    for (shift = 28; shift >= 0; shift -= 4) {
        int d = (int)((msgId >> shift) & 0xF);
        buf[n++] = (char)(d < 10 ? '0' + d : 'A' + d - 10);
    }
    buf[n] = 0;
    return n;
}

/* GetModuleFileNameA — walk PEB->Ldr, match DllBase, copy the module's
 * FullDllName UTF-16 → ASCII. NULL mod = the exe (first list entry). */
DWORD WINAPI GetModuleFileNameA(HMODULE mod, LPSTR buf, DWORD size)
{
    PPEB_LDR_DATA ldr = nt_peb()->Ldr;
    PLIST_ENTRY head, cur;
    PLDR_DATA_TABLE_ENTRY e = 0;
    DWORD i, n;

    if (!ldr || !buf || size == 0) return 0;
    head = &ldr->InLoadOrderModuleList;
    if (!mod) {
        e = (PLDR_DATA_TABLE_ENTRY)head->Flink;   /* first entry = exe */
    } else {
        for (cur = head->Flink; cur != head; cur = cur->Flink) {
            PLDR_DATA_TABLE_ENTRY ce = (PLDR_DATA_TABLE_ENTRY)cur;
            if (ce->DllBase == (PVOID)mod) { e = ce; break; }
        }
    }
    if (!e || !e->FullDllName.Buffer) { SetLastError(126); return 0; }

    n = (DWORD)(e->FullDllName.Length / 2);   /* UNICODE_STRING Length is bytes */
    if (n >= size) n = size - 1;
    for (i = 0; i < n; i++) buf[i] = (char)e->FullDllName.Buffer[i];
    buf[n] = 0;
    return n;
}
