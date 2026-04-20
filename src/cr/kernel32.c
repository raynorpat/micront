/*
 * kernel32.c — Win32 API shim on ntdll, scoped to the LuaJIT surface.
 *
 * Everything here is a thin wrapper around an ntdll primitive. The
 * kernel32 ↔ ntdll mapping is pretty mechanical:
 *
 *   LoadLibrary*        ↔ LdrLoadDll
 *   FreeLibrary         ↔ LdrUnloadDll
 *   GetProcAddress      ↔ LdrGetProcedureAddress
 *   GetModuleHandle*    ↔ walk PEB->Ldr
 *   Get/SetLastError    ↔ global (will promote to TEB+0x34 when MT)
 *   VirtualAlloc/Free   ↔ Nt{Allocate,Free}VirtualMemory
 *   VirtualProtect      ↔ NtProtectVirtualMemory
 *   Tls*                ↔ global bitmap + array (see threading note)
 *   *CriticalSection    ↔ Rtl*CriticalSection (ntdll exports these)
 *   GetTickCount        ↔ NtQuerySystemTime
 *   Sleep               ↔ NtDelayExecution
 *   GetCurrent{Proc,Thr}↔ pseudo-handles (-1, -2)
 *   ExitProcess         ↔ NtTerminateProcess
 */

#include "kernel32.h"

/* ---------- Internal NT types ---------------------------------------- */

typedef long              NTSTATUS;
typedef unsigned char     UCHAR;
typedef unsigned short    USHORT;
typedef unsigned long     ULONG;
typedef long              LONG;
typedef ULONG            *PULONG;
typedef unsigned short   *PWSTR;
typedef const unsigned short *PCWSTR;

#define NTAPI             __attribute__((stdcall))
#define STATUS_SUCCESS    ((NTSTATUS)0x00000000L)
#define NT_SUCCESS(s)     ((s) >= 0)

typedef struct _UNICODE_STRING {
    USHORT Length, MaximumLength;
    PWSTR  Buffer;
} UNICODE_STRING, *PUNICODE_STRING;

typedef struct _ANSI_STRING {
    USHORT Length, MaximumLength;
    char  *Buffer;
} ANSI_STRING, *PANSI_STRING;

typedef struct _LARGE_INTEGER {
    ULONG LowPart;
    LONG  HighPart;
} LARGE_INTEGER, *PLARGE_INTEGER;

#define NT_CURRENT_PROCESS  ((HANDLE)(long)-1)

/* PEB — see project_nt35_struct_packing memory: NT 3.5 is pack(2). */
#pragma pack(push, 2)
typedef struct _LIST_ENTRY {
    struct _LIST_ENTRY *Flink, *Blink;
} LIST_ENTRY, *PLIST_ENTRY;

typedef struct _PEB_LDR_DATA {
    ULONG Length;
    UCHAR Initialized;
    HANDLE SsHandle;
    LIST_ENTRY InLoadOrderModuleList;
    LIST_ENTRY InMemoryOrderModuleList;
    LIST_ENTRY InInitializationOrderModuleList;
} PEB_LDR_DATA, *PPEB_LDR_DATA;

typedef struct _LDR_DATA_TABLE_ENTRY {
    LIST_ENTRY InLoadOrderLinks;
    LIST_ENTRY InMemoryOrderLinks;
    LIST_ENTRY InInitializationOrderLinks;
    PVOID      DllBase;
    PVOID      EntryPoint;
    ULONG      SizeOfImage;
    UNICODE_STRING FullDllName;
    UNICODE_STRING BaseDllName;
    /* more fields we don't touch */
} LDR_DATA_TABLE_ENTRY, *PLDR_DATA_TABLE_ENTRY;

typedef struct _PEB {
    UCHAR  InheritedAddressSpace;    /* +0x00 */
    HANDLE Mutant;                   /* +0x02 */
    PVOID  ImageBaseAddress;         /* +0x06 */
    PPEB_LDR_DATA Ldr;               /* +0x0A */
    PVOID  ProcessParameters;        /* +0x0E */
    PVOID  SubSystemData;            /* +0x12 */
    PVOID  ProcessHeap;              /* +0x16 */
} PEB, *PPEB;
#pragma pack(pop)

/* ---------- ntdll prototypes we call --------------------------------- */

extern NTSTATUS NTAPI LdrLoadDll(PCWSTR SearchPath, PULONG DllCharacteristics,
                                 PUNICODE_STRING DllName, HANDLE *DllHandle);
extern NTSTATUS NTAPI LdrUnloadDll(HANDLE DllHandle);
extern NTSTATUS NTAPI LdrGetProcedureAddress(HANDLE DllHandle,
                                             PANSI_STRING Name,
                                             ULONG Ordinal, PVOID *Address);

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

extern NTSTATUS NTAPI NtQuerySystemTime(PLARGE_INTEGER);
extern NTSTATUS NTAPI NtQueryPerformanceCounter(PLARGE_INTEGER, PLARGE_INTEGER);
extern NTSTATUS NTAPI NtDelayExecution(UCHAR Alertable, PLARGE_INTEGER);
extern NTSTATUS NTAPI NtTerminateProcess(HANDLE, NTSTATUS);

extern void NTAPI RtlInitUnicodeString(PUNICODE_STRING, PCWSTR);
extern void NTAPI RtlInitAnsiString   (PANSI_STRING, const char *);
extern void NTAPI RtlInitializeCriticalSection(void *);
extern void NTAPI RtlEnterCriticalSection      (void *);
extern void NTAPI RtlLeaveCriticalSection      (void *);
extern void NTAPI RtlDeleteCriticalSection     (void *);

/* Tiny locals we need — avoid pulling in ntshim.h. */
static size_t _k32_strlen(const char *s) { size_t n=0; while (s[n]) n++; return n; }

/* ---------- PEB / TEB access ---------------------------------------- */

static PPEB _peb(void)
{
    PPEB p;
    __asm__ volatile ("movl %%fs:0x30, %0" : "=r"(p));
    return p;
}

/* ---------- Last error ---------------------------------------------- */
/* Threading note: real Win32 stores this in TEB+0x34 (LastErrorValue).
 * We use a process-global for now — LuaJIT is single-threaded unless
 * a user script explicitly creates threads via FFI. Promoting this to
 * __readfsdword(0x34) is a 2-line change when we add MT. */
static DWORD g_last_error = 0;

DWORD WINAPI GetLastError(void)          { return g_last_error; }
void  WINAPI SetLastError(DWORD err)     { g_last_error = err; }

/* ---------- DLL loading --------------------------------------------- */

/* ASCII → UTF-16 in-place into caller-provided buffer. Good enough for
 * DLL names — no MBCS, no locale. */
static void _ascii_to_wide(const char *s, unsigned short *out, size_t cap)
{
    size_t i = 0, n = _k32_strlen(s);
    if (n >= cap) n = cap - 1;
    for (; i < n; i++) out[i] = (unsigned short)(unsigned char)s[i];
    out[n] = 0;
}

/* Case-insensitive wide-string compare (ASCII only — sufficient for
 * module base-name matching like "KERNEL32.DLL" vs "kernel32.dll"). */
static int _wcsicmp_ascii(const unsigned short *a, const unsigned short *b)
{
    for (;;) {
        unsigned short ca = *a++, cb = *b++;
        if (ca >= 'A' && ca <= 'Z') ca += 32;
        if (cb >= 'A' && cb <= 'Z') cb += 32;
        if (ca != cb) return (int)ca - (int)cb;
        if (!ca) return 0;
    }
}

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

    _ascii_to_wide(name, wname, sizeof(wname)/sizeof(wname[0]));
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
    /* If name is a pure-ordinal reference, LuaJIT won't use it —
     * skip the heuristic entirely. */
    if (!name) { SetLastError(127 /* ERROR_PROC_NOT_FOUND */); return 0; }
    RtlInitAnsiString(&as, name);
    st = LdrGetProcedureAddress((HANDLE)h, &as, 0, &p);
    if (!NT_SUCCESS(st) || !p) { SetLastError(127); return 0; }
    return p;
}

/* GetModuleHandle: walks the loader's InLoadOrder module list and
 * matches on base filename (case-insensitive). NULL name → the exe
 * itself (first entry). No path canonicalization; LuaJIT only passes
 * bare names here. */
HMODULE WINAPI GetModuleHandleA(LPCSTR name)
{
    PPEB_LDR_DATA ldr = _peb()->Ldr;
    PLIST_ENTRY head, cur;
    unsigned short wname[260];

    if (!ldr) { SetLastError(126); return 0; }
    head = &ldr->InLoadOrderModuleList;
    if (!name) {
        /* EXE is the first InLoadOrder entry. */
        PLDR_DATA_TABLE_ENTRY e = (PLDR_DATA_TABLE_ENTRY)head->Flink;
        return (HMODULE)e->DllBase;
    }
    _ascii_to_wide(name, wname, sizeof(wname)/sizeof(wname[0]));
    for (cur = head->Flink; cur != head; cur = cur->Flink) {
        PLDR_DATA_TABLE_ENTRY e = (PLDR_DATA_TABLE_ENTRY)cur;
        if (e->BaseDllName.Buffer &&
            _wcsicmp_ascii(e->BaseDllName.Buffer, wname) == 0)
            return (HMODULE)e->DllBase;
    }
    SetLastError(126);
    return 0;
}

BOOL WINAPI GetModuleHandleExA(DWORD flags, LPCSTR name, HMODULE *out)
{
    (void)flags;
    if (!out) { SetLastError(87); return FALSE; }
    /* UNCHANGED_REFCOUNT semantics — no-op for us, since we don't
     * refcount bases. FROM_ADDRESS would require scanning the module
     * list with SizeOfImage; LuaJIT only uses it to find the module
     * containing its own .text, which equals "the exe", so we special-
     * case NULL-name below and fall back to the first module entry. */
    if (flags & GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS) {
        /* name is actually a void* address. Treat as "the exe". */
        *out = GetModuleHandleA(0);
        return *out ? TRUE : FALSE;
    }
    *out = GetModuleHandleA(name);
    return *out ? TRUE : FALSE;
}

/* ---------- Virtual memory ------------------------------------------ */

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

/* VirtualQuery — lj_alloc.c uses this to sanity-check reservations
 * against existing allocations. NtQueryVirtualMemory(MemoryBasicInformation)
 * returns the same MEMORY_BASIC_INFORMATION layout, so pass-through. */
extern NTSTATUS NTAPI NtQueryVirtualMemory(HANDLE ProcessHandle,
                                           PVOID BaseAddress,
                                           ULONG InformationClass,
                                           PVOID Buffer,
                                           SIZE_T Length,
                                           PSIZE_T ReturnLength);

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

/* RaiseException — lj_err.c uses this to raise Lua errors up to a
 * handler frame. NT ntdll exports RtlRaiseException with a different
 * signature (takes EXCEPTION_RECORD); here we package the args and
 * forward. LuaJIT's handler matches on ExceptionCode only. */
typedef struct _EXCEPTION_RECORD {
    DWORD    ExceptionCode;
    DWORD    ExceptionFlags;
    struct _EXCEPTION_RECORD *ExceptionRecord;
    PVOID    ExceptionAddress;
    DWORD    NumberParameters;
    ULONG    ExceptionInformation[15];
} EXCEPTION_RECORD;

extern void NTAPI RtlRaiseException(EXCEPTION_RECORD *);

void WINAPI RaiseException(DWORD code, DWORD flags,
                           DWORD argc, const unsigned long *argv)
{
    EXCEPTION_RECORD er;
    DWORD i;
    er.ExceptionCode      = code;
    er.ExceptionFlags     = flags;
    er.ExceptionRecord    = 0;
    er.ExceptionAddress   = 0;
    er.NumberParameters   = argc > 15 ? 15 : argc;
    for (i = 0; i < er.NumberParameters && argv; i++)
        er.ExceptionInformation[i] = argv[i];
    RtlRaiseException(&er);
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

/* ---------- TLS ------------------------------------------------------ */
/* Threading note: process-global slots, not per-thread. Fine for
 * single-threaded LuaJIT. Each lua_State that calls TlsSetValue
 * stomps every other state — but there's only one state to stomp. */

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

BOOL   WINAPI TlsFree(DWORD idx)
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

BOOL   WINAPI TlsSetValue(DWORD idx, LPVOID v)
{
    if (idx >= MAX_TLS) { SetLastError(87); return FALSE; }
    g_tls[idx] = v;
    return TRUE;
}

/* ---------- Critical sections --------------------------------------- */

void WINAPI InitializeCriticalSection(LPCRITICAL_SECTION cs) { RtlInitializeCriticalSection(cs); }
void WINAPI EnterCriticalSection     (LPCRITICAL_SECTION cs) { RtlEnterCriticalSection(cs); }
void WINAPI LeaveCriticalSection     (LPCRITICAL_SECTION cs) { RtlLeaveCriticalSection(cs); }
void WINAPI DeleteCriticalSection    (LPCRITICAL_SECTION cs) { RtlDeleteCriticalSection(cs); }

/* ---------- Time / sleep -------------------------------------------- */

void WINAPI GetSystemTimeAsFileTime(LPFILETIME ft)
{
    LARGE_INTEGER t;
    NtQuerySystemTime(&t);
    ft->dwLowDateTime  = t.LowPart;
    ft->dwHighDateTime = (DWORD)t.HighPart;
}

/* GetTickCount: ms since some epoch. NT normally has KUSER_SHARED_DATA
 * with a pre-scaled tick count, but we may not have that; fall back to
 * NtQuerySystemTime / 10000 (100ns ticks → ms). Monotonic enough. */
DWORD WINAPI GetTickCount(void)
{
    LARGE_INTEGER t;
    long long ns100;
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

/* ---------- Process / thread ---------------------------------------- */

HANDLE WINAPI GetCurrentProcess(void) { return (HANDLE)(long)-1; }
HANDLE WINAPI GetCurrentThread (void) { return (HANDLE)(long)-2; }
DWORD  WINAPI GetCurrentProcessId(void) { return 0; }   /* TODO: TEB ClientId */
DWORD  WINAPI GetCurrentThreadId(void)  { return 0; }

void WINAPI ExitProcess(DWORD code)
{
    NtTerminateProcess(NT_CURRENT_PROCESS, (NTSTATUS)code);
    for (;;) { }
}

/* ---------- FormatMessageA / GetModuleFileNameA (lib_package) ------- */

/* LuaJIT's package loader uses FormatMessageA to turn GetLastError
 * codes into human-readable strings for error reporting. A real
 * implementation walks message-table resources per DLL per locale.
 * Ours substitutes a generic "error 0x%X" printf — good enough for
 * diagnostics, and the caller doesn't inspect the contents. */
DWORD WINAPI FormatMessageA(DWORD flags, LPCVOID source, DWORD msgId,
                            DWORD lang, LPSTR buf, DWORD size, void *args)
{
    /* Minimal %X formatter (avoid pulling in snprintf dependencies). */
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

/* GetModuleFileNameA returns the on-disk path of a loaded module. We
 * walk PEB->Ldr (same list as GetModuleHandleA) and copy the module's
 * FullDllName, ASCII-downcasting the UTF-16. NULL mod = the exe. */
DWORD WINAPI GetModuleFileNameA(HMODULE mod, LPSTR buf, DWORD size)
{
    PPEB_LDR_DATA ldr = _peb()->Ldr;
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
