-- nt.term.line — a line reader: the readline loop over a transport.
--
-- This is the seam where the pure pieces meet a transport.  It owns a vt
-- decoder, an editor, and a renderer, and drives them from bytes the
-- transport delivers — issuing echo back through the transport.  It does
-- NOT know what the transport is: an in-process channel (nt.term.sched),
-- a pipe to another lua_State, or a serial console all present the same
-- blocking read()/write(), and read() simply parks the calling task when
-- there's nothing yet.  So the same reader serves a local console and a
-- remote session unchanged.
--
--   local rl = line.new{ input = t, output = t,   -- t may be one duplex
--                        prompt = "> ", history = hist, complete = fn }
--   local s = rl:read()        -- run inside a scheduler task:
--                              --   a committed line string, or nil at EOF
--
-- Bytes read past a committed line (a paste that spans Enter) are kept
-- and consumed by the next :read(), so nothing is dropped.

local vt     = require('nt.term.vt')
local edit   = require('nt.term.edit')
local render = require('nt.term.render')
local R      = require('nt.term.keys').R

local M = {}

local RL = {}
RL.__index = RL

function M.new(opts)
    assert(opts and opts.input, "line.new: opts.input transport required")
    return setmetatable({
        input  = opts.input,
        output = opts.output or opts.input,    -- one duplex transport by default
        dec    = vt.decoder(),
        ed     = edit.new{ history = opts.history, complete = opts.complete },
        r      = render.new(opts.prompt or ""),
        pbuf   = "",                            -- bytes read past the last line
        pi     = 1,
    }, RL)
end

function RL:setprompt(p) self.r:setprompt(p) end

-- One byte from the transport, draining any carry-over from a previous
-- read() first.  Returns nil at end of stream.  Parks the task (via the
-- transport's read()) when nothing is buffered.
function RL:_byte()
    while self.pi > #self.pbuf do
        local chunk = self.input:read()
        if chunk == nil then return nil end
        self.pbuf, self.pi = chunk, 1
    end
    local b = self.pbuf:byte(self.pi)
    self.pi = self.pi + 1
    return b
end

local function w(self, bytes)
    if bytes and #bytes > 0 then self.output:write(bytes) end
end

-- Read one line.  Returns the committed string, or nil at EOF.
function RL:read()
    w(self, self.r:open())
    while true do
        local b = self:_byte()
        if b == nil then return nil end
        local kind, arg = self.dec:feed(b)
        if kind ~= nil then
            local result, line = self.ed:feed(kind, arg)
            if result == R.COMMIT then
                w(self, self.r:commit())
                return line
            elseif result == R.EOF then
                return nil
            elseif result == R.INTERRUPT then
                w(self, self.r:cancel())
                w(self, self.r:open())          -- fresh prompt, same call
            elseif result == R.BELL then
                w(self, self.r:bell())
            else
                w(self, self.r:sync(self.ed:text(), self.ed.pos))
                local cands = self.ed:take_completions()
                if cands then
                    w(self, self.r:list(cands, self.ed:text(), self.ed.pos))
                end
            end
        end
    end
end

return M
