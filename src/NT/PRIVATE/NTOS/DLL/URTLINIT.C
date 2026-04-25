/*++

Copyright (c) 1989  Microsoft Corporation

Module Name:

    urtlinit.c

Abstract:

    This module contains code to initialize the user mode RTL in a
    process.

Author:

    Chuck Lenzmeier (chuckl) 8-Sep-1989

Environment:

    User Mode only

Revision History:

--*/

#include <nt.h>
#include <ntrtl.h>
#include <nturtl.h>

//
// User-mode RTL initialization routines. RtlpInitializeRtl is
// semi-public (called by ntcrt0.s). Historically also ran the CSR
// client-thread disconnect on DLL_THREAD_DETACH; MicroNT has no CSR
// subsystem so the hook is a no-op.
//

BOOLEAN
RtlpInitializeRtl(
    IN PVOID DllHandle,
    IN ULONG Reason,
    IN PCONTEXT Context OPTIONAL
    )
{
    DBG_UNREFERENCED_PARAMETER(DllHandle);
    DBG_UNREFERENCED_PARAMETER(Reason);
    DBG_UNREFERENCED_PARAMETER(Context);
    return TRUE;
}
