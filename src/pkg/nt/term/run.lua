-- nt.term.run — spawn a program attached to the serial console.
--
-- The composition that replaces the old nt.tty.run: serial console
-- (nt.term.console) + child pipes (nt.term.child) + the raw/cooked bridge
-- + the scheduler.  Owns nothing itself — it just wires the pieces and
-- runs the reactor until the child exits, then returns its exit status.
--
--   local status = run.cooked{ exe = exe, cmdline = cmd, cwd = ,
--                              dll_path = , env = , prompt = , log = }
--
-- cooked: keystrokes go through the line discipline (echo + editing +
-- CR->\n) and only whole lines reach the child — what an interactive REPL
-- wants.  (raw, when needed, would skip the discipline; agenthost's raw
-- path spawns with inherited stdio directly and doesn't come through here.)

local sched   = require('nt.term.sched')
local console = require('nt.term.console')
local child   = require('nt.term.child')
local bridge  = require('nt.term.bridge')

local M = {}

function M.cooked(opts)
    assert(opts and opts.exe, "run.cooked: opts.exe required")
    local log  = opts.log or function() end
    local term = console.open()
    local S    = sched.new()
    local out  = S:channel()              -- merged terminal output (echo + child)
    local c    = child.spawn(opts)
    log("term.run: spawned child under cooked console")

    -- ONE writer to the serial stream.  The stream has a single set of
    -- write state, so echo (from the line reader) and child output must be
    -- serialized through one task rather than written by both relays at
    -- once.  When the merged output drains to EOF — the child has exited
    -- and everything it printed is on screen — stop the reactor.  That
    -- abandons the input reader still parked on the (never-EOF) console;
    -- term:close() below cancels its pending read.  Draining BEFORE the
    -- stop is why the reader can't wake mid-teardown: while `out` has
    -- bytes the scheduler always has ready work and never kernel-waits, so
    -- the parked reader is never serviced, then we stop.
    S:spawn(function()
        while true do
            local d = out:read()
            if d == nil then break end
            term:write(d)
        end
        S:stop()
    end)

    bridge.cooked(S, term, out, c, {
        prompt  = opts.prompt,
        on_done = function() out:close() end,   -- child gone -> let the writer drain + stop
    })

    S:run()

    local status = c:wait()
    log("term.run: child exited status=0x" .. string.format("%08x", status))
    c:close()
    term:close()
    return status
end

return M
