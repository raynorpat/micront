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

//
// NtGenerateSecureRandom -- the syscall behind RtlGenRandom / SystemFunction036
// / BCryptGenRandom.  Fills the caller's buffer with CSPRNG output.
//
// Squeezing writes into a kernel stack buffer because RngGenerateBytes briefly
// raises to DISPATCH_LEVEL under the pool lock -- its output must land in
// non-paged memory.  The copy out to the (possibly paged, possibly bogus) user
// buffer happens at PASSIVE_LEVEL with no lock held, inside SEH, so a bad
// pointer fails the call instead of bugchecking.
//
NTSTATUS
NtGenerateSecureRandom (
    OUT PVOID Buffer,
    IN ULONG Length
    )
{
    UCHAR  chunk[256];
    PUCHAR dst = (PUCHAR)Buffer;
    ULONG  remaining = Length;
    ULONG  n;

    if (Length == 0) {
        return STATUS_SUCCESS;
    }

    try {
        if (KeGetPreviousMode() != KernelMode) {
            ProbeForWrite(Buffer, Length, sizeof(UCHAR));
        }

        while (remaining > 0) {
            n = (remaining < sizeof(chunk)) ? remaining : sizeof(chunk);
            RngGenerateBytes(chunk, n);
            RtlCopyMemory(dst, chunk, n);
            dst += n;
            remaining -= n;
        }

    } except (EXCEPTION_EXECUTE_HANDLER) {
        RtlZeroMemory(chunk, sizeof(chunk));
        return GetExceptionCode();
    }

    /* Don't leave CSPRNG output sitting on the kernel stack. */
    RtlZeroMemory(chunk, sizeof(chunk));
    return STATUS_SUCCESS;
}
