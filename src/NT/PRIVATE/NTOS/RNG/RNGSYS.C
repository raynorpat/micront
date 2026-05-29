/*++

Module Name:

    rngsys.c

Abstract:

    RNG subsystem boot-time initialization.  (The NtGenerateSecureRandom
    syscall and the \Device\Random object are added here in later changes.)

--*/

#include "rngp.h"

#if defined(ALLOC_PRAGMA)
#pragma alloc_text(INIT, RngInitSystem)
#endif

//
// A fixed label absorbed at startup so our pool's state is domain-separated
// from a bare Xoodyak instance even before any real entropy has arrived.
//
static const UCHAR RngpInitLabel[] = "MicroNT-RNG/Xoodyak-v1";

BOOLEAN
RngInitSystem (
    IN ULONG Phase,
    IN PLOADER_PARAMETER_BLOCK LoaderBlock
    )
{
    ULONG failedStage;

    UNREFERENCED_PARAMETER(LoaderBlock);

    if (Phase == 0) {

        //
        // Self-test FIRST.  A broken permutation or Cyclist would hand out
        // predictable bytes that *look* random -- refuse to boot instead.
        //
        failedStage = RngpSelfTest();
        if (failedStage != 0) {
            KeBugCheckEx(PHASE0_INITIALIZATION_FAILED,
                         'RNG0', failedStage, 0, 0);
        }

        KeInitializeSpinLock(&RngpLock);
        RngpCyclistInit(&RngpPool);
        RngpAbsorbAny(&RngpPool,
                      RngpInitLabel,
                      sizeof(RngpInitLabel) - 1,
                      0x03);

        DbgPrint("RNG: Xoodyak pool initialized, self-test OK\n");
    }

    return TRUE;
}
