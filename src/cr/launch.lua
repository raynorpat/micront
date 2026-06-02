-- launch.lua — universal init launcher.
--
-- Invoked as the init program for every profile:  launch.lua [<module> [args...]]
-- The first positional names the module to require(); with none, falls back to
-- `main` (the interactive connect-back agent).  The steerable `default` profile
-- bakes just "launch.lua" so the boot command line's post-"--" tail (appended by
-- the kernel onto the init CommandLine) supplies the module; other profiles bake
-- their module name here (compose's resolve_init derives it from `entry`).
--
-- An init entry must be a loose file (the kernel loads it by absolute path), but
-- a package's guest entrypoint often wants to live *inside* its zip (e.g.
-- ntosbe.selfhost, shipped in ntosbe.zip — keeping the package self-contained).
-- This launcher bridges the two: it require()s the named module, running that
-- module's chunk as the program.  The preamble has set package.path + the zip
-- searcher + io/os, so the require resolves from whatever package ships it.
--
-- require() runs a module chunk with only (modname, path) as ..., so arguments
-- travel via the global arg table: we rebase it so the launched module reads its
-- own args at arg[1..], exactly as a top-level script would.  A module that
-- returns a function is treated as a main() and called with those args.
--
-- The `main` fallback below pairs with the default profile's `entry = "main.lua"`
-- (staged at \SystemRoot\pkg\main.lua); keep the two in sync.
--
-- Lives in System32 (with lua.exe / lua.dll / preamble.lua), NOT on the pkg/
-- package path: it's the init program loaded by absolute path, never require()d,
-- so it must not be resolvable as a package.

local mod = (arg and arg[1]) or "main"

-- Rebase the global arg table so the launched module sees its own positional
-- arguments at arg[1..] (arg[0] = its name), as a top-level script would.
local rebased, n = { [0] = mod }, 0
for j = 2, #arg do n = n + 1; rebased[n] = arg[j] end
_G.arg = rebased

local m = require(mod)
if type(m) == "function" then return m(unpack(rebased, 1, n)) end
return m
