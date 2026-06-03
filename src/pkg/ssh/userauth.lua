-- ssh.userauth — user authentication (RFC 4252), publickey / ssh-ed25519.
--
-- Pure codec + signature check.  The interesting, easy-to-get-wrong bit is the
-- blob the client signs (RFC 4252 §7): session_id ‖ the request up to and
-- including the public-key blob.  Get a byte wrong and ed25519_verify rejects a
-- genuine OpenSSH signature, so this is verified live against a real client.
--
-- Authorization policy (which keys are allowed) is intentionally NOT here —
-- this only answers "did the holder of THIS key sign THIS request".  The
-- caller decides whether to accept the key (the server's authorize policy).

local wire   = require('ssh.wire')
local consts = require('ssh.consts')
local crypto = require('ssh.crypto')

local M = {}

-- parse a USERAUTH_REQUEST payload (RFC 4252 §5):
--   byte 50, string user, string service, string method, <method-specific>
function M.parse_request(payload)
    local r = wire.reader(payload)
    assert(r:u8() == consts.msg.USERAUTH_REQUEST, "ssh.userauth: not a USERAUTH_REQUEST")
    local req = { user = r:string(), service = r:string(), method = r:string() }
    if req.method == "publickey" then
        req.have_sig = r:boolean()
        req.pk_alg   = r:string()
        req.pk_blob  = r:string()
        if req.have_sig then req.sig = r:string() end
    elseif req.method == "password" then
        req.change   = r:boolean()
        req.password = r:string()
    end
    return req
end

function M.build_failure(methods, partial)
    return wire.buf()
        :u8(consts.msg.USERAUTH_FAILURE)
        :namelist(methods or {})
        :boolean(partial or false)
        :tostring()
end

function M.build_success()
    return wire.buf():u8(consts.msg.USERAUTH_SUCCESS):tostring()
end

-- USERAUTH_PK_OK (msg 60) — "this key is acceptable; send the signature".
function M.build_pk_ok(pk_alg, pk_blob)
    return wire.buf()
        :u8(consts.msg.USERAUTH_PK_OK)
        :string(pk_alg)
        :string(pk_blob)
        :tostring()
end

-- The exact data the client signs for publickey auth (RFC 4252 §7):
--   string session_id
--   byte   SSH_MSG_USERAUTH_REQUEST
--   string user, string service, string "publickey"
--   boolean TRUE
--   string public_key_algorithm, string public_key_blob
function M.pk_signed_data(session_id, user, service, pk_alg, pk_blob)
    return wire.buf()
        :string(session_id)
        :u8(consts.msg.USERAUTH_REQUEST)
        :string(user)
        :string(service)
        :string("publickey")
        :boolean(true)
        :string(pk_alg)
        :string(pk_blob)
        :tostring()
end

-- verify_ed25519(req, session_id) -> bool.  Confirms the ssh-ed25519 signature
-- in `req` is valid over the RFC 4252 §7 blob for the key in req.pk_blob.
-- Robust against malformed attacker-controlled blobs (pcall -> false).
function M.verify_ed25519(req, session_id)
    local ok, result = pcall(function()
        if req.pk_alg ~= "ssh-ed25519" or not req.sig then return false end
        -- pk_blob = string "ssh-ed25519" + string pubkey(32)
        local rb = wire.reader(req.pk_blob)
        if rb:string() ~= "ssh-ed25519" then return false end
        local pubkey = rb:string()
        if #pubkey ~= 32 then return false end
        -- signature blob = string "ssh-ed25519" + string sig(64)
        local rs = wire.reader(req.sig)
        if rs:string() ~= "ssh-ed25519" then return false end
        local sig = rs:string()
        if #sig ~= 64 then return false end
        local data = M.pk_signed_data(session_id, req.user, req.service,
                                      req.pk_alg, req.pk_blob)
        return crypto.ed25519_verify(sig, data, pubkey)
    end)
    return ok and result == true
end

return M
