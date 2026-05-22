-- ntosbe layer: lua
--
-- The LuaJIT application runtime — and only that.  Three files in
-- System32 (lua.exe the thin trampoline, built in cr/ as run.exe and
-- staged under its on-disk name; lua.dll the VM; preamble.lua the
-- runtime bootstrap), plus the io/os stdlib shims that replace LuaJIT's
-- compiled-out lib_io/lib_os.
--
-- Packages are NOT this layer's job — each ships via its own layer
-- (nt -> nt.zip, ntosbe -> ntosbe.zip, test -> test.zip, ...).  Entry
-- scripts ship via a profile's `entry`.  This layer just makes the VM
-- runnable and supplies the init-process Exe default; `requires = nt`
-- because the preamble's io/os shims pull nt.dll.fs at startup, so
-- every Lua-running profile carries the nt package transitively.

local luapkg = require('ntosbe.luapkg')

local M = {}

M.name = "lua"
M.requires = { "nt" }
M.description = "LuaJIT runtime (lua.exe + lua.dll + preamble + io/os shims)"

-- The runtime layer owns the init Exe.  Profiles supply init.args (via
-- their `entry`); core supplies init.stdio.
M.init = {
    exe = "System32\\lua.exe",
}

function M.files(paths)
    -- The runtime lives in System32: NT 3.5's kernel-side image loader
    -- searches *only* System32 for the initial process's imports, and
    -- lua.dll loads preamble.lua by an absolute System32 path before
    -- any package.path exists.
    --
    -- io.lua / os.lua MUST stay loose under pkg/: the preamble loads
    -- them via the default file searcher to restore the io/os globals
    -- before (and so independent of) the zip searcher.
    return {
        { dest = "System32/lua.exe",      src = paths.cr_dir .. "/run.exe"      },
        { dest = "System32/lua.dll",      src = paths.cr_dir .. "/lua.dll"      },
        { dest = "System32/preamble.lua", src = paths.cr_dir .. "/preamble.lua" },
        -- Generic launcher for module-form profile entries (e.g.
        -- entry = "ntosbe.selfhost").  Lives in System32, NOT pkg/:
        -- it's loaded by absolute path as the init program, never
        -- require()d — keeping it off the package path so `require
        -- ('launch')` can't mistake it for a package.  See compose.lua.
        { dest = "System32/launch.lua",   src = paths.cr_dir .. "/launch.lua" },
        -- io/os shims DO belong on the package path: they're require()d
        -- (require('io')/require('os')) and must stay loose so the
        -- preamble restores the globals before the zip searcher exists.
        luapkg.loose("io.lua", paths),
        luapkg.loose("os.lua", paths),
    }
end

return M
