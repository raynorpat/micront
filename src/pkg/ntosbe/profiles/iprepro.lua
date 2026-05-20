-- ntosbe profile: iprepro
--
-- IP-stack hardening reproducer target.  Same lean layer set as the
-- `selftest` profile (drivers + Lua + nt.net.*; no NT source tree, no
-- MS toolchain) but the init entry is iprepro.lua instead of
-- selftest.lua.
--
-- Unlike selftest this runs NO test.* suites: surgical reproduction of
-- one finding wants a fast boot into a single network endpoint, not the
-- whole regression run.  The host-side packet harness
-- (src/tools/netharness/) drives the per-finding reproducers against it.
--
-- See docs-wip/IPSTACK-HARDENING.md §5.
--
-- A profile is just a layer list + the init entry; see ntosbe/compose.lua.

return {
    layers = {
        "core", "lua",
        "drivers.storage.*", "drivers.fs.*",
        "drivers.net", "drivers.input", "drivers.video", "drivers.virtio.*",
    },
    init = { args = "\\SystemRoot\\lua\\iprepro.lua" },
}
