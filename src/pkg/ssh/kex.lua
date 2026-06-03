-- ssh.kex — curve25519-sha256 key exchange (RFC 5656 / 8731 + RFC 4253 §7-8).
--
-- Pure protocol math + codec: KEXINIT build/parse + algorithm negotiation,
-- the curve25519 ECDH, the exchange hash H, ssh-ed25519 host-key/signature
-- blobs, and the RFC 4253 §7.2 key derivation.  NO socket I/O — the actual
-- KEXINIT/KEX_ECDH packet exchange is driven by the transport-discipline
-- layer over ssh.xport; keeping the math pure is what makes the whole
-- handshake verifiable offline (fixed ephemeral scalar + cookie => the
-- entire output is deterministic; see test.ssh.kex).
--
-- Suite: curve25519-sha256 KEX, ssh-ed25519 host key, with H/keys hashed by
-- SHA-256.  The shared secret K is the 32-byte X25519 output encoded as an
-- mpint (RFC 8731).

local wire   = require('ssh.wire')
local consts = require('ssh.consts')
local crypto = require('ssh.crypto')

local M = {}

-- ---- KEXINIT (RFC 4253 §7.1) --------------------------------------
--
--   byte         SSH_MSG_KEXINIT
--   byte[16]     cookie
--   name-list    kex_algorithms
--   name-list    server_host_key_algorithms
--   name-list    encryption_algorithms_client_to_server / _server_to_client
--   name-list    mac_algorithms_client_to_server / _server_to_client
--   name-list    compression_algorithms_client_to_server / _server_to_client
--   name-list    languages_client_to_server / _server_to_client
--   boolean      first_kex_packet_follows
--   uint32       0 (reserved)
--
-- The full payload (msg byte through reserved) is what feeds I_C / I_S in
-- the exchange hash, so build_kexinit returns it verbatim.

-- build_kexinit(cookie) — cookie is 16 bytes (injected for determinism in
-- tests; nt.dll.rng in production).  Advertises our one suite.
function M.build_kexinit(cookie)
    assert(#cookie == 16, "KEXINIT cookie must be 16 bytes")
    local a = consts.algo
    return wire.buf()
        :u8(consts.msg.KEXINIT)
        :raw(cookie)
        :namelist(a.kex)
        :namelist(a.host_key)
        :namelist(a.cipher):namelist(a.cipher)              -- enc c2s / s2c
        :namelist(a.mac):namelist(a.mac)                    -- mac c2s / s2c (unused: AEAD)
        :namelist(a.compression):namelist(a.compression)    -- comp c2s / s2c
        :namelist({}):namelist({})                          -- lang c2s / s2c
        :boolean(false)                                     -- first_kex_packet_follows
        :u32(0)                                             -- reserved
        :tostring()
end

function M.parse_kexinit(payload)
    local r = wire.reader(payload)
    assert(r:u8() == consts.msg.KEXINIT, "ssh.kex: not a KEXINIT")
    return {
        cookie    = r:bytes(16),
        kex       = r:namelist(),
        host_key  = r:namelist(),
        enc_c2s   = r:namelist(), enc_s2c  = r:namelist(),
        mac_c2s   = r:namelist(), mac_s2c  = r:namelist(),
        comp_c2s  = r:namelist(), comp_s2c = r:namelist(),
        lang_c2s  = r:namelist(), lang_s2c = r:namelist(),
        first_kex_follows = r:boolean(),
        reserved  = r:u32(),
    }
end

-- negotiate (RFC 4253 §7.1): the chosen algorithm is the first name on the
-- CLIENT's list that also appears on the SERVER's list (client preference
-- wins).  Returns nil for a slot with no overlap.
-- nil-tolerant: a malformed/partial peer KEXINIT (a missing name-list)
-- yields nil for that slot rather than crashing negotiation.
local function pick(client_list, server_list)
    local have = {}
    for _, n in ipairs(server_list or {}) do have[n] = true end
    for _, n in ipairs(client_list or {}) do
        if have[n] then return n end
    end
    return nil
end

function M.negotiate(client, server)
    return {
        kex        = pick(client.kex,      server.kex),
        host_key   = pick(client.host_key, server.host_key),
        cipher_c2s = pick(client.enc_c2s,  server.enc_c2s),
        cipher_s2c = pick(client.enc_s2c,  server.enc_s2c),
        comp_c2s   = pick(client.comp_c2s, server.comp_c2s),
        comp_s2c   = pick(client.comp_s2c, server.comp_s2c),
        -- mac left out: chacha20-poly1305@openssh.com is AEAD (implicit MAC).
    }
end

-- ---- ssh-ed25519 host key + signature blobs (RFC 8709) ------------
--   K_S        = string "ssh-ed25519" + string pubkey(32)
--   signature  = string "ssh-ed25519" + string sig(64)   (signs H directly)

function M.ed25519_hostkey_blob(pubkey)
    return wire.buf():string("ssh-ed25519"):string(pubkey):tostring()
end

function M.ed25519_sig_blob(sig)
    return wire.buf():string("ssh-ed25519"):string(sig):tostring()
end

function M.parse_named_blob(blob)
    local r = wire.reader(blob)
    return r:string(), r:string()   -- type, payload (pubkey or sig)
end

-- ---- curve25519 ECDH ----------------------------------------------
-- ephemeral(scalar?) -> scalar, pubkey.  scalar optional (deterministic
-- tests); otherwise drawn from nt.dll.rng via crypto.x25519_keypair.
-- Monocypher clamps internally, so an injected raw scalar is fine.
function M.ephemeral(scalar)
    if scalar then
        return scalar, crypto.x25519(scalar, crypto.X25519_BASE)
    end
    return crypto.x25519_keypair()
end

-- shared_secret(our_scalar, their_pubkey) -> K (32 raw bytes).
-- Raises on an all-zero result (RFC 8731 contributory-behaviour check, in
-- crypto.x25519).
function M.shared_secret(our_scalar, their_pubkey)
    return crypto.x25519(our_scalar, their_pubkey)
end

-- ---- exchange hash H (RFC 4253 §8, RFC 8731) ----------------------
--   H = SHA256( string(V_C) string(V_S) string(I_C) string(I_S)
--               string(K_S) string(Q_C) string(Q_S) mpint(K) )
-- v_c/v_s : identification strings (no CR/LF).  i_c/i_s : KEXINIT payloads.
-- k_s : host-key blob.  q_c/q_s : 32-byte ephemeral pubkeys.  k : 32-byte
-- X25519 shared secret (encoded as mpint here).
function M.exchange_hash(p)
    return crypto.sha256(wire.buf()
        :string(p.v_c):string(p.v_s)
        :string(p.i_c):string(p.i_s)
        :string(p.k_s)
        :string(p.q_c):string(p.q_s)
        :mpint(p.k)
        :tostring())
end

-- ---- key derivation (RFC 4253 §7.2) -------------------------------
--   K1 = HASH(K || H || "X" || session_id)
--   K2 = HASH(K || H || K1) ; K3 = HASH(K || H || K1||K2) ; ...
--   key = K1 || K2 || ...  (truncated to the needed length)
-- K is mpint-encoded; H and session_id are raw.  session_id is H from the
-- first key exchange (stable across rekeys).
local function derive_one(k_mpint, H, session_id, letter, need)
    local out = crypto.sha256(k_mpint .. H .. letter .. session_id)
    while #out < need do
        out = out .. crypto.sha256(k_mpint .. H .. out)
    end
    return string.sub(out, 1, need)
end

-- derive_keys(K_raw, H, session_id) -> the six RFC keys (A-F).  For
-- chacha20-poly1305@openssh.com only the 64-byte cipher keys (C/D) are used:
-- the IVs (A/B) are unused (seqnr is the nonce) and the MAC keys (E/F) are
-- implicit (AEAD).  We still expose A/B at 8 bytes for completeness / other
-- ciphers; E/F are omitted.
function M.derive_keys(k_raw, H, session_id)
    local k = wire.mpint(k_raw)
    return {
        iv_c2s  = derive_one(k, H, session_id, "A", 8),
        iv_s2c  = derive_one(k, H, session_id, "B", 8),
        key_c2s = derive_one(k, H, session_id, "C", 64),
        key_s2c = derive_one(k, H, session_id, "D", 64),
    }
end

return M
