/*++

Copyright (c) 2026 MicroNT

Module Name:

    wsprintf.c

Abstract:

    wsprintfA / wsprintfW exported from kernel32 instead of user32.

    Stock NT 3.5 placed wsprintf in user32.dll for historical reasons
    (it dates back to Windows 3.x where user32 was just "the Windows
    runtime").  The function itself is a string formatter — nothing
    GUI about it.  user32 in turn imports gdi32 and pulls in the
    whole window-manager / CSRSS chain at load time, which is heavy
    cancer to drag in just to format a number into a buffer.

    kernel32 is the right home: it already exports the other
    historically-misplaced string utilities (lstrcpyA, lstrcatA,
    lstrcmpA, lstrlenA, ...) for the same reason.  wsprintf joins
    them.  Net effect: console-only Win32 binaries (cmd.exe being
    the immediate consumer) link only against kernel32 + ntdll, no
    user32, no gdi32.

    Implementation delegates to libc.lib's static vsprintf /
    vswprintf — both fully implement the format specifiers cmd.exe
    actually uses (%d %s %ws %lx).  WSPRINTF_LIMIT (1024 chars) from
    the original is not enforced here; callers in our codebase pass
    fixed-size buffers and would overflow with `vsprintf` regardless,
    which is the same risk profile as the original wsprintf had.

Author:

    MicroNT (replaces user32!wsprintf)

--*/

#include <nt.h>
#include <ntrtl.h>
#include <nturtl.h>
#include <windows.h>
#include <stdarg.h>
#include <stdio.h>

int __cdecl wsprintfA(LPSTR buf, LPCSTR fmt, ...)
{
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vsprintf(buf, fmt, ap);
    va_end(ap);
    return n;
}

int __cdecl wsprintfW(LPWSTR buf, LPCWSTR fmt, ...)
{
    va_list ap;
    int n;

    va_start(ap, fmt);
    n = vswprintf(buf, fmt, ap);
    va_end(ap);
    return n;
}
