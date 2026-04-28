-- ntosbe.lua — host CLI entry into pkg/ntosbe.
--
-- Sets package.path to find pkg/ntosbe/* relative to this script's
-- location, then dispatches into the package's main().  Reachable
-- as a regular Lua script invocation:
--
--     luajit src/ntosbe.lua --src-root=... --efi-binary=... --output-dir=...
--
-- The `-e CHUNK -- args...` form Lua provides treats the first arg as
-- a script path, which doesn't compose with --flag=value-style args;
-- this shim sidesteps that by being a real script.

local SCRIPT_DIR = arg[0]:match("(.*/)") or "./"
package.path = SCRIPT_DIR .. "pkg/?.lua;"
            .. SCRIPT_DIR .. "pkg/?/init.lua;"
            .. package.path

os.exit(require('ntosbe').main(arg))
