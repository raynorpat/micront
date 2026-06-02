-- ssh.crypto — FFI binding to djbcrypt.dll, the DJB primitive set.
--
-- djbcrypt.dll (NT/PRIVATE/WINDOWS/...) is a small native DLL of imported
-- reference C: X25519 + Ed25519 (ref10 / donna), ChaCha20 + Poly1305
-- (DJB / donna), SHA-256 + SHA-512.  Two design rules:
--
--   * The DLL exports PURE, STATELESS functions.  No randombytes inside
--     it — entropy stays in Lua via nt.dll.rng (NtGenerateSecureRandom),
--     so the DLL carries no OS coupling and is trivially KAT-testable.
--   * The signatures below ARE the DLL's contract; its .def mirrors this
--     cdef one-for-one.  Change them together.
--
-- This module exposes Lua-string-friendly wrappers (inputs are Lua
-- strings, outputs are fixed-width Lua strings).  ssh.crypto loads the
-- DLL lazily so the rest of the package can be required (and unit-tested
-- at the wire layer) before djbcrypt.dll exists on the image.

local ffi = require('ffi')
local bit = require('bit')
local rng = require('nt.dll.rng')

ffi.cdef[[
/* hashes — one-shot (incremental not needed: KEX builds H whole) */
void dc_sha256(const unsigned char *in, size_t len, unsigned char out[32]);
void dc_sha512(const unsigned char *in, size_t len, unsigned char out[64]);

/* X25519: out = scalar * point.  Returns 0 on success. */
int  dc_x25519(unsigned char out[32],
               const unsigned char scalar[32],
               const unsigned char point[32]);

/* Ed25519 (donna-shaped: 32-byte seed as the secret key). */
void dc_ed25519_pubkey(unsigned char pk[32], const unsigned char sk[32]);
void dc_ed25519_sign  (unsigned char sig[64],
                       const unsigned char *m, size_t mlen,
                       const unsigned char sk[32],
                       const unsigned char pk[32]);
int  dc_ed25519_verify(const unsigned char sig[64],
                       const unsigned char *m, size_t mlen,
                       const unsigned char pk[32]);   /* 0 == valid */

/* ChaCha20 keystream/XOR; 8-byte nonce (the SSH seqnr) + initial block
   counter.  OpenSSH's chacha20-poly1305 only ever starts the counter at 0
   (length word / Poly1305 key) or 1 (payload), so a 32-bit counter is
   exact and dodges 64-bit-by-value ABI on the period compiler. */
void dc_chacha20(unsigned char *out, const unsigned char *in, size_t len,
                 const unsigned char key[32], const unsigned char nonce[8],
                 unsigned int counter);

/* Poly1305 one-shot MAC. */
void dc_poly1305(unsigned char tag[16],
                 const unsigned char *m, size_t len,
                 const unsigned char key[32]);
]]

local M = {}

-- Lazy DLL handle: first real call loads it; a clear error if absent.
local C
local function lib()
    if not C then
        local ok, h = pcall(ffi.load, 'djbcrypt')
        if not ok then
            error("ssh.crypto: djbcrypt.dll not available (" ..
                  tostring(h) .. ")", 2)
        end
        C = h
    end
    return C
end

-- X25519 base point (u = 9), RFC 7748.
M.X25519_BASE = "\9" .. string.rep("\0", 31)

-- ---- hashes -------------------------------------------------------

function M.sha256(s)
    local out = ffi.new('unsigned char[32]')
    lib().dc_sha256(s, #s, out)
    return ffi.string(out, 32)
end

function M.sha512(s)
    local out = ffi.new('unsigned char[64]')
    lib().dc_sha512(s, #s, out)
    return ffi.string(out, 64)
end

-- ---- X25519 -------------------------------------------------------

function M.x25519(scalar, point)
    assert(#scalar == 32 and #point == 32, "x25519 needs 32-byte inputs")
    local out = ffi.new('unsigned char[32]')
    if lib().dc_x25519(out, scalar, point) ~= 0 then
        error("ssh.crypto: x25519 failed", 2)
    end
    return ffi.string(out, 32)
end

-- ephemeral keypair: 32 random bytes, RFC 7748 clamp, scalar*base.
-- Returns priv, pub (both 32-byte strings).
function M.x25519_keypair()
    local s = rng.bytes(32)
    local b = { string.byte(s, 1, 32) }
    b[1]  = bit.band(b[1],  0xF8)
    b[32] = bit.band(b[32], 0x7F)
    b[32] = bit.bor (b[32], 0x40)
    local priv = string.char(unpack(b))
    return priv, M.x25519(priv, M.X25519_BASE)
end

-- ---- Ed25519 ------------------------------------------------------

function M.ed25519_pubkey(sk)
    assert(#sk == 32, "ed25519 sk (seed) must be 32 bytes")
    local pk = ffi.new('unsigned char[32]')
    lib().dc_ed25519_pubkey(pk, sk)
    return ffi.string(pk, 32)
end

function M.ed25519_sign(msg, sk, pk)
    local sig = ffi.new('unsigned char[64]')
    lib().dc_ed25519_sign(sig, msg, #msg, sk, pk)
    return ffi.string(sig, 64)
end

function M.ed25519_verify(sig, msg, pk)
    assert(#sig == 64, "ed25519 sig must be 64 bytes")
    return lib().dc_ed25519_verify(sig, msg, #msg, pk) == 0
end

-- ---- ChaCha20 / Poly1305 ------------------------------------------

function M.chacha20(data, key, nonce, counter)
    assert(#key == 32 and #nonce == 8, "chacha20 key/nonce size")
    local out = ffi.new('unsigned char[?]', #data)
    lib().dc_chacha20(out, data, #data, key, nonce, counter or 0)
    return ffi.string(out, #data)
end

function M.poly1305(msg, key)
    assert(#key == 32, "poly1305 key must be 32 bytes")
    local tag = ffi.new('unsigned char[16]')
    lib().dc_poly1305(tag, msg, #msg, key)
    return ffi.string(tag, 16)
end

return M
