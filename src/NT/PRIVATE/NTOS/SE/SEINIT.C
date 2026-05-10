/*++

Copyright (c) 1989  Microsoft Corporation

Module Name:

    seinit.c

Abstract:

    Executive security components Initialization.

Author:

    Jim Kelly (JimK) 10-May-1990

Revision History:

--*/

#include <nt.h>
#include "sep.h"
#include "tokenp.h"
#include <string.h>

//
// Security Database Constants
//

#define SEP_INITIAL_KEY_COUNT 15
#define SEP_INITIAL_LEVEL_COUNT 6L

#ifdef ALLOC_PRAGMA
#pragma alloc_text(INIT,SeInitSystem)
#pragma alloc_text(INIT,SepInitializationPhase0)
#pragma alloc_text(INIT,SepInitializationPhase1)
#endif

BOOLEAN
SeInitSystem( VOID )

/*++

Routine Description:

    Perform security related system initialization functions.

Arguments:

    None.

Return Value:

    TRUE - Initialization succeeded.

    FALSE - Initialization failed.

--*/

{
    PAGED_CODE(); 

    switch ( InitializationPhase ) {

    case 0 :
        return SepInitializationPhase0();
    case 1 :
        return SepInitializationPhase1();
    default:
        KeBugCheck(UNEXPECTED_INITIALIZATION_CALL);
    }
}


BOOLEAN
SepInitializationPhase0( VOID )

/*++

Routine Description:

    Perform phase 0 security initialization.

    This includes:

        - Initialize LUID allocation
        - Initialize security global variables
        - initialize the token object.
        - Initialize the necessary security components of the boot thread/process


Arguments:

    None.

Return Value:

    TRUE - Initialization was successful.

    FALSE - Initialization Failed.

--*/

{

    PAGED_CODE();

    //
    //  LUID allocation services are needed by security prior to phase 0
    //  Executive initialization.  So, LUID initialization is performed
    //  here
    //

    if (ExLuidInitialization() == FALSE) {
        KdPrint(("Security: Locally Unique ID initialization failed.\n"));
        return FALSE;
    }

    //
    // Initialize security global variables
    //

    if (!SepVariableInitialization()) {
        KdPrint(("Security: Global variable initialization failed.\n"));
        return FALSE;
    }

    //
    // MicroNT: SepRmInitPhase0 only set up the LSA logon-session tracking
    // table; with no LSA we skip it.
    //

    //
    // Initialize the token object type.
    //

    if (!SepTokenInitialization()) {
        KdPrint(("Security: Token object initialization failed.\n"));
        return FALSE;
    }

    //
    // Initialize the security fields of the boot thread.
    //

    PsGetCurrentProcess()->Token = SeMakeSystemToken();
    PsGetCurrentThread()->Client = NULL;

    return TRUE;
}


BOOLEAN
SepInitializationPhase1( VOID )

/*++

Routine Description:

    Perform phase 1 security initialization.

    MicroNT: no LSA. The original Phase-1 work was creating the \Security
    object directory, the LSA_AUTHENTICATION_INITIALIZED event, and the
    audit subsystem - all gone. This function remains as a noop hook for
    the init sequence in case future kernel-only Phase-1 work appears.

Arguments:

    None.

Return Value:

    TRUE - Initialization was successful.

    FALSE - Initialization Failed.

--*/

{
    PAGED_CODE();

#ifndef SETEST

    return TRUE;

#else

    return SepDevelopmentTest();

#endif  //SETEST

}
