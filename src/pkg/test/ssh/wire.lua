-- test.ssh.wire — SSH wire types (RFC 4251 §5) + the `none` packet
-- framing (RFC 4253 §6).  Pure Lua: no djbcrypt.dll, no kernel, runs
-- anywhere LuaJIT does.

local t      = require('test')
local wire   = require('ssh.wire')
local packet = require('ssh.packet')

t.suite("ssh.wire")

t.test("primitive encoders round-trip through Reader", function()
    local b = wire.buf()
    b:u8(20):u32(305419896):boolean(true)
     :string("hello"):namelist({ "a", "bb", "ccc" })
    local r = wire.reader(b:tostring())
    t.eq(r:u8(), 20)
    t.eq(r:u32(), 305419896)            -- 0x12345678
    t.eq(r:boolean(), true)
    t.eq(r:string(), "hello")
    local nl = r:namelist()
    t.eq(#nl, 3); t.eq(nl[1], "a"); t.eq(nl[3], "ccc")
    t.eq(r:remaining(), 0)
end)

t.test("u32 survives the high bit (no sign mangling)", function()
    t.eq(wire.reader(wire.u32(0xFFFFFFFF)):u32(), 0xFFFFFFFF)
    t.eq(wire.reader(wire.u32(0x80000000)):u32(), 0x80000000)
end)

t.test("mpint encoding (RFC 4251 §5)", function()
    -- high bit set -> 0x00 prefix so the value stays positive
    t.eq(wire.mpint("\255\0"), wire.string("\0\255\0"))
    -- leading zero octets stripped
    t.eq(wire.mpint("\0\0\1"), wire.string("\1"))
    -- zero -> empty string (length 0)
    t.eq(wire.mpint("\0\0"), wire.u32(0))
end)

t.test("empty name-list decodes to {}", function()
    local r = wire.reader(wire.namelist({}))
    t.eq(#r:namelist(), 0)
end)

t.suite("ssh.packet")

t.test("none transform: seal/read round-trip, block-aligned", function()
    local c = packet.none()
    local cases = { "\20", "\20abc", string.rep("x", 100), string.rep("\0", 7) }
    for _, payload in ipairs(cases) do
        local w = c:seal(0, payload)
        t.eq(#w % c.block_size, 0, "wire length is a block multiple")
        local pos = 1
        local function read_exact(n)
            local s = string.sub(w, pos, pos + n - 1)
            pos = pos + n
            return s
        end
        t.eq(c:read(0, read_exact), payload, "payload survives round-trip")
    end
end)

t.test("none transform: minimum padding is 4 bytes", function()
    local c = packet.none()
    -- empty payload: 4 (len) + 1 (padlen) = 5, pad to 8 would be 3 < 4,
    -- so it must bump to 11 -> packet rounds to 16 total on the wire.
    local w = c:seal(0, "")
    t.eq(#w % 8, 0)
    t.ok(#w >= 8 + 4)
end)
