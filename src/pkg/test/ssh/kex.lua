-- test.ssh.kex — curve25519-sha256 key exchange.
--
-- Two tiers:
--   * Pure codec (no djbcrypt): KEXINIT build/parse round-trip + negotiation.
--   * Full-handshake self-consistency (needs djbcrypt): with both ephemeral
--     scalars + the host key pinned, drive both sides of the KEX and assert
--     they agree on K, H, the host-key signature, and the derived keys.  This
--     verifies the entire transport math offline — no peer, no socket.
--
-- The remaining gap is a *cross-implementation* check (we could agree with
-- ourselves but still differ from the world); that's the golden-vector slot
-- at the bottom, pending an H/keys vector dumped from wolfSSH (KEX/hash) and
-- OpenSSH (cipher).

local t      = require('test')
local kex    = require('ssh.kex')
local crypto = require('ssh.crypto')

t.suite("ssh.kex")

local function hex(s)
    return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end
local DLL_OK = pcall(function() crypto.sha256("") end)
local function need_dll() if not DLL_OK then t.skip("djbcrypt.dll not loadable") return true end end

-- ---- pure codec ---------------------------------------------------
t.test("KEXINIT build/parse round-trip", function()
    local payload = kex.build_kexinit(string.rep("\0", 16))
    local p = kex.parse_kexinit(payload)
    t.eq(p.kex[1],      "curve25519-sha256")
    t.eq(p.host_key[1], "ssh-ed25519")
    t.eq(p.enc_c2s[1],  "chacha20-poly1305@openssh.com")
    t.eq(p.comp_c2s[1], "none")
    t.eq(p.first_kex_follows, false)
    t.eq(p.reserved, 0)
    -- and the payload re-builds identically from the same cookie
    t.eq(kex.build_kexinit(p.cookie), payload)
end)

t.test("negotiation picks client-preferred mutual algorithm", function()
    local mine = kex.parse_kexinit(kex.build_kexinit(string.rep("\0", 16)))
    local chosen = kex.negotiate(mine, mine)
    t.eq(chosen.kex,        "curve25519-sha256")
    t.eq(chosen.host_key,   "ssh-ed25519")
    t.eq(chosen.cipher_c2s, "chacha20-poly1305@openssh.com")
    -- no overlap -> nil
    local none = kex.negotiate({ kex = {"diffie-hellman-group14-sha1"} },
                               { kex = {"curve25519-sha256"} })
    t.eq(none.kex, nil)
end)

t.test("ssh-ed25519 host-key / signature blob round-trip", function()
    if need_dll() then return end
    local pub = string.rep("\7", 32)
    local typ, payload = kex.parse_named_blob(kex.ed25519_hostkey_blob(pub))
    t.eq(typ, "ssh-ed25519"); t.eq(payload, pub)
    local sig = string.rep("\9", 64)
    local st, sp = kex.parse_named_blob(kex.ed25519_sig_blob(sig))
    t.eq(st, "ssh-ed25519"); t.eq(sp, sig)
end)

-- ---- full-handshake self-consistency (offline) --------------------
t.test("curve25519 KEX: both sides agree on K, H, signature, keys", function()
    if need_dll() then return end

    -- pinned inputs => deterministic handshake
    local a_scalar = string.rep("\11", 32)   -- client ephemeral
    local b_scalar = string.rep("\22", 32)   -- server ephemeral
    local hk_seed  = string.rep("\33", 32)    -- server host key
    local hk_pub   = crypto.ed25519_pubkey(hk_seed)

    local _, q_c = kex.ephemeral(a_scalar)    -- client pubkey
    local _, q_s = kex.ephemeral(b_scalar)    -- server pubkey

    -- 1. ECDH: each side computes K from its own scalar + peer's pubkey
    local k_client = kex.shared_secret(a_scalar, q_s)
    local k_server = kex.shared_secret(b_scalar, q_c)
    t.eq(k_client, k_server, "shared secret K agrees")

    -- 2. exchange hash from real KEXINIT payloads + host-key blob
    local params = {
        v_c = "SSH-2.0-MicroNT_client",
        v_s = "SSH-2.0-MicroNT_0.1",
        i_c = kex.build_kexinit(string.rep("\1", 16)),
        i_s = kex.build_kexinit(string.rep("\2", 16)),
        k_s = kex.ed25519_hostkey_blob(hk_pub),
        q_c = q_c, q_s = q_s, k = k_client,
    }
    local H = kex.exchange_hash(params)
    t.eq(H, kex.exchange_hash(params), "exchange hash is deterministic")
    t.eq(#H, 32, "H is a SHA-256 digest")

    -- 3. server signs H (ssh-ed25519 signs H directly); client verifies
    local sig = crypto.ed25519_sign(H, hk_seed, hk_pub)
    t.ok(crypto.ed25519_verify(sig, H, hk_pub), "host-key signature verifies")
    -- tamper with H -> reject
    local badH = string.char((string.byte(H, 1) + 1) % 256) .. string.sub(H, 2)
    t.ok(not crypto.ed25519_verify(sig, badH, hk_pub), "tampered H rejected")

    -- 4. key derivation: session_id = H on the first KEX; both sides match
    local kc = kex.derive_keys(k_client, H, H)
    local ks = kex.derive_keys(k_server, H, H)
    t.eq(kc.key_c2s, ks.key_c2s, "derived c2s key agrees")
    t.eq(kc.key_s2c, ks.key_s2c, "derived s2c key agrees")
    t.eq(#kc.key_c2s, 64, "chacha20-poly1305 cipher key is 64 bytes")
    t.ne(kc.key_c2s, kc.key_s2c, "c2s and s2c keys differ")
end)

t.test("exchange hash is sensitive to each input", function()
    if need_dll() then return end
    local base = {
        v_c = "SSH-2.0-A", v_s = "SSH-2.0-B",
        i_c = "\20ic", i_s = "\20is",
        k_s = "ks", q_c = string.rep("\3", 32), q_s = string.rep("\4", 32),
        k = string.rep("\5", 32),
    }
    local H0 = kex.exchange_hash(base)
    for _, field in ipairs({ "v_c", "q_c", "q_s", "k" }) do
        local m = {}; for k, v in pairs(base) do m[k] = v end
        m[field] = (field == "k" or field:sub(1,1) == "q")
                   and string.rep("\6", 32) or (base[field] .. "x")
        t.ne(kex.exchange_hash(m), H0, "H changes when " .. field .. " changes")
    end
end)

-- ---- cross-implementation golden vector (live, OpenSSH-blessed) ---
-- Captured from a real handshake with OpenSSH_8.9p1 driven against the server.
-- OpenSSH recomputed H from these exact inputs and verified our ssh-ed25519
-- signature over it, then sent NEWKEYS — so H (and every input feeding it) is
-- RFC-correct by an independent implementation's blessing.  This pins our
-- exchange_hash against that H: the real "do we match the world" check that
-- self-consistency can't give.  The derived keys are still our own computation
-- (OpenSSH used the matching key_c2s to encrypt its SERVICE_REQUEST); they get
-- fully cross-validated once the chacha20-poly1305 cipher can decrypt it.
t.test("KEX golden vector vs OpenSSH_8.9p1", function()
    if need_dll() then return end
    local function unhex(s)
        return (s:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
    end
    local v = {
        v_c = "SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.13",
        v_s = "SSH-2.0-MicroNT_0.1",
        i_c = unhex("141df6c22622b8f6f20b07a0ced61a68d100000131637572766532353531392d7368613235362c637572766532353531392d736861323536406c69627373682e6f72672c656364682d736861322d6e697374703235362c656364682d736861322d6e697374703338342c656364682d736861322d6e697374703532312c736e747275703736317832353531392d736861353132406f70656e7373682e636f6d2c6469666669652d68656c6c6d616e2d67726f75702d65786368616e67652d7368613235362c6469666669652d68656c6c6d616e2d67726f757031362d7368613531322c6469666669652d68656c6c6d616e2d67726f757031382d7368613531322c6469666669652d68656c6c6d616e2d67726f757031342d7368613235362c6578742d696e666f2d632c6b65782d7374726963742d632d763030406f70656e7373682e636f6d000001cf7373682d656432353531392d636572742d763031406f70656e7373682e636f6d2c65636473612d736861322d6e697374703235362d636572742d763031406f70656e7373682e636f6d2c65636473612d736861322d6e697374703338342d636572742d763031406f70656e7373682e636f6d2c65636473612d736861322d6e697374703532312d636572742d763031406f70656e7373682e636f6d2c736b2d7373682d656432353531392d636572742d763031406f70656e7373682e636f6d2c736b2d65636473612d736861322d6e697374703235362d636572742d763031406f70656e7373682e636f6d2c7273612d736861322d3531322d636572742d763031406f70656e7373682e636f6d2c7273612d736861322d3235362d636572742d763031406f70656e7373682e636f6d2c7373682d656432353531392c65636473612d736861322d6e697374703235362c65636473612d736861322d6e697374703338342c65636473612d736861322d6e697374703532312c736b2d7373682d65643235353139406f70656e7373682e636f6d2c736b2d65636473612d736861322d6e69737470323536406f70656e7373682e636f6d2c7273612d736861322d3531322c7273612d736861322d3235360000006c63686163686132302d706f6c7931333035406f70656e7373682e636f6d2c6165733132382d6374722c6165733139322d6374722c6165733235362d6374722c6165733132382d67636d406f70656e7373682e636f6d2c6165733235362d67636d406f70656e7373682e636f6d0000006c63686163686132302d706f6c7931333035406f70656e7373682e636f6d2c6165733132382d6374722c6165733139322d6374722c6165733235362d6374722c6165733132382d67636d406f70656e7373682e636f6d2c6165733235362d67636d406f70656e7373682e636f6d000000d5756d61632d36342d65746d406f70656e7373682e636f6d2c756d61632d3132382d65746d406f70656e7373682e636f6d2c686d61632d736861322d3235362d65746d406f70656e7373682e636f6d2c686d61632d736861322d3531322d65746d406f70656e7373682e636f6d2c686d61632d736861312d65746d406f70656e7373682e636f6d2c756d61632d3634406f70656e7373682e636f6d2c756d61632d313238406f70656e7373682e636f6d2c686d61632d736861322d3235362c686d61632d736861322d3531322c686d61632d73686131000000d5756d61632d36342d65746d406f70656e7373682e636f6d2c756d61632d3132382d65746d406f70656e7373682e636f6d2c686d61632d736861322d3235362d65746d406f70656e7373682e636f6d2c686d61632d736861322d3531322d65746d406f70656e7373682e636f6d2c686d61632d736861312d65746d406f70656e7373682e636f6d2c756d61632d3634406f70656e7373682e636f6d2c756d61632d313238406f70656e7373682e636f6d2c686d61632d736861322d3235362c686d61632d736861322d3531322c686d61632d736861310000001a6e6f6e652c7a6c6962406f70656e7373682e636f6d2c7a6c69620000001a6e6f6e652c7a6c6962406f70656e7373682e636f6d2c7a6c696200000000000000000000000000"),
        i_s = unhex("14de7d2bd95f8ab6c5176a7ac206cdc8130000002e637572766532353531392d7368613235362c637572766532353531392d736861323536406c69627373682e6f72670000000b7373682d656432353531390000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d0000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d0000000d686d61632d736861322d3235360000000d686d61632d736861322d323536000000046e6f6e65000000046e6f6e6500000000000000000000000000"),
        k_s = unhex("0000000b7373682d6564323535313900000020197f6b23e16c8532c6abc838facd5ea789be0c76b2920334039bfa8b3d368d61"),
        q_c = unhex("5bac385905df53a96478c637fea4be9dd5de568115f06ecd497ef8cfb749e51a"),
        q_s = unhex("3b24d674609f8d1448abff5bfa13451a51c422e3b79f8379a17285abde097420"),
        k   = unhex("efca1be55165e28c326b7fc27f9b643c503bc033432befef7527e4578222072f"),
    }
    local H = "57271ed77c037cac5cab1010e0fcc051b9a64fce32c48be9d1e1feb4cf5402f3"
    t.eq(hex(kex.exchange_hash(v)), H, "exchange hash matches OpenSSH")

    local keys = kex.derive_keys(v.k, unhex(H), unhex(H))
    t.eq(hex(keys.key_c2s),
        "19a437c5a64fb404ef9a8055fc0a0d511b412f8b8486ca6f450b3a428c75d421" ..
        "0cc86bedb18be9c8138445b184d59ad8e1e6a682d6505179addfd9e62a95ba50", "key_c2s")
    t.eq(hex(keys.key_s2c),
        "2e7e49e043543481ec1451f0001fab3914c8ff34c400488dfb105fb68c7039a4" ..
        "ccbd9e2970669084acab303903337c93e7e71d3a7a21636df58018b1a9862d72", "key_s2c")
end)
