-- ssh.packet — the SSH binary packet protocol (RFC 4253 §6).
--
-- On the wire a packet is:
--   uint32  packet_length        (covers padding_length + payload + padding;
--                                 NOT counting these 4 bytes themselves)
--   byte    padding_length
--   byte[]  payload              (the message: msg-type byte + body)
--   byte[]  random padding       (4..255 bytes)
--   byte[]  mac                  (present once a MAC is in force)
-- with padding chosen so packet_length+4 is a multiple of the cipher
-- block size (min 8), and padding_length >= 4.
--
-- The cipher seam lives here.  A *cipher* object fully owns how a packet
-- is framed on the wire, because that differs fundamentally between
-- transforms — in particular chacha20-poly1305@openssh.com encrypts the
-- length field separately, so "read the cleartext length first" is not
-- universal.  A cipher implements:
--
--   cipher:seal(seq, payload) -> bytes
--        Serialise one packet carrying `payload`, returning the exact
--        bytes to write to the transport.  `seq` is the outgoing packet
--        sequence number (uint32, wraps) — the AEAD nonce.
--
--   cipher:read(seq, read_exact) -> payload
--        Read exactly one packet.  `read_exact(n)` returns n bytes from
--        the transport (blocking) or raises.  `seq` is the incoming
--        sequence number.  Returns the decrypted payload.
--
--   cipher.block_size, cipher.mac_len   (informational)
--
-- This module ships the `none` transform (pre-NEWKEYS / cipher "none").
-- The chacha20-poly1305 AEAD cipher is a separate module that implements
-- the same two methods over ssh.crypto; see the contract block below.

local wire = require('ssh.wire')

local M = {}

-- Sanity ceiling on a single packet (RFC 4253 §6.1 floor is 32768 for
-- payload; we cap the whole packet generously to reject garbage early).
M.MAX_PACKET = 256 * 1024

-- ---- the `none` transform (cleartext framing) ---------------------

local None = {}
None.__index = None

function M.none()
    return setmetatable({ block_size = 8, mac_len = 0 }, None)
end

-- Pad so (4 + 1 + #payload + pad) is a multiple of block_size, with
-- pad >= 4.  Padding content is irrelevant for the cleartext transform
-- (the peer discards it); we use zero fill for determinism.  An AEAD
-- cipher MUST use random padding instead.
local function pad_len(payload_len, block_size)
    local unpadded = 4 + 1 + payload_len
    local pad = block_size - (unpadded % block_size)
    if pad < 4 then pad = pad + block_size end
    return pad
end

function None:seal(_seq, payload)
    local pad = pad_len(#payload, self.block_size)
    local packet_length = 1 + #payload + pad
    return wire.u32(packet_length)
        .. wire.u8(pad)
        .. payload
        .. string.rep("\0", pad)
end

function None:read(_seq, read_exact)
    local packet_length = wire.reader(read_exact(4)):u32()
    if packet_length < 1 or packet_length > M.MAX_PACKET then
        error("ssh.packet: bad packet_length " .. packet_length, 2)
    end
    local body    = read_exact(packet_length)        -- padlen+payload+padding
    local padlen  = string.byte(body, 1)
    local payload = string.sub(body, 2, packet_length - padlen)
    return payload
end

-- ---- AEAD cipher contract (chacha20-poly1305@openssh.com) ---------
--
-- Implemented in a sibling module once ssh.crypto is wired.  Recorded
-- here so the seam and the OpenSSH construction are co-located:
--
--   * The 64-byte key splits into K_1 (bytes 33..64) and K_2 (bytes 1..32).
--   * Nonce = seq as a 64-bit big-endian value (high 32 bits zero until
--     seq wraps past 2^32, which a rekey precedes).
--   * seal(seq, payload):
--       pad with RANDOM bytes (block_size 8) → packet_length||padlen||
--         payload||padding  (the same plaintext layout as above, no MAC
--         field — the tag replaces it)
--       C_len  = chacha20(K_1, nonce, counter=0) XOR the 4 length bytes
--       poly_key = chacha20(K_2, nonce, counter=0)[0..32]
--       C_body = chacha20(K_2, nonce, counter=1) XOR (padlen||payload||padding)
--       tag    = poly1305(poly_key, C_len || C_body)
--       wire   = C_len || C_body || tag        (tag is 16 bytes)
--   * read(seq, read_exact):
--       C_len  = read_exact(4); decrypt with K_1,counter=0 → packet_length
--       C_body = read_exact(packet_length); tag = read_exact(16)
--       verify poly1305 over C_len||C_body BEFORE decrypting the body
--       decrypt body with K_2,counter=1; strip padding → payload
--
-- block_size = 8, mac_len = 16, and length-decryption is folded into read.

return M
