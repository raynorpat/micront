-- ntosbe profile: selftest
--
-- The fast iteration disk: full hardware/driver config but WITHOUT the
-- NT source tree or the MS toolchain.  The kernel and test.fuzz.*
-- suites never touch \SystemRoot\src, so staging the source tree
-- (which dominates disk-compose wall time) buys nothing here.  For the
-- in-OS self-host build use the `selfhost` profile instead.
--
-- A profile is a layer list + an entry script; see ntosbe/compose.lua.
-- `core` is implicit (always added first).  `lua` pulls `nt`; `test`
-- ships the harness + suites as test.zip and also pulls `nt`.

return {
    layers = {
        "lua", "test",
        "drivers.storage.*", "drivers.fs.*",
        "drivers.net", "drivers.input", "drivers.video", "drivers.virtio.*",
    },
    entry = "selftest.lua",
}
