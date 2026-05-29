/*++

Module Name:

    rngkat.c

Abstract:

    Power-on known-answer self-test for the RNG crypto core.  A wrong Xoodoo
    permutation or mis-wired Cyclist is silently insecure, so RngInitSystem
    runs this at boot and bugchecks on any mismatch.

    Two vectors, both from authoritative sources:

      Stage 1 -- Xoodoo[12] applied to the all-zero state.  Matches the
                 reference permutation test vector (e.g. inmcm/xoodoo).

      Stage 2 -- Xoodyak-Hash of the empty message, 32-byte output.  Matches
                 Count = 1 of the official NIST LWC Xoodyak hash KAT
                 (LWC_HASH_KAT_256.txt).  This exercises the full Cyclist
                 absorb + squeeze path the pool uses, not just the permutation.

--*/

#include "rngp.h"

#if defined(ALLOC_PRAGMA)
#pragma alloc_text(INIT, RngpSelfTest)
#endif

//
// Xoodoo[12](0) -- 48 bytes, little-endian lanes.
//
static const UCHAR RngpKatXoodooZero[XOODOO_BYTES] = {
    0x8D, 0xD8, 0xD5, 0x89, 0xBF, 0xFC, 0x63, 0xA9,
    0x19, 0x2D, 0x23, 0x1B, 0x14, 0xA0, 0xA5, 0xFF,
    0x06, 0x81, 0xB1, 0x36, 0xFE, 0xC1, 0xC7, 0xAF,
    0xBE, 0x7C, 0xE5, 0xAE, 0xBD, 0x40, 0x75, 0xA7,
    0x70, 0xE8, 0x86, 0x2E, 0xC9, 0xB7, 0xF5, 0xFE,
    0xF2, 0xAD, 0x4F, 0x8B, 0x62, 0x40, 0x4F, 0x5E
};

//
// Xoodyak-Hash("") -- 32 bytes.
//
static const UCHAR RngpKatHashEmpty[32] = {
    0xEA, 0x15, 0x2F, 0x2B, 0x47, 0xBC, 0xE2, 0x4E,
    0xFB, 0x66, 0xC4, 0x79, 0xD4, 0xAD, 0xF1, 0x7B,
    0xD3, 0x24, 0xD8, 0x06, 0xE8, 0x5F, 0xF7, 0x5E,
    0xE3, 0x69, 0xEE, 0x50, 0xDC, 0x8F, 0x8B, 0xD1
};

ULONG
RngpSelfTest (
    VOID
    )
{
    RNG_CYCLIST xk;
    ULONG state[XOODOO_LANES];
    UCHAR buf[XOODOO_BYTES];
    ULONG i;

    //
    // Stage 1: Xoodoo[12] of the all-zero state.
    //
    for (i = 0; i < XOODOO_LANES; i += 1) {
        state[i] = 0;
    }
    RngpXoodoo(state);
    for (i = 0; i < XOODOO_BYTES; i += 1) {
        buf[i] = (UCHAR)(state[i >> 2] >> (8 * (i & 3)));
    }
    if (RtlCompareMemory(buf, (PVOID)RngpKatXoodooZero, XOODOO_BYTES) != XOODOO_BYTES) {
        return 1;
    }

    //
    // Stage 2: Xoodyak-Hash of the empty message (absorb 0 bytes, squeeze 32).
    //
    RngpCyclistInit(&xk);
    RngpAbsorbAny(&xk, buf, 0, 0x03);     // buf is a valid pointer; 0 bytes read
    RngpSqueezeAny(&xk, buf, 32);
    if (RtlCompareMemory(buf, (PVOID)RngpKatHashEmpty, 32) != 32) {
        return 2;
    }

    return 0;
}
