/*++

Module Name:

    xoodoo.c

Abstract:

    The Xoodoo[12] permutation (Keccak team).  384-bit state held as 12
    little-endian 32-bit lanes: lanes 0..3 are plane y=0, 4..7 are y=1,
    8..11 are y=2.  One round is theta, rho-west, iota, chi, rho-east; this
    implementation folds them into a single pass following the public XKCP /
    reference structure.

    Pure XOR/AND/NOT/rotate -- no S-box tables and no data-dependent branches,
    which suits the ancient CL 8.50 toolchain.  Validated against the all-zero
    known-answer vector in rngkat.c.

--*/

#include "rngp.h"

//
// Cyclic left rotate.  Every call site uses a shift in 1..31 (5, 8, 11, 14, 1),
// so the (32 - n) right shift is always well defined.
//
#define ROTL32(x, n)  ( ((ULONG)(x) << (n)) | ((ULONG)(x) >> (32 - (n))) )

//
// Round constants, applied first (RC[0]) through last (RC[11]) for Xoodoo[12].
//
static const ULONG RngpRoundConstants[XOODOO_LANES] = {
    0x00000058UL, 0x00000038UL, 0x000003C0UL, 0x000000D0UL,
    0x00000120UL, 0x00000014UL, 0x00000060UL, 0x0000002CUL,
    0x00000380UL, 0x000000F0UL, 0x000001A0UL, 0x00000012UL
};

VOID
RngpXoodoo (
    IN OUT ULONG S[XOODOO_LANES]
    )
{
    ULONG round;
    ULONG p[4];
    ULONG e[4];
    ULONG t[XOODOO_LANES];

    for (round = 0; round < XOODOO_LANES; round += 1) {

        //
        // Theta: column parity, then the (5,14) fold across neighbouring columns.
        //
        p[0] = S[0] ^ S[4] ^ S[8];
        p[1] = S[1] ^ S[5] ^ S[9];
        p[2] = S[2] ^ S[6] ^ S[10];
        p[3] = S[3] ^ S[7] ^ S[11];

        e[0] = ROTL32(p[3], 5) ^ ROTL32(p[3], 14);
        e[1] = ROTL32(p[0], 5) ^ ROTL32(p[0], 14);
        e[2] = ROTL32(p[1], 5) ^ ROTL32(p[1], 14);
        e[3] = ROTL32(p[2], 5) ^ ROTL32(p[2], 14);

        //
        // Theta mix + iota (into plane 0) + rho-west (plane 1 lane shift,
        // plane 2 rotate-by-11).
        //
        t[0]  = e[0] ^ S[0] ^ RngpRoundConstants[round];
        t[1]  = e[1] ^ S[1];
        t[2]  = e[2] ^ S[2];
        t[3]  = e[3] ^ S[3];

        t[4]  = e[3] ^ S[7];
        t[5]  = e[0] ^ S[4];
        t[6]  = e[1] ^ S[5];
        t[7]  = e[2] ^ S[6];

        t[8]  = ROTL32(e[0] ^ S[8],  11);
        t[9]  = ROTL32(e[1] ^ S[9],  11);
        t[10] = ROTL32(e[2] ^ S[10], 11);
        t[11] = ROTL32(e[3] ^ S[11], 11);

        //
        // Chi (the only non-linear step) + rho-east (plane 1 rotate-by-1,
        // plane 2 lane shift + rotate-by-8).
        //
        S[0] = ((~t[4])  & t[8])  ^ t[0];
        S[1] = ((~t[5])  & t[9])  ^ t[1];
        S[2] = ((~t[6])  & t[10]) ^ t[2];
        S[3] = ((~t[7])  & t[11]) ^ t[3];

        S[4] = ROTL32(((~t[8])  & t[0]) ^ t[4], 1);
        S[5] = ROTL32(((~t[9])  & t[1]) ^ t[5], 1);
        S[6] = ROTL32(((~t[10]) & t[2]) ^ t[6], 1);
        S[7] = ROTL32(((~t[11]) & t[3]) ^ t[7], 1);

        S[8]  = ROTL32(((~t[2]) & t[6]) ^ t[10], 8);
        S[9]  = ROTL32(((~t[3]) & t[7]) ^ t[11], 8);
        S[10] = ROTL32(((~t[0]) & t[4]) ^ t[8],  8);
        S[11] = ROTL32(((~t[1]) & t[5]) ^ t[9],  8);
    }
}
