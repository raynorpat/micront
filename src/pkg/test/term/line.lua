-- nt.term.line — end-to-end readline over the scheduler.
--
-- This is the integration test for the whole logic stack: a driver task
-- writes raw keystroke bytes into an in-process channel; the reader task
-- runs rl:read() (vt decode -> edit -> render) and echoes back through a
-- second channel a collector drains.  All cooperative, no kernel — the
-- same wiring a serial backend will slot under later.

local t     = require('test')
local sched = require('nt.term.sched')
local line  = require('nt.term.line')

t.suite("nt.term.line: readline end-to-end")

-- Run one reader against a scripted sequence of keystroke bytes.  Returns
-- (committed-line, echoed-bytes).  `keys` is the raw byte string the
-- "terminal" sends; opts passes through to line.new (prompt/history/...).
local function session(keystrokes, opts)
    local S      = sched.new()
    local inp    = S:channel()
    local outp   = S:channel()
    opts = opts or {}
    opts.input, opts.output = inp, outp
    local rl     = line.new(opts)

    local got, echo = nil, {}
    S:spawn(function()                       -- reader
        got = rl:read()
        outp:close()                         -- let the collector finish
    end)
    S:spawn(function()                       -- collector
        while true do
            local d = outp:read()
            if d == nil then break end
            echo[#echo+1] = d
        end
    end)
    S:spawn(function() inp:write(keystrokes) end)
    S:run()
    return got, table.concat(echo)
end

t.test("a simple line: prompt, echo, commit", function()
    local got, echo = session("hi\r", { prompt = "> " })
    t.eq(got, "hi")
    t.eq(echo, "> hi\r\n")
end)

t.test("backspace mid-typing edits the committed line", function()
    local got = session("abc\127d\r")          -- 0x7F erases the c
    t.eq(got, "abd")
end)

t.test("arrow-left then insert lands mid-line", function()
    -- type "ac", Left, "b", Enter -> "abc"
    local got = session("ac\27[Db\r")
    t.eq(got, "abc")
end)

t.test("Home + forward-delete removes the first glyph", function()
    local got = session("abc\27[H\27[3~\r")    -- Home, Delete
    t.eq(got, "bc")
end)

t.test("^D on an empty line ends the stream (nil)", function()
    local got = session("\4")
    t.eq(got, nil)
end)

t.test("^C abandons the line; the next line still commits", function()
    -- "junk" ^C "ok" Enter — within ONE read() the ^C resets and a fresh
    -- prompt is drawn; the committed line is "ok".
    local got, echo = session("junk\3ok\r", { prompt = "> " })
    t.eq(got, "ok")
    t.ok(echo:find("%^C\r\n"), "the ^C marker was echoed")
end)

t.test("history recall across two reads on one reader", function()
    -- Drive two reads on a single reader sharing history: commit "first",
    -- then on the second line press Up to recall it and commit.
    local S    = sched.new()
    local inp  = S:channel()
    local outp = S:channel()
    local rl   = line.new{ input = inp, output = outp, prompt = "> " }
    local lines = {}
    S:spawn(function()
        lines[1] = rl:read()                 -- expects "first\r"
        lines[2] = rl:read()                 -- expects Up + Enter -> "first"
        outp:close()
    end)
    S:spawn(function() while outp:read() ~= nil do end end)  -- drain echo
    S:spawn(function()
        inp:write("first\r")
        sched.pass()                          -- let the first read() commit
        inp:write("\27[A\r")                  -- Up, Enter
    end)
    S:run()
    t.eq(lines[1], "first")
    t.eq(lines[2], "first", "Up recalled the previous line")
end)

t.test("Tab completion fills inline", function()
    local complete = function(linetext, pos)
        if linetext:sub(1, pos) == "Re" then
            return { from = 1, candidates = { "Registry" } }
        end
    end
    local got = session("Re\t\r", { complete = complete })
    t.eq(got, "Registry")
end)

t.test("a paste spanning Enter keeps the remainder for the next read", function()
    -- One write delivers two lines; two reads on one reader return both.
    local S    = sched.new()
    local inp  = S:channel()
    local outp = S:channel()
    local rl   = line.new{ input = inp, output = outp }
    local lines = {}
    S:spawn(function()
        lines[1] = rl:read()
        lines[2] = rl:read()
        outp:close()
    end)
    S:spawn(function() while outp:read() ~= nil do end end)
    S:spawn(function() inp:write("one\rtwo\r") end)
    S:run()
    t.eq(lines[1], "one")
    t.eq(lines[2], "two", "the second line survived in the carry-over buffer")
end)
