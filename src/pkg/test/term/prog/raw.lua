-- Child fixture for the RAW bridge mode.  Run in a spawned lua.exe via
--   lua.exe -e "require('test.term.prog.raw')"
-- with its stdin/stdout wired to the bridge's child pipes.
--
-- It reads ALL of stdin until EOF and echoes it back wrapped in <R>...</R>
-- so the parent can extract exactly what the child received, byte for
-- byte.  In raw mode that must be the terminal input verbatim — CR,
-- backspace, and other control bytes intact, no line framing, no echo.
-- (The marker avoids '[' / ']' because cooked echo carries VT sequences
-- like ESC[K, and '<R>' never appears in the keystrokes we send.)
--
-- NOT a test suite (no t.test): it would block on stdin if required in
-- the selftest process.  It is only ever loaded by the spawned child.

local io = require('io')

local data = io.read("*a") or ""
io.write("<R>" .. data .. "</R>")
