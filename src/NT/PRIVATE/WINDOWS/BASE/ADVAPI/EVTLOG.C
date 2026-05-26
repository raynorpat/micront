/*++

Copyright (c) MicroNT contributors

Module Name:

    evtlog.c

Abstract:

    Stubs for the Event Log client surface.  Real NT routes these via
    RPC to eventlog.exe and the EventLog service -- MicroNT has no
    service subsystem and no event log.

    Callers that handle the "no event log" case gracefully (notably
    OpenSSL's xsyslog, which skips entirely if RegisterEventSourceA
    returns NULL) just log elsewhere.  Anything that passes our NULL
    handle on to ReportEventA / DeregisterEventSource gets a truthful
    INVALID_HANDLE failure.

--*/

#include <nt.h>
#include <ntrtl.h>
#include <nturtl.h>
#include <windows.h>

/*
 * RegisterEventSourceA -- pretend we tried, refuse access.
 *
 * The OpenSSL xsyslog path is:
 *   h = RegisterEventSourceA(NULL, source);
 *   if (h == NULL) { use stderr fallback; }
 *
 * Returning NULL with ACCESS_DENIED is exactly what they handle.
 */
HANDLE
WINAPI
RegisterEventSourceA(
    IN LPCSTR lpUNCServerName OPTIONAL,
    IN LPCSTR lpSourceName
    )
{
    UNREFERENCED_PARAMETER(lpUNCServerName);
    UNREFERENCED_PARAMETER(lpSourceName);
    SetLastError(ERROR_ACCESS_DENIED);
    return NULL;
}

/*
 * ReportEventA -- nobody should be calling this with a real handle
 * because RegisterEventSourceA only ever returned NULL.  Defence in
 * depth: return INVALID_HANDLE.
 */
BOOL
WINAPI
ReportEventA(
    IN HANDLE hEventLog,
    IN WORD wType,
    IN WORD wCategory,
    IN DWORD dwEventID,
    IN PSID lpUserSid OPTIONAL,
    IN WORD wNumStrings,
    IN DWORD dwDataSize,
    IN LPCSTR *lpStrings OPTIONAL,
    IN LPVOID lpRawData OPTIONAL
    )
{
    UNREFERENCED_PARAMETER(hEventLog);
    UNREFERENCED_PARAMETER(wType);
    UNREFERENCED_PARAMETER(wCategory);
    UNREFERENCED_PARAMETER(dwEventID);
    UNREFERENCED_PARAMETER(lpUserSid);
    UNREFERENCED_PARAMETER(wNumStrings);
    UNREFERENCED_PARAMETER(dwDataSize);
    UNREFERENCED_PARAMETER(lpStrings);
    UNREFERENCED_PARAMETER(lpRawData);
    SetLastError(ERROR_INVALID_HANDLE);
    return FALSE;
}

/*
 * DeregisterEventSource -- same logic as ReportEventA above.
 */
BOOL
WINAPI
DeregisterEventSource(
    IN HANDLE hEventLog
    )
{
    UNREFERENCED_PARAMETER(hEventLog);
    SetLastError(ERROR_INVALID_HANDLE);
    return FALSE;
}
