-- nt.dll.io — I/O manager objects that are not files.  Maps to NTOS/IO on the
-- kernel side (ntioapi.h / NTOS/IO/COMPLETE.C).
--
-- Today this is the I/O completion port: a KQUEUE-backed object that backs the
-- Win32 IOCP family.  Completions reach a port either by associating a file
-- handle (NtSetInformationFile/FileCompletionInformation, in nt.dll.fs) or by
-- posting directly (NtSetIoCompletion).  They are drained with
-- NtRemoveIoCompletion (one) or NtRemoveIoCompletionEx (many).
--
-- File syscalls (NtReadFile/NtWriteFile/NtDeviceIoControlFile/...) live in
-- nt.dll.fs; this module is the non-file IO surface, kept separate so the
-- IO-completion kernel subsystem maps 1:1 to its Lua interface and tests.

local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

ffi.cdef[[
/* IO_COMPLETION_BASIC_INFORMATION — single LONG (queue depth). */
typedef struct _IO_COMPLETION_BASIC_INFORMATION {
    long Depth;
} IO_COMPLETION_BASIC_INFORMATION;

/* GetQueuedCompletionStatusEx array element. */
typedef struct _FILE_IO_COMPLETION_INFORMATION {
    void *KeyContext;
    void *ApcContext;
    IO_STATUS_BLOCK IoStatusBlock;
} FILE_IO_COMPLETION_INFORMATION;

NTSTATUS __stdcall NtCreateIoCompletion(HANDLE *h, ULONG Access,
                                        OBJECT_ATTRIBUTES *oa,
                                        ULONG ConcurrentThreads);
NTSTATUS __stdcall NtOpenIoCompletion(HANDLE *h, ULONG Access,
                                      OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtQueryIoCompletion(HANDLE h,
                                       int InformationClass,
                                       void *Information,
                                       ULONG Length,
                                       ULONG *ReturnLength);
NTSTATUS __stdcall NtSetIoCompletion(HANDLE h, void *KeyContext, void *ApcContext,
                                     NTSTATUS IoStatus, ULONG IoStatusInformation);
NTSTATUS __stdcall NtRemoveIoCompletion(HANDLE h,
                                        void **KeyContext,
                                        void **ApcContext,
                                        IO_STATUS_BLOCK *IoStatusBlock,
                                        LARGE_INTEGER *Timeout);
NTSTATUS __stdcall NtRemoveIoCompletionEx(HANDLE h,
                                          FILE_IO_COMPLETION_INFORMATION *Info,
                                          ULONG Count, ULONG *NumRemoved,
                                          LARGE_INTEGER *Timeout, int Alertable);
]]

local M = {}

-- ------------------------------------------------------------------
-- Raw wrappers
-- ------------------------------------------------------------------

function M.NtCreateIoCompletion(access, oa, concurrent_threads)
    local h = ffi.new('HANDLE[1]')
    local st = ntdll.NtCreateIoCompletion(h, access, oa, concurrent_threads or 0)
    if err.is_error(st) then err.raise('NtCreateIoCompletion', st) end
    return handle.wrap(h[0])
end

function M.NtOpenIoCompletion(access, oa)
    local h = ffi.new('HANDLE[1]')
    local st = ntdll.NtOpenIoCompletion(h, access, oa)
    if err.is_error(st) then err.raise('NtOpenIoCompletion', st) end
    return handle.wrap(h[0])
end

-- Dequeue a completion packet. Returns (key, apc, status, information), or nil
-- on timeout (STATUS_TIMEOUT passes through without raising). `timeout` is a
-- LARGE_INTEGER* (use ke.timeout(seconds); nil blocks indefinitely).
function M.NtRemoveIoCompletion(h, timeout)
    local key  = ffi.new('void *[1]')
    local apc  = ffi.new('void *[1]')
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local st = ntdll.NtRemoveIoCompletion(handle.raw(h), key, apc, iosb, timeout)
    local stu = err.normalize(st)
    if stu == 0x102 --[[ STATUS_TIMEOUT ]] then return nil end
    if err.is_error(st) then err.raise('NtRemoveIoCompletion', st) end
    return key[0], apc[0], iosb.Status, iosb.Information
end

-- Post a completion packet directly to the port (NtSetIoCompletion; backs
-- PostQueuedCompletionStatus). key/apc are opaque pointers, status an NTSTATUS,
-- information a ULONG. They surface verbatim in a subsequent remove.
function M.NtSetIoCompletion(h, key, apc, status, information)
    local st = ntdll.NtSetIoCompletion(handle.raw(h),
                                       ffi.cast('void *', key or 0),
                                       ffi.cast('void *', apc or 0),
                                       status or 0,
                                       information or 0)
    if err.is_error(st) then err.raise('NtSetIoCompletion', st) end
    return st
end

-- Dequeue up to `max` packets in one call (NtRemoveIoCompletionEx; backs
-- GetQueuedCompletionStatusEx). Blocks (with optional `timeout` LARGE_INTEGER*)
-- only for the first packet, then drains the rest non-blocking. Returns an
-- array of { key, apc, status, information } -- empty on timeout.
function M.NtRemoveIoCompletionEx(h, max, timeout, alertable)
    max = max or 1
    local arr = ffi.new('FILE_IO_COMPLETION_INFORMATION[?]', max)
    local n   = ffi.new('ULONG[1]')
    local st = ntdll.NtRemoveIoCompletionEx(handle.raw(h), arr, max, n,
                                            timeout, alertable and 1 or 0)
    local stu = err.normalize(st)
    if stu == 0x102 --[[ STATUS_TIMEOUT ]] then return {} end
    if err.is_error(st) then err.raise('NtRemoveIoCompletionEx', st) end
    local out = {}
    for i = 0, tonumber(n[0]) - 1 do
        out[i + 1] = {
            key         = arr[i].KeyContext,
            apc         = arr[i].ApcContext,
            status      = arr[i].IoStatusBlock.Status,
            information = arr[i].IoStatusBlock.Information,
        }
    end
    return out
end

-- Query the depth of the completion queue (pending packets). Only
-- IoCompletionBasicInformation exists.
function M.NtQueryIoCompletion(h)
    local info = ffi.new('IO_COMPLETION_BASIC_INFORMATION')
    local ret  = ffi.new('ULONG[1]')
    local st = ntdll.NtQueryIoCompletion(handle.raw(h),
                                         0 --[[ BasicInformation ]],
                                         info,
                                         ffi.sizeof('IO_COMPLETION_BASIC_INFORMATION'),
                                         ret)
    if err.is_error(st) then err.raise('NtQueryIoCompletion', st) end
    return info.Depth
end

-- ------------------------------------------------------------------
-- IoCompletion object
-- ------------------------------------------------------------------

local IoCompletion = {}
IoCompletion.__index = IoCompletion

-- Returns queue depth (LONG pending-packets count).
function IoCompletion:depth() return M.NtQueryIoCompletion(self._h) end

-- Post a packet to this port (key/apc opaque, status/information scalars).
function IoCompletion:set(key, apc, status, information)
    return M.NtSetIoCompletion(self._h, key, apc, status, information)
end

-- Dequeue one packet (optional timeout in seconds; nil = infinite).
-- Returns (key, apc_context, status, information) or nil on timeout.
function IoCompletion:remove(seconds)
    local ke = require('nt.dll.ke')
    return M.NtRemoveIoCompletion(self._h, ke.timeout(seconds))
end

-- Dequeue up to `max` packets at once (optional timeout in seconds for the
-- first). Returns an array of { key, apc, status, information }.
function IoCompletion:remove_many(max, seconds, alertable)
    local ke = require('nt.dll.ke')
    return M.NtRemoveIoCompletionEx(self._h, max, ke.timeout(seconds), alertable)
end

function IoCompletion:handle() return self._h end
IoCompletion.close = handle.close_h

local IO_COMPLETION_ALL_ACCESS = 0x1F0003

function M.iocompletion(opts)
    opts = opts or {}
    local h = M.NtCreateIoCompletion(
        opts.access or IO_COMPLETION_ALL_ACCESS,
        opts.oa,
        opts.concurrent_threads or 0)
    return setmetatable({ _h = h }, IoCompletion)
end

M.IoCompletion = IoCompletion

return M
