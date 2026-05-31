-- io — Lua-side io module over nt.dll.fs.
--
-- Read-side coverage uses ntoskrnl.exe (large, well-known content) and
-- the registry hive's text artefacts. Write-side and seek/round-trip
-- coverage uses scratch files on the FAT root at \SystemRoot\.
-- Each write test cleans up after itself via os.remove (so a failed
-- pcall-isolated test doesn't leak a stale file into later tests).
--
-- Lifetime audit while reading these tests:
--   * Every io.open returns a File table holding an NT_HANDLE (self._h).
--     File:close goes through that NT_HANDLE wrapper — no raw HANDLE
--     ever surfaces to test code.
--   * Path strings to io.open / io.lines / os.remove are UTF-8 Lua
--     strings; conversion to UTF-16 happens inside oa.path / fs.set_rename.
--   * cdata buffers used internally by File:read / File:write are
--     local to the C-side wrappers; we never see them here.

local t   = require('test')
local io  = require('io')
local os  = require('os')

t.suite("io")

local SCRATCH = "\\SystemRoot\\__test_io.tmp"

-- Best-effort cleanup before each test that uses SCRATCH so leftover
-- state from a partially-failed prior run can't poison the result.
local function reset_scratch()
    os.remove(SCRATCH)
end

-- ------------------------------------------------------------------
-- Open / close / type
-- ------------------------------------------------------------------

t.test("io.open on missing file returns nil + errmsg", function()
    local f, err = io.open("\\SystemRoot\\__no_such_file.xyz", "r")
    t.eq(f, nil)
    t.ok(err and #err > 0, "got an error message")
end)

t.test("io.open on bad mode returns nil + errmsg", function()
    local f, err = io.open("\\SystemRoot\\anything", "zzz")
    t.eq(f, nil)
    t.ok(err and err:match("mode"), "errmsg mentions mode: " .. tostring(err))
end)

-- kernel32.dll is the canonical large PE on \SystemRoot — ntoskrnl.exe
-- and hal.dll are routed where='esp' (read by boot-efi pre-handoff)
-- and so don't appear under \SystemRoot in split layouts.
t.test("io.open kernel32 readable, io.type=='file'", function()
    local f = io.open("\\SystemRoot\\SYSTEM32\\KERNEL32.DLL", "rb")
    t.ne(f, nil)
    t.eq(io.type(f), "file")
    f:close()
    t.eq(io.type(f), "closed file")
end)

t.test("io.type returns nil for non-file values", function()
    t.eq(io.type(nil),     nil)
    t.eq(io.type("hello"), nil)
    t.eq(io.type({}),      nil)
    t.eq(io.type(42),      nil)
end)

t.test("close is idempotent", function()
    local f = io.open("\\SystemRoot\\SYSTEM32\\KERNEL32.DLL", "rb")
    t.eq(f:close(), true)
    t.eq(f:close(), true, "second close is a no-op, no raise")
end)

-- ------------------------------------------------------------------
-- Read formats
-- ------------------------------------------------------------------

t.test("read 'n' bytes — MZ magic from kernel32", function()
    local f = io.open("\\SystemRoot\\SYSTEM32\\KERNEL32.DLL", "rb")
    local two = f:read(2)
    t.eq(two, "MZ")
    f:close()
end)

t.test("read past EOF returns nil", function()
    -- Open kernel32, seek to end, read should give nil.
    local f = io.open("\\SystemRoot\\SYSTEM32\\KERNEL32.DLL", "rb")
    f:seek("end")
    t.eq(f:read(16), nil, "at EOF, read returns nil")
    f:close()
end)

t.test("read '*a' returns all bytes when small", function()
    -- Use a tiny scratch file so '*a' is fast.
    reset_scratch()
    local w = io.open(SCRATCH, "wb")
    w:write("hello, world\n")
    w:close()

    local r = io.open(SCRATCH, "rb")
    local all = r:read("*a")
    t.eq(all, "hello, world\n")
    r:close()
    os.remove(SCRATCH)
end)

t.test("read '*l' iterates lines, strips trailing \\r and \\n", function()
    reset_scratch()
    local w = io.open(SCRATCH, "wb")
    w:write("alpha\nbeta\r\ngamma")        -- last line has no trailing \n
    w:close()

    local r = io.open(SCRATCH, "rb")
    t.eq(r:read("*l"), "alpha")
    t.eq(r:read("*l"), "beta",  "CRLF stripped")
    t.eq(r:read("*l"), "gamma", "trailing line without \\n returned")
    t.eq(r:read("*l"), nil,     "next call returns nil at EOF")
    r:close()
    os.remove(SCRATCH)
end)

t.test("read with no args defaults to '*l'", function()
    reset_scratch()
    local w = io.open(SCRATCH, "wb")
    w:write("first\nsecond\n")
    w:close()
    local r = io.open(SCRATCH, "rb")
    t.eq(r:read(), "first")
    r:close()
    os.remove(SCRATCH)
end)

t.test("read multiple formats in one call returns multiple values", function()
    reset_scratch()
    local w = io.open(SCRATCH, "wb")
    w:write("ABCDEF\nXYZ\n")
    w:close()
    local r = io.open(SCRATCH, "rb")
    local a, b, c = r:read(3, "*l", "*l")
    t.eq(a, "ABC")
    t.eq(b, "DEF",  "after the 3 bytes, '*l' picks up the rest of line 1")
    t.eq(c, "XYZ")
    r:close()
    os.remove(SCRATCH)
end)

-- ------------------------------------------------------------------
-- Write
-- ------------------------------------------------------------------

t.test("write strings + numbers, chains via return self", function()
    reset_scratch()
    local f = io.open(SCRATCH, "wb")
    local same = f:write("A=", 42, " B=", 3.14, "\n")
    t.eq(same, f, "write returns the file for chaining")
    f:close()

    local r = io.open(SCRATCH, "rb")
    t.eq(r:read("*a"), "A=42 B=3.14\n")
    r:close()
    os.remove(SCRATCH)
end)

t.test("write rejects non-string/non-number", function()
    reset_scratch()
    local f = io.open(SCRATCH, "wb")
    t.raises(function() f:write({}) end, "write")
    f:close()
    os.remove(SCRATCH)
end)

-- ------------------------------------------------------------------
-- Seek
-- ------------------------------------------------------------------

t.test("seek 'set' / 'cur' / 'end' return new positions", function()
    reset_scratch()
    local w = io.open(SCRATCH, "wb")
    w:write("0123456789ABCDEF")             -- 16 bytes
    w:close()

    local r = io.open(SCRATCH, "rb")
    t.eq(r:seek("set", 4), 4)
    t.eq(r:read(2), "45")                    -- pos was 4, read 2
    t.eq(r:seek("cur", -3), 3)               -- back up 3 from cur (=6)
    t.eq(r:read(2), "34")
    t.eq(r:seek("end"), 16,  "seek to EOF reports total size")
    t.eq(r:read(1), nil,     "read at EOF returns nil")
    t.eq(r:seek("set", 0), 0)
    t.eq(r:read(4), "0123",  "seek invalidated buffer; re-read works")
    r:close()
    os.remove(SCRATCH)
end)

-- ------------------------------------------------------------------
-- Append mode
-- ------------------------------------------------------------------

t.test("'a' mode opens at EOF, preserves existing content", function()
    reset_scratch()
    local f = io.open(SCRATCH, "wb")
    f:write("first")
    f:close()

    local f2 = io.open(SCRATCH, "ab")
    f2:write(" second")
    f2:close()

    local r = io.open(SCRATCH, "rb")
    t.eq(r:read("*a"), "first second")
    r:close()
    os.remove(SCRATCH)
end)

-- ------------------------------------------------------------------
-- Lines iteration
-- ------------------------------------------------------------------

t.test("io.lines iterates a file then closes", function()
    reset_scratch()
    local w = io.open(SCRATCH, "wb")
    w:write("a\nb\nc\n")
    w:close()

    local got = {}
    for line in io.lines(SCRATCH) do
        got[#got+1] = line
    end
    t.eq(#got, 3)
    t.eq(got[1], "a")
    t.eq(got[2], "b")
    t.eq(got[3], "c")
    os.remove(SCRATCH)
end)

t.test("file:lines iterates without closing", function()
    reset_scratch()
    local w = io.open(SCRATCH, "wb")
    w:write("x\ny\n")
    w:close()

    local r = io.open(SCRATCH, "rb")
    local got = {}
    for line in r:lines() do got[#got+1] = line end
    t.eq(#got, 2)
    t.eq(io.type(r), "file", "file:lines doesn't auto-close")
    r:close()
    os.remove(SCRATCH)
end)

-- ------------------------------------------------------------------
-- Operations on closed files / unsupported APIs
-- ------------------------------------------------------------------

t.test("read on closed file raises", function()
    local f = io.open("\\SystemRoot\\SYSTEM32\\KERNEL32.DLL", "rb")
    f:close()
    t.raises(function() f:read(2) end, "closed")
end)

t.test("flush returns the file (no-op stub)", function()
    reset_scratch()
    local f = io.open(SCRATCH, "wb")
    t.eq(f:flush(), f)
    f:close()
    os.remove(SCRATCH)
end)

t.test("setvbuf returns the file (no-op stub)", function()
    reset_scratch()
    local f = io.open(SCRATCH, "wb")
    t.eq(f:setvbuf("no"),   f)
    t.eq(f:setvbuf("full", 4096), f)
    f:close()
    os.remove(SCRATCH)
end)

t.test("io.popen / tmpfile raise with clear message", function()
    t.raises(io.popen,   "popen")
    t.raises(io.tmpfile, "tmpfile")
end)

-- ------------------------------------------------------------------
-- Standard streams (io.stdin / io.stdout / io.stderr) + default I/O
-- ------------------------------------------------------------------
--
-- These wrap the inherited PEB Standard{Input,Output,Error} handles — on
-- micront the serial console.  We never read from the live console here
-- (that would block the suite waiting for a keystroke); instead we drive
-- io.read / io.write through io.input / io.output redirected at a scratch
-- file, which exercises the exact same code path without needing input.

t.test("io.stdin/stdout/stderr are inherited file objects", function()
    t.eq(io.type(io.stdin),  "file", "stdin wired from PEB StandardInput")
    t.eq(io.type(io.stdout), "file", "stdout wired from PEB StandardOutput")
    t.eq(io.type(io.stderr), "file", "stderr wired from PEB StandardError")
end)

t.test("io.input()/io.output() default to stdin/stdout", function()
    t.eq(io.input(),  io.stdin)
    t.eq(io.output(), io.stdout)
end)

t.test("io.input(filename) redirects io.read, then restores", function()
    reset_scratch()
    local w = io.open(SCRATCH, "wb")
    w:write("line1\nline2\n")
    w:close()

    local prev = io.input()
    local f = io.input(SCRATCH)                -- open + install as default input
    t.eq(io.type(f), "file")
    t.eq(io.read("*l"), "line1", "io.read pulls from the redirected input")
    t.eq(io.read("*l"), "line2")
    f:close()
    io.input(prev)                             -- restore the console as stdin
    t.eq(io.input(), prev)
    os.remove(SCRATCH)
end)

t.test("io.output(filename) redirects io.write, then restores", function()
    reset_scratch()
    local prev = io.output()
    local f = io.output(SCRATCH)
    local ret = io.write("hello ", 123, "\n")
    t.eq(ret, f, "io.write returns the default output file for chaining")
    f:close()
    io.output(prev)                            -- restore the console as stdout
    t.eq(io.output(), prev)

    local r = io.open(SCRATCH, "rb")
    t.eq(r:read("*a"), "hello 123\n")
    r:close()
    os.remove(SCRATCH)
end)

t.test("io.lines() with no filename returns an iterator over stdin", function()
    -- Just confirm we get an iterator (the old code raised here). Don't
    -- pull from it — that would block on the console.
    t.eq(type(io.lines()), "function")
end)
