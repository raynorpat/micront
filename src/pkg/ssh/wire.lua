-- ssh.wire — SSH binary wire types (RFC 4251 §5).
--
-- The five primitive encodings SSH packets are built from:
--   byte         one octet
--   boolean      one octet, 0 = false, anything else = true (we emit 1)
--   uint32       4 octets, big-endian
--   string       uint32 length prefix + that many octets (binary-safe)
--   mpint        a multiple-precision integer: a `string` holding the
--                two's-complement big-endian value, leading zero byte
--                prepended when the high bit would otherwise be set;
--                zero is the empty string.
--   name-list    a `string` of comma-separated ASCII names.
--
-- Two halves: standalone encoders that return byte-strings (compose with
-- `..`, matching nt.net.dhcp's u8/u16/u32 idiom), and a cursor `Reader` /
-- accumulator `Buf` so packet (de)serialisation keeps its position state
-- on an instance rather than in a module global.

local bit = require('bit')

local band, rshift, lshift, bor =
    bit.band, bit.rshift, bit.lshift, bit.bor

local M = {}

-- ---- standalone encoders ------------------------------------------

function M.u8(n)
    return string.char(band(n, 0xFF))
end

function M.boolean(b)
    return string.char(b and 1 or 0)
end

function M.u32(n)
    -- big-endian; band each octet so any Lua number value is accepted.
    return string.char(band(rshift(n, 24), 0xFF),
                       band(rshift(n, 16), 0xFF),
                       band(rshift(n,  8), 0xFF),
                       band(n,           0xFF))
end

function M.string(s)
    s = s or ""
    return M.u32(#s) .. s
end

-- mpint(raw): `raw` is the canonical big-endian unsigned magnitude (e.g.
-- a 32-byte X25519 shared secret).  Strip leading zero octets, then —
-- because SSH mpints are signed — prepend 0x00 if the top bit is set so
-- the value stays positive.  All-zero magnitude encodes as a 0-length
-- string.
function M.mpint(raw)
    local i = 1
    while i <= #raw and string.byte(raw, i) == 0 do
        i = i + 1
    end
    if i > #raw then
        return M.u32(0)               -- value is zero
    end
    local mag = string.sub(raw, i)
    if band(string.byte(mag, 1), 0x80) ~= 0 then
        mag = "\0" .. mag
    end
    return M.string(mag)
end

-- name-list(t): t is an array of names; encoded as a comma-joined string.
function M.namelist(t)
    return M.string(table.concat(t, ","))
end

-- ---- Reader: cursor over a byte-string ----------------------------

local Reader = {}
Reader.__index = Reader

function M.reader(s)
    return setmetatable({ s = s, pos = 1 }, Reader)
end

function Reader:remaining()
    return #self.s - self.pos + 1
end

function Reader:bytes(n)
    local e = self.pos + n - 1
    if e > #self.s then
        error("ssh.wire: short read (" .. n .. " bytes)", 2)
    end
    local out = string.sub(self.s, self.pos, e)
    self.pos = e + 1
    return out
end

function Reader:u8()
    local b = string.byte(self.s, self.pos)
    if not b then error("ssh.wire: short read (u8)", 2) end
    self.pos = self.pos + 1
    return b
end

function Reader:boolean()
    return self:u8() ~= 0
end

function Reader:u32()
    local a, b, c, d = string.byte(self.s, self.pos, self.pos + 3)
    if not d then error("ssh.wire: short read (u32)", 2) end
    self.pos = self.pos + 4
    -- bor of a shifted high byte can land in the negative 32-bit range;
    -- normalise to a non-negative Lua number.
    local v = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    if v < 0 then v = v + 4294967296 end
    return v
end

function Reader:string()
    return self:bytes(self:u32())
end

-- mpint reader: returns the raw signed magnitude bytes as received (no
-- normalisation).  Callers needing a fixed-width unsigned value strip/pad
-- themselves.  Minimal for now — we only consume peer mpints we hash.
function Reader:mpint()
    return self:string()
end

function Reader:namelist()
    local s = self:string()
    if s == "" then return {} end
    local out, from = {}, 1
    while true do
        local c = string.find(s, ",", from, true)
        if not c then
            out[#out + 1] = string.sub(s, from)
            break
        end
        out[#out + 1] = string.sub(s, from, c - 1)
        from = c + 1
    end
    return out
end

function Reader:rest()
    local out = string.sub(self.s, self.pos)
    self.pos = #self.s + 1
    return out
end

-- ---- Buf: accumulating writer -------------------------------------

local Buf = {}
Buf.__index = Buf

function M.buf()
    return setmetatable({ parts = {} }, Buf)
end

function Buf:raw(s)       self.parts[#self.parts + 1] = s;            return self end
function Buf:u8(n)        return self:raw(M.u8(n))                          end
function Buf:boolean(b)   return self:raw(M.boolean(b))                     end
function Buf:u32(n)       return self:raw(M.u32(n))                         end
function Buf:string(s)    return self:raw(M.string(s))                      end
function Buf:mpint(raw)   return self:raw(M.mpint(raw))                     end
function Buf:namelist(t)  return self:raw(M.namelist(t))                    end

function Buf:tostring()
    return table.concat(self.parts)
end

return M
