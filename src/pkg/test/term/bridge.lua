-- nt.term.bridge / nt.term.child — raw vs cooked, against a REAL child.
--
-- BOOT-ONLY: spawns \SystemRoot\System32\lua.exe with its stdin/stdout on
-- overlapped pipes and bridges it to an in-process "terminal" made of two
-- sched channels.  So one scheduler juggles cooperative channel handoffs
-- (the terminal side) AND real overlapped pipe I/O to a separate process
-- (the child side) at once — the async integration we want to prove.
--
-- The child fixtures (test.term.prog.raw / .cooked) read their stdin and
-- echo it back wrapped in [...], so the parent can extract exactly what
-- the child received and contrast the two modes:
--   raw    — bytes verbatim, no echo, no framing (CR and BS survive).
--   cooked — the line discipline edits + frames; whole lines arrive.

local t      = require('test')
local sched  = require('nt.term.sched')
local bridge = require('nt.term.bridge')
local child  = require('nt.term.child')

t.suite("nt.term.bridge: raw/cooked over a spawned process")

local LUA_EXE = "\\SystemRoot\\System32\\lua.exe"

-- Spawn `prog` (a require path) under `modefn` (bridge.raw/bridge.cooked),
-- feed it `input` as terminal keystrokes, and return everything the
-- terminal side received back (echo + the child's bracketed report).
local function drive(modefn, prog, input)
    local S    = sched.new()
    local tin  = S:channel()        -- terminal -> bridge (keystrokes)
    local tout = S:channel()        -- bridge -> terminal (echo + child out)
    local c    = child.spawn{
        exe     = LUA_EXE,
        cmdline = string.format('"lua.exe" -e "require(\'%s\')"', prog),
    }
    modefn(S, tin, tout, c)
    local got = {}
    S:spawn(function()
        while true do
            local d = tout:read()
            if d == nil then break end
            got[#got + 1] = d
        end
    end)
    S:spawn(function() tin:write(input); tin:close() end)

    local ok, err = pcall(function() S:run() end)
    c:close()                       -- always reap the child + handles
    if not ok then error(err, 0) end
    return table.concat(got)
end

t.test("raw: bytes reach the child verbatim, no echo, no framing", function()
    local out = drive(bridge.raw, "test.term.prog.raw", "ab\bc\r")
    -- Raw has no echo, so the whole terminal output IS the child's report.
    t.eq(out:sub(1, 3), "<R>", "no echo precedes the child output in raw")
    t.eq(out:match("<R>(.-)</R>"), "ab\bc\r",
         "CR and backspace bytes survived untouched")
end)

t.test("cooked: editing + CR->\\n; the line arrives whole", function()
    -- "ab", backspace (drops b), "c", Enter  ->  the child reads "ac"
    local out = drive(bridge.cooked, "test.term.prog.cooked", "ab\bc\r")
    t.eq(out:match("<R>(.-)</R>"), "ac",
         "the discipline edited and delivered one finished line")
end)

t.test("cooked: a multi-line burst frames into separate lines", function()
    -- One write spans two Enters; the child sees two whole lines.
    local out = drive(bridge.cooked, "test.term.prog.cooked", "one\rtwo\r")
    local parts = {}
    for p in out:gmatch("<R>(.-)</R>") do parts[#parts + 1] = p end
    t.eq(table.concat(parts, ","), "one,two")
end)

t.test("cooked: keystrokes are echoed to the terminal", function()
    local out = drive(bridge.cooked, "test.term.prog.cooked", "hi\r")
    local pre = out:match("^(.-)<R>")          -- echo precedes child output
    t.ok(pre and pre:find("hi"), "typed characters were echoed back")
end)
