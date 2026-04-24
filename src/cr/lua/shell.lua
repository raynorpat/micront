-- shell.lua — entry point launched by userinit as the user shell.
--
-- Set in mkhive.py's gui profile as
--   HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\Shell =
--     "%SystemRoot%\lua\run.exe %SystemRoot%\lua\shell.lua"
-- (the env-var expansion happens in our patched USERINIT.C::ExecApplication;
-- stock NT 3.5 didn't expand, requiring literal paths).
--
-- This is a placeholder. Userland Lua/Win32 surface (windows, menus,
-- input dispatch) lands here as we wire up FFI bindings to user32 /
-- gdi32. Today the only job is to log via DbgPrint that we ran and
-- stay alive (exiting would let userinit / winlogon think the shell
-- crashed).

local ffi   = require('ffi')
local ntdll = require('nt.dll')
local ke    = require('nt.dll.ke')

ffi.cdef[[
void __stdcall DbgPrint(const char *Format, ...);
]]

ntdll.DbgPrint("shell.lua: launched\n")

-- Stay alive. Long-naps loop — we don't have a message pump yet, so
-- there's nothing useful to do between sleeps. When we add user32
-- bindings this becomes a GetMessage/DispatchMessage loop.
while true do
    ke.NtDelayExecution(false, ke.timeout(60))
end
