-- nt.term.render — declarative (text,cursor) -> VT bytes.
--
-- Pure: drive state transitions and assert the exact byte delta.  The
-- editor and renderer are tested apart; an integration test that runs
-- key bytes through vt -> edit -> render lives in test.term.line.

local t      = require('test')
local render = require('nt.term.render')

t.suite("nt.term.render: VT output")

t.test("open draws the prompt for an empty line", function()
    local r = render.new("> ")
    t.eq(r:open(), "> ")
end)

t.test("typing at the end emits just the appended glyph", function()
    local r = render.new("> ")
    r:open()
    t.eq(r:sync("a", 1),  "a")
    t.eq(r:sync("ab", 2), "b")
    t.eq(r:sync("abc", 3), "c")
end)

t.test("cursor-left with unchanged text emits backspaces only", function()
    local r = render.new("")
    r:open()
    r:sync("abc", 3)
    t.eq(r:sync("abc", 1), "\b\b", "moved two columns left")
end)

t.test("cursor-right re-emits the glyphs moved over", function()
    local r = render.new("")
    r:open(); r:sync("abc", 3); r:sync("abc", 0)
    t.eq(r:sync("abc", 2), "ab", "re-emit a,b to advance the cursor")
end)

t.test("no-op transition emits nothing", function()
    local r = render.new("")
    r:open(); r:sync("abc", 3)
    t.eq(r:sync("abc", 3), "")
end)

t.test("mid-line insert repaints in place and repositions", function()
    local r = render.new("")
    r:open(); r:sync("ab", 2); r:sync("ab", 1)     -- cursor between a and b
    -- insert X -> "aXb", cursor at 2: back to start, clear, rewrite, back 1
    t.eq(r:sync("aXb", 2), "\b\27[KaXb\b")
end)

t.test("erase repaints in place", function()
    local r = render.new("")
    r:open(); r:sync("abc", 3)
    t.eq(r:sync("ab", 2), "\b\b\b\27[Kab")
end)

t.test("commit ends the row and resets the drawn state", function()
    local r = render.new("> ")
    r:open(); r:sync("hi", 2)
    t.eq(r:commit(), "\r\n")
    -- after commit, the next line starts clean: a fresh append is just "x"
    r:open()
    t.eq(r:sync("x", 1), "x")
end)

t.test("cancel echoes ^C and ends the row", function()
    local r = render.new("")
    r:open(); r:sync("junk", 4)
    t.eq(r:cancel(), "^C\r\n")
end)

t.test("list prints candidates then redraws prompt + line", function()
    local r = render.new("> ")
    r:open(); r:sync("D", 1)
    t.eq(r:list({ "Device", "Driver" }, "D", 1),
         "\r\nDevice  Driver\r\n> D")
end)

t.test("list restores a non-end cursor after the redraw", function()
    local r = render.new("$ ")
    r:open(); r:sync("abc", 3); r:sync("abc", 1)
    t.eq(r:list({ "x", "y" }, "abc", 1), "\r\nx  y\r\n$ abc\b\b")
end)
