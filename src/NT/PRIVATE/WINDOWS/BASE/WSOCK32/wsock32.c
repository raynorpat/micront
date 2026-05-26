/*++

Copyright (c) MicroNT contributors

Module Name:

    wsock32.c

Abstract:

    Stub for the wsock32.dll forwarder.  All exports live in
    wsock32.def as PE forwarder strings to WS2_32; this file
    exists only to give LINK a .obj to combine with the .def.

--*/

#include <nt.h>
#include <ntrtl.h>
#include <nturtl.h>
#include <windows.h>

BOOL
WsockDllInitialize (
    IN PVOID DllHandle,
    IN ULONG Reason,
    IN PVOID Context OPTIONAL
    )
{
    /*
     * No per-process or per-thread state -- the real init lives in
     * ws2_32's SockInitialize, which runs when the forwarder targets
     * resolve at import-snap time.
     */
    UNREFERENCED_PARAMETER( DllHandle );
    UNREFERENCED_PARAMETER( Reason );
    UNREFERENCED_PARAMETER( Context );
    return TRUE;
}
