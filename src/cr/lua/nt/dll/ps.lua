-- nt.dll.ps — Process / thread handle openers. Maps to NTOS/PS.
--
-- Unlike most namespace objects, processes and threads aren't opened
-- by NT path — they're opened by CLIENT_ID (pid/tid pair). The
-- OBJECT_ATTRIBUTES argument still has to be a valid struct (Length
-- field set) though its ObjectName goes unused.

local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

ffi.cdef[[
NTSTATUS __stdcall NtOpenProcess(HANDLE *h, ULONG Access,
                                 OBJECT_ATTRIBUTES *oa, CLIENT_ID *cid);
NTSTATUS __stdcall NtOpenThread (HANDLE *h, ULONG Access,
                                 OBJECT_ATTRIBUTES *oa, CLIENT_ID *cid);
]]

local M = {}

function M.NtOpenProcess(access, oa, cid)
    local h = ffi.new('HANDLE[1]')
    local st = ntdll.NtOpenProcess(h, access, oa, cid)
    if err.is_error(st) then err.raise('NtOpenProcess', st) end
    return handle.wrap(h[0])
end

function M.NtOpenThread(access, oa, cid)
    local h = ffi.new('HANDLE[1]')
    local st = ntdll.NtOpenThread(h, access, oa, cid)
    if err.is_error(st) then err.raise('NtOpenThread', st) end
    return handle.wrap(h[0])
end

-- Build a minimal OBJECT_ATTRIBUTES with only Length populated — what
-- CLIENT_ID-based opens require.
function M.empty_oa()
    local oa = ffi.new('OBJECT_ATTRIBUTES')
    oa.Length = ffi.sizeof('OBJECT_ATTRIBUTES')
    return oa
end

return M
