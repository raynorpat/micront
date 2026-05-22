-- ntosbe layer: nt
--
-- The NT API library — ntdll / kernel32 / object-manager / registry /
-- filesystem / networking bindings under the `nt.*` namespace.  Shipped
-- as a single STORED archive at \SystemRoot\pkg\nt.zip; the on-target
-- zip searcher (src/cr/preamble.lua) resolves require('nt.dll.fs') to
-- the member nt/dll/fs.lua inside it.
--
-- Required by the `lua` runtime layer (the preamble's io/os shims pull
-- nt.dll.fs), so every Lua-running profile carries it transitively.

local luapkg = require('ntosbe.luapkg')

local M = {}

M.name = "nt"
M.description = "NT API library (nt.* bindings) -> pkg\\nt.zip"

function M.files(paths, list_tree)
    return { luapkg.zip("nt", paths, list_tree) }
end

return M
