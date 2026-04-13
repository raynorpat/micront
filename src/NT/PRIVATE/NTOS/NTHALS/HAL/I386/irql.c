/*
 * irql.c - MicroNT HAL IRQL management
 *
 * Maps NT IRQLs to 8259 PIC mask register values.
 * KfRaiseIrql/KfLowerIrql are the fast (fastcall) versions.
 */

#include "halp.h"

/*
 * IRQL management and software-interrupt request/clear/dispatch now live
 * in asm (irqlasm.asm, swint.asm, swinttab.asm). The asm handlers build
 * proper trap frames so SwapContext can return via IRET when a context
 * switch happens inside a dispatched DPC/APC. A pure-C dispatch was
 * broken: see project memory "HAL SW-int port pending".
 *
 * The C stubs below are just the pieces the asm doesn't cover.
 */


/*
 * Spinlock support — UP versions (no actual spinning needed)
 */
VOID
KeAcquireSpinLock(
    IN PKSPIN_LOCK SpinLock,
    OUT PKIRQL OldIrql
    )
{
    *OldIrql = KfRaiseIrql(DISPATCH_LEVEL);
}

VOID
KeReleaseSpinLock(
    IN PKSPIN_LOCK SpinLock,
    IN KIRQL NewIrql
    )
{
    KfLowerIrql(NewIrql);
}

KIRQL
__fastcall
KfAcquireSpinLock(
    IN PKSPIN_LOCK SpinLock
    )
{
    return KfRaiseIrql(DISPATCH_LEVEL);
}

VOID
__fastcall
KfReleaseSpinLock(
    IN PKSPIN_LOCK SpinLock,
    IN KIRQL NewIrql
    )
{
    KfLowerIrql(NewIrql);
}

/*
 * Fast mutex (UP versions) — MUST be __fastcall per IXLOCK.ASM original HAL.
 * The kernel passes FastMutex in ECX. Wrong calling convention corrupts the
 * caller's stack (extra `ret 4` pops 4 bytes that shouldn't be popped).
 */
VOID
__fastcall
ExAcquireFastMutex(
    IN PVOID FastMutex
    )
{
    KfRaiseIrql(APC_LEVEL);
}

BOOLEAN
__fastcall
ExTryToAcquireFastMutex(
    IN PVOID FastMutex
    )
{
    KfRaiseIrql(APC_LEVEL);
    return TRUE;
}

VOID
__fastcall
ExReleaseFastMutex(
    IN PVOID FastMutex
    )
{
    KfLowerIrql(PASSIVE_LEVEL);
}
