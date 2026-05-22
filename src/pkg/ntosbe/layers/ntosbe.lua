-- ntosbe layer: ntosbe
--
-- The disk-builder itself, shipped onto the image at
-- \SystemRoot\pkg\ntosbe.zip so a booted MicroNT can self-host —
-- test.ntosbe drives ntosbe.build / ntosbe.platform in-process to
-- rebuild the OS from \SystemRoot\src.  Pairs with the `ntsrc` (NT
-- source tree) and `msvc` (toolchain) layers; needed by the selfhost
-- profile, omitted elsewhere.
--
-- require('ntosbe') -> ntosbe.zip member ntosbe/init.lua.

local luapkg = require('ntosbe.luapkg')

local M = {}

M.name = "ntosbe"
M.requires = { "nt" }
M.description = "ntosbe disk builder (self-host) -> pkg\\ntosbe.zip"

function M.files(paths, list_tree)
    return { luapkg.zip("ntosbe", paths, list_tree) }
end

return M
