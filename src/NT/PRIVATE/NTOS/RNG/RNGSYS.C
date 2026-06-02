/*++

Module Name:

    rngsys.c

Abstract:

    RNG subsystem boot-time initialization.  (The NtGenerateSecureRandom
    syscall and the \Device\Random object are added here in later changes.)

--*/

#include "rngp.h"

static VOID RngpAbsorbLoaderBlock(IN PLOADER_PARAMETER_BLOCK LoaderBlock);

#if defined(ALLOC_PRAGMA)
#pragma alloc_text(INIT, RngInitSystem)
#pragma alloc_text(INIT, RngpAbsorbLoaderBlock)
#endif

//
// A fixed label absorbed at startup so our pool's state is domain-separated
// from a bare Xoodyak instance even before any real entropy has arrived.
//
static const UCHAR RngpInitLabel[] = "MicroNT-RNG/Xoodyak-v1";

//
// Fold the loader's view of the machine into the pool: the physical memory
// map (each descriptor's type + base + extent).  For a fixed platform/VM
// config these are largely constant across reboots -- this is domain
// separation / uniqueness, not secret bits -- but they cost nothing (the
// loader already built the list) and they reach the pool at Phase 0, before
// any clock tick or RDRAND batch, when it would otherwise hold only the static
// init label.  Purely passive: we read a list the loader populated and touch
// no hardware.  (The boot-driver load order is a candidate second source here
// once its list-entry layout is pinned down.)
//
static VOID
RngpAbsorbLoaderBlock (
    IN PLOADER_PARAMETER_BLOCK LoaderBlock
    )
{
    PLIST_ENTRY                   head;
    PLIST_ENTRY                   next;
    PMEMORY_ALLOCATION_DESCRIPTOR md;
    struct {
        ULONG Type;
        ULONG BasePage;
        ULONG PageCount;
    } rec;

    head = &LoaderBlock->MemoryDescriptorListHead;
    for (next = head->Flink; next != head; next = next->Flink) {
        md = CONTAINING_RECORD(next, MEMORY_ALLOCATION_DESCRIPTOR, ListEntry);
        rec.Type      = (ULONG)md->MemoryType;
        rec.BasePage  = md->BasePage;
        rec.PageCount = md->PageCount;
        RngpAbsorbAny(&RngpPool, (const UCHAR *)&rec, sizeof(rec), 0x03);
    }
}

BOOLEAN
RngInitSystem (
    IN ULONG Phase,
    IN PLOADER_PARAMETER_BLOCK LoaderBlock
    )
{
    ULONG failedStage;

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

        //
        // Fold in the loader's memory map -- the earliest available entropy,
        // before HAL gathering or any clock tick.
        //
        RngpAbsorbLoaderBlock(LoaderBlock);

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
