-- nt.dll.fs — file and device I/O. Maps to NTOS/IO on the kernel side.
--
-- Bridging pattern is the same as nt.dll.ke (OUT→return, NTSTATUS<0
-- → raise), with a few fs-specific shapes:
--
--   NtCreateFile / NtOpenFile
--     Two OUT args: the file handle and the IoStatusBlock. Wrapper
--     returns (handle, disposition). Disposition is iosb.Information
--     — FILE_CREATED=2, FILE_OPENED=1, FILE_OVERWRITTEN=3, etc.
--     Callers that only need the handle: `local h = fs.NtOpenFile(...)`.
--
--   NtReadFile
--     Returns (bytes_read, status). status is STATUS_SUCCESS (0) on
--     full read, STATUS_END_OF_FILE (0xC0000011) when the caller has
--     hit EOF (possibly with a partial read — bytes_read may be > 0
--     even on EOF). STATUS_END_OF_FILE is *not* raised since EOF is
--     expected in read loops; any other NTSTATUS<0 is raised.
--
--   NtWriteFile / NtDeviceIoControlFile
--     Return bytes_written (iosb.Information). Raise on NTSTATUS<0.
--
-- File handles from this module close via NtClose in nt.dll.ob:
--     require('nt.dll.ob').NtClose(h)

local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

ffi.cdef[[
NTSTATUS __stdcall NtCreateFile(HANDLE *FileHandle,
                                ULONG DesiredAccess,
                                OBJECT_ATTRIBUTES *ObjectAttributes,
                                IO_STATUS_BLOCK *IoStatusBlock,
                                LARGE_INTEGER *AllocationSize,
                                ULONG FileAttributes,
                                ULONG ShareAccess,
                                ULONG CreateDisposition,
                                ULONG CreateOptions,
                                void *EaBuffer,
                                ULONG EaLength);

NTSTATUS __stdcall NtOpenFile  (HANDLE *FileHandle,
                                ULONG DesiredAccess,
                                OBJECT_ATTRIBUTES *ObjectAttributes,
                                IO_STATUS_BLOCK *IoStatusBlock,
                                ULONG ShareAccess,
                                ULONG OpenOptions);

NTSTATUS __stdcall NtReadFile  (HANDLE FileHandle,
                                HANDLE Event,
                                void *ApcRoutine,
                                void *ApcContext,
                                IO_STATUS_BLOCK *IoStatusBlock,
                                void *Buffer,
                                ULONG Length,
                                LARGE_INTEGER *ByteOffset,
                                ULONG *Key);

NTSTATUS __stdcall NtWriteFile (HANDLE FileHandle,
                                HANDLE Event,
                                void *ApcRoutine,
                                void *ApcContext,
                                IO_STATUS_BLOCK *IoStatusBlock,
                                void *Buffer,
                                ULONG Length,
                                LARGE_INTEGER *ByteOffset,
                                ULONG *Key);

NTSTATUS __stdcall NtDeviceIoControlFile(HANDLE FileHandle,
                                         HANDLE Event,
                                         void *ApcRoutine,
                                         void *ApcContext,
                                         IO_STATUS_BLOCK *IoStatusBlock,
                                         ULONG IoControlCode,
                                         void *InputBuffer,
                                         ULONG InputBufferLength,
                                         void *OutputBuffer,
                                         ULONG OutputBufferLength);
]]

-- STATUS_END_OF_FILE = 0xC0000011 — severity ERROR, so the uniform
-- is_error check would raise on it. EOF is expected in read loops
-- though, so NtReadFile special-cases it through.
local STATUS_END_OF_FILE_UINT = 0xC0000011

local M = {}

function M.NtCreateFile(access, oa, alloc_size, file_attrs, share,
                        disposition, options, ea_buffer, ea_length)
    local h    = ffi.new('HANDLE[1]')
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local st   = ntdll.NtCreateFile(h, access, oa, iosb,
                                    alloc_size, file_attrs, share,
                                    disposition, options,
                                    ea_buffer, ea_length or 0)
    if err.is_error(st) then err.raise('NtCreateFile', st) end
    return handle.wrap(h[0]), iosb.Information
end

function M.NtOpenFile(access, oa, share, options)
    local h    = ffi.new('HANDLE[1]')
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local st   = ntdll.NtOpenFile(h, access, oa, iosb, share, options)
    if err.is_error(st) then err.raise('NtOpenFile', st) end
    return handle.wrap(h[0]), iosb.Information
end

function M.NtReadFile(h, buffer, length, byte_offset)
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local st = ntdll.NtReadFile(handle.raw(h), nil, nil, nil, iosb,
                                buffer, length, byte_offset, nil)
    local stu = err.normalize(st)
    if err.is_error(st) and stu ~= STATUS_END_OF_FILE_UINT then
        err.raise('NtReadFile', st)
    end
    return iosb.Information, stu
end

function M.NtWriteFile(h, buffer, length, byte_offset)
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local st = ntdll.NtWriteFile(handle.raw(h), nil, nil, nil, iosb,
                                 buffer, length, byte_offset, nil)
    if err.is_error(st) then err.raise('NtWriteFile', st) end
    return iosb.Information
end

function M.NtDeviceIoControlFile(h, ioctl,
                                 in_buf, in_len, out_buf, out_len)
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local st = ntdll.NtDeviceIoControlFile(handle.raw(h), nil, nil, nil, iosb,
                                           ioctl,
                                           in_buf, in_len or 0,
                                           out_buf, out_len or 0)
    if err.is_error(st) then err.raise('NtDeviceIoControlFile', st) end
    return iosb.Information
end

return M

-- ----------------------------------------------------------------------
-- TODO — NT file/IO syscalls not yet bridged here. Add when a real
-- caller reaches for one. Grouped by shape of the wrapper they'd need.
--
-- Straightforward (same pattern as the above):
--   NtFsControlFile          filesystem-level IOCTL (FSCTL_* codes)
--   NtFlushBuffersFile       flush cached writes to disk
--   NtLockFile               byte-range lock
--   NtUnlockFile             byte-range unlock
--   NtCancelIoFile           cancel pending async I/O on a handle
--   NtDeleteFile             delete-by-path (no open needed)
--
-- Size-query pattern (caller typically invokes twice: probe length,
-- alloc buffer, call for real). Don't fit the uniform wrapper — add
-- hand-rolled helpers, or leave for raw `ntdll.<Foo>` access:
--   NtQueryInformationFile       FILE_*_INFORMATION classes
--   NtSetInformationFile         "
--   NtQueryVolumeInformationFile FILE_FS_*_INFORMATION classes
--   NtSetVolumeInformationFile   "
--   NtQueryDirectoryFile         enumerate directory contents
--   NtQueryAttributesFile        cheap stat(2) without opening the file
--   NtQueryFullAttributesFile    "  with more fields
--
-- Async / callback-driven:
--   NtNotifyChangeDirectoryFile  dir watch — completes via APC/IOCP
--
-- Named object creation (distinct from NtCreateFile):
--   NtCreateNamedPipeFile        pipe server endpoint
--   NtCreateMailslotFile         mailslot server endpoint
--
-- Scatter/gather (verify NT 3.5 ntdll actually exports — may be NT4+):
--   NtReadFileScatter
--   NtWriteFileGather
