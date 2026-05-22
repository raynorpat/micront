-- ntosbe layer: test
--
-- The selftest harness + every suite under test/ (including the
-- security fuzz suites under test/fuzz/), shipped at
-- \SystemRoot\pkg\test.zip.  require('test') -> test.zip member
-- test/init.lua (the harness); require('test.cm') / require('test.fuzz.se')
-- -> the corresponding members.
--
-- The entry scripts that drive the suites (selftest.lua / selfhost.lua)
-- are NOT in this zip — they're loaded by absolute path via the
-- profile's `entry`, so they stay loose top-level packages.

local luapkg = require('ntosbe.luapkg')

local M = {}

M.name = "test"
M.requires = { "nt" }
M.description = "selftest harness + suites -> pkg\\test.zip"

function M.files(paths, list_tree)
    return { luapkg.zip("test", paths, list_tree) }
end

return M
