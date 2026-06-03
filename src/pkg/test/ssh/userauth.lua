-- test.ssh.userauth — RFC 4252 publickey (ssh-ed25519).
--
-- Codec round-trips (no DLL) + a full sign/verify self-consistency and tamper
-- rejection (needs djbcrypt).  The cross-impl check is live: the server
-- verifies a real OpenSSH client's publickey signature.

local t        = require('test')
local userauth = require('ssh.userauth')
local kex      = require('ssh.kex')
local crypto   = require('ssh.crypto')
local wire     = require('ssh.wire')
local consts   = require('ssh.consts')

t.suite("ssh.userauth")

local DLL_OK = pcall(function() crypto.sha256("") end)
local function need_dll() if not DLL_OK then t.skip("djbcrypt.dll not loadable") return true end end

-- build a publickey USERAUTH_REQUEST (client side) so we can parse it back
local function build_pk_request(user, service, have_sig, pk_alg, pk_blob, sig)
    local b = wire.buf()
        :u8(consts.msg.USERAUTH_REQUEST)
        :string(user):string(service):string("publickey")
        :boolean(have_sig):string(pk_alg):string(pk_blob)
    if have_sig then b:string(sig) end
    return b:tostring()
end

t.test("USERAUTH_REQUEST publickey parse round-trip", function()
    local req = userauth.parse_request(
        build_pk_request("alice", "ssh-connection", false, "ssh-ed25519", "BLOB"))
    t.eq(req.user, "alice")
    t.eq(req.service, "ssh-connection")
    t.eq(req.method, "publickey")
    t.eq(req.have_sig, false)
    t.eq(req.pk_alg, "ssh-ed25519")
    t.eq(req.pk_blob, "BLOB")
    t.eq(req.sig, nil)
    -- with signature
    local req2 = userauth.parse_request(
        build_pk_request("bob", "ssh-connection", true, "ssh-ed25519", "BLOB", "SIG"))
    t.eq(req2.have_sig, true)
    t.eq(req2.sig, "SIG")
end)

t.test("none-method request parses (no method-specific fields)", function()
    local req = userauth.parse_request(wire.buf()
        :u8(consts.msg.USERAUTH_REQUEST)
        :string("u"):string("ssh-connection"):string("none"):tostring())
    t.eq(req.method, "none")
    t.eq(req.have_sig, nil)
end)

t.test("publickey ed25519 sign/verify round-trip", function()
    if need_dll() then return end
    local seed       = string.rep("\77", 32)
    local pub        = crypto.ed25519_pubkey(seed)
    local pk_blob    = kex.ed25519_hostkey_blob(pub)   -- "ssh-ed25519" + pubkey
    local session_id = string.rep("\1", 32)
    local user, svc  = "alice", "ssh-connection"

    -- client signs the RFC 4252 §7 blob
    local data = userauth.pk_signed_data(session_id, user, svc, "ssh-ed25519", pk_blob)
    local sig  = kex.ed25519_sig_blob(crypto.ed25519_sign(data, seed, pub))
    local req  = { user = user, service = svc, method = "publickey", have_sig = true,
                   pk_alg = "ssh-ed25519", pk_blob = pk_blob, sig = sig }

    t.ok(userauth.verify_ed25519(req, session_id), "valid signature accepted")
    t.ok(not userauth.verify_ed25519(req, string.rep("\2", 32)), "wrong session_id rejected")

    local function clone(x) local c = {}; for k, v in pairs(x) do c[k] = v end; return c end
    local bad_user = clone(req); bad_user.user = "bob"
    t.ok(not userauth.verify_ed25519(bad_user, session_id), "tampered user rejected")
    -- malformed blob must not crash, just fail
    local junk = clone(req); junk.sig = "\0\0"
    t.ok(not userauth.verify_ed25519(junk, session_id), "malformed sig blob rejected")
end)
