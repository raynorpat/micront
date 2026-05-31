-- nt.dll.npfs — named-pipe client surface. Maps to the NTOS/NPFS kernel
-- driver (\Device\NamedPipe).
--
-- Named pipes are the connection-oriented IPC filesystem: a server end
-- (create_named_pipe) and a client end (open_pipe) of the same
-- \Device\NamedPipe\<name> path, with byte-stream or message framing,
-- peek / transceive / wait / disconnect control operations, and a
-- per-end completion-event mechanism. All of it rides on the generic Io
-- syscalls in nt.dll.fs (NtCreateFile / NtFsControlFile / Nt{Query,Set}-
-- InformationFile); only NtCreateNamedPipeFile and the pipe-specific
-- structs/FSCTLs live here.
--
-- Sibling: nt.dll.msfs (mailslots — datagram IPC). Generic file ops,
-- volume-information queries and NtFlushBuffersFile stay in nt.dll.fs.

local bit    = require('bit')
local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local fs     = require('nt.dll.fs')      -- generic Io: NtCreateFile / NtFsControlFile / ctl_code
local oa     = require('nt.dll.oa')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')
local str    = require('nt.dll.str')

-- Pipe structs are all naturally aligned (ULONG / LARGE_INTEGER-first),
-- so they compile pack-independently — a plain cdef at LuaJIT's default
-- alignment, matching the layout NPFS expects.
ffi.cdef[[
/* Server end of a named pipe. The client end opens its
 * \Device\NamedPipe\<name> path with plain NtCreateFile / NtOpenFile;
 * only the server end needs the dedicated syscall and its pipe-specific
 * parameters. See M.create_named_pipe. */
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

/* Named-pipe info structs (NTIOAPI.H). All ULONG / LARGE_INTEGER, so
 * naturally aligned — pack-independent (no NT-3.5 pack(2) hazard). */
typedef struct _FILE_PIPE_INFORMATION {
    ULONG ReadMode;
    ULONG CompletionMode;
} FILE_PIPE_INFORMATION;

typedef struct _FILE_PIPE_LOCAL_INFORMATION {
    ULONG NamedPipeType;
    ULONG NamedPipeConfiguration;
    ULONG MaximumInstances;
    ULONG CurrentInstances;
    ULONG InboundQuota;
    ULONG ReadDataAvailable;
    ULONG OutboundQuota;
    ULONG WriteQuotaAvailable;
    ULONG NamedPipeState;
    ULONG NamedPipeEnd;
} FILE_PIPE_LOCAL_INFORMATION;

/* FSCTL_PIPE_PEEK output: fixed header then Data[] bytes. Sized
 * header + datalen by the caller; a trailing VLA so one ffi.new owns
 * the whole allocation. */
typedef struct _FILE_PIPE_PEEK_BUFFER {
    ULONG NamedPipeState;
    ULONG ReadDataAvailable;
    ULONG NumberOfMessages;
    ULONG MessageLength;
    char  Data[?];
} FILE_PIPE_PEEK_BUFFER;

/* FSCTL_PIPE_WAIT input. Issued against the \Device\NamedPipe root
 * handle (not a pipe instance); Name is the bare pipe name WITHOUT a
 * leading backslash. VLA Name[] fused into the one allocation. */
typedef struct _FILE_PIPE_WAIT_FOR_BUFFER {
    LARGE_INTEGER Timeout;
    ULONG         NameLength;       /* bytes, not wchars */
    unsigned char TimeoutSpecified;
    wchar_t       Name[?];
} FILE_PIPE_WAIT_FOR_BUFFER;

/* FSCTL_PIPE_ASSIGN_EVENT input. Registers a caller-supplied event handle
 * with one end of the pipe; npfs signals it (KeSetEvent) whenever the
 * OTHER end does I/O — a read/write/state-change. KeyValue is opaque to
 * the kernel, echoed back by FSCTL_PIPE_QUERY_EVENT. */
typedef struct _FILE_PIPE_ASSIGN_EVENT_BUFFER {
    HANDLE EventHandle;
    ULONG  KeyValue;
} FILE_PIPE_ASSIGN_EVENT_BUFFER;
]]

local M = {}

-- 100-ns ticks in one second — NT's LARGE_INTEGER timeout unit.
local NT_TICKS_PER_SEC = 10000000

-- ------------------------------------------------------------------
-- Constants (NTIOAPI.H) — named so callers don't pass bare 0/1.
-- ------------------------------------------------------------------

-- Pipe type / read mode / completion mode.
M.FILE_PIPE_BYTE_STREAM_TYPE    = 0x00000000
M.FILE_PIPE_MESSAGE_TYPE        = 0x00000001
M.FILE_PIPE_BYTE_STREAM_MODE    = 0x00000000
M.FILE_PIPE_MESSAGE_MODE        = 0x00000001
M.FILE_PIPE_QUEUE_OPERATION     = 0x00000000   -- completion: blocking
M.FILE_PIPE_COMPLETE_OPERATION  = 0x00000001   -- completion: return immediately
M.FILE_PIPE_UNLIMITED_INSTANCES = 0xFFFFFFFF

-- NamedPipeConfiguration (data direction the pipe carries).
M.FILE_PIPE_INBOUND             = 0x00000000   -- client -> server only
M.FILE_PIPE_OUTBOUND            = 0x00000001   -- server -> client only
M.FILE_PIPE_FULL_DUPLEX         = 0x00000002   -- both

-- NamedPipeState (FILE_PIPE_LOCAL_INFORMATION.NamedPipeState).
M.FILE_PIPE_DISCONNECTED_STATE  = 0x00000001
M.FILE_PIPE_LISTENING_STATE     = 0x00000002
M.FILE_PIPE_CONNECTED_STATE     = 0x00000003
M.FILE_PIPE_CLOSING_STATE       = 0x00000004

-- NamedPipeEnd — note the unintuitive ordering (client is 0).
M.FILE_PIPE_CLIENT_END          = 0x00000000
M.FILE_PIPE_SERVER_END          = 0x00000001

-- FILE_INFORMATION_CLASS values for the pipe classes (NTIOAPI.H enum,
-- 1-based). Used with NtQuery/SetInformationFile.
M.FilePipeInformation           = 23
M.FilePipeLocalInformation      = 24
M.FilePipeRemoteInformation     = 25

-- Named-pipe status codes seen on the round-trip paths. PIPE_EMPTY means
-- "no data available right now" on a nowait (FILE_PIPE_COMPLETE_OPERATION)
-- handle — NOT end of stream; BROKEN / CLOSING mean the writer end is gone
-- (treat as EOF). (Generic NTSTATUS — BUFFER_OVERFLOW, IO_TIMEOUT,
-- OBJECT_NAME_NOT_FOUND, etc. — stay in nt.dll.fs.)
M.STATUS_PIPE_EMPTY             = 0xC00000D9
M.STATUS_PIPE_BROKEN            = 0xC000014B
M.STATUS_PIPE_CLOSING           = 0xC0000128
M.STATUS_PIPE_DISCONNECTED      = 0xC00000B0
M.STATUS_PIPE_NOT_AVAILABLE     = 0xC00000AC
M.STATUS_PIPE_BUSY              = 0xC00000AE
M.STATUS_INVALID_READ_MODE      = 0xC00000B4

-- Named-pipe FSCTLs (NTIOAPI.H) — all routed via fs.NtFsControlFile.
-- Codes built from fs.ctl_code(device, fn, method, access).
local FILE_DEVICE_NAMED_PIPE = 0x00000011
local METHOD_BUFFERED        = 0
local METHOD_NEITHER         = 3
local FILE_ANY_ACCESS        = 0
M.FSCTL_PIPE_ASSIGN_EVENT = fs.ctl_code(FILE_DEVICE_NAMED_PIPE, 0, METHOD_BUFFERED, FILE_ANY_ACCESS)
M.FSCTL_PIPE_DISCONNECT   = fs.ctl_code(FILE_DEVICE_NAMED_PIPE, 1, METHOD_BUFFERED, FILE_ANY_ACCESS)
M.FSCTL_PIPE_LISTEN       = fs.ctl_code(FILE_DEVICE_NAMED_PIPE, 2, METHOD_BUFFERED, FILE_ANY_ACCESS)
M.FSCTL_PIPE_PEEK         = fs.ctl_code(FILE_DEVICE_NAMED_PIPE, 3, METHOD_BUFFERED, fs.FILE_READ_DATA)
M.FSCTL_PIPE_TRANSCEIVE   = fs.ctl_code(FILE_DEVICE_NAMED_PIPE, 5, METHOD_NEITHER,
                                        bit.bor(fs.FILE_READ_DATA, fs.FILE_WRITE_DATA))
M.FSCTL_PIPE_WAIT         = fs.ctl_code(FILE_DEVICE_NAMED_PIPE, 6, METHOD_BUFFERED, FILE_ANY_ACCESS)

-- ------------------------------------------------------------------
-- Endpoints — server creation and client open.
-- ------------------------------------------------------------------

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
        error("npfs.create_named_pipe: opts.name is required", 2)
    end
    local noa  = oa.path(opts.name)
    local h    = ffi.new('HANDLE[1]')
    local iosb = ffi.new('IO_STATUS_BLOCK')

    -- Relative (negative) timeout, in 100-ns ticks.
    local timeout = ffi.new('LARGE_INTEGER')
    timeout.QuadPart = -((opts.timeout or 5) * NT_TICKS_PER_SEC)

    local st = ntdll.NtCreateNamedPipeFile(
        h,
        opts.access      or bit.bor(fs.FILE_GENERIC_READ, fs.FILE_GENERIC_WRITE),
        noa.oa,
        iosb,
        opts.share       or bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        opts.disposition or fs.FILE_OPEN_IF,
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

-- open_pipe(name, opts) -> (handle, disposition).  Opens the CLIENT end
-- of an existing named pipe.  The open auto-connects to a listening
-- server instance (npfs CREATE.C) — no explicit listen/connect dance —
-- so the returned handle is immediately ready for read/write.  opts:
--   access       DesiredAccess  (default GENERIC_READ|WRITE, full duplex)
--   share        ShareAccess    (default SHARE_READ|WRITE)
--   disposition  CreateDisposition (default FILE_OPEN — the pipe exists)
--   options      CreateOptions  (default FILE_SYNCHRONOUS_IO_NONALERT, so
--                                reads block-until-data instead of pending)
-- Raises (NtCreateFile) on failure: STATUS_PIPE_NOT_AVAILABLE means no
-- server instance was listening; OBJECT_NAME_NOT_FOUND means no server
-- end exists at all.
function M.open_pipe(name, opts)
    opts = opts or {}
    local noa = oa.path(name)
    return fs.NtCreateFile(
        opts.access      or bit.bor(fs.FILE_GENERIC_READ, fs.FILE_GENERIC_WRITE),
        noa.oa, nil, fs.FILE_ATTRIBUTE_NORMAL,
        opts.share       or bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        opts.disposition or fs.FILE_OPEN,
        opts.options     or fs.FILE_SYNCHRONOUS_IO_NONALERT)
end

-- ------------------------------------------------------------------
-- Control operations — info query, mode change, peek, transceive,
-- disconnect, listen, wait, completion-event assignment.
-- ------------------------------------------------------------------

-- pipe_local_info(h) -> FILE_PIPE_LOCAL_INFORMATION cdata.  Reports the
-- connected end's NamedPipeState (M.FILE_PIPE_*_STATE), CurrentInstances,
-- ReadDataAvailable, NamedPipeEnd (M.FILE_PIPE_{CLIENT,SERVER}_END), etc.
function M.pipe_local_info(h)
    local info = ffi.new('FILE_PIPE_LOCAL_INFORMATION')
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local st = ntdll.NtQueryInformationFile(handle.raw(h), iosb, info,
        ffi.sizeof('FILE_PIPE_LOCAL_INFORMATION'), M.FilePipeLocalInformation)
    if err.is_error(st) then err.raise('NtQueryInformationFile', st) end
    return info
end

-- set_pipe_mode(h, opts) — change ReadMode / CompletionMode on one end
-- via FILE_PIPE_INFORMATION.  opts.read_mode / opts.completion_mode
-- default to byte-stream / queue.  Message read mode on a byte-stream
-- pipe -> STATUS_INVALID_PARAMETER; switching to COMPLETE_OPERATION while
-- the queue is non-empty -> STATUS_PIPE_BUSY.
function M.set_pipe_mode(h, opts)
    opts = opts or {}
    local info = ffi.new('FILE_PIPE_INFORMATION')
    info.ReadMode       = opts.read_mode       or M.FILE_PIPE_BYTE_STREAM_MODE
    info.CompletionMode = opts.completion_mode or M.FILE_PIPE_QUEUE_OPERATION
    fs.NtSetInformationFile(h, info, ffi.sizeof('FILE_PIPE_INFORMATION'),
                            M.FilePipeInformation)
end

-- pipe_peek(h, max_data) -> table.  FSCTL_PIPE_PEEK looks at queued data
-- WITHOUT consuming it.  max_data (default 256) bounds the data bytes
-- copied back.  Returns { state, available, messages, message_length,
-- data } where `data` is up to max_data bytes (a Lua string) and
-- `available` is the full ReadDataAvailable count (may exceed #data — the
-- kernel then returns STATUS_BUFFER_OVERFLOW, a warning, not an error).
function M.pipe_peek(h, max_data)
    max_data = max_data or 256
    local buf    = ffi.new('FILE_PIPE_PEEK_BUFFER', max_data)
    local header = ffi.offsetof('FILE_PIPE_PEEK_BUFFER', 'Data')
    local info   = fs.NtFsControlFile(h, M.FSCTL_PIPE_PEEK, nil, 0,
                                      buf, header + max_data)
    local ndata  = info > header and (info - header) or 0
    return {
        state          = buf.NamedPipeState,
        available      = buf.ReadDataAvailable,
        messages       = buf.NumberOfMessages,
        message_length = buf.MessageLength,
        data           = ndata > 0 and ffi.string(buf.Data, ndata) or "",
    }
end

-- pipe_transceive(h, input, out_len) -> response string.  FSCTL_PIPE_
-- TRANSCEIVE writes `input` to the pipe and reads the peer's reply in
-- one op.  REQUIRES a full-duplex, message-mode pipe with an empty read
-- queue on this end (else STATUS_PIPE_BUSY / STATUS_INVALID_READ_MODE).
-- It always pends until the peer writes a reply, so the peer must run on
-- a separate thread.  out_len bounds the reply (default 256).
function M.pipe_transceive(h, input, out_len)
    out_len = out_len or 256
    local out = ffi.new('char[?]', out_len)
    -- METHOD_NEITHER: input/output pass straight through as the raw user
    -- buffers (no kernel-side copy).
    local n = fs.NtFsControlFile(h, M.FSCTL_PIPE_TRANSCEIVE,
                                 input, #input, out, out_len)
    return ffi.string(out, n)
end

-- pipe_disconnect(h) — server-end FSCTL_PIPE_DISCONNECT.  Tears the
-- instance down to DISCONNECTED state; the client's next read/write then
-- fails with STATUS_PIPE_DISCONNECTED.  Re-listen with pipe_listen.
function M.pipe_disconnect(h)
    fs.NtFsControlFile(h, M.FSCTL_PIPE_DISCONNECT)
end

-- pipe_listen(h) — server-end FSCTL_PIPE_LISTEN.  BLOCKS until a client
-- connects (so call it from a thread that can wait, or after arranging a
-- client open on another thread).
function M.pipe_listen(h)
    fs.NtFsControlFile(h, M.FSCTL_PIPE_LISTEN)
end

-- pipe_wait(leaf_name, timeout_secs) -> true.  FSCTL_PIPE_WAIT against
-- the \Device\NamedPipe root DCB: blocks (up to timeout_secs) until a
-- server instance of `leaf_name` is listening.  `leaf_name` is the bare
-- pipe name with NO leading backslash (npfs prepends one) — e.g. "foo"
-- for \Device\NamedPipe\foo.  timeout_secs nil -> use the pipe's own
-- DefaultTimeout.  Raises STATUS_OBJECT_NAME_NOT_FOUND if no such pipe
-- exists, STATUS_IO_TIMEOUT if the wait expires.
--
-- The TRAILING backslash is load-bearing: opening "\Device\NamedPipe"
-- (no slash) lands on the file-system VCB, but FSCTL_PIPE_WAIT requires
-- the root DCB, which npfs gives only when the remaining name is "\"
-- (npfs CREATE.C) — otherwise STATUS_ILLEGAL_FUNCTION.
function M.pipe_wait(leaf_name, timeout_secs)
    local root_oa = oa.path("\\Device\\NamedPipe\\")
    local root = fs.NtOpenFile(
        bit.bor(fs.FILE_GENERIC_READ, fs.SYNCHRONIZE),
        root_oa.oa,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        fs.FILE_SYNCHRONOUS_IO_NONALERT)
    local wchars = str.decode_utf8(leaf_name)
    local n   = #wchars
    local wb  = ffi.sizeof('wchar_t')
    local buf = ffi.new('FILE_PIPE_WAIT_FOR_BUFFER', n)
    buf.NameLength       = n * wb
    buf.TimeoutSpecified = timeout_secs and 1 or 0
    if timeout_secs then
        buf.Timeout.QuadPart = -(timeout_secs * NT_TICKS_PER_SEC)
    end
    for i = 1, n do buf.Name[i-1] = wchars[i] end
    local size = ffi.offsetof('FILE_PIPE_WAIT_FOR_BUFFER', 'Name') + n * wb
    -- Close the root handle whether the FSCTL raised or not.
    local ok, info = pcall(fs.NtFsControlFile, root, M.FSCTL_PIPE_WAIT,
                           buf, size, nil, 0)
    root:close()
    if not ok then error(info, 0) end
    return true
end

-- pipe_assign_event(h, event, key) — FSCTL_PIPE_ASSIGN_EVENT.
-- Registers `event` (an NT_HANDLE for an event object, e.g.
-- ke.event():handle()) with this end of the pipe.  npfs signals the
-- event whenever the OTHER end does I/O (a write/read/state change), so
-- a waiter can block on the event instead of on a pending read.  Pass
-- event = nil to clear a previously-assigned event (npfs deletes the
-- table entry).  `key` is an opaque value echoed by FSCTL_PIPE_QUERY_EVENT
-- (default 0).
function M.pipe_assign_event(h, event, key)
    local buf = ffi.new('FILE_PIPE_ASSIGN_EVENT_BUFFER')
    -- handle.raw enforces NT_HANDLE; nil -> NULL handle = clear.
    buf.EventHandle = event and handle.raw(event) or nil
    buf.KeyValue    = key or 0
    fs.NtFsControlFile(h, M.FSCTL_PIPE_ASSIGN_EVENT,
                       buf, ffi.sizeof('FILE_PIPE_ASSIGN_EVENT_BUFFER'))
end

return M
