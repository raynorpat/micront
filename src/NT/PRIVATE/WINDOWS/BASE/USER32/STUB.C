/*++

Copyright (c) MicroNT contributors

Module Name:

    stub.c

Abstract:

    Stubs for the "is there a user / interactive desktop?" surface and
    MessageBoxA.  Real NT routes these via CSR LPC to win32k.sys (window
    station / user object subsystem) -- MicroNT has neither.  The
    stubs return the truthful "no UI, no desktop, no user object"
    answer so headless callers (notably OpenSSL's OPENSSL_isservice(),
    pulled in as a static dependency by Python 2.5's _ssl.pyd) take
    the no-dialog branch.

    MessageBoxA is the one exception: instead of silently lying, the
    stub tees the caption + text to STD_ERROR_HANDLE so anyone trying
    to surface an error still gets it logged before we return IDOK.

--*/

#include "precomp.h"
#pragma hdrstop

/*
 * GetDesktopWindow -- return NULL.  The reference NT 3.5
 * implementation (wow.c) dereferences per-thread desktop info; we
 * have no desktop, so NULL is the right "nothing here" answer.
 * OPENSSL_isservice() casts the return value to (void) and discards
 * it; other callers expect NULL on failure.
 */
HWND
WINAPI
GetDesktopWindow(
    VOID
    )
{
    return NULL;
}

/*
 * GetProcessWindowStation -- return NULL, ACCESS_DENIED.  The
 * reference implementation (cf.h) is a CSR LPC to USERSRV;
 * OPENSSL_isservice() reads `if (h == NULL) return -1;` and bails
 * before touching GetUserObjectInformationW.
 */
HWINSTA
WINAPI
GetProcessWindowStation(
    VOID
    )
{
    SetLastError(ERROR_ACCESS_DENIED);
    return NULL;
}

/*
 * GetUserObjectInformationW -- return FALSE, INVALID_HANDLE.  If
 * something passes us our own NULL hwinsta the truthful answer is
 * "that's not a real handle".
 */
BOOL
WINAPI
GetUserObjectInformationW(
    IN HANDLE hObj,
    IN int nIndex,
    OUT PVOID pvInfo,
    IN DWORD nLength,
    OUT LPDWORD pnLengthNeeded OPTIONAL
    )
{
    UNREFERENCED_PARAMETER(hObj);
    UNREFERENCED_PARAMETER(nIndex);
    UNREFERENCED_PARAMETER(pvInfo);
    UNREFERENCED_PARAMETER(nLength);
    if (pnLengthNeeded != NULL) {
        *pnLengthNeeded = 0;
    }
    SetLastError(ERROR_INVALID_HANDLE);
    return FALSE;
}

/*
 * MessageBoxA -- log the message to stderr and return IDOK as if the
 * (imaginary) user clicked OK.  Real NT puts up a modal dialog; we
 * have no UI, but silently dropping a diagnostic the library went
 * out of its way to surface would be worse than logging it.
 *
 * Multiple short WriteFile calls (no _snprintf dependency) keep the
 * stub's link footprint at just kernel32.  Partial writes are
 * ignored -- this is best-effort error reporting, not a contract.
 */
int
WINAPI
MessageBoxA(
    IN HWND hWnd OPTIONAL,
    IN LPCSTR lpText OPTIONAL,
    IN LPCSTR lpCaption OPTIONAL,
    IN UINT uType
    )
{
    HANDLE hStderr;
    DWORD written;
    static const CHAR prefix[] = "MessageBoxA: ";
    static const CHAR sep[]    = ": ";
    static const CHAR nl[]     = "\n";

    UNREFERENCED_PARAMETER(hWnd);
    UNREFERENCED_PARAMETER(uType);

    hStderr = GetStdHandle(STD_ERROR_HANDLE);
    if (hStderr != INVALID_HANDLE_VALUE && hStderr != NULL) {
        WriteFile(hStderr, prefix, sizeof(prefix) - 1, &written, NULL);
        if (lpCaption != NULL) {
            WriteFile(hStderr, lpCaption, strlen(lpCaption), &written, NULL);
            if (lpText != NULL) {
                WriteFile(hStderr, sep, sizeof(sep) - 1, &written, NULL);
            }
        }
        if (lpText != NULL) {
            WriteFile(hStderr, lpText, strlen(lpText), &written, NULL);
        }
        WriteFile(hStderr, nl, sizeof(nl) - 1, &written, NULL);
    }

    return IDOK;
}
