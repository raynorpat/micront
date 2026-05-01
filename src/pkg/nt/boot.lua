-- nt.boot — one-shot boot-prelude every entry point runs.
--
-- Stock NT does most of this from kernel-mode INIT (or csrss for the
-- user-mode pieces).  MicroNT has stripped csrss and most of the HAL
-- ARC plumbing, so we publish the missing namespace pieces from Lua
-- right after the initial process starts.  Every entry point
-- (main.lua, selftest.lua, future installer scripts) calls
-- nt.boot.run() before doing its own thing.
--
-- What this publishes:
--
--   \NLS\Nls*  — named sections backing kernel32's nlslib.  Stock NT
--                does this in basesrv (inside csrss); we don't have
--                csrss.  See nt.nls for details.
--
--   \DosDevices\C:  — symlink to the boot volume so Win32 toolchain
--                code (NMAKE, CL, LINK, cmd) resolves DOS paths
--                naturally through RtlDosPathNameToNtPathName_U.
--                Stock NT does this in HAL's IoAssignDriveLetters
--                from ARC LoaderBlock data; we have neither.  See
--                nt.dosdev.
--
-- Both publish steps need SeCreatePermanentPrivilege (the OBJ_PERMANENT
-- attribute on the created namespace objects detaches them from this
-- process's lifetime).  We acquire the privilege once and run both
-- publishers under it.
--
-- Idempotent: safe to re-run from a child process.  Each publisher
-- uses OBJ_OPENIF so re-publishing collapses to a no-op rather than
-- STATUS_OBJECT_NAME_COLLISION.

local se  = require('nt.dll.se')

local M = {}

local function publish_all()
    require('nt.nls').publish()
    require('nt.dosdev').publish()
end

function M.run()
    se.with_privileges({"SeCreatePermanentPrivilege"}, publish_all)
end

return M
