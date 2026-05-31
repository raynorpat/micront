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

local bit    = require('bit')
local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')
local oa     = require('nt.dll.oa')
local str    = require('nt.dll.str')

-- Pack(4) for LARGE_INTEGER-bearing structs; see nt.dll.sys for the
-- NT 3.5 alignment discussion.
ffi.cdef[[
#pragma pack(push, 4)
typedef struct _FILE_BASIC_INFORMATION {
    LARGE_INTEGER CreationTime;
    LARGE_INTEGER LastAccessTime;
    LARGE_INTEGER LastWriteTime;
    LARGE_INTEGER ChangeTime;
    ULONG         FileAttributes;
} FILE_BASIC_INFORMATION;

typedef struct _FILE_STANDARD_INFORMATION {
    LARGE_INTEGER AllocationSize;
    LARGE_INTEGER EndOfFile;
    ULONG         NumberOfLinks;
    unsigned char DeletePending;
    unsigned char Directory;
} FILE_STANDARD_INFORMATION;

typedef struct _FILE_NETWORK_OPEN_INFORMATION {
    LARGE_INTEGER CreationTime;
    LARGE_INTEGER LastAccessTime;
    LARGE_INTEGER LastWriteTime;
    LARGE_INTEGER ChangeTime;
    LARGE_INTEGER AllocationSize;
    LARGE_INTEGER EndOfFile;
    ULONG         FileAttributes;
} FILE_NETWORK_OPEN_INFORMATION;

typedef struct _FILE_DIRECTORY_INFORMATION {
    ULONG         NextEntryOffset;
    ULONG         FileIndex;
    LARGE_INTEGER CreationTime;
    LARGE_INTEGER LastAccessTime;
    LARGE_INTEGER LastWriteTime;
    LARGE_INTEGER ChangeTime;
    LARGE_INTEGER EndOfFile;
    LARGE_INTEGER AllocationSize;
    ULONG         FileAttributes;
    ULONG         FileNameLength;
    wchar_t       FileName[1];
} FILE_DIRECTORY_INFORMATION;

/* The three richer enumeration projections.  All share the leading
 * NextEntryOffset/FileIndex; FileNameLength and FileName sit at a
 * class-specific offset, so iter_dir casts to the matching struct. */
typedef struct _FILE_FULL_DIR_INFORMATION {
    ULONG         NextEntryOffset;
    ULONG         FileIndex;
    LARGE_INTEGER CreationTime;
    LARGE_INTEGER LastAccessTime;
    LARGE_INTEGER LastWriteTime;
    LARGE_INTEGER ChangeTime;
    LARGE_INTEGER EndOfFile;
    LARGE_INTEGER AllocationSize;
    ULONG         FileAttributes;
    ULONG         FileNameLength;
    ULONG         EaSize;
    wchar_t       FileName[1];
} FILE_FULL_DIR_INFORMATION;

typedef struct _FILE_BOTH_DIR_INFORMATION {
    ULONG         NextEntryOffset;
    ULONG         FileIndex;
    LARGE_INTEGER CreationTime;
    LARGE_INTEGER LastAccessTime;
    LARGE_INTEGER LastWriteTime;
    LARGE_INTEGER ChangeTime;
    LARGE_INTEGER EndOfFile;
    LARGE_INTEGER AllocationSize;
    ULONG         FileAttributes;
    ULONG         FileNameLength;
    ULONG         EaSize;
    signed char   ShortNameLength;  /* bytes */
    wchar_t       ShortName[12];
    wchar_t       FileName[1];
} FILE_BOTH_DIR_INFORMATION;

typedef struct _FILE_NAMES_INFORMATION {
    ULONG         NextEntryOffset;
    ULONG         FileIndex;
    ULONG         FileNameLength;
    wchar_t       FileName[1];
} FILE_NAMES_INFORMATION;

typedef struct _FILE_POSITION_INFORMATION {
    LARGE_INTEGER CurrentByteOffset;
} FILE_POSITION_INFORMATION;

typedef struct _FILE_END_OF_FILE_INFORMATION {
    LARGE_INTEGER EndOfFile;
} FILE_END_OF_FILE_INFORMATION;

typedef struct _FILE_DISPOSITION_INFORMATION {
    unsigned char DeleteFile;
} FILE_DISPOSITION_INFORMATION;

/* Flat (HANDLE + ULONG, both 4 bytes) — pack-agnostic, but it sits in
 * the pack(4) block alongside the other FILE_*_INFORMATION types. */
typedef struct _FILE_COMPLETION_INFORMATION {
    HANDLE Port;
    ULONG  Key;
} FILE_COMPLETION_INFORMATION;

#pragma pack(pop)

/* FILE_RENAME_INFORMATION is variable-length: header + inline FileName.
 * Trailing wchar_t[?] flexes via ffi.new('FILE_RENAME_INFORMATION', n);
 * the result is a single cdata whose lifetime covers both the header
 * and the name buffer — same fused-allocation pattern as NT_STRING and
 * NT_OA_PATH, no cast-pointer aliasing.
 *
 * Pack is 2 (NOT 4) because NT 3.5's kernel struct layout for this
 * specific type uses pack(2) — empirically verified via DbgPrint of
 * FIELD_OFFSET(FILE_RENAME_INFORMATION, FileName) returning 10 (not
 * 12). With pack(2), HANDLE goes at offset 2 (1-byte pad after the
 * BOOLEAN), ULONG at offset 6, FileName at offset 10. With pack(4)
 * we'd put HANDLE at 4 / FileName at 12, and the kernel would
 * misread our FileNameLength field as 0x00360000 = 3,538,944 (the
 * low byte of our actual FileNameLength shifted into the high byte
 * of the kernel's expected position). The validation
 * `FIELD_OFFSET(FileName) + FileNameLength <= Length` blows up with
 * STATUS_INVALID_PARAMETER. Other fs structs in this module are
 * pack(4)-safe because they don't have a small-then-large field
 * pairing that creates pack-dependent padding. */
#pragma pack(push, 2)
typedef struct _FILE_RENAME_INFORMATION {
    unsigned char ReplaceIfExists;
    HANDLE        RootDirectory;
    ULONG         FileNameLength;   /* bytes, not wchars */
    wchar_t       FileName[?];
} FILE_RENAME_INFORMATION;
#pragma pack(pop)

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

/* Server end of a named pipe. Like NtCreateFile but carries the pipe-
 * specific create parameters (type / read mode / completion mode,
 * instance count, in/out quotas, default timeout). The client end
 * opens an existing pipe with plain NtCreateFile / NtOpenFile. */
NTSTATUS __stdcall NtCreateNamedPipeFile(HANDLE *FileHandle,
                                         ULONG DesiredAccess,
                                         OBJECT_ATTRIBUTES *ObjectAttributes,
                                         IO_STATUS_BLOCK *IoStatusBlock,
                                         ULONG ShareAccess,
                                         ULONG CreateDisposition,
                                         ULONG CreateOptions,
                                         ULONG NamedPipeType,
                                         ULONG ReadMode,
                                         ULONG CompletionMode,
                                         ULONG MaximumInstances,
                                         ULONG InboundQuota,
                                         ULONG OutboundQuota,
                                         LARGE_INTEGER *DefaultTimeout);

NTSTATUS __stdcall NtQueryInformationFile(HANDLE FileHandle,
                                          IO_STATUS_BLOCK *IoStatusBlock,
                                          void *FileInformation,
                                          ULONG Length,
                                          int FileInformationClass);

NTSTATUS __stdcall NtSetInformationFile(HANDLE FileHandle,
                                        IO_STATUS_BLOCK *IoStatusBlock,
                                        void *FileInformation,
                                        ULONG Length,
                                        int FileInformationClass);

NTSTATUS __stdcall NtQueryDirectoryFile(HANDLE FileHandle,
                                        HANDLE Event,
                                        void *ApcRoutine,
                                        void *ApcContext,
                                        IO_STATUS_BLOCK *IoStatusBlock,
                                        void *FileInformation,
                                        ULONG Length,
                                        int FileInformationClass,
                                        unsigned char ReturnSingleEntry,
                                        UNICODE_STRING *FileName,
                                        unsigned char RestartScan);

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

/* Buffer is `const void *` here (semantically — kernel reads from
 * it, doesn't write).  The looser declaration matches what LuaJIT
 * can auto-convert from a Lua string, so callers can pass a string
 * directly without an intermediate cdata copy.  NT API headers
 * declare it as plain `PVOID` but the kernel respects const. */
NTSTATUS __stdcall NtWriteFile (HANDLE FileHandle,
                                HANDLE Event,
                                void *ApcRoutine,
                                void *ApcContext,
                                IO_STATUS_BLOCK *IoStatusBlock,
                                const void *Buffer,
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

/* Path-based "cheap stat" — the kernel opens, queries, and closes in one
 * syscall, no handle required.
 *   NtQueryAttributesFile      -> FILE_BASIC_INFORMATION         (times + attrs)
 *   NtQueryFullAttributesFile  -> FILE_NETWORK_OPEN_INFORMATION  (also size)
 * Both live in NTOS/IO/MISC.C.  NtQueryFullAttributesFile is the post-3.5
 * addition forward-ported to back GetFileAttributesEx; the kernel synthesizes
 * its size from FileStandardInformation in the parse path. */
NTSTATUS __stdcall NtQueryAttributesFile(
    OBJECT_ATTRIBUTES      *ObjectAttributes,
    FILE_BASIC_INFORMATION *FileInformation);

NTSTATUS __stdcall NtQueryFullAttributesFile(
    OBJECT_ATTRIBUTES             *ObjectAttributes,
    FILE_NETWORK_OPEN_INFORMATION *FileInformation);

/* SERIAL_TIMEOUTS (NTDDSER.H) — operand for IOCTL_SERIAL_{GET,SET}_TIMEOUTS.
 * All fields are milliseconds; the SERIAL driver (DD/SERIAL/READ.C) reads
 * them to decide how long a read waits.  See M.serial_set_timeouts. */
typedef struct _SERIAL_TIMEOUTS {
    ULONG ReadIntervalTimeout;
    ULONG ReadTotalTimeoutMultiplier;
    ULONG ReadTotalTimeoutConstant;
    ULONG WriteTotalTimeoutMultiplier;
    ULONG WriteTotalTimeoutConstant;
} SERIAL_TIMEOUTS;
]]

-- STATUS_END_OF_FILE has severity ERROR, so the uniform is_error
-- check would raise on it. EOF is expected in read loops though, so
-- NtReadFile special-cases it through. Constant lives in M (publicly
-- exposed so callers can match against the status we return).

local M = {}

-- ------------------------------------------------------------------
-- File-API constants — re-exported so callers (io.lua, os.lua, tests)
-- don't have to re-derive them from MSDN-style hex literals. Values
-- are stable across NT versions; sourced from NT/PUBLIC/SDK/INC/NTIOAPI.H
-- and WINNT.H.
-- ------------------------------------------------------------------

-- Access masks — composite "GENERIC" forms include SYNCHRONIZE, so
-- callers don't need to OR it in separately for synchronous handles.
M.FILE_GENERIC_READ            = 0x00120089
M.FILE_GENERIC_WRITE           = 0x00120116

-- Specific-rights bits within the file generic mapping.  Useful for
-- callers that want a finer-grained access mask (e.g. tests that open
-- with FILE_READ_DATA only to verify FILE_READ_ATTRIBUTES isn't
-- implicitly granted).  Composite GENERIC_READ / _WRITE above are
-- preferred for normal callers.
M.FILE_READ_DATA               = 0x00000001
M.FILE_WRITE_DATA              = 0x00000002
M.FILE_APPEND_DATA             = 0x00000004
M.FILE_READ_EA                 = 0x00000008
M.FILE_WRITE_EA                = 0x00000010
M.FILE_EXECUTE                 = 0x00000020
M.FILE_READ_ATTRIBUTES         = 0x00000080
M.FILE_WRITE_ATTRIBUTES        = 0x00000100

-- Standard rights commonly OR'd with the per-class bits above.
M.DELETE                       = 0x00010000
M.SYNCHRONIZE                  = 0x00100000

-- ShareAccess.
M.FILE_SHARE_READ              = 0x00000001
M.FILE_SHARE_WRITE             = 0x00000002
M.FILE_SHARE_DELETE            = 0x00000004

-- CreateDisposition.
M.FILE_SUPERSEDE               = 0
M.FILE_OPEN                    = 1
M.FILE_CREATE                  = 2
M.FILE_OPEN_IF                 = 3
M.FILE_OVERWRITE               = 4
M.FILE_OVERWRITE_IF            = 5

-- CreateOptions.
M.FILE_DIRECTORY_FILE          = 0x00000001
M.FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020
M.FILE_NON_DIRECTORY_FILE      = 0x00000040
M.FILE_DELETE_ON_CLOSE         = 0x00001000

-- FileAttributes (NtCreateFile FileAttributes argument).
M.FILE_ATTRIBUTE_NORMAL        = 0x00000080
M.FILE_ATTRIBUTE_DIRECTORY     = 0x00000010

-- Pseudo-status codes used at the read boundary. STATUS_END_OF_FILE
-- (severity ERROR) is special-cased through NtReadFile rather than
-- raised, so callers that want to detect EOF need this constant.
M.STATUS_END_OF_FILE           = 0xC0000011
-- Named-pipe read boundaries: PIPE_EMPTY means "no data available right now"
-- on a nowait (FILE_PIPE_COMPLETE_OPERATION) handle — NOT end of stream;
-- BROKEN / CLOSING mean the writer end is gone (treat as EOF).
M.STATUS_PIPE_EMPTY            = 0xC00000D9
M.STATUS_PIPE_BROKEN          = 0xC000014B
M.STATUS_PIPE_CLOSING         = 0xC0000128
M.STATUS_NO_MORE_FILES         = 0x80000006
-- A filtered NtQueryDirectoryFile whose pattern matched nothing at all
-- returns this on the first call (vs NO_MORE_FILES once some entries
-- have been returned).  Both are end-of-enumeration signals, not real
-- errors — see NtQueryDirectoryFile below.
M.STATUS_NO_SUCH_FILE          = 0xC000000F

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

-- ------------------------------------------------------------------
-- Named pipes — server endpoint creation.
--
-- The client end of an existing pipe opens with NtCreateFile /
-- NtOpenFile on its \Device\NamedPipe\... path; only the server end
-- needs the dedicated syscall and its pipe-specific parameters.
-- ------------------------------------------------------------------

-- Pipe type / mode constants (NTIOAPI.H) — named so callers don't pass
-- bare 0/1.
M.FILE_PIPE_BYTE_STREAM_TYPE    = 0x00000000
M.FILE_PIPE_MESSAGE_TYPE        = 0x00000001
M.FILE_PIPE_BYTE_STREAM_MODE    = 0x00000000
M.FILE_PIPE_MESSAGE_MODE        = 0x00000001
M.FILE_PIPE_QUEUE_OPERATION     = 0x00000000   -- completion: blocking
M.FILE_PIPE_COMPLETE_OPERATION  = 0x00000001   -- completion: return immediately
M.FILE_PIPE_UNLIMITED_INSTANCES = 0xFFFFFFFF

-- 100-ns ticks in one second — NT's LARGE_INTEGER timeout unit.
local NT_TICKS_PER_SEC = 10000000

-- create_named_pipe(opts) -> (handle, disposition).  Creates (or opens
-- another instance of) the server end of a named pipe.  opts:
--   name             NT path, e.g. "\\Device\\NamedPipe\\foo"  (required)
--   access           DesiredAccess         (default GENERIC_READ|WRITE)
--   share            ShareAccess           (default SHARE_READ|WRITE)
--   disposition      CreateDisposition     (default FILE_OPEN_IF)
--   options          CreateOptions         (default 0)
--   pipe_type        FILE_PIPE_*_TYPE      (default byte stream)
--   read_mode        FILE_PIPE_*_MODE      (default byte stream)
--   completion_mode  FILE_PIPE_*_OPERATION (default queue / blocking)
--   max_instances    simultaneous instances (default 1)
--   inbound_quota    pool bytes for inbound writes  (default 4096)
--   outbound_quota   pool bytes for outbound writes (default 4096)
--   timeout          default instance-wait timeout, seconds (default 5)
-- Raises on failure, like the other fs creators.  `disposition` is the
-- IoStatusBlock Information word (FILE_CREATED / FILE_OPENED).
function M.create_named_pipe(opts)
    opts = opts or {}
    if not opts.name then
        error("fs.create_named_pipe: opts.name is required", 2)
    end
    local noa  = oa.path(opts.name)
    local h    = ffi.new('HANDLE[1]')
    local iosb = ffi.new('IO_STATUS_BLOCK')

    -- Relative (negative) timeout, in 100-ns ticks.
    local timeout = ffi.new('LARGE_INTEGER')
    timeout.QuadPart = -((opts.timeout or 5) * NT_TICKS_PER_SEC)

    local st = ntdll.NtCreateNamedPipeFile(
        h,
        opts.access      or bit.bor(M.FILE_GENERIC_READ, M.FILE_GENERIC_WRITE),
        noa.oa,
        iosb,
        opts.share       or bit.bor(M.FILE_SHARE_READ, M.FILE_SHARE_WRITE),
        opts.disposition or M.FILE_OPEN_IF,
        opts.options     or 0,
        opts.pipe_type       or M.FILE_PIPE_BYTE_STREAM_TYPE,
        opts.read_mode       or M.FILE_PIPE_BYTE_STREAM_MODE,
        opts.completion_mode or M.FILE_PIPE_QUEUE_OPERATION,
        opts.max_instances   or 1,
        opts.inbound_quota   or 4096,
        opts.outbound_quota  or 4096,
        timeout)
    if err.is_error(st) then err.raise('NtCreateNamedPipeFile', st) end
    return handle.wrap(h[0]), iosb.Information
end

function M.NtReadFile(h, buffer, length, byte_offset)
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local st = ntdll.NtReadFile(handle.raw(h), nil, nil, nil, iosb,
                                buffer, length, byte_offset, nil)
    local stu = err.normalize(st)
    if err.is_error(st) and stu ~= M.STATUS_END_OF_FILE then
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

-- IOCTL_SERIAL_{GET,SET}_TIMEOUTS, CTL_CODE(FILE_DEVICE_SERIAL_PORT=0x1b,
-- function, METHOD_BUFFERED, FILE_ANY_ACCESS).  Mirrors the literal INIT.C
-- uses to put the boot console into "crunch down to one" raw mode.
M.IOCTL_SERIAL_GET_TIMEOUTS = 0x001B0020
M.IOCTL_SERIAL_SET_TIMEOUTS = 0x001B001C

-- serial_get_timeouts(h) -> SERIAL_TIMEOUTS cdata (a snapshot the caller can
-- mutate and feed back to serial_set_timeouts to restore prior state).
function M.serial_get_timeouts(h)
    local t = ffi.new('SERIAL_TIMEOUTS')
    M.NtDeviceIoControlFile(h, M.IOCTL_SERIAL_GET_TIMEOUTS,
        nil, 0, t, ffi.sizeof('SERIAL_TIMEOUTS'))
    return t
end

-- serial_set_timeouts(h, t) where t is a SERIAL_TIMEOUTS cdata (or a table
-- with the same field names).  Raises on a non-serial device.
function M.serial_set_timeouts(h, t)
    if type(t) == 'table' then
        local c = ffi.new('SERIAL_TIMEOUTS')
        c.ReadIntervalTimeout         = t.ReadIntervalTimeout         or 0
        c.ReadTotalTimeoutMultiplier  = t.ReadTotalTimeoutMultiplier  or 0
        c.ReadTotalTimeoutConstant    = t.ReadTotalTimeoutConstant    or 0
        c.WriteTotalTimeoutMultiplier = t.WriteTotalTimeoutMultiplier or 0
        c.WriteTotalTimeoutConstant   = t.WriteTotalTimeoutConstant   or 0
        t = c
    end
    M.NtDeviceIoControlFile(h, M.IOCTL_SERIAL_SET_TIMEOUTS,
        t, ffi.sizeof('SERIAL_TIMEOUTS'), nil, 0)
end

-- FILE_INFORMATION_CLASS subset used below. Values from
-- NT/PUBLIC/SDK/INC/NTIOAPI.H — stable across NT versions.
local FileBasicInformation       = 4
local FileStandardInformation    = 5
local FileRenameInformation      = 10
local FileDispositionInformation = 13
local FilePositionInformation    = 14
local FileEndOfFileInformation   = 20
local FileCompletionInformation  = 30

M.FileBasicInformation       = FileBasicInformation
M.FileStandardInformation    = FileStandardInformation
M.FileRenameInformation      = FileRenameInformation
M.FileDispositionInformation = FileDispositionInformation
M.FilePositionInformation    = FilePositionInformation
M.FileEndOfFileInformation   = FileEndOfFileInformation
M.FileCompletionInformation  = FileCompletionInformation

-- Query fixed-size file info. Returns a freshly-allocated cdata of the
-- requested class. NT 3.5 strict-checks Length == sizeof for fixed
-- classes (same rule as NtQueryObject), so size is taken from the cdef.
local function make_file_query(struct_name, info_class)
    local size = ffi.sizeof(struct_name)
    return function(h)
        local info = ffi.new(struct_name)
        local iosb = ffi.new('IO_STATUS_BLOCK')
        local st = ntdll.NtQueryInformationFile(handle.raw(h), iosb,
                                                info, size, info_class)
        if err.is_error(st) then err.raise('NtQueryInformationFile', st) end
        return info
    end
end

M.query_basic    = make_file_query('FILE_BASIC_INFORMATION',    FileBasicInformation)
M.query_standard = make_file_query('FILE_STANDARD_INFORMATION', FileStandardInformation)

-- Path-based queries (no handle): the kernel opens, queries, and closes in
-- one syscall.  query_attributes returns basic info (times + attrs);
-- query_full_attributes also returns the file size (EndOfFile /
-- AllocationSize) -- the field GetFileAttributesEx / stat needs.
function M.query_attributes(path)
    local p    = oa.path(path)
    local info = ffi.new('FILE_BASIC_INFORMATION')
    local st   = ntdll.NtQueryAttributesFile(p.oa, info)
    if err.is_error(st) then err.raise('NtQueryAttributesFile', st) end
    return info
end

function M.query_full_attributes(path)
    local p    = oa.path(path)
    local info = ffi.new('FILE_NETWORK_OPEN_INFORMATION')
    local st   = ntdll.NtQueryFullAttributesFile(p.oa, info)
    if err.is_error(st) then err.raise('NtQueryFullAttributesFile', st) end
    return info
end

-- Generic NtSetInformationFile bridge. info is a cdata of any size; the
-- caller supplies the matching FILE_*_INFORMATION class.
function M.NtSetInformationFile(h, info, length, info_class)
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local st = ntdll.NtSetInformationFile(handle.raw(h), iosb,
                                          info, length, info_class)
    if err.is_error(st) then err.raise('NtSetInformationFile', st) end
    return iosb.Information
end

-- file:seek-style helpers. Set (and read) the kernel-side file pointer
-- on a synchronous handle. NtRead/WriteFile with ByteOffset=nil consults
-- this pointer; the wrappers in this module already pass `byte_offset`
-- explicitly, but for io.lua's `file:seek` we want NT to track position.
function M.set_position(h, offset)
    local info = ffi.new('FILE_POSITION_INFORMATION')
    info.CurrentByteOffset.QuadPart = offset
    M.NtSetInformationFile(h, info,
                           ffi.sizeof('FILE_POSITION_INFORMATION'),
                           FilePositionInformation)
end

function M.get_position(h)
    local info = ffi.new('FILE_POSITION_INFORMATION')
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local st = ntdll.NtQueryInformationFile(handle.raw(h), iosb,
        info, ffi.sizeof('FILE_POSITION_INFORMATION'), FilePositionInformation)
    if err.is_error(st) then err.raise('NtQueryInformationFile', st) end
    return tonumber(info.CurrentByteOffset.QuadPart)
end

-- Mark file for deletion on last close. Handle must have been opened
-- with DELETE access. NT 3.5 deletes when the last handle to the file
-- (anywhere in the system) is closed; subsequent opens fail with
-- STATUS_DELETE_PENDING until that happens.
function M.set_disposition(h, delete)
    local info = ffi.new('FILE_DISPOSITION_INFORMATION')
    info.DeleteFile = delete and 1 or 0
    M.NtSetInformationFile(h, info,
                           ffi.sizeof('FILE_DISPOSITION_INFORMATION'),
                           FileDispositionInformation)
end

-- Truncate / extend the file to the given byte length. Handle needs
-- FILE_WRITE_DATA. After this returns the file pointer is unchanged.
function M.set_end_of_file(h, length)
    local info = ffi.new('FILE_END_OF_FILE_INFORMATION')
    info.EndOfFile.QuadPart = length
    M.NtSetInformationFile(h, info,
                           ffi.sizeof('FILE_END_OF_FILE_INFORMATION'),
                           FileEndOfFileInformation)
end

-- Associate `file_handle` with an I/O completion `port` so that
-- completions of async I/O on the file queue a packet to the port.
-- `port` is an NT_HANDLE for an IoCompletion object; `key` is an opaque
-- ULONG echoed back as the KeyContext of every drained completion
-- (default 0).
--
-- The file must have been opened for ASYNCHRONOUS I/O — the kernel
-- (QSINFO.C:1393) rejects a synchronous handle (one opened with a
-- FILE_SYNCHRONOUS_IO_* option) or a handle already associated with a
-- port, both as STATUS_INVALID_PARAMETER. Note also that the kernel
-- only queues a port packet for I/O that carried a non-NULL ApcContext.
function M.set_completion_port(file_handle, port, key)
    local info = ffi.new('FILE_COMPLETION_INFORMATION')
    info.Port = handle.raw(port)
    info.Key  = key or 0
    M.NtSetInformationFile(file_handle, info,
                           ffi.sizeof('FILE_COMPLETION_INFORMATION'),
                           FileCompletionInformation)
end

-- Rename via FILE_RENAME_INFORMATION. `new_name` is a UTF-8 Lua string;
-- decoded internally to UTF-16. `replace` defaults to false; if true
-- and the target exists it gets clobbered. `root_handle` is an optional
-- NT_HANDLE — when provided, the name is interpreted relative to that
-- directory (e.g. for renaming inside an already-opened parent dir
-- handle). Raw HANDLEs are not accepted; handle.raw enforces NT_HANDLE.
local WCHAR_BYTES = ffi.sizeof('wchar_t')

function M.set_rename(h, new_name, replace, root_handle)
    local wchars = str.decode_utf8(new_name)
    local n      = #wchars
    -- Single fused cdata: header + n wchars in one allocation. ffi.new
    -- with the trailing-VLA cdef gives us one ref to keep alive across
    -- the syscall; no cast-pointer aliasing.
    local info = ffi.new('FILE_RENAME_INFORMATION', n)
    info.ReplaceIfExists = replace and 1 or 0
    info.RootDirectory   = root_handle and handle.raw(root_handle) or nil
    info.FileNameLength  = n * WCHAR_BYTES        -- bytes, per NT contract
    for i = 1, n do
        info.FileName[i-1] = wchars[i]
    end
    -- `ffi.sizeof('TYPE', nelem)` is the documented LuaJIT idiom for
    -- VLA-struct sizing; should give header + nelem*element_size.
    local total_length = ffi.sizeof('FILE_RENAME_INFORMATION', n)
    M.NtSetInformationFile(h, info, total_length, FileRenameInformation)
end

-- FileInformationClass values accepted by NtQueryDirectoryFile.  Each
-- selects a different per-entry projection; iter_dir decodes whichever
-- one was requested.
M.FileDirectoryInformation     = 1   -- FILE_DIRECTORY_INFORMATION
M.FileFullDirectoryInformation = 2   -- + EaSize
M.FileBothDirectoryInformation = 3   -- + EaSize + ShortName (8.3)
M.FileNamesInformation         = 12  -- name only (leanest)

-- Directory enumeration. Caller provides buffer; each call returns one
-- or more FILE_*_DIR/NAMES_INFORMATION records (linked via
-- NextEntryOffset). Returns (bytes_written, status). STATUS_NO_MORE_FILES
-- (0x80000006) is WARNING-severity so it passes through is_error.
--
-- name_filter is an optional UTF-8 search pattern (NT wildcards * and ?
-- allowed); nil enumerates everything. NT captures the pattern on the
-- first (restart_scan) call and ignores it on continuations — pass it
-- only with restart_scan=true, or NT treats it as "resume after this
-- name" instead.
--
-- info_class selects the record shape (M.File*Information above);
-- defaults to FileDirectoryInformation.
function M.NtQueryDirectoryFile(h, buffer, length, restart_scan, name_filter,
                                info_class)
    local iosb = ffi.new('IO_STATUS_BLOCK')
    -- Held as a local so the fused UNICODE_STRING + wbuf stays alive
    -- across the syscall; nil filter -> NULL FileName (enumerate all).
    local filter = name_filter and str.to_utf16(name_filter) or nil
    local st = ntdll.NtQueryDirectoryFile(handle.raw(h), nil, nil, nil, iosb,
                                          buffer, length,
                                          info_class or M.FileDirectoryInformation,
                                          0 --[[ ReturnSingleEntry=false ]],
                                          filter and ffi.cast('UNICODE_STRING *', filter.us)
                                                 or nil,
                                          restart_scan and 1 or 0)
    local stn = err.normalize(st)
    -- NO_SUCH_FILE means a filtered scan matched nothing — an empty
    -- result, not a failure; surface it like NO_MORE_FILES so callers
    -- (iter_dir) end the enumeration cleanly instead of raising.
    if err.is_error(st) and stn ~= M.STATUS_NO_SUCH_FILE then
        err.raise('NtQueryDirectoryFile', st)
    end
    return iosb.Information, stn
end

-- ------------------------------------------------------------------
-- Higher-level wrappers built on the primitives above.  These exist
-- so callers in ntosbe.platform (and any other consumer) don't have
-- to re-derive the same flag soup at every site.
-- ------------------------------------------------------------------

local STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034
local STATUS_OBJECT_PATH_NOT_FOUND = 0xC000003A

-- query_attributes(path) → FILE_BASIC_INFORMATION cdata, or nil if the
-- file/dir is missing.  One syscall, no handle alloc.  Wraps
-- NtQueryAttributesFile (NT 3.5; NT 4.0+ has NtQueryFullAttributesFile
-- which also returns size, but we don't need that for the build path).
--
-- Use cases: file_exists(p) = query_attributes(p) ~= nil ;
--            is_dir(p)      = bit.band(.FileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0;
--            mtime(p)       = .LastWriteTime → rtl.li_to_unix.
function M.query_attributes(path)
    local noa  = oa.path(path)
    local info = ffi.new('FILE_BASIC_INFORMATION')
    local st   = ntdll.NtQueryAttributesFile(noa.oa, info)
    local stu  = err.normalize(st)
    if stu == STATUS_OBJECT_NAME_NOT_FOUND
       or stu == STATUS_OBJECT_PATH_NOT_FOUND then
        return nil
    end
    if err.is_error(st) then err.raise('NtQueryAttributesFile', st) end
    return info
end

-- create_dir(path) → handle, was_created.  Composes NtCreateFile with
-- the right flag mix for "ensure directory exists; return a handle to
-- it".  was_created is true if the dir was just created (FILE_CREATED
-- = 2 in IoStatusBlock) vs already-existed (FILE_OPENED = 1).  The
-- handle is returned as an NT_HANDLE — caller :close() when done.
--
-- Used by platform.mkdir_p which walks each component.
M.FILE_OPENED  = 1
M.FILE_CREATED = 2

function M.create_dir(path)
    local noa = oa.path(path)
    local h, info = M.NtCreateFile(
        bit.bor(M.FILE_GENERIC_READ, M.SYNCHRONIZE),
        noa.oa,
        nil,                                       -- AllocationSize
        M.FILE_ATTRIBUTE_DIRECTORY,
        bit.bor(M.FILE_SHARE_READ, M.FILE_SHARE_WRITE),
        M.FILE_OPEN_IF,
        bit.bor(M.FILE_DIRECTORY_FILE, M.FILE_SYNCHRONOUS_IO_NONALERT),
        nil, 0)
    return h, info == M.FILE_CREATED
end

-- Per-FileInformationClass record struct.  iter_dir casts the buffer
-- cursor to the matching type so .FileName / .FileNameLength /
-- .NextEntryOffset resolve at the right (class-specific) offsets.
local DIR_INFO_STRUCT = {
    [M.FileDirectoryInformation]     = 'FILE_DIRECTORY_INFORMATION *',
    [M.FileFullDirectoryInformation] = 'FILE_FULL_DIR_INFORMATION *',
    [M.FileBothDirectoryInformation] = 'FILE_BOTH_DIR_INFORMATION *',
    [M.FileNamesInformation]         = 'FILE_NAMES_INFORMATION *',
}

-- iter_dir(handle [, name_filter [, info_class]]) → iterator yielding
-- (name, info) pairs.
--
-- Wraps NtQueryDirectoryFile + linked-list parse over a single 8 KB
-- buffer.  NextEntryOffset = 0 marks the last record in a buffer; we
-- re-call NtQueryDirectoryFile (restart_scan=false) for the next
-- batch, until STATUS_NO_MORE_FILES.
--
-- name_filter is an optional UTF-8 search pattern (NT wildcards * / ?);
-- nil enumerates everything.  It is handed to the kernel only on the
-- restart call — see NtQueryDirectoryFile's contract.
--
-- info_class (M.File*Information) picks the record shape; defaults to
-- FileDirectoryInformation.  `info` is a pointer into the buffer at the
-- current record, cast to the matching struct — caller reads
-- .FileAttributes / .ShortName / .EaSize etc. inline without a second
-- syscall.  Don't store the pointer beyond one iteration; the next
-- yield reuses the buffer.
--
-- "." and ".." are filtered out (callers never want them).
local BUF_BYTES = 8 * 1024

function M.iter_dir(h, name_filter, info_class)
    info_class = info_class or M.FileDirectoryInformation
    local rec_ptr = DIR_INFO_STRUCT[info_class]
    if rec_ptr == nil then
        error("iter_dir: unsupported info_class " .. tostring(info_class), 2)
    end

    local buf        = ffi.new('uint8_t[?]', BUF_BYTES)
    local first_call = true
    local cur        = nil       -- pointer to the current record

    local function refill()
        local bytes, st = M.NtQueryDirectoryFile(
            h, buf, BUF_BYTES, first_call,
            first_call and name_filter or nil, info_class)
        first_call = false
        if st == M.STATUS_NO_MORE_FILES or st == M.STATUS_NO_SUCH_FILE then
            return false
        end
        cur = ffi.cast(rec_ptr, buf)
        return true
    end

    local function next_entry()
        ::again::
        if cur == nil then
            if not refill() then return nil end
        end
        local info = cur
        local n_chars = math.floor(info.FileNameLength / 2)
        -- FileName is declared `wchar_t FileName[1]` but the kernel
        -- writes FileNameLength bytes inline starting at that offset.
        -- Cast explicitly so str.from_wchars indexes via pointer
        -- arithmetic rather than struct-field access semantics.
        local wp = ffi.cast('uint16_t *', info.FileName)
        local name = str.from_wchars(wp, n_chars)

        -- Advance.
        if info.NextEntryOffset == 0 then
            cur = nil       -- forces refill on next call
        else
            cur = ffi.cast(rec_ptr,
                           ffi.cast('uint8_t *', cur) + info.NextEntryOffset)
        end

        if name == "." or name == ".." then goto again end
        return name, info
    end

    return next_entry
end

-- Convenience: list_dir(path [, name_filter]) opens, drains, closes.
-- Returns an array of file names (no "." / "..").  Mirrors host
-- platform.list_dir exactly so callers don't have to branch.
-- name_filter is an optional UTF-8 search pattern (NT wildcards * / ?);
-- nil lists everything.
--
-- pcall + always-close pattern: NtQueryDirectoryFile may raise on
-- (e.g.) STATUS_INSUFFICIENT_RESOURCES; we still want the handle
-- closed deterministically rather than waiting for __gc.  Same shape
-- as ps.RtlCreateUserProcess's RtlDestroyProcessParameters guard.
function M.list_dir(path, name_filter)
    local noa = oa.path(path)
    local h = M.NtOpenFile(
        bit.bor(M.FILE_GENERIC_READ, M.SYNCHRONIZE),
        noa.oa,
        bit.bor(M.FILE_SHARE_READ, M.FILE_SHARE_WRITE),
        bit.bor(M.FILE_DIRECTORY_FILE, M.FILE_SYNCHRONOUS_IO_NONALERT))
    local ok, ret = pcall(function()
        local names = {}
        for name, _info in M.iter_dir(h, name_filter) do
            names[#names + 1] = name
        end
        return names
    end)
    h:close()
    if not ok then error(ret, 0) end
    return ret
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
--   NtSetInformationFile         set FILE_*_INFORMATION
--   NtQueryVolumeInformationFile FILE_FS_*_INFORMATION classes
--   NtSetVolumeInformationFile   "
--   NtQueryAttributesFile        cheap stat(2) without opening the file
--   NtQueryFullAttributesFile    "  with more fields
--
-- Async / callback-driven:
--   NtNotifyChangeDirectoryFile  dir watch — completes via APC/IOCP
--
-- Named object creation (distinct from NtCreateFile):
--   NtCreateMailslotFile         mailslot server endpoint
--   (NtCreateNamedPipeFile is bridged above — see M.create_named_pipe.)
--
-- Scatter/gather (verify NT 3.5 ntdll actually exports — may be NT4+):
--   NtReadFileScatter
--   NtWriteFileGather
