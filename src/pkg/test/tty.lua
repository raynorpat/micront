-- nt.tty — line-discipline state machine (tty.lineedit).
--
-- These exercise the PURE part of nt.tty: feeding raw input bytes and
-- checking the (echo, committed-line) the discipline produces.  No pipes,
-- threads, or child processes — tty.run's I/O plumbing is covered by the
-- live interactive console, not here.

local t   = require('test')
local tty = require('nt.tty')

t.suite("nt.tty: lineedit")

-- Drive a string of raw bytes through one editor; return the concatenated
-- echo and the list of committed lines.
local function drive(ed, s)
    local echo, lines = {}, {}
    for i = 1, #s do
        local e, line = ed:feed(s:byte(i))
        echo[#echo + 1] = e
        if line ~= nil then lines[#lines + 1] = line end
    end
    return table.concat(echo), lines
end

t.test("module surface", function()
    t.eq(type(tty.lineedit), "function")
    t.eq(type(tty.run),      "function")
end)

t.test("printable chars echo and commit on CR", function()
    local ed = tty.lineedit()
    local echo, lines = drive(ed, "ab\r")        -- 0x0D = Enter
    t.eq(echo, "ab\r\n")                          -- each char echoed, CR -> CRLF
    t.eq(#lines, 1)
    t.eq(lines[1], "ab")
end)

t.test("LF also commits a line", function()
    local _, lines = drive(tty.lineedit(), "x\n") -- 0x0A
    t.eq(lines[1], "x")
end)

t.test("backspace (DEL 0x7F) erases last glyph", function()
    local ed = tty.lineedit()
    local echo, lines = drive(ed, "ab\127c\r")
    t.eq(lines[1], "ac",  "the deleted char is gone from the committed line")
    t.eq(echo, "ab\b \bc\r\n", "erase echoes back-space-back")
end)

t.test("backspace 0x08 also erases", function()
    local _, lines = drive(tty.lineedit(), "ab\8\r")
    t.eq(lines[1], "a")
end)

t.test("backspace on empty line is a no-op", function()
    local ed = tty.lineedit()
    local echo, lines = drive(ed, "\127\r")
    t.eq(echo, "\r\n", "no erase echo when nothing to delete")
    t.eq(lines[1], "")
end)

t.test("CSI escape (arrow key) is swallowed, not buffered", function()
    -- Up arrow = ESC [ A.  It must not corrupt the line.
    local _, lines = drive(tty.lineedit(), "a\27[Ab\r")
    t.eq(lines[1], "ab", "arrow key dropped, surrounding chars intact")
end)

t.test("SS3 escape (F-key) is swallowed", function()
    -- ESC O P = F1.
    local _, lines = drive(tty.lineedit(), "\27OPz\r")
    t.eq(lines[1], "z")
end)

t.test("multi-byte CSI with parameters is fully consumed", function()
    -- PgUp = ESC [ 5 ~ ; final byte '~' (0x7E) ends it.
    local _, lines = drive(tty.lineedit(), "q\27[5~w\r")
    t.eq(lines[1], "qw")
end)

t.test("Ctrl-C cancels the current line", function()
    local ed = tty.lineedit()
    local echo, lines = drive(ed, "abc\3x\r")     -- 0x03 = ETX
    t.eq(echo:find("%^C\r\n") ~= nil, true, "echoes ^C and a newline")
    t.eq(lines[1], "x", "the abc before Ctrl-C is discarded")
end)

t.test("several lines commit in order", function()
    local _, lines = drive(tty.lineedit(), "one\rtwo\rthree\r")
    t.eq(#lines, 3)
    t.eq(lines[1], "one")
    t.eq(lines[2], "two")
    t.eq(lines[3], "three")
end)

t.test("non-printable control bytes are ignored", function()
    -- A bare Tab (0x09) and NUL (0x00) shouldn't reach the line.
    local _, lines = drive(tty.lineedit(), "a\9\0b\r")
    t.eq(lines[1], "ab")
end)
