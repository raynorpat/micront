-- nt.term.edit — a reusable line editor (readline/linenoise-style).
--
-- Pure and declarative: it owns mutable state — a character buffer, a
-- cursor, and a history cursor — and consumes normalized key events via
-- :feed(kind, arg).  It emits NO bytes and knows NOTHING about VT: a
-- renderer (nt.term.render) diffs the editor's (text, cursor) state into
-- output for whatever surface it targets (serial VT today, VGA later).
-- That separation is what makes this embeddable in any app that wants a
-- prompt, independent of how the app draws.
--
--   local ed = edit.new{ history = sharedList, complete = fn }
--   local result, line = ed:feed(kind, arg)   -- (kind,arg) from nt.term.vt
--     result == R.NONE      still editing
--             == R.COMMIT    `line` is the finished line (also pushed to
--                            history); the editor has reset for the next
--             == R.EOF       ^D on an empty line
--             == R.INTERRUPT ^C; the line was abandoned, editor reset
--             == R.BELL      a no-op (e.g. completion found nothing)
--
-- Renderer-facing state: ed:text() (current line), ed.pos (cursor, count
-- of chars left of it), ed:take_completions() (a candidate list to show,
-- consumed once after a Tab that couldn't fill further).
--
-- The buffer is a table of one-character strings, mutated in place; a
-- line string is materialized only on commit / when a renderer asks for
-- :text().  Per keystroke the editor allocates nothing of consequence.
-- ASCII for now (one byte == one column); UTF-8 columns come later.

local keys = require('nt.term.keys')
local K, R = keys.K, keys.R

local M = {}

local E = {}
E.__index = E

function M.new(opts)
    opts = opts or {}
    local history = opts.history or {}
    return setmetatable({
        buf      = {},
        pos      = 0,                    -- chars left of the cursor (0..#buf)
        history  = history,
        hidx     = #history + 1,         -- one past the end = the live line
        live     = nil,                  -- live line stashed on first Up
        complete = opts.complete,
        cands    = nil,                  -- pending completion list to show
    }, E)
end

-- ---- state the renderer reads -----------------------------------

function E:text()
    return table.concat(self.buf)
end

-- A candidate list to display (set by a Tab that couldn't fill further),
-- returned once and cleared.
function E:take_completions()
    local c = self.cands
    self.cands = nil
    return c
end

-- ---- internal buffer ops ----------------------------------------

function E:_set_line(s)
    local b = {}
    for i = 1, #s do b[i] = s:sub(i, i) end
    self.buf, self.pos = b, #b
end

function E:_reset()
    self.buf, self.pos = {}, 0
    self.hidx, self.live = #self.history + 1, nil
end

-- ---- history ----------------------------------------------------

function E:_recall(dir)
    local h = self.history
    if dir < 0 then                      -- Up: older
        if self.hidx <= 1 then return end
        if self.hidx == #h + 1 then self.live = self:text() end
        self.hidx = self.hidx - 1
        self:_set_line(h[self.hidx])
    else                                 -- Down: newer
        if self.hidx >= #h + 1 then return end
        self.hidx = self.hidx + 1
        self:_set_line(self.hidx == #h + 1 and (self.live or "") or h[self.hidx])
    end
end

-- ---- completion -------------------------------------------------

local function common_prefix(a, b)
    local n, i = math.min(#a, #b), 0
    while i < n and a:byte(i + 1) == b:byte(i + 1) do i = i + 1 end
    return a:sub(1, i)
end

-- Replace buf[from..pos] with `repl`, leaving the tail right of the
-- cursor intact and the cursor at the end of the replacement.
function E:_replace_word(from, repl)
    local tail = {}
    for i = self.pos + 1, #self.buf do tail[#tail + 1] = self.buf[i] end
    local nb = {}
    for i = 1, from - 1 do nb[#nb + 1] = self.buf[i] end
    for i = 1, #repl    do nb[#nb + 1] = repl:sub(i, i) end
    self.pos = #nb
    for i = 1, #tail do nb[#nb + 1] = tail[i] end
    self.buf = nb
end

function E:_tab()
    if not self.complete then return R.BELL end
    local res  = self.complete(self:text(), self.pos)
    local cand = res and res.candidates
    if not cand or #cand == 0 then return R.BELL end
    local from = res.from or (self.pos + 1)
    if #cand == 1 then
        self:_replace_word(from, cand[1])
        return R.NONE
    end
    local lcp = cand[1]
    for i = 2, #cand do lcp = common_prefix(lcp, cand[i]) end
    local word = self:text():sub(from, self.pos)
    if #lcp > #word then
        self:_replace_word(from, lcp)
        return R.NONE
    end
    self.cands = cand                    -- can't grow → hand list to renderer
    return R.NONE
end

-- ---- the one entry point ----------------------------------------

function E:feed(kind, arg)
    if kind == K.TEXT then
        self.pos = self.pos + 1
        table.insert(self.buf, self.pos, string.char(arg))
        return R.NONE
    elseif kind == K.ENTER then
        local line = self:text()
        local h = self.history
        if #line > 0 and h[#h] ~= line then h[#h + 1] = line end
        self:_reset()
        return R.COMMIT, line
    elseif kind == K.BACKSPACE then
        if self.pos > 0 then
            table.remove(self.buf, self.pos)
            self.pos = self.pos - 1
        end
        return R.NONE
    elseif kind == K.DELETE then
        if self.pos < #self.buf then table.remove(self.buf, self.pos + 1) end
        return R.NONE
    elseif kind == K.LEFT then
        if self.pos > 0 then self.pos = self.pos - 1 end
        return R.NONE
    elseif kind == K.RIGHT then
        if self.pos < #self.buf then self.pos = self.pos + 1 end
        return R.NONE
    elseif kind == K.HOME then
        self.pos = 0
        return R.NONE
    elseif kind == K.END then
        self.pos = #self.buf
        return R.NONE
    elseif kind == K.UP then
        self:_recall(-1); return R.NONE
    elseif kind == K.DOWN then
        self:_recall(1);  return R.NONE
    elseif kind == K.TAB then
        return self:_tab()
    elseif kind == K.INTERRUPT then
        self:_reset()
        return R.INTERRUPT
    elseif kind == K.EOF then
        if #self.buf == 0 then return R.EOF end
        return R.NONE
    end
    return R.NONE                        -- CTRL / unknown: ignored
end

return M
