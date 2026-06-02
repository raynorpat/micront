/*++

Module Name:

    djbcrypt.c

Abstract:

    djbcrypt.dll -- the DJB crypto primitive set MicroNT's SSH stack (and
    any future consumer) links against.  GLUE ONLY: a small, stable, pure
    C-linkage ABI (the dc_* exports) forwarding into vendored reference C.

    Primitives:
      X25519, Ed25519, ChaCha20, Poly1305, SHA-512   <- Monocypher 4.0.2
                                                         (mono.cpp/monoed.cpp,
                                                          built as C++)
      SHA-256                                         <- B-Con crypto-algorithms
                                                         public-domain (sha256.c)

    Design rules (kept in lockstep with pkg/ssh/crypto.lua's ffi.cdef --
    that cdef IS this ABI; calling convention is cdecl on both sides):

      * PURE + STATELESS.  No randombytes here; entropy is the caller's job
        (Lua draws it from NtGenerateSecureRandom via nt.dll.rng), so the
        DLL has no OS coupling and every export is directly KAT-testable.
      * No NT/Windows headers in this TU -- only <string.h> and the crypto
        headers -- so sha256.h's BYTE/WORD typedefs don't collide with
        windows.h.  The DLL entry point uses bare ABI-equivalent types.

--*/

#include <string.h>     /* memcpy, memset */
#include "mono.h"       /* crypto_x25519, crypto_chacha20_djb, crypto_poly1305 */
#include "monoed.h"     /* crypto_sha512, crypto_ed25519_*                     */
#include "sha256.h"     /* sha256_init/update/final                           */

/*
 * DLL entry.  BOOL APIENTRY (PVOID, ULONG, PVOID) spelled with bare
 * ABI-identical types to avoid pulling in <windows.h> here.  Named in
 * SOURCES via DLLENTRY=DjbcryptDllInit.
 */
int __stdcall
DjbcryptDllInit(void *DllHandle, unsigned long Reason, void *Context)
{
    (void)DllHandle;
    (void)Reason;
    (void)Context;
    return 1;   /* TRUE */
}

/* ---- hashes ------------------------------------------------------- */

void
dc_sha256(const unsigned char *in, size_t len, unsigned char *out)
{
    SHA256_CTX ctx;
    sha256_init(&ctx);
    sha256_update(&ctx, in, len);
    sha256_final(&ctx, out);
}

void
dc_sha512(const unsigned char *in, size_t len, unsigned char *out)
{
    crypto_sha512(out, in, len);
}

/* ---- X25519 ------------------------------------------------------- */

/*
 * out = scalar * point.  Monocypher clamps the scalar internally and
 * returns void; per RFC 8731 we reject an all-zero shared secret
 * (low-order point) by returning non-zero.  The OR-accumulate is
 * constant-time (no early-out).
 */
int
dc_x25519(unsigned char *out,
          const unsigned char *scalar,
          const unsigned char *point)
{
    unsigned char zero = 0;
    int i;
    crypto_x25519(out, scalar, point);
    for (i = 0; i < 32; i++) {
        zero = (unsigned char)(zero | out[i]);
    }
    return zero == 0 ? -1 : 0;   /* 0 == success */
}

/* ---- Ed25519 ------------------------------------------------------ */

/*
 * Monocypher 4.x keys the signer with a 64-byte secret = seed(32) ||
 * public_key(32).  Our ABI takes the 32-byte seed (sk) plus the public
 * key separately (the form an ssh-ed25519 key carries), so reassemble
 * the 64-byte secret at the boundary.
 */

void
dc_ed25519_pubkey(unsigned char *pk, const unsigned char *sk)
{
    unsigned char secret[64];
    unsigned char seed[32];
    memcpy(seed, sk, 32);                 /* key_pair wipes its seed arg */
    crypto_ed25519_key_pair(secret, pk, seed);
    memset(secret, 0, sizeof secret);
}

void
dc_ed25519_sign(unsigned char *sig,
                const unsigned char *m, size_t mlen,
                const unsigned char *sk, const unsigned char *pk)
{
    unsigned char secret[64];
    memcpy(secret,      sk, 32);          /* seed   */
    memcpy(secret + 32, pk, 32);          /* pubkey */
    crypto_ed25519_sign(sig, secret, m, mlen);
    memset(secret, 0, sizeof secret);
}

int
dc_ed25519_verify(const unsigned char *sig,
                  const unsigned char *m, size_t mlen,
                  const unsigned char *pk)
{
    /* crypto_ed25519_check returns 0 on a valid signature, -1 otherwise;
       pass it through (pkg/ssh/crypto.lua treats 0 as valid). */
    return crypto_ed25519_check(sig, pk, m, mlen);
}

/* ---- ChaCha20 / Poly1305 ------------------------------------------ */

void
dc_chacha20(unsigned char *out, const unsigned char *in, size_t len,
            const unsigned char *key, const unsigned char *nonce,
            unsigned int counter)
{
    /* initial block counter is only ever 0 or 1 in the openssh
       construction; widen to the djb variant's 64-bit counter. */
    (void)crypto_chacha20_djb(out, in, len, key, nonce, (uint64_t)counter);
}

void
dc_poly1305(unsigned char *tag,
            const unsigned char *m, size_t mlen,
            const unsigned char *key)
{
    crypto_poly1305(tag, m, mlen, key);
}
