-- ntosbe.selfhost — the in-OS self-host entrypoint.
--
-- Runs the ntosbe build *inside the booted guest*, the same way it runs
-- on the build host: drive ntosbe.build against the staged NT source
-- tree (\SystemRoot\src) using the in-OS MSVC toolchain
-- (\SystemRoot\pkg\msvc20).  This is a real operation, not a test —
-- "are we self-hosting?" answered by actually rebuilding the OS's
-- C/asm components with our own kernel + toolchain.
--
-- The `selfhost` profile boots this via `entry = "ntosbe.selfhost"`;
-- the loose launcher (pkg/launch.lua) require()s it, which runs this
-- chunk.  Shipped inside ntosbe.zip so the builder is fully
-- self-contained — its host CLI (ntosbe.main) and its guest entry
-- (this) travel together.
--
-- Not yet wired: building a full disk image in-guest (the `disk`
-- target would rewrite the volume we're booted from).  We rebuild
-- tools + ntoskrnl + drivers + userland — every component NMAKE can
-- compile under the in-OS toolchain.

local se    = require('nt.dll.se')
local sys   = require('nt.dll.sys')
local build = require('ntosbe.build')

print("MicroNT selfhost — in-OS ntosbe build")
print("====================================")

-- Boot prelude: publish \NLS\ named sections + \DosDevices\C: (the
-- latter is what Win32 toolchain children resolve C:\… through, since
-- our HAL has no IoAssignDriveLetters).  Idempotent.
require('nt.boot').run()

-- Guest paths use DOS form (C:\…) so the Win32 toolchain children's
-- CRT fopen / GetModuleFileNameW resolve via RtlDosPathNameToNtPathName_U
-- → \DosDevices\C: → boot volume.  path_strip drops the leading
-- /SystemRoot so a source at \SystemRoot\src\foo becomes C:\src\foo.
local ok, rc = pcall(build.main, {
    script_dir = "/SystemRoot/src",
    repo_root  = "/SystemRoot",
    wibo_tools = "/SystemRoot/pkg/msvc20",
    drive_root = "C:",
    path_strip = "/SystemRoot",
    args       = { "tools", "ntoskrnl", "drivers", "userland" },
})

print("")
local success = ok and rc == 0
if success then
    print("SELFHOST OK — in-OS rebuild completed")
else
    print(string.format("SELFHOST FAILED — %s",
        ok and ("build rc=" .. tostring(rc)) or ("error: " .. tostring(rc))))
end

-- Clean shutdown — same ladder as the other boot entry scripts.
pcall(se.revert_to_self)
local sd_ok, sd_err = pcall(function()
    local tok = se.open_process_token{
        access = se.TOKEN_QUERY + se.TOKEN_ADJUST_PRIVILEGES,
    }
    se.enable_privileges(tok, {"SeShutdownPrivilege"})
    sys.NtShutdownSystem('power_off')
    tok:close()
end)
if not sd_ok then
    print("shutdown failed: " .. tostring(sd_err))
    print("(spinning — kill QEMU manually)")
end
while true do end
