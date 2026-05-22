-- MicroNT boot smoke test.  Tightest possible "did the system come up
-- on this hardware shape?" check — bring up the boot prelude, print
-- one sentinel, shut down.  ~5-10 s per matrix entry vs ~4 min for
-- the full selftest, which lets CI run the smoke across every
-- (MACHINE, DISK) combo without dominating wall time.
--
-- The CI step greps for '^SMOKE OK' on the serial log and fails the
-- step if missing.  Every line of output before that is normal kernel
-- + driver init noise; only the sentinel matters for pass/fail.

-- package.path + searcher + io/os globals come from the runtime
-- preamble (\SystemRoot\System32\preamble.lua).

local se  = require('nt.dll.se')
local sys = require('nt.dll.sys')

-- Boot prelude (NLS named sections, \DosDevices\C: symlink).  Same
-- step main.lua + selftest.lua run; if it explodes here, the smoke
-- catches it across whichever machine shape surfaces the regression.
require('nt.boot').run()

print("SMOKE OK")

-- Same shutdown dance as selftest.lua — defensively un-impersonate,
-- enable SeShutdownPrivilege, ask the kernel to power off.  Spin if
-- the call fails so QEMU's wall-clock timeout is the backstop.
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
    print("smoke shutdown failed: " .. tostring(sd_err))
end
while true do end
