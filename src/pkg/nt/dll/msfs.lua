-- nt.dll.msfs — mailslot surface. Maps to the NTOS/MAILSLOT kernel
-- driver (msfs.sys, \Device\Mailslot).
--
-- Mailslots are datagram IPC: the server (read) end is created with
-- create_mailslot; the client (write) end opens the same
-- \Device\Mailslot\<name> path with open_mailslot. One NtWriteFile on
-- the client = one message; one NtReadFile on the server returns one
-- whole message (FIFO). Messages flow client -> server only.
--
-- Like nt.dll.npfs, this rides on the generic Io syscalls in nt.dll.fs
-- (NtCreateFile / NtFsControlFile / Nt{Query,Set}InformationFile); only
-- NtCreateMailslotFile and the mailslot-specific structs/FSCTL live here.

local bit    = require('bit')
local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local fs     = require('nt.dll.fs')      -- generic Io: NtCreateFile / NtFsControlFile / ctl_code
local oa     = require('nt.dll.oa')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

-- Mailslot structs are naturally aligned (ULONG / LARGE_INTEGER), so a
-- plain cdef at LuaJIT's default alignment matches the layout msfs expects.
ffi.cdef[[
/* Server end of a mailslot. The write (client) end opens the
 * \Device\Mailslot\<name> path with plain NtCreateFile / NtOpenFile.
 * ReadTimeout: 0 = return immediately, -1 = wait forever, else a
 * relative (negative) 100-ns timeout. See M.create_mailslot. */
NTSTATUS __stdcall NtCreateMailslotFile(HANDLE *FileHandle,
                                        ULONG DesiredAccess,
                                        OBJECT_ATTRIBUTES *ObjectAttributes,
                                        IO_STATUS_BLOCK *IoStatusBlock,
                                        ULONG CreateOptions,
                                        ULONG MailslotQuota,
                                        ULONG MaximumMessageSize,
                                        LARGE_INTEGER *ReadTimeout);

/* Mailslot info structs (NTIOAPI.H). */
typedef struct _FILE_MAILSLOT_QUERY_INFORMATION {
    ULONG         MaximumMessageSize;
    ULONG         MailslotQuota;
    ULONG         NextMessageSize;
    ULONG         MessagesAvailable;
    LARGE_INTEGER ReadTimeout;
} FILE_MAILSLOT_QUERY_INFORMATION;

typedef struct _FILE_MAILSLOT_SET_INFORMATION {
    LARGE_INTEGER *ReadTimeout;
} FILE_MAILSLOT_SET_INFORMATION;

/* Lua-side allocation that fuses the timeout value into the SAME cdata as
 * the pointer to it (Storage), so one live reference — the struct we pass
 * to the syscall — keeps the pointee alive while the kernel dereferences
 * *ReadTimeout. A raw FFI pointer (info.ReadTimeout -> a separate cdata)
 * is NOT a GC reference, so a separate LARGE_INTEGER could be collected
 * mid-call. Same self-referential idiom as nt.dll.oa's NT_OA_PATH. Only
 * the leading FILE_MAILSLOT_SET_INFORMATION-sized prefix is the wire ABI. */
typedef struct {
    LARGE_INTEGER *ReadTimeout;
    LARGE_INTEGER  Storage;
} MS_SET_TIMEOUT;

/* FSCTL_MAILSLOT_PEEK header (METHOD_NEITHER): this struct goes in the
 * *input* buffer (the driver writes counts back into it); the message
 * data lands in the separate *output* buffer. No trailing data. */
typedef struct _FILE_MAILSLOT_PEEK_BUFFER {
    ULONG ReadDataAvailable;
    ULONG NumberOfMessages;
    ULONG MessageLength;
} FILE_MAILSLOT_PEEK_BUFFER;
]]

local M = {}

-- 100-ns ticks in one second — NT's LARGE_INTEGER timeout unit.
local NT_TICKS_PER_SEC = 10000000

-- ------------------------------------------------------------------
-- Constants (NTIOAPI.H).
-- ------------------------------------------------------------------

-- FILE_INFORMATION_CLASS values for the mailslot classes (NTIOAPI.H enum,
-- 1-based). Used with NtQuery/SetInformationFile.
M.FileMailslotQueryInformation  = 26
M.FileMailslotSetInformation    = 27

-- NextMessageSize when the mailslot is empty.
M.MAILSLOT_NO_MESSAGE           = 0xFFFFFFFF

-- Read-timeout sentinels (seconds, as passed to create_mailslot /
-- set_mailslot_timeout). 0 = return at once if no message; math.huge =
-- block until a message arrives.
M.MAILSLOT_WAIT_IMMEDIATE = 0
M.MAILSLOT_WAIT_FOREVER   = math.huge

-- Mailslot FSCTL (NTIOAPI.H) — routed via fs.NtFsControlFile.
local FILE_DEVICE_MAILSLOT = 0x0000000C
local METHOD_NEITHER       = 3
M.FSCTL_MAILSLOT_PEEK = fs.ctl_code(FILE_DEVICE_MAILSLOT, 0, METHOD_NEITHER, fs.FILE_READ_DATA)

-- Map a seconds value (0 / math.huge / N) onto an NT mailslot ReadTimeout
-- LARGE_INTEGER: 0 -> immediate, huge -> -1 (forever), else negative
-- relative ticks.  Writes into `li` (a LARGE_INTEGER cdata) and returns it.
local function mailslot_timeout(li, secs)
    secs = secs or 0
    if secs == math.huge then
        li.QuadPart = -1                          -- MAILSLOT_WAIT_FOREVER
    else
        li.QuadPart = -(secs * NT_TICKS_PER_SEC)  -- 0 -> immediate
    end
    return li
end

-- ------------------------------------------------------------------
-- Endpoints — server creation and client open.
-- ------------------------------------------------------------------

-- create_mailslot(opts) -> (handle, disposition).  Server (read) end.
--   name              NT path "\\Device\\Mailslot\\foo"  (required)
--   access            DesiredAccess  (default GENERIC_READ|SYNCHRONIZE)
--   options           CreateOptions  (default FILE_SYNCHRONOUS_IO_NONALERT)
--   quota             MailslotQuota bytes, 0 = driver default
--   max_message_size  0 = unlimited
--   read_timeout      seconds; 0 = return immediately (default),
--                     math.huge = wait forever
function M.create_mailslot(opts)
    opts = opts or {}
    if not opts.name then
        error("msfs.create_mailslot: opts.name is required", 2)
    end
    local noa  = oa.path(opts.name)
    local h    = ffi.new('HANDLE[1]')
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local rt   = mailslot_timeout(ffi.new('LARGE_INTEGER'), opts.read_timeout)

    local st = ntdll.NtCreateMailslotFile(
        h,
        opts.access  or bit.bor(fs.FILE_GENERIC_READ, fs.SYNCHRONIZE),
        noa.oa,
        iosb,
        opts.options or fs.FILE_SYNCHRONOUS_IO_NONALERT,
        opts.quota   or 0,
        opts.max_message_size or 0,
        rt)
    if err.is_error(st) then err.raise('NtCreateMailslotFile', st) end
    return handle.wrap(h[0]), iosb.Information
end

-- open_mailslot(name, opts) -> (handle, disposition).  Client (write) end
-- of an existing mailslot.
--   access   DesiredAccess  (default GENERIC_WRITE)
--   share    ShareAccess    (default SHARE_READ|WRITE)
--   options  CreateOptions  (default FILE_SYNCHRONOUS_IO_NONALERT)
function M.open_mailslot(name, opts)
    opts = opts or {}
    local noa = oa.path(name)
    return fs.NtCreateFile(
        opts.access      or fs.FILE_GENERIC_WRITE,
        noa.oa, nil, fs.FILE_ATTRIBUTE_NORMAL,
        opts.share       or bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        opts.disposition or fs.FILE_OPEN,
        opts.options     or fs.FILE_SYNCHRONOUS_IO_NONALERT)
end

-- ------------------------------------------------------------------
-- Control operations — info query, timeout adjust, peek.
-- ------------------------------------------------------------------

-- mailslot_info(h) -> FILE_MAILSLOT_QUERY_INFORMATION cdata.  On the
-- server handle.  NextMessageSize == MAILSLOT_NO_MESSAGE (0xFFFFFFFF)
-- when empty; MessagesAvailable counts queued messages.
function M.mailslot_info(h)
    local info = ffi.new('FILE_MAILSLOT_QUERY_INFORMATION')
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local st = ntdll.NtQueryInformationFile(handle.raw(h), iosb, info,
        ffi.sizeof('FILE_MAILSLOT_QUERY_INFORMATION'),
        M.FileMailslotQueryInformation)
    if err.is_error(st) then err.raise('NtQueryInformationFile', st) end
    return info
end

-- set_mailslot_timeout(h, secs) — adjust the server read timeout after
-- create.  The wire struct's only field is a *pointer* to the timeout, so
-- we fuse the value (Storage) and the pointer into one MS_SET_TIMEOUT
-- allocation pointing at itself: keeping that single cdata alive across
-- the (synchronous) syscall keeps the pointee alive too.  Length is the
-- wire-ABI prefix (just the pointer), not sizeof(MS_SET_TIMEOUT).
function M.set_mailslot_timeout(h, secs)
    local info = ffi.new('MS_SET_TIMEOUT')
    mailslot_timeout(info.Storage, secs)
    info.ReadTimeout = info.Storage          -- -> &info.Storage, same allocation
    fs.NtSetInformationFile(h, info, ffi.sizeof('FILE_MAILSLOT_SET_INFORMATION'),
                            M.FileMailslotSetInformation)
end

-- mailslot_peek(h, max_data) -> table.  FSCTL_MAILSLOT_PEEK on the server
-- handle: inspects the next queued message WITHOUT consuming it.  The
-- METHOD_NEITHER contract is unusual — the count header
-- (FILE_MAILSLOT_PEEK_BUFFER) is written into the INPUT buffer, the
-- message bytes into the OUTPUT buffer.  Returns { available, messages,
-- message_length, data } (data truncated to max_data, default 256).
function M.mailslot_peek(h, max_data)
    max_data = max_data or 256
    local hdr = ffi.new('FILE_MAILSLOT_PEEK_BUFFER')
    local out = ffi.new('char[?]', max_data)
    local n = fs.NtFsControlFile(h, M.FSCTL_MAILSLOT_PEEK,
                                 hdr, ffi.sizeof('FILE_MAILSLOT_PEEK_BUFFER'),
                                 out, max_data)
    local ndata = n < max_data and n or max_data
    return {
        available      = hdr.ReadDataAvailable,
        messages       = hdr.NumberOfMessages,
        message_length = hdr.MessageLength,
        data           = ndata > 0 and ffi.string(out, ndata) or "",
    }
end

return M
