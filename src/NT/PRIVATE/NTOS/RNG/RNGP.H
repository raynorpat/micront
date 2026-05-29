/*++

Module Name:

    rngp.h

Abstract:

    Private definitions for the RNG subsystem (the in-kernel CSPRNG).

    Crypto core: the Xoodyak Cyclist duplex over the Xoodoo[12] permutation
    (Daemen, Hoffert, Van Assche, Van Keer & Peeters -- the Keccak team).
    We use Cyclist in its unkeyed "hash" mode as a sponge PRNG: Absorb()
    folds entropy in, Squeeze() draws pseudo-random bytes out, Ratchet()
    forgets the rate for forward secrecy.

    The permutation and the empty-message hash are pinned by known-answer
    tests in rngkat.c (see RngpSelfTest).

--*/

#ifndef _RNGP_H_
#define _RNGP_H_

#include "ntos.h"

#define XOODOO_LANES   12          // 384-bit state = 12 little-endian 32-bit lanes
#define XOODOO_BYTES   48
#define RNG_RATE       16          // Xoodyak hash-mode rate (R_hash), in bytes

//
// A Cyclist instance in hash mode.  Used both for the long-lived pool and for
// scratch instances inside the self-test.
//
typedef struct _RNG_CYCLIST {
    ULONG   State[XOODOO_LANES];   // Xoodoo state, 12 little-endian lanes
    BOOLEAN PhaseUp;               // TRUE iff the last Cyclist op was Up (fresh == TRUE)
} RNG_CYCLIST, *PRNG_CYCLIST;

//
// The pool and its lock (rngpool.c).  Resident / non-paged: RngAddEntropy may
// run at DISPATCH_LEVEL from the virtio-rng DPC and clock-adjacent paths.
//
extern RNG_CYCLIST RngpPool;
extern KSPIN_LOCK  RngpLock;

//
// xoodoo.c -- the permutation.
//
VOID
RngpXoodoo (
    IN OUT ULONG State[XOODOO_LANES]
    );

//
// rngpool.c -- Cyclist hash-mode primitives, operating on a caller-supplied
// instance (so the self-test can exercise them without touching the pool).
//
VOID
RngpCyclistInit (
    OUT PRNG_CYCLIST Xk
    );

VOID
RngpAbsorbAny (
    IN OUT PRNG_CYCLIST Xk,
    IN const UCHAR *X,
    IN ULONG Length,
    IN UCHAR Cd
    );

VOID
RngpSqueezeAny (
    IN OUT PRNG_CYCLIST Xk,
    OUT UCHAR *Y,
    IN ULONG Length
    );

VOID
RngpRatchet (
    IN OUT PRNG_CYCLIST Xk
    );

//
// rngkat.c -- power-on self-test.  Returns 0 on success, or a nonzero stage
// number identifying the failing known-answer test.
//
ULONG
RngpSelfTest (
    VOID
    );

#endif // _RNGP_H_
