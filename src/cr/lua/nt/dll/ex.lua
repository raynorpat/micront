-- nt.dll.ex — Executive primitives (sync objects, memory sections).
-- Maps to NTOS/EX on the kernel side. Everything here is shaped
-- identically: NtOpenX(HANDLE *out, ACCESS_MASK, OBJECT_ATTRIBUTES *).
--
-- Nothing here sets values, signals, or waits — those live on the
-- opened handle via Nt{Wait,Set,Release,Reset,Pulse}*. Add as real
-- callers show up; for now the object-manager tree only needs the
-- openers so introspection via NtQueryObject works.

local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

ffi.cdef[[
NTSTATUS __stdcall NtOpenEvent       (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenEventPair   (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenSection     (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenMutant      (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenSemaphore   (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenTimer       (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenIoCompletion(HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
]]

local M = {}

-- All six are the same shape; write one local maker, export six bindings
-- so callers keep distinct NtOpenX names (matches nt.dll.* convention
-- that sub-modules bind real ntdll exports, not abstractions).
local function make_opener(name)
    return function(access, oa)
        local h  = ffi.new('HANDLE[1]')
        local st = ntdll[name](h, access, oa)
        if err.is_error(st) then err.raise(name, st) end
        return handle.wrap(h[0])
    end
end

M.NtOpenEvent        = make_opener('NtOpenEvent')
M.NtOpenEventPair    = make_opener('NtOpenEventPair')
M.NtOpenSection      = make_opener('NtOpenSection')
M.NtOpenMutant       = make_opener('NtOpenMutant')
M.NtOpenSemaphore    = make_opener('NtOpenSemaphore')
M.NtOpenTimer        = make_opener('NtOpenTimer')
M.NtOpenIoCompletion = make_opener('NtOpenIoCompletion')

return M
