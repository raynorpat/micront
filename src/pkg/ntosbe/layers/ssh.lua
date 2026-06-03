-- ntosbe layer: ssh
--
-- Minimal SSH-2 implementation: the `ssh.*` library namespace (wire / packet /
-- crypto / kex / userauth / channel / cipoly + the conn reactor and session
-- handlers).  Shipped as a single STORED archive at \SystemRoot\pkg\ssh.zip;
-- the on-target zip searcher (src/cr/preamble.lua) resolves require('ssh.wire')
-- to the member ssh/wire.lua inside it.  The server PROGRAM is not here — it is
-- the deployment entry pkg/sshd.lua, which uses this library.
--
-- Depends on the `nt` package (afd transport, rng) and, at runtime, on
-- djbcrypt.dll (FFI'd by ssh.crypto) — shipped by the `core` layer.

local luapkg = require('ntosbe.luapkg')

local M = {}

M.name = "ssh"
M.description = "minimal SSH-2 (ssh.* package) -> pkg\\ssh.zip"
M.requires = { "nt" }

function M.files(paths, list_tree)
    return { luapkg.zip("ssh", paths, list_tree) }
end

return M
