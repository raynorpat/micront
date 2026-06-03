/*++

Copyright (c) 1989  Microsoft Corporation

Module Name:

    delay.c

Abstract:

   This module implements the executive delay execution system service.

Author:

    David N. Cutler (davec) 13-May-1989

Environment:

    Kernel mode only.

Revision History:

--*/

#include "exp.h"

#ifdef ALLOC_PRAGMA
#pragma alloc_text(PAGE, NtDelayExecution)
#pragma alloc_text(PAGE, NtYieldExecution)
#endif


NTSTATUS
NtDelayExecution (
    IN BOOLEAN Alertable,
    IN PLARGE_INTEGER DelayInterval
    )

/*++

Routine Description:

    This function delays the execution of the current thread for the specified
    interval of time.

Arguments:

    Alertable - Supplies a boolean value that specifies whether the delay
        is alertable.

    DelayInterval - Supplies the absolute of relative time over which the
        delay is to occur.

Return Value:

    TBS

--*/

{

    LARGE_INTEGER Interval;
    KPROCESSOR_MODE PreviousMode;
    NTSTATUS Status;

    //
    // Establish an exception handler and probe delay interval address. If
    // the probe fails, then return the exception code as the service status.
    // Otherwise return the status value returned by the delay execution
    // routine.
    //

    try {

        //
        // Get previous processor mode and probe delay interval address if
        // necessary.
        //

        PreviousMode = KeGetPreviousMode();
        if (PreviousMode != KernelMode) {
            ProbeForRead(DelayInterval, sizeof(LARGE_INTEGER), sizeof(ULONG));
        }
        Interval = *DelayInterval;

        //
        // Delay execution for the specified amount of time.
        //

        Status = KeDelayExecutionThread(PreviousMode, Alertable, &Interval);

    //
    // If an exception occurs during the probing of the delay interval address,
    // then always handle the exception and return the exception code as the
    // status value.
    //

    } except(EXCEPTION_EXECUTE_HANDLER) {
        return GetExceptionCode();
    }

    //
    // Return service status.
    //

    return Status;
}

NTSTATUS
NtYieldExecution (
    VOID
    )

/*++

Routine Description:

    This function yields execution of the current thread to any other ready
    thread for up to one quantum.  It backs the Win32 SwitchToThread API.

    The yield is expressed as an already-expired (zero) delay: KeDelayExecutionThread
    with a due time in the past skips timer insertion and drops straight into the
    dispatcher's round-robin branch (see ke\wait.c), which reselects a ready thread
    and switches to it when one exists, and otherwise returns at once.  Reusing that
    proven scheduler path avoids open-coding a context switch here.

Arguments:

    None.

Return Value:

    STATUS_SUCCESS.  (NT also defines STATUS_NO_YIELD_PERFORMED for the case where no
    other thread was runnable; the round-robin delay path does not surface that
    distinction, and SwitchToThread treats any success as a completed call.)

--*/

{

    LARGE_INTEGER Interval;

    //
    // A zero interval lies in the past, so KeDelayExecutionThread takes its yield
    // (round-robin) branch instead of inserting a timer and waiting.  KernelMode and
    // non-alertable mean there is no user buffer to probe and no APC or alert can
    // abort the call.
    //

    Interval.QuadPart = 0;
    KeDelayExecutionThread(KernelMode, FALSE, &Interval);
    return STATUS_SUCCESS;
}
