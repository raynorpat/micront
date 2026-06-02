-- ntosbe profile: default
--
-- The lean interactive disk: the OS + LuaJIT runtime + the nt package
-- + the full hardware/driver config, booting main.lua (the connect-back
-- agent) by default.  No NT source tree, no MSVC toolchain, no test suites —
-- that's what the `selfhost` and `selftest` profiles are for.
--
-- This is what a bare `ntosbe` invocation and `make boot` / `make disk`
-- compose.  `lua` pulls `nt` via its requires, so the nt package is
-- present without listing it.
--
-- A profile is a layer list + an entry script; see ntosbe/compose.lua.

return {
    layers = {
        "lua",
        "drivers.storage.*", "drivers.fs.*",
        "drivers.net", "drivers.input", "drivers.video", "drivers.virtio.*",
    },
    entry = "main.lua",
    -- Steerable disk: bake the launcher with NO module so the boot command-line
    -- tail (text after `--` in boot.sh --kernel-opts, forwarded by the kernel onto
    -- the init CommandLine) chooses what runs.  With no tail, launch.lua falls
    -- back to `main` — the agent staged loose at pkg\main.lua via `entry` above.
    init = { args = "\\SystemRoot\\System32\\launch.lua" },
}
