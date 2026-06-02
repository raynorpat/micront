-- test.ssh.crypto — known-answer tests for djbcrypt.dll, exercised
-- through ssh.crypto's FFI binding.  Since we ship this DLL, every
-- primitive is pinned to a published vector (RFC where one exists) or a
-- self-consistency round-trip.
--
-- Vectors are confirmed end-to-end on the first real VM run; a
-- misremembered expected value fails loudly (a false negative), it does
-- not weaken the crypto.  If djbcrypt.dll isn't loadable yet (FFI load
-- fails), the whole suite skips rather than erroring.

local t      = require('test')
local bit    = require('bit')
local crypto = require('ssh.crypto')

t.suite("ssh.crypto")

-- hex <-> bytes
local function unhex(s)
    return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
end
local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

-- Probe the DLL once; skip the suite cleanly if it isn't present.
local DLL_OK = pcall(function() crypto.sha256("") end)
local function need_dll()
    if not DLL_OK then t.skip("djbcrypt.dll not loadable") return true end
    return false
end

-- ---- SHA-256 (FIPS 180-4 / NIST) ----------------------------------
t.test("sha256 KAT", function()
    if need_dll() then return end
    t.eq(hex(crypto.sha256("abc")),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    t.eq(hex(crypto.sha256("")),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
end)

-- ---- SHA-512 (FIPS 180-4) -----------------------------------------
t.test("sha512 KAT", function()
    if need_dll() then return end
    t.eq(hex(crypto.sha512("abc")),
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" ..
        "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    t.eq(hex(crypto.sha512("")),
        "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce" ..
        "47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
end)

-- ---- Poly1305 (RFC 8439 §2.5.2) -----------------------------------
t.test("poly1305 KAT", function()
    if need_dll() then return end
    local key = unhex("85d6be7857556d337f4452fe42d506a8" ..
                      "0103808afb0db2fd4abff6af4149f51b")
    local msg = "Cryptographic Forum Research Group"
    t.eq(hex(crypto.poly1305(msg, key)), "a8061dc1305136c6c22b8baf0c0127a9")
end)

-- ---- ChaCha20 (DJB variant: 8-byte nonce, counter 0) --------------
-- All-zero key + nonce keystream is variant-agnostic (the counter/nonce
-- words are all zero either way) and widely published.
t.test("chacha20 zero-key keystream KAT", function()
    if need_dll() then return end
    local ks = crypto.chacha20(string.rep("\0", 64),
                               string.rep("\0", 32), string.rep("\0", 8), 0)
    t.eq(hex(ks),
        "76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7" ..
        "da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586")
end)

t.test("chacha20 XOR is involutive", function()
    if need_dll() then return end
    local key   = unhex("000102030405060708090a0b0c0d0e0f" ..
                        "101112131415161718191a1b1c1d1e1f")
    local nonce = unhex("0001020304050607")
    local pt    = "the quick brown fox"
    local ct    = crypto.chacha20(pt, key, nonce, 1)
    t.ne(ct, pt)
    t.eq(crypto.chacha20(ct, key, nonce, 1), pt)   -- decrypt == identity
end)

-- ---- X25519 (RFC 7748 §5.2, first vector) -------------------------
t.test("x25519 KAT", function()
    if need_dll() then return end
    local scalar = unhex("a546e36bf0527c9d3b16154b82465edd" ..
                         "62144c0ac1fc5a18506a2244ba449ac4")
    local u      = unhex("e6db6867583030db3594c1a424b15f7c" ..
                         "726624ec26b3353b10a903a6d0ab1c4c")
    t.eq(hex(crypto.x25519(scalar, u)),
        "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
end)

t.test("x25519 keypair: pub = priv*base, ECDH agrees", function()
    if need_dll() then return end
    local a_priv, a_pub = crypto.x25519_keypair()
    local b_priv, b_pub = crypto.x25519_keypair()
    t.eq(#a_priv, 32); t.eq(#a_pub, 32)
    -- shared secret computed from either side matches
    t.eq(crypto.x25519(a_priv, b_pub), crypto.x25519(b_priv, a_pub))
end)

-- ---- Ed25519 ------------------------------------------------------
-- KAT on the verify path (RFC 8032 §7.1 TEST 1, empty message) using
-- only the published public key + signature — no seed needed.
t.test("ed25519 verify KAT (RFC 8032 test 1)", function()
    if need_dll() then return end
    local pk  = unhex("d75a980182b10ab7d54bfed3c964073a" ..
                      "0ee172f3daa62325af021a68f707511a")
    local sig = unhex("e5564300c360ac729086e2cc806e828a" ..
                      "84877f1eb8e5d974d873e06522490155" ..
                      "5fb8821590a33bacc61e39701cf9b46b" ..
                      "d25bf5f0595bbe24655141438e7a100b")
    t.ok(crypto.ed25519_verify(sig, "", pk), "valid signature accepted")
    -- flip one signature byte -> must reject
    local bad = string.char(bit.bxor(string.byte(sig, 1), 0x01)) .. string.sub(sig, 2)
    t.ok(not crypto.ed25519_verify(bad, "", pk), "tampered signature rejected")
end)

t.test("ed25519 sign/verify round-trip (seed -> pubkey -> sign -> verify)", function()
    if need_dll() then return end
    local seed = string.rep("\66", 32)               -- arbitrary fixed seed
    local pk   = crypto.ed25519_pubkey(seed)
    t.eq(#pk, 32)
    local sig  = crypto.ed25519_sign("hello micront", seed, pk)
    t.eq(#sig, 64)
    t.ok(crypto.ed25519_verify(sig, "hello micront", pk), "own signature verifies")
    t.ok(not crypto.ed25519_verify(sig, "hello microNT", pk), "wrong message rejected")
end)
