-- nt.term.render — the output half of the VT codec.
--
-- A renderer turns the line editor's declarative (text, cursor) state
-- into the bytes that make a VT terminal show it.  It is the ONLY place
-- that emits escape sequences; the editor stays pure data.  Because the
-- input is just state, a different renderer (a VGA cell grid, later) can
-- consume the same editor unchanged — that's the point of the split.
--
-- Stateful per line: it remembers what it last drew so each update is a
-- minimal delta, not a full redraw:
--   * typing at the end   -> emit the appended suffix only
--   * a cursor-only move   -> emit backspaces / re-emit the glyphs moved over
--   * anything else        -> repaint the line in place (\b… \27[K text)
-- Escape vocabulary kept deliberately tiny and VT100-safe: BS (0x08),
-- CR, and EL ("\27[K", erase to end of line).
--
--   local r = render.new("> ")
--   emit(r:open())                 -- draw the prompt, empty line
--   emit(r:sync(ed:text(), ed.pos))-- after each editing key
--   emit(r:list(cands, t, c))      -- show completion candidates, redraw
--   emit(r:commit())   / r:cancel()/ r:bell()

local M = {}

local R = {}
R.__index = R

function M.new(prompt)
    return setmetatable({
        prompt  = prompt or "",
        ptext   = "",      -- last text drawn
        pcursor = 0,       -- last cursor column drawn (chars from prompt end)
    }, R)
end

function R:setprompt(prompt)
    self.prompt = prompt or ""
end

-- Draw the prompt for a fresh, empty line.
function R:open()
    self.ptext, self.pcursor = "", 0
    return self.prompt
end

-- Emit the delta that turns the previously-drawn line into (text, cursor).
function R:sync(text, cursor)
    local pt, pc = self.ptext, self.pcursor
    local out
    if text == pt then                                   -- cursor move only
        if cursor < pc then
            out = string.rep("\b", pc - cursor)
        elseif cursor > pc then
            out = pt:sub(pc + 1, cursor)                 -- re-emit glyphs moved over
        else
            out = ""
        end
    elseif pc == #pt and cursor == #text
           and #text > #pt and text:sub(1, #pt) == pt then
        out = text:sub(#pt + 1)                          -- pure append at end
    else                                                 -- repaint in place
        out = string.rep("\b", pc) .. "\27[K" .. text
              .. string.rep("\b", #text - cursor)
    end
    self.ptext, self.pcursor = text, cursor
    return out
end

-- Print a completion candidate list on fresh lines, then redraw the
-- prompt and current line with the cursor restored.
function R:list(cands, text, cursor)
    self.ptext, self.pcursor = text, cursor
    return "\r\n" .. table.concat(cands, "  ") .. "\r\n"
        .. self.prompt .. text .. string.rep("\b", #text - cursor)
end

-- Finish the current line (Enter): move to the next row and forget the
-- drawn state so the next :open() starts clean.
function R:commit()
    self.ptext, self.pcursor = "", 0
    return "\r\n"
end

-- Abandon the current line (^C): echo the conventional marker and end
-- the row.
function R:cancel()
    self.ptext, self.pcursor = "", 0
    return "^C\r\n"
end

function R:bell()
    return "\7"
end

return M
