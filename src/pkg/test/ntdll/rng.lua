-- nt.dll.rng — NtGenerateSecureRandom (the kernel CSPRNG).
--
-- Exercises the draw path end to end: that it returns the requested number
-- of bytes, that successive draws differ (the pool advances + ratchets), and
-- that a bogus buffer pointer fails cleanly via the kernel probe/SEH rather
-- than bugchecking — if it bugchecked, the VM would die and the suite would
-- never report.

local ffi = require('ffi')
local t   = require('test')
local rng = require('nt.dll.rng')

t.suite("rng")

t.test("bytes(0) returns empty string", function()
    t.eq(rng.bytes(0), "")
end)

t.test("bytes(n) returns exactly n bytes", function()
    t.eq(#rng.bytes(1),  1)
    t.eq(#rng.bytes(32), 32)
    t.eq(#rng.bytes(40), 40)        -- not a multiple of the 16-byte rate
    t.eq(#rng.bytes(600), 600)      -- spans many squeeze blocks
end)

t.test("successive draws differ", function()
    t.ne(rng.bytes(32), rng.bytes(32))
end)

t.test("a large draw is not all-zero", function()
    t.ne(rng.bytes(64), string.rep("\0", 64))
end)

t.test("generate() into a valid buffer succeeds", function()
    local buf = ffi.new('unsigned char[32]')
    t.eq(rng.generate(buf, 32), 0)              -- STATUS_SUCCESS
end)

t.test("kernel-range buffer pointer fails cleanly (no bugcheck)", function()
    -- 0x80000000 is above the user probe limit; ProbeForWrite must reject it
    -- and the syscall must return an error status, leaving the system alive.
    local bad = ffi.cast('void *', 0x80000000)
    t.ne(rng.generate(bad, 16), 0)
end)
