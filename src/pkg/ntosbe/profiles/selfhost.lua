-- ntosbe profile: selfhost
--
-- The in-OS build environment: the ntosbe builder (ntosbe), the NT
-- source tree (ntsrc) and the MS toolchain (msvc).  Boots straight into
-- ntosbe.selfhost, which drives ntosbe.build against \SystemRoot\src
-- using the in-OS toolchain — the same build that runs on the host,
-- run from inside the guest.  Not a test run: a real self-host build.
--
-- The lean interactive disk is the `default` profile; selfhost is the
-- heavy build environment.  (No `test` package — the old msvc/platform
-- smoke suites served their purpose proving the toolchain wiring and
-- are retired; the build itself is the proof now.)

return {
    layers = {
        "lua", "ntosbe", "ntsrc", "msvc",
        "drivers.storage.*", "drivers.fs.*",
        "drivers.net", "drivers.input", "drivers.video", "drivers.virtio.*",
    },
    entry = "ntosbe.selfhost",
}
