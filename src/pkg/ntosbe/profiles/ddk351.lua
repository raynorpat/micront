-- ntosbe profile: ddk351
--
-- ABI conformance disk — boots NT 3.51 DDK pre-compiled CLI utilities
-- against our kernel + kernel32 + ntdll and reports a pass/fail
-- summary.  Lean layer set (same as selftest) so compose is fast;
-- the runner lives in src/pkg/ddk351/main.lua.

return {
    layers = {
        "core", "lua",
        "drivers.storage.*", "drivers.fs.*",
        "drivers.net", "drivers.input", "drivers.video", "drivers.virtio.*",
        "ddk351",
    },
    init = { args = "\\SystemRoot\\lua\\ddk351\\main.lua" },
}
