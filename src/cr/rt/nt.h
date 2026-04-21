/*
 * nt.h — NT-internal types, macros and structs shared by rt/ sources.
 *
 * Scope: exactly what multiple rt/ .c files need. Adding something here
 * is a statement that two or more consumers need it. One-off types stay
 * in the .c file that owns them.
 *
 * Packing: NT 3.5 compiled its PEB/TEB/ProcessParameters/LDR structs
 * with pack(2). mingw's natural alignment would place fields at the
 * wrong offsets and the whole thing silently mis-dereferences. Every
 * NT-side struct defined here is wrapped in pack(2).
 *
 * NOT included here:
 *   - ntdll function prototypes (each .c file declares only the subset
 *     it actually calls — keeps dependency surface visible).
 *   - Win32 types (DWORD/BOOL/WINAPI/…) — those live in kernel32.h,
 *     scoped to the Win32 shim. Don't conflate the two namespaces.
 */

#ifndef RT_NT_H
#define RT_NT_H

#include <stddef.h>

/* ---------------------- Primitive typedefs --------------------------- */

typedef unsigned char         UCHAR;
typedef unsigned short        USHORT;
typedef unsigned long         ULONG;
typedef long                  LONG;
typedef long                  NTSTATUS;
typedef unsigned char         BOOLEAN;
typedef void                 *PVOID;
typedef void                 *HANDLE;
typedef unsigned short       *PWSTR;
typedef const unsigned short *PCWSTR;
typedef const char           *PCSTR;
typedef unsigned int          SIZE_T;
typedef SIZE_T               *PSIZE_T;
typedef ULONG                *PULONG;

#define NTAPI                 __attribute__((stdcall))
#define STATUS_SUCCESS        ((NTSTATUS)0x00000000L)
#define NT_SUCCESS(s)         ((s) >= 0)
#define NT_CURRENT_PROCESS    ((HANDLE)(long)-1)

#define OBJ_CASE_INSENSITIVE  0x00000040
#define HEAP_ZERO_MEMORY      0x00000008

/* ---------------------- NT structs (pack 2) -------------------------- */
#pragma pack(push, 2)

typedef struct _UNICODE_STRING {
    USHORT Length;
    USHORT MaximumLength;
    PWSTR  Buffer;
} UNICODE_STRING, *PUNICODE_STRING;

typedef struct _ANSI_STRING {
    USHORT Length;
    USHORT MaximumLength;
    char  *Buffer;
} ANSI_STRING, *PANSI_STRING;

typedef struct _LARGE_INTEGER {
    ULONG LowPart;
    LONG  HighPart;
} LARGE_INTEGER, *PLARGE_INTEGER;

typedef struct _IO_STATUS_BLOCK {
    NTSTATUS Status;
    ULONG    Information;
} IO_STATUS_BLOCK, *PIO_STATUS_BLOCK;

typedef struct _OBJECT_ATTRIBUTES {
    ULONG           Length;
    HANDLE          RootDirectory;
    PUNICODE_STRING ObjectName;
    ULONG           Attributes;
    PVOID           SecurityDescriptor;
    PVOID           SecurityQualityOfService;
} OBJECT_ATTRIBUTES, *POBJECT_ATTRIBUTES;

typedef struct _LIST_ENTRY {
    struct _LIST_ENTRY *Flink, *Blink;
} LIST_ENTRY, *PLIST_ENTRY;

typedef struct _PEB_LDR_DATA {
    ULONG      Length;
    UCHAR      Initialized;
    HANDLE     SsHandle;
    LIST_ENTRY InLoadOrderModuleList;
    LIST_ENTRY InMemoryOrderModuleList;
    LIST_ENTRY InInitializationOrderModuleList;
} PEB_LDR_DATA, *PPEB_LDR_DATA;

typedef struct _LDR_DATA_TABLE_ENTRY {
    LIST_ENTRY     InLoadOrderLinks;
    LIST_ENTRY     InMemoryOrderLinks;
    LIST_ENTRY     InInitializationOrderLinks;
    PVOID          DllBase;
    PVOID          EntryPoint;
    ULONG          SizeOfImage;
    UNICODE_STRING FullDllName;
    UNICODE_STRING BaseDllName;
    /* further fields ignored */
} LDR_DATA_TABLE_ENTRY, *PLDR_DATA_TABLE_ENTRY;

typedef struct _CURDIR {
    UNICODE_STRING DosPath;
    HANDLE         Handle;
} CURDIR;

typedef struct _RTL_USER_PROCESS_PARAMETERS {
    ULONG          MaximumLength;
    ULONG          Length;
    ULONG          Flags;
    ULONG          DebugFlags;
    HANDLE         ConsoleHandle;
    ULONG          ConsoleFlags;
    HANDLE         StandardInput;
    HANDLE         StandardOutput;
    HANDLE         StandardError;
    CURDIR         CurrentDirectory;
    UNICODE_STRING DllPath;
    UNICODE_STRING ImagePathName;
    UNICODE_STRING CommandLine;
    /* further fields ignored */
} RTL_USER_PROCESS_PARAMETERS, *PRTL_USER_PROCESS_PARAMETERS;

typedef struct _PEB {
    BOOLEAN                      InheritedAddressSpace;  /* +0x00 */
    HANDLE                       Mutant;                 /* +0x02 */
    PVOID                        ImageBaseAddress;       /* +0x06 */
    PPEB_LDR_DATA                Ldr;                    /* +0x0A */
    PRTL_USER_PROCESS_PARAMETERS ProcessParameters;      /* +0x0E */
    PVOID                        SubSystemData;          /* +0x12 */
    PVOID                        ProcessHeap;            /* +0x16 */
} PEB, *PPEB;

#pragma pack(pop)

/* ---------------------- PEB accessor --------------------------------- */

/* TEB is at fs:0, PEB at TEB+0x30. Single source of truth — every other
 * rt/ source that needs the PEB calls this inline. */
static __inline__ PPEB nt_peb(void)
{
    PPEB p;
    __asm__ volatile ("movl %%fs:0x30, %0" : "=r"(p));
    return p;
}

#endif /* RT_NT_H */
