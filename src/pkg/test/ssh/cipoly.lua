-- test.ssh.cipoly — chacha20-poly1305@openssh.com AEAD packet cipher.
--
-- Round-trip + tamper detection (needs djbcrypt).  The construction has no
-- published fixed KAT (it's the openssh-specific framing, and seal uses random
-- padding), so correctness here is self-consistency + AEAD integrity; the
-- cross-impl check is live — the server decrypts a real OpenSSH SERVICE_REQUEST
-- and OpenSSH accepts our encrypted SERVICE_ACCEPT.

local t      = require('test')
local bit    = require('bit')
local cipoly = require('ssh.cipoly')
local crypto = require('ssh.crypto')
local rng    = require('nt.dll.rng')

t.suite("ssh.cipoly")

local DLL_OK = pcall(function() crypto.sha256("") end)
local function need_dll() if not DLL_OK then t.skip("djbcrypt.dll not loadable") return true end end

-- a read_exact() over a fixed buffer
local function reader_of(s)
    local pos = 1
    return function(n) local r = string.sub(s, pos, pos + n - 1); pos = pos + n; return r end
end
local function flip(s, i)
    return string.sub(s, 1, i - 1) ..
           string.char(bit.bxor(string.byte(s, i), 0x01)) ..
           string.sub(s, i + 1)
end

t.test("seal/read round-trip across payloads + sequence numbers", function()
    if need_dll() then return end
    local c = cipoly.new(rng.bytes(64))
    local payloads = { "", "\5", "\50userauth", string.rep("x", 100), string.rep("\0", 7) }
    for _, seq in ipairs({ 0, 1, 3, 255, 65536 }) do
        for _, payload in ipairs(payloads) do
            local w = c:seal(seq, payload)
            -- packet_length (= enc_body = #w - 4 enc_len - 16 tag) is the
            -- block-aligned region for AEAD; the 4-byte length isn't counted.
            t.eq((#w - 20) % 8, 0, "packet_length block-aligned")
            t.eq(c:read(seq, reader_of(w)), payload,
                 ("round-trip seq=%d len=%d"):format(seq, #payload))
        end
    end
end)

t.test("tampered body / tag / sequence number is rejected", function()
    if need_dll() then return end
    local c = cipoly.new(rng.bytes(64))
    local w = c:seal(0, "secret-payload-here")
    -- body/tag tampers leave the length field intact, so they reach and fail
    -- the Poly1305 check deterministically.
    t.raises(function() c:read(0, reader_of(flip(w, 6)))  end, "MAC")  -- body byte
    t.raises(function() c:read(0, reader_of(flip(w, #w)))  end, "MAC")  -- tag byte
    -- wrong nonce: the K_1-decrypted length is garbage, so it's usually caught
    -- at the length bounds check (before the MAC).  Either way it MUST reject.
    t.raises(function() c:read(1, reader_of(w))            end)         -- wrong nonce
    t.eq(c:read(0, reader_of(w)), "secret-payload-here", "untampered still reads")
end)

t.test("the two directional keys produce independent ciphertext", function()
    if need_dll() then return end
    local c2s = cipoly.new(rng.bytes(64))
    local s2c = cipoly.new(rng.bytes(64))
    t.ne(c2s:seal(0, "ping"), s2c:seal(0, "ping"))
end)
