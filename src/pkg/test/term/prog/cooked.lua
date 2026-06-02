-- Child fixture for the COOKED bridge mode.  Run in a spawned lua.exe via
--   lua.exe -e "require('test.term.prog.cooked')"
-- with its stdin/stdout wired to the bridge's child pipes.
--
-- It reads stdin a LINE at a time until EOF and echoes each line back
-- wrapped in <R>...</R>.  In cooked mode the line discipline has already
-- done the editing and CR->\n translation, so each io.lines() iteration
-- must yield a whole, finished line delivered as one unit — e.g. the
-- terminal input "ab\bc\r" arrives here as the single line "ac".  (The
-- <R> marker avoids '[' / ']', which appear in the cooked echo's VT.)
--
-- NOT a test suite: only loaded by the spawned child (it blocks on stdin).

local io = require('io')

local out = {}
for ln in io.lines() do
    out[#out + 1] = "<R>" .. ln .. "</R>"
end
io.write(table.concat(out))
