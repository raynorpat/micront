/*++

Module Name:

    userenv.c

Abstract:

    userenv.dll -- user-profile environment helpers.  Rust's std imports
    exactly one name from here, GetUserProfileDirectoryW, as the fallback for
    std::env::home_dir() when %USERPROFILE% is unset.

    Real userenv resolves the profile path from the token SID via the registry
    ProfileList key.  MicroNT has no per-user profile store yet, so this returns
    a single fixed profile directory -- enough to satisfy the import and give
    home_dir() a sane answer.  Revisit when real user profiles land.

--*/

#include <windows.h>

//
// The fixed profile directory handed back to every caller.  Counted length
// (in wide chars, including the terminating NUL) is the array size.
//
static const WCHAR ProfileDir[] = L"C:\\Users\\Default";

//
// GetUserProfileDirectoryW(hToken, lpProfileDir, lpcchSize).  On entry
// *lpcchSize is the caller's buffer size in wide chars; on exit it is the
// size used (or required).  Returns FALSE + ERROR_INSUFFICIENT_BUFFER if the
// buffer is too small (or NULL), per the documented contract.
//
BOOL
APIENTRY
GetUserProfileDirectoryW(
    IN     HANDLE  hToken,
    OUT    LPWSTR  lpProfileDir,
    IN OUT LPDWORD lpcchSize
    )
{
    DWORD needed = sizeof( ProfileDir ) / sizeof( WCHAR );   // includes NUL
    DWORD i;

    UNREFERENCED_PARAMETER( hToken );

    if (lpcchSize == NULL) {
        SetLastError( ERROR_INVALID_PARAMETER );
        return FALSE;
    }

    if (lpProfileDir == NULL || *lpcchSize < needed) {
        *lpcchSize = needed;
        SetLastError( ERROR_INSUFFICIENT_BUFFER );
        return FALSE;
    }

    for (i = 0; i < needed; i += 1) {
        lpProfileDir[i] = ProfileDir[i];
    }
    *lpcchSize = needed;
    return TRUE;
}

BOOL
UserenvDllInit(
    IN PVOID DllHandle,
    IN ULONG Reason,
    IN PVOID Context OPTIONAL
    )
{
    UNREFERENCED_PARAMETER( DllHandle );
    UNREFERENCED_PARAMETER( Reason );
    UNREFERENCED_PARAMETER( Context );
    return TRUE;
}
