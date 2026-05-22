-- ntosbe profile: ddk351
--
-- ABI conformance disk — boots NT 3.51 DDK pre-compiled CLI utilities
-- against our kernel + kernel32 + ntdll and reports a pass/fail
-- summary.  The runner ships with its binary bundle (the ddk351 layer
-- stages main.lua + bin/*.EXE under pkg/ddk351/), so the entry is set
-- via explicit init.args rather than the `entry` sugar (which would
-- double-stage main.lua).

return {
    layers = {
        "lua", "ddk351",
        "drivers.storage.*", "drivers.fs.*",
        "drivers.net", "drivers.input", "drivers.video", "drivers.virtio.*",
    },
    init = { args = "\\SystemRoot\\pkg\\ddk351\\main.lua" },
}
