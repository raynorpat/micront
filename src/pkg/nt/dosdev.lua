-- nt.dosdev — boot-time publisher for the \DosDevices\<letter>:
-- drive-letter symlinks Win32 toolchain code expects.
--
-- Stock NT 3.5 builds these in HAL during IoAssignDriveLetters: the
-- HAL walks LoaderBlock->ArcDiskInformation, reads partition tables,
-- and creates one symlink per disk/partition.  MicroNT has stripped
-- ARC entirely — our HAL stub for IoAssignDriveLetters is a no-op,
-- and rebuilding the ARC plumbing just to publish drive letters
-- isn't worth it (we only need C: today).
--
-- Instead, we let the kernel's standard \SystemRoot setup happen
-- (IopReassignSystemRoot in IOINIT.C creates \SystemRoot pointing at
-- \Device\Harddisk0\Partition1 from the NtBootPathName the loader
-- supplied), then in user mode read that target and publish a
-- second alias under \DosDevices\C: pointing at the same volume.
-- After this, Win32 fopen / CreateFileW go: DOS path → ntdll
-- RtlDosPathNameToNtPathName_U → \DosDevices\C:\foo → resolves
-- through our symlink → \Device\Harddisk0\Partition1\foo.
--
-- Caller must hold SeCreatePermanentPrivilege when invoking publish().
-- Use se.with_privileges({"SeCreatePermanentPrivilege"}, dosdev.publish)
-- — same pattern as nt.nls.publish.

local ob     = require('nt.dll.ob')
local oa     = require('nt.dll.oa')
local str    = require('nt.dll.str')

local PERMANENT_NAMED = {
    oa.OBJ_PERMANENT,
    oa.OBJ_CASE_INSENSITIVE,
    oa.OBJ_OPENIF,
}

local M = {}

-- Read \SystemRoot's target.  IopReassignSystemRoot leaves it pointing
-- at the boot device (\Device\Harddisk<N>\Partition<P>); we mirror that
-- target into \DosDevices\C: so DOS paths resolve to the same volume.
local function read_systemroot_target()
    local link_oa = oa.path("\\SystemRoot")
    local h = ob.NtOpenSymbolicLinkObject(ob.SYMBOLIC_LINK_QUERY, link_oa.oa)
    local target = ob.NtQuerySymbolicLinkObject(h)
    h:close()
    return target
end

-- Create one drive-letter symlink under \DosDevices.  OBJ_PERMANENT
-- detaches it from this handle's lifetime so it survives publisher
-- exit; OBJ_OPENIF makes a re-publish a no-op (idempotent boot)
-- instead of STATUS_OBJECT_NAME_COLLISION.
local function publish_letter(letter, target_utf8)
    local name    = "\\DosDevices\\" .. letter .. ":"
    local link_oa = oa.path(name, PERMANENT_NAMED)
    local target  = str.to_utf16(target_utf8)
    local h = ob.NtCreateSymbolicLinkObject(
        ob.SYMBOLIC_LINK_ALL_ACCESS, link_oa.oa, target.us)
    h:close()
end

function M.publish()
    -- C: → wherever \SystemRoot points.  All booted MicroNT paths are
    -- on a single FAT16 volume today — one drive letter is enough.
    -- Add D:, E: etc. here when multi-volume comes up.
    local target = read_systemroot_target()
    publish_letter("C", target)
end

return M
