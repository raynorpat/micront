-- ntosbe profile: sshd
--
-- Boots straight into the SSH server (the sshd.lua entry, which uses the ssh
-- library) for live testing against a real OpenSSH client.  Same
-- hardware/driver layer set as `selftest` (so it ramdisk-boots identically)
-- but without the test harness, and the entry is the SSH server.
--
-- Pair with `make sshd-ramdisk`, which forwards host :2222 -> guest :22.
-- launch.lua require()s sshd (the loose pkg/sshd.lua entry) and runs its main().

return {
    layers = {
        "lua", "ssh",
        "drivers.storage.*", "drivers.fs.*",
        "drivers.net", "drivers.input", "drivers.video", "drivers.virtio.*",
    },
    entry = "sshd.lua",
}
