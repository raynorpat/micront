-- launch.lua — generic module entrypoint launcher.
--
-- An init entry must be a loose file (the kernel loads it by absolute
-- path), but a package's guest entrypoint often wants to live *inside*
-- its zip (e.g. ntosbe.selfhost, shipped in ntosbe.zip — keeping the
-- package self-contained).  This thin launcher bridges the two: it
-- require()s the module named as its first argument, running that
-- module's chunk as the program.
--
-- Lives in System32 (with lua.exe / lua.dll / preamble.lua), NOT on
-- the pkg/ package path: it's the init program loaded by absolute
-- path, never require()d, so it must not be resolvable as a package.
--
-- A profile selects this path with  entry = "<dotted.module.name>"
-- (vs entry = "<file>.lua" for a plain loose script); compose points
-- Control\Init Args at "\SystemRoot\System32\launch.lua <module>".
-- The preamble has set package.path + the zip searcher + io/os, so
-- the require resolves from whatever package ships the module.

local mod = arg and arg[1]
if not mod then
    error("launch.lua: no module named (expected a single argument)", 0)
end
require(mod)
