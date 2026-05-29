/*++

Module Name:

    rngpool.c

Abstract:

    The entropy pool: a long-lived Xoodyak Cyclist instance in hash mode plus
    the public kernel API (RngAddEntropy / RngGenerateBytes).

    Cyclist hash mode, as used here:
      Down(Xi, Cd)  -- XOR [Xi || 0x01 || 0..0 || (Cd & 1)] into the state.
      Up(Yi, n)     -- permute, then emit the first n state bytes (no Cu in
                       hash mode).
      AbsorbAny     -- Down the input in R_hash-byte blocks, Up between blocks;
                       first block carries Cd, the rest carry 0.
      SqueezeAny    -- Up to emit, Down(empty) between R_hash-byte chunks.
      Ratchet       -- squeeze R_hash bytes then absorb them back; because the
                       squeezed bytes equal the current rate, the absorb XORs
                       the rate to zero -- the rate is forgotten, which gives
                       forward secrecy (a later state capture cannot recover
                       earlier output).

    The permutation and Cyclist wiring are pinned by RngpSelfTest (rngkat.c).

--*/

#include "rngp.h"

//
// The one authoritative pool and its lock.  Both live in resident (non-paged)
// data: RngAddEntropy can be called at DISPATCH_LEVEL.
//
RNG_CYCLIST RngpPool;
KSPIN_LOCK  RngpLock;

VOID
RngpCyclistInit (
    OUT PRNG_CYCLIST Xk
    )
{
    RtlZeroMemory(Xk, sizeof(*Xk));
    Xk->PhaseUp = TRUE;            // a fresh Cyclist starts in the Up phase
}

//
// Down: inject bytes into the state via XOR, with sponge padding and the
// hash-mode domain byte.  Length is always <= RNG_RATE here.
//
static VOID
RngpDown (
    IN OUT PRNG_CYCLIST Xk,
    IN const UCHAR *Xi,
    IN ULONG Length,
    IN UCHAR Cd
    )
{
    UCHAR fill[XOODOO_BYTES];
    ULONG i;

    RtlZeroMemory(fill, sizeof(fill));
    for (i = 0; i < Length; i += 1) {
        fill[i] = Xi[i];
    }
    fill[Length] ^= 0x01;                          // 10* padding
    fill[XOODOO_BYTES - 1] ^= (UCHAR)(Cd & 0x01);  // hash mode keeps only Cd's LSB

    for (i = 0; i < XOODOO_LANES; i += 1) {
        Xk->State[i] ^= (ULONG)fill[i * 4]
                      | ((ULONG)fill[i * 4 + 1] << 8)
                      | ((ULONG)fill[i * 4 + 2] << 16)
                      | ((ULONG)fill[i * 4 + 3] << 24);
    }
    Xk->PhaseUp = FALSE;
}

//
// Up: permute, then optionally extract the first OutLength state bytes.
//
static VOID
RngpUp (
    IN OUT PRNG_CYCLIST Xk,
    OUT UCHAR *Yi OPTIONAL,
    IN ULONG OutLength
    )
{
    ULONG i;

    RngpXoodoo(Xk->State);        // hash mode injects no Cu before permuting
    Xk->PhaseUp = TRUE;
    for (i = 0; i < OutLength; i += 1) {
        Yi[i] = (UCHAR)(Xk->State[i >> 2] >> (8 * (i & 3)));
    }
}

VOID
RngpAbsorbAny (
    IN OUT PRNG_CYCLIST Xk,
    IN const UCHAR *X,
    IN ULONG Length,
    IN UCHAR Cd
    )
{
    ULONG processed = 0;
    ULONG remaining = Length;
    ULONG absorbLen = RNG_RATE;
    UCHAR cd = Cd;

    //
    // Note the loop always runs at least once, so a zero-length absorb still
    // injects one (padding-only) Down -- matching the reference behaviour.
    //
    for (;;) {
        if (!Xk->PhaseUp) {
            RngpUp(Xk, NULL, 0);
        }
        if (remaining < absorbLen) {
            absorbLen = remaining;
        }
        RngpDown(Xk, X + processed, absorbLen, cd);
        cd = 0x00;
        remaining -= absorbLen;
        processed += absorbLen;
        if (remaining == 0) {
            break;
        }
    }
}

VOID
RngpSqueezeAny (
    IN OUT PRNG_CYCLIST Xk,
    OUT UCHAR *Y,
    IN ULONG Length
    )
{
    ULONG squeezeLen;
    ULONG produced;

    squeezeLen = (Length < RNG_RATE) ? Length : RNG_RATE;
    RngpUp(Xk, Y, squeezeLen);
    produced = squeezeLen;

    while (produced < Length) {
        RngpDown(Xk, Y, 0, 0x00);          // Down(empty) between output chunks
        squeezeLen = ((Length - produced) < RNG_RATE) ? (Length - produced) : RNG_RATE;
        RngpUp(Xk, Y + produced, squeezeLen);
        produced += squeezeLen;
    }
}

VOID
RngpRatchet (
    IN OUT PRNG_CYCLIST Xk
    )
{
    UCHAR tmp[RNG_RATE];

    RngpSqueezeAny(Xk, tmp, RNG_RATE);
    RngpAbsorbAny(Xk, tmp, RNG_RATE, 0x00);
    RtlZeroMemory(tmp, sizeof(tmp));
}

//
// ---------------------------- public kernel API ----------------------------
//

VOID
RngAddEntropy (
    IN PVOID Buffer,
    IN ULONG Length
    )
{
    KIRQL oldIrql;

    if (Length == 0) {
        return;
    }
    KeAcquireSpinLock(&RngpLock, &oldIrql);
    RngpAbsorbAny(&RngpPool, (const UCHAR *)Buffer, Length, 0x03);
    KeReleaseSpinLock(&RngpLock, oldIrql);
}

VOID
RngGenerateBytes (
    OUT PVOID Buffer,
    IN ULONG Length
    )
{
    KIRQL oldIrql;

    if (Length == 0) {
        return;
    }
    KeAcquireSpinLock(&RngpLock, &oldIrql);
    RngpSqueezeAny(&RngpPool, (UCHAR *)Buffer, Length);
    RngpRatchet(&RngpPool);            // forget the rate -> forward secrecy
    KeReleaseSpinLock(&RngpLock, oldIrql);
}
