-- nt.term.keys — the integer enums that flow through the terminal stack.
--
-- A key event is two numbers, (kind, arg) — never a table, never a string
-- tag.  Two numbers are unboxed on the JIT path: zero allocation, no GC,
-- no per-event shape guard.  `kind` is one of K below; `arg` is the
-- codepoint for TEXT (and the letter byte for CTRL), 0 otherwise.
--
-- These tables are constants — never mutated after load — so the JIT
-- specializes reads from them.  Read once into a local in hot code
-- (`local K = require('nt.term.keys').K`) and compare against K.LEFT etc.

local M = {}

-- Input key kinds: what nt.term.vt decodes raw bytes into, and what
-- nt.term.edit consumes via :feed(kind, arg).
M.K = {
    TEXT      = 1,    -- arg = byte/codepoint of a printable character
    ENTER     = 2,    -- commit the line
    BACKSPACE = 3,    -- erase the glyph left of the cursor
    DELETE    = 4,    -- erase the glyph under the cursor (forward)
    LEFT      = 5,
    RIGHT     = 6,
    HOME      = 7,
    END       = 8,
    UP        = 9,    -- recall previous history entry
    DOWN      = 10,   -- recall next history entry
    TAB       = 11,   -- completion
    INTERRUPT = 12,   -- ^C — abandon the line
    EOF       = 13,   -- ^D — end of input (on an empty line)
    CTRL      = 14,   -- arg = uppercase-letter byte of an unhandled ^X
}

-- edit:feed results — the number it returns after consuming a key.
M.R = {
    NONE      = 0,    -- consumed; the line is still being edited
    COMMIT    = 1,    -- a line was committed (returned alongside this)
    EOF       = 2,    -- end of input
    INTERRUPT = 3,    -- the line was abandoned (^C)
    BELL      = 4,    -- nothing happened (e.g. failed completion) — alert
}

return M
