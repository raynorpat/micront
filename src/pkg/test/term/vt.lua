-- nt.term.vt — byte → key-event decoder.
--
-- Pure: feed raw bytes, assert the (kind, arg) pairs that complete.  The
-- VT/ANSI sequence vocabulary is pinned here so nothing above the codec
-- ever has to parse an escape byte.

local t  = require('test')
local vt = require('nt.term.vt')
local K  = require('nt.term.keys').K

t.suite("nt.term.vt: input decoder")

-- Drive a byte string through one decoder; collect completed events as
-- {kind, arg} pairs (a table per event is fine here — test code, not the
-- hot path the decoder itself runs).
local function decode(s)
    local d, out = vt.decoder(), {}
    for i = 1, #s do
        local kind, arg = d:feed(s:byte(i))
        if kind ~= nil then out[#out+1] = { kind, arg } end
    end
    return out
end

local function one(s)
    local out = decode(s)
    t.eq(#out, 1, "exactly one event for " .. ("%q"):format(s))
    return out[1]
end

t.test("printable -> TEXT(byte)", function()
    local e = one("a")
    t.eq(e[1], K.TEXT)
    t.eq(e[2], 97)
end)

t.test("CR and LF both -> ENTER", function()
    t.eq(one("\r")[1], K.ENTER)
    t.eq(one("\n")[1], K.ENTER)
end)

t.test("BS and DEL both -> BACKSPACE", function()
    t.eq(one("\8")[1],   K.BACKSPACE)
    t.eq(one("\127")[1], K.BACKSPACE)
end)

t.test("TAB / ^C / ^D map to TAB / INTERRUPT / EOF", function()
    t.eq(one("\9")[1], K.TAB)
    t.eq(one("\3")[1], K.INTERRUPT)
    t.eq(one("\4")[1], K.EOF)
end)

t.test("CSI arrows decode to UP/DOWN/RIGHT/LEFT", function()
    t.eq(one("\27[A")[1], K.UP)
    t.eq(one("\27[B")[1], K.DOWN)
    t.eq(one("\27[C")[1], K.RIGHT)
    t.eq(one("\27[D")[1], K.LEFT)
end)

t.test("SS3 arrows (application mode) decode the same", function()
    t.eq(one("\27OA")[1], K.UP)
    t.eq(one("\27OD")[1], K.LEFT)
end)

t.test("CSI Home/End letters", function()
    t.eq(one("\27[H")[1], K.HOME)
    t.eq(one("\27[F")[1], K.END)
end)

t.test("numpad ~ family: 1~/7~ Home, 4~/8~ End, 3~ Delete", function()
    t.eq(one("\27[1~")[1], K.HOME)
    t.eq(one("\27[7~")[1], K.HOME)
    t.eq(one("\27[4~")[1], K.END)
    t.eq(one("\27[8~")[1], K.END)
    t.eq(one("\27[3~")[1], K.DELETE)
end)

t.test("modifier parameter is accepted, modifier ignored", function()
    -- Ctrl+Left = ESC [ 1 ; 5 D — decodes as LEFT (modifier dropped).
    t.eq(one("\27[1;5D")[1], K.LEFT)
end)

t.test("unrecognized sequences are swallowed, surrounding text intact", function()
    -- PgUp (ESC[5~) and F1 (ESC O P) yield no event; the a/b around them
    -- still arrive as TEXT.
    local out = decode("a\27[5~b")
    t.eq(#out, 2)
    t.eq(out[1][2], 97)   -- 'a'
    t.eq(out[2][2], 98)   -- 'b'
    t.eq(#decode("\27OP"), 0, "F1 swallowed")
end)

t.test("lone ESC and stray control bytes are dropped", function()
    t.eq(#decode("\27"), 0, "bare ESC, no follow byte")
    t.eq(#decode("\0\1\30"), 0, "NUL and misc control")
end)

t.test("a split escape sequence across feeds still decodes", function()
    -- One byte at a time is exactly how the reader feeds it.
    local out = decode("x\27[Dy")
    t.eq(#out, 3)
    t.eq(out[1][1], K.TEXT)
    t.eq(out[2][1], K.LEFT)
    t.eq(out[3][1], K.TEXT)
end)
