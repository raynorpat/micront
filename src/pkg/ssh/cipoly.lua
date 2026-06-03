-- ssh.cipoly — the chacha20-poly1305@openssh.com AEAD packet cipher.
--
-- Implements ssh.packet's cipher seam (block_size / mac_len / seal / read)
-- for the one cipher in our suite.  Construction (OpenSSH PROTOCOL.chacha20
-- poly1305; RFC 8439 primitives):
--
--   * 64-byte key = K_2 (bytes 1..32) ‖ K_1 (bytes 33..64).  K_1 encrypts
--     ONLY the 4-byte packet-length field; K_2 encrypts the body and seeds
--     Poly1305.  (RFC: first 256 bits are K_2, second 256 bits are K_1.)
--   * Nonce = the SSH packet sequence number as a 64-bit big-endian value.
--     (Sequence numbers do NOT reset at NEWKEYS — they count every packet.)
--   * ChaCha20 block counter 0 of K_2 yields the Poly1305 key; the body is
--     encrypted with K_2 starting at block counter 1.
--   * On the wire: enc_length(4) ‖ enc_body ‖ poly1305_tag(16), the tag over
--     enc_length ‖ enc_body.  No separate MAC field — the tag is the MAC.
--
-- Each instance is one direction's key (server: send=key_s2c, recv=key_c2s).

local bit    = require('bit')
local crypto = require('ssh.crypto')
local wire   = require('ssh.wire')
local rng    = require('nt.dll.rng')

local M = {}

local C = {}
C.__index = C

-- new(key) — 64-byte directional key.
function M.new(key)
    assert(#key == 64, "chacha20-poly1305 key must be 64 bytes")
    return setmetatable({
        block_size = 8,
        mac_len    = 16,
        k2 = string.sub(key,  1, 32),   -- body + Poly1305 key
        k1 = string.sub(key, 33, 64),   -- packet-length field
    }, C)
end

-- 8-byte big-endian nonce from the sequence number (high 32 bits zero until
-- seq wraps past 2^32, which a rekey precedes).
local function nonce(seq)
    return string.char(0, 0, 0, 0,
        bit.band(bit.rshift(seq, 24), 0xFF),
        bit.band(bit.rshift(seq, 16), 0xFF),
        bit.band(bit.rshift(seq,  8), 0xFF),
        bit.band(seq, 0xFF))
end

-- AEAD padding (RFC 5647-style): align packet_length = (padlen ‖ payload ‖
-- padding) to block_size 8, min padding 4.  Unlike CBC/CTR (and our `none`
-- transform), the 4-byte length field is NOT counted here — it's encrypted by
-- a separate cipher instance and isn't part of the block-aligned region.  Get
-- this wrong and OpenSSH rejects with "padding error: need N block 8 mod M".
local function pad_len(payload_len)
    local pad = 8 - ((1 + payload_len) % 8)
    if pad < 4 then pad = pad + 8 end
    return pad
end

-- constant-time tag comparison — never branch on secret-dependent content.
local function ct_eq(a, b)
    if #a ~= #b then return false end
    local d = 0
    for i = 1, #a do
        d = bit.bor(d, bit.bxor(string.byte(a, i), string.byte(b, i)))
    end
    return d == 0
end

function C:seal(seq, payload)
    local n   = nonce(seq)
    local pad = pad_len(#payload)
    local pl  = 1 + #payload + pad                       -- packet_length value

    local enc_len  = crypto.chacha20(wire.u32(pl), self.k1, n, 0)
    local poly_key = crypto.chacha20(string.rep("\0", 32), self.k2, n, 0)
    local body     = wire.u8(pad) .. payload .. rng.bytes(pad)
    local enc_body = crypto.chacha20(body, self.k2, n, 1)
    local tag      = crypto.poly1305(enc_len .. enc_body, poly_key)
    return enc_len .. enc_body .. tag
end

function C:read(seq, read_exact)
    local n = nonce(seq)

    -- 1. decrypt the length field (K_1, counter 0) to know how much to read
    local enc_len = read_exact(4)
    local pl = wire.reader(crypto.chacha20(enc_len, self.k1, n, 0)):u32()
    if pl < 1 or pl > 256 * 1024 then
        error("ssh.cipoly: bad packet_length " .. pl, 2)
    end

    -- 2. read body + tag, verify Poly1305 over enc_len‖enc_body BEFORE decrypt
    local enc_body = read_exact(pl)
    local tag      = read_exact(16)
    local poly_key = crypto.chacha20(string.rep("\0", 32), self.k2, n, 0)
    if not ct_eq(crypto.poly1305(enc_len .. enc_body, poly_key), tag) then
        error("ssh.cipoly: Poly1305 tag mismatch (MAC error)", 2)
    end

    -- 3. decrypt body (K_2, counter 1), strip padding
    local body   = crypto.chacha20(enc_body, self.k2, n, 1)
    local padlen = string.byte(body, 1)
    return string.sub(body, 2, pl - padlen)
end

return M
