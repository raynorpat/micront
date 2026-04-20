/*
 * kernel32.h — minimal Win32 API surface on top of NT 3.5 ntdll.
 *
 * Scope: just what LuaJIT's lj_clib.c and lj_alloc.c touch. Not a
 * full kernel32 replacement — no console, no process creation, no
 * atoms, no mailslots. Enough to link a native-NT LuaJIT.
 *
 * Architecture: links into the consumer as libkernel32.a (static).
 * Symbol names match real Win32 so a mingw build's automatic import
 * against libkernel32 resolves against our replacement without
 * source-level patches in LuaJIT. We use __stdcall throughout to
 * produce the expected `_Name@N` decoration.
 *
 * Threading: GetLastError/SetLastError + TLS slots live in a process-
 * global right now. Safe for single-threaded consumers (LuaJIT is by
 * default). When we spawn threads we'll promote to real TEB fields
 * (LastErrorValue @ TEB+0x34, TlsSlots array inside TEB).
 */

#ifndef KERNEL32_H
#define KERNEL32_H

#include <stddef.h>

/* ---------------------- Types ---------------------------------------- */

typedef unsigned long        DWORD;
typedef unsigned short       WORD;
typedef unsigned char        BYTE;
typedef int                  BOOL;
typedef void                *PVOID;
typedef void                *HANDLE;
typedef HANDLE               HMODULE;
typedef HANDLE               HINSTANCE;
typedef void                *LPVOID;
typedef const void          *LPCVOID;
typedef char                *LPSTR;
typedef const char          *LPCSTR;
typedef DWORD               *LPDWORD;
typedef unsigned int         SIZE_T;
typedef SIZE_T              *PSIZE_T;

#define WINAPI               __attribute__((stdcall))
#define TRUE                 1
#define FALSE                0
#define INVALID_HANDLE_VALUE ((HANDLE)(long)-1)
#define TLS_OUT_OF_INDEXES   ((DWORD)0xFFFFFFFF)

/* VirtualAlloc protection / allocation flags */
#define PAGE_NOACCESS          0x01
#define PAGE_READONLY          0x02
#define PAGE_READWRITE         0x04
#define PAGE_WRITECOPY         0x08
#define PAGE_EXECUTE           0x10
#define PAGE_EXECUTE_READ      0x20
#define PAGE_EXECUTE_READWRITE 0x40
#define PAGE_EXECUTE_WRITECOPY 0x80

#define MEM_COMMIT             0x00001000
#define MEM_RESERVE            0x00002000
#define MEM_DECOMMIT           0x00004000
#define MEM_RELEASE            0x00008000

/* LoadLibraryEx flags — we accept but ignore all of these. */
#define DONT_RESOLVE_DLL_REFERENCES            0x00000001
#define LOAD_WITH_ALTERED_SEARCH_PATH          0x00000008

/* GetModuleHandleEx flags */
#define GET_MODULE_HANDLE_EX_FLAG_PIN                (0x00000001)
#define GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT (0x00000002)
#define GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS       (0x00000004)

typedef struct _FILETIME {
    DWORD dwLowDateTime;
    DWORD dwHighDateTime;
} FILETIME, *LPFILETIME;

/* CRITICAL_SECTION — opaque from Win32's perspective. We reserve
 * enough space for ntdll's RTL_CRITICAL_SECTION (24 bytes on x86)
 * and pass through. */
typedef struct _CRITICAL_SECTION {
    BYTE opaque[24];
} CRITICAL_SECTION, *LPCRITICAL_SECTION;

/* ---------------------- DLL loading / symbols ------------------------ */

HMODULE WINAPI LoadLibraryA     (LPCSTR);
HMODULE WINAPI LoadLibraryExA   (LPCSTR, HANDLE, DWORD);
BOOL    WINAPI FreeLibrary      (HMODULE);
HMODULE WINAPI GetModuleHandleA (LPCSTR);
BOOL    WINAPI GetModuleHandleExA(DWORD, LPCSTR, HMODULE *);
PVOID   WINAPI GetProcAddress   (HMODULE, LPCSTR);

/* ---------------------- Error codes --------------------------------- */

DWORD   WINAPI GetLastError     (void);
void    WINAPI SetLastError     (DWORD);

/* ---------------------- Virtual memory ------------------------------ */

LPVOID  WINAPI VirtualAlloc     (LPVOID, SIZE_T, DWORD, DWORD);
BOOL    WINAPI VirtualFree      (LPVOID, SIZE_T, DWORD);
BOOL    WINAPI VirtualProtect   (LPVOID, SIZE_T, DWORD, LPDWORD);

typedef struct _MEMORY_BASIC_INFORMATION {
    PVOID  BaseAddress;
    PVOID  AllocationBase;
    DWORD  AllocationProtect;
    SIZE_T RegionSize;
    DWORD  State;
    DWORD  Protect;
    DWORD  Type;
} MEMORY_BASIC_INFORMATION, *PMEMORY_BASIC_INFORMATION;

SIZE_T  WINAPI VirtualQuery     (LPCVOID, PMEMORY_BASIC_INFORMATION, SIZE_T);

/* ---------------------- SEH (raise only) ---------------------------- */

void    WINAPI RaiseException   (DWORD code, DWORD flags,
                                 DWORD argc, const unsigned long *argv);

/* ---------------------- TLS ----------------------------------------- */

DWORD   WINAPI TlsAlloc         (void);
BOOL    WINAPI TlsFree          (DWORD);
LPVOID  WINAPI TlsGetValue      (DWORD);
BOOL    WINAPI TlsSetValue      (DWORD, LPVOID);

/* ---------------------- Critical sections --------------------------- */

void    WINAPI InitializeCriticalSection(LPCRITICAL_SECTION);
void    WINAPI EnterCriticalSection     (LPCRITICAL_SECTION);
void    WINAPI LeaveCriticalSection     (LPCRITICAL_SECTION);
void    WINAPI DeleteCriticalSection    (LPCRITICAL_SECTION);

/* ---------------------- Time / sleep -------------------------------- */

void    WINAPI GetSystemTimeAsFileTime(LPFILETIME);
DWORD   WINAPI GetTickCount     (void);
BOOL    WINAPI QueryPerformanceCounter  (FILETIME *);   /* LARGE_INTEGER alias */
BOOL    WINAPI QueryPerformanceFrequency(FILETIME *);
void    WINAPI Sleep            (DWORD ms);

/* ---------------------- Process / thread ---------------------------- */

HANDLE  WINAPI GetCurrentProcess(void);
HANDLE  WINAPI GetCurrentThread (void);
DWORD   WINAPI GetCurrentProcessId(void);
DWORD   WINAPI GetCurrentThreadId(void);
void    WINAPI ExitProcess      (DWORD);

/* ---------------------- Misc (for lib_package) ---------------------- */

DWORD   WINAPI FormatMessageA   (DWORD flags, LPCVOID source, DWORD msgId,
                                 DWORD lang, LPSTR buf, DWORD size, void *args);
DWORD   WINAPI GetModuleFileNameA(HMODULE mod, LPSTR buf, DWORD size);

#endif /* KERNEL32_H */
