-- ntosbe profile: default
--
-- The lean interactive disk: the OS + LuaJIT runtime + the nt package
-- + the full hardware/driver config, booting main.lua (the namespace
-- browser).  No NT source tree, no MSVC toolchain, no test suites —
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
}
