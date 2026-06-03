-- nt.term.bridge — connect a terminal to a child, raw or cooked.
--
-- Two relay tasks on a scheduler shuttle bytes between a terminal (the
-- `tin`/`tout` transports — channels in-process, or a console stream) and
-- a child's stdin/stdout.  The ONLY difference between the modes is what
-- sits in the middle:
--
--   raw    — nothing.  Bytes pass through verbatim, both ways.  CR stays
--            CR, control bytes survive, no echo.
--   cooked — a managed filter: an nt.term.line reader cooks the terminal
--            input (echo + in-line editing + CR->\n) and forwards only
--            whole committed lines to the child.  This is the line
--            discipline as a pluggable stage you can inspect and swap.
--
-- Lifecycle: each relay ends when its upstream ends — terminal-EOF closes
-- the child's stdin; child-stdout-EOF fires `on_done`.  The terminal-input
-- relay ALWAYS closes the child's stdin on terminal EOF (the child needs
-- that to finish reading).  What happens when the CHILD's output ends is
-- the caller's policy via opts.on_done (default: close the terminal output
-- — right for a channel collector or a throwaway pipe).  A persistent
-- console overrides it (e.g. to drain + stop the reactor) because closing
-- the live console out from under the input relay would race its read.

local line = require('nt.term.line')

local M = {}

local function default_done(tout)
    return function() tout:close() end
end

-- raw: byte-transparent both directions.
function M.raw(S, tin, tout, child, opts)
    local on_done = (opts and opts.on_done) or default_done(tout)
    S:spawn(function()                       -- terminal -> child stdin
        while true do
            local d = tin:read()
            if d == nil then child.stdin:close(); break end
            child.stdin:write(d)
        end
    end)
    S:spawn(function()                       -- child stdout -> terminal
        while true do
            local d = child.stdout:read()
            if d == nil then on_done(); break end
            tout:write(d)
        end
    end)
end

-- cooked: the line discipline is the filter; only committed lines (with a
-- trailing \n) reach the child.  opts.onlcr turns on the OUTPUT half of the
-- discipline (a tty's OPOST/ONLCR): the child writes bare \n, but a terminal
-- in raw mode — an SSH pty client, say — needs \r\n or its lines staircase, so
-- child output gets bare LF -> CRLF.  (The line editor's own echo already
-- emits \r\n via the renderer, so only the child's stream is cooked here.)
function M.cooked(S, tin, tout, child, opts)
    local on_done = (opts and opts.on_done) or default_done(tout)
    local onlcr   = opts and opts.onlcr
    local rl = line.new{ input = tin, output = tout,
                         prompt = opts and opts.prompt or "" }
    S:spawn(function()                       -- terminal -> cook -> child stdin
        while true do
            local ln = rl:read()
            if ln == nil then child.stdin:close(); break end
            child.stdin:write(ln .. "\n")
        end
    end)
    S:spawn(function()                       -- child stdout -> terminal
        while true do
            local d = child.stdout:read()
            if d == nil then on_done(); break end
            if onlcr then d = (d:gsub("\r?\n", "\r\n")) end
            tout:write(d)
        end
    end)
end

return M
