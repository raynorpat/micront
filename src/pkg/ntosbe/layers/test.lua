-- ntosbe layer: test
--
-- The selftest harness + every suite under test/ (including the
-- security fuzz suites under test/fuzz/), shipped at
-- \SystemRoot\pkg\test.zip.  require('test') -> test.zip member
-- test/init.lua (the harness); require('test.cm') / require('test.fuzz.se')
-- -> the corresponding members.
--
-- selftest.lua (the script that drives the suites) is NOT in this zip —
-- it's staged loose at \SystemRoot\pkg\selftest.lua via the selftest
-- profile's `entry` and run through the launcher (System32\launch.lua
-- selftest), which require()s it.

local luapkg = require('ntosbe.luapkg')

local M = {}

M.name = "test"
M.requires = { "nt" }
M.description = "selftest harness + suites -> pkg\\test.zip"

function M.files(paths, list_tree)
    return { luapkg.zip("test", paths, list_tree) }
end

return M
