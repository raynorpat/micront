-- nt.term.edit — the reusable line editor.
--
-- Pure: feed normalized key events, assert the (text, cursor) state, the
-- result enum, and history/completion behaviour.  No bytes, no VT — the
-- renderer is tested separately.

local t    = require('test')
local edit = require('nt.term.edit')
local keys = require('nt.term.keys')
local K, R = keys.K, keys.R

t.suite("nt.term.edit: line editor")

-- Type a run of printable characters.
local function typ(ed, s)
    for i = 1, #s do ed:feed(K.TEXT, s:byte(i)) end
end

t.test("typing appends and tracks the cursor", function()
    local ed = edit.new()
    typ(ed, "abc")
    t.eq(ed:text(), "abc")
    t.eq(ed.pos, 3)
end)

t.test("Enter commits the line and resets the editor", function()
    local ed = edit.new()
    typ(ed, "hello")
    local r, line = ed:feed(K.ENTER, 0)
    t.eq(r, R.COMMIT)
    t.eq(line, "hello")
    t.eq(ed:text(), "", "editor reset after commit")
    t.eq(ed.pos, 0)
end)

t.test("backspace erases left of cursor; mid-line keeps the tail", function()
    local ed = edit.new()
    typ(ed, "abc")
    ed:feed(K.LEFT, 0)                 -- cursor between b and c
    ed:feed(K.BACKSPACE, 0)            -- remove b
    t.eq(ed:text(), "ac")
    t.eq(ed.pos, 1)
end)

t.test("left/right/home/end move without mutating", function()
    local ed = edit.new()
    typ(ed, "abcd")
    ed:feed(K.HOME, 0); t.eq(ed.pos, 0)
    ed:feed(K.RIGHT, 0); t.eq(ed.pos, 1)
    ed:feed(K.END, 0);  t.eq(ed.pos, 4)
    ed:feed(K.LEFT, 0); t.eq(ed.pos, 3)
    t.eq(ed:text(), "abcd", "navigation never changes the text")
end)

t.test("insert in the middle lands at the cursor", function()
    local ed = edit.new()
    typ(ed, "ac")
    ed:feed(K.LEFT, 0)                 -- between a and c
    ed:feed(K.TEXT, ("b"):byte())
    t.eq(ed:text(), "abc")
    t.eq(ed.pos, 2)
end)

t.test("forward delete removes the glyph under the cursor", function()
    local ed = edit.new()
    typ(ed, "abc")
    ed:feed(K.HOME, 0)
    ed:feed(K.DELETE, 0)
    t.eq(ed:text(), "bc")
    t.eq(ed.pos, 0)
end)

t.test("^D on an empty line is EOF; on a non-empty line it's ignored", function()
    local ed = edit.new()
    t.eq((ed:feed(K.EOF, 0)), R.EOF)
    typ(ed, "x")
    t.eq((ed:feed(K.EOF, 0)), R.NONE)
    t.eq(ed:text(), "x")
end)

t.test("^C abandons the line and reports INTERRUPT", function()
    local ed = edit.new()
    typ(ed, "junk")
    local r = ed:feed(K.INTERRUPT, 0)
    t.eq(r, R.INTERRUPT)
    t.eq(ed:text(), "")
end)

t.test("committed non-empty lines accumulate in shared history", function()
    local hist = {}
    local ed = edit.new{ history = hist }
    typ(ed, "one"); ed:feed(K.ENTER, 0)
    typ(ed, "two"); ed:feed(K.ENTER, 0)
    t.eq(#hist, 2)
    t.eq(hist[1], "one")
    t.eq(hist[2], "two")
end)

t.test("empty lines and immediate dupes are not added to history", function()
    local hist = {}
    local ed = edit.new{ history = hist }
    ed:feed(K.ENTER, 0)                -- empty: not recorded
    typ(ed, "x"); ed:feed(K.ENTER, 0)
    typ(ed, "x"); ed:feed(K.ENTER, 0)  -- dup of previous: not recorded
    t.eq(#hist, 1)
end)

t.test("Up/Down recall history, newest first, restoring the live line", function()
    local hist = { "first", "second" }
    local ed = edit.new{ history = hist }
    typ(ed, "live")
    ed:feed(K.UP, 0);  t.eq(ed:text(), "second")
    ed:feed(K.UP, 0);  t.eq(ed:text(), "first")
    ed:feed(K.DOWN, 0); t.eq(ed:text(), "second")
    ed:feed(K.DOWN, 0); t.eq(ed:text(), "live", "Down past the newest restores the live edit")
end)

t.test("completion: one candidate fills the word", function()
    local ed = edit.new{ complete = function() return { from = 1, candidates = { "Registry" } } end }
    typ(ed, "Re")
    local r = ed:feed(K.TAB, 0)
    t.eq(r, R.NONE)
    t.eq(ed:text(), "Registry")
    t.eq(ed.pos, 8)
end)

t.test("completion: many candidates grow to the common prefix", function()
    local ed = edit.new{ complete = function() return { from = 1, candidates = { "abcd", "abce" } } end }
    typ(ed, "a")
    ed:feed(K.TAB, 0)
    t.eq(ed:text(), "abc")
    t.eq(ed:take_completions(), nil, "no list while the prefix still grew")
end)

t.test("completion: an ungrowable prefix hands the list to the renderer", function()
    local ed = edit.new{ complete = function() return { from = 1, candidates = { "Device", "Driver" } } end }
    typ(ed, "D")
    ed:feed(K.TAB, 0)
    local cands = ed:take_completions()
    t.ok(cands, "candidate list was offered")
    t.eq(#cands, 2)
    t.eq(ed:take_completions(), nil, "consumed once")
    t.eq(ed:text(), "D", "buffer unchanged when the prefix can't grow")
end)

t.test("completion: no candidates rings the bell", function()
    local ed = edit.new{ complete = function() return { from = 1, candidates = {} } end }
    typ(ed, "zz")
    t.eq((ed:feed(K.TAB, 0)), R.BELL)
    t.eq(ed:text(), "zz")
end)

t.test("completion fills mid-word and preserves the tail", function()
    -- complete the word before the cursor; "X" sits to the right untouched.
    local ed = edit.new{ complete = function() return { from = 1, candidates = { "abcd" } } end }
    typ(ed, "aX")
    ed:feed(K.LEFT, 0)                 -- cursor between a and X; word = "a"
    ed:feed(K.TAB, 0)
    t.eq(ed:text(), "abcdX")
    t.eq(ed.pos, 4, "cursor at end of the filled word, before the tail")
end)
