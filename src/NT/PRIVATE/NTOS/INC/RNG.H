/*++

Module Name:

    rng.h

Abstract:

    Public interface to the MicroNT RNG subsystem -- the in-kernel CSPRNG.

    The RNG subsystem owns a single authoritative entropy pool (a Xoodyak
    Cyclist duplex over the Xoodoo[12] permutation).  It is deliberately
    deterministic: it contains no clocks, no hardware probing and no threads,
    which is what lets it be validated against fixed known-answer tests at
    boot.  All the messy, non-deterministic entropy gathering lives in the HAL
    (which feeds the pool via RngAddEntropy) and, optionally, the virtio-rng
    driver.

--*/

#ifndef _RNG_H_
#define _RNG_H_

//
// Boot-time initialization.
//   Phase 0 -- run the power-on self-test (bugcheck on failure) and bring the
//              pool up, BEFORE the HAL so its boot-time entropy has somewhere
//              to go.
//   Phase 1 -- register \Device\Random and start the periodic reseed thread
//              (added in later changes).
// Always returns TRUE; a self-test failure bugchecks rather than returning.
//

BOOLEAN
RngInitSystem (
    IN ULONG Phase,
    IN PLOADER_PARAMETER_BLOCK LoaderBlock
    );

//
// Absorb raw entropy into the pool.  Safe to call at or below DISPATCH_LEVEL.
//
// There is no entropy estimate: the caller hands over values that are known
// to *collectively* contain entropy (timer readings, RDRAND output, device
// bytes); the duplex concentrates whatever real entropy is present.
//

VOID
RngAddEntropy (
    IN PVOID Buffer,
    IN ULONG Length
    );

//
// Fill Buffer with Length cryptographically-strong random bytes.
//

VOID
RngGenerateBytes (
    OUT PVOID Buffer,
    IN ULONG Length
    );

//
// System service (NtGenerateSecureRandom / ZwGenerateSecureRandom): fill the
// caller's buffer with Length cryptographically-strong random bytes.
//
NTSTATUS
NtGenerateSecureRandom (
    OUT PVOID Buffer,
    IN ULONG Length
    );

#endif // _RNG_H_
