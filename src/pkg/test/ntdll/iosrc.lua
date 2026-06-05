-- test.iosrc — an IOCP completion source for tests.
--
-- Manufactures *IRP-backed* completions deterministically by issuing async
-- reads on a scratch file associated with the port (the file-association
-- path -- as opposed to packets posted directly via NtSetIoCompletion).
--
-- Mechanism (kernel side, confirmed against NTOS/IO):
--   * NtSetInformationFile / FileCompletionInformation binds the file
--     object to the port plus a ULONG key. The key is fixed once, at
--     association time (re-association is rejected).
--   * On completion, IopCompleteRequest queues a packet to the port
--     iff the read carried a non-NULL ApcContext (INTERNAL.C:998).
--   * NtRemoveIoCompletion then yields KeyContext = the association
--     key, ApcContext = the read's ApcContext cookie, IoStatusBlock =
--     the read result (Status + Information).
--
-- This helper is shared by test/sync.lua (idiomatic round-trip tests)
-- and test/fuzz/iocp.lua. It uses raw ntdll.NtReadFile because the
-- idiomatic fs.NtReadFile wrapper is synchronous and exposes no
-- ApcContext — and a non-NULL ApcContext is exactly what makes the
-- completion queue.

local ffi    = require('ffi')
local bit    = require('bit')
local ntdll  = require('nt.dll')
local fs     = require('nt.dll.fs')
local oa     = require('nt.dll.oa')
local handle = require('nt.dll.handle')
local err    = require('nt.dll.errors')

local M = {}

-- Known payload written into every scratch file. A completion's
-- IoStatusBlock.Information equals the byte count read back — callers
-- assert against PAYLOAD_LEN.
local PAYLOAD = "iocp-completion-source-payload"
M.PAYLOAD_LEN = #PAYLOAD

-- Per-run counter so repeated sources never collide on a path. The
-- file name stem stays 8.3-safe: "iocp" + 4 hex digits.
local counter = 0
local function fresh_path()
    counter = counter + 1
    return string.format("\\SystemRoot\\iocp%04x.tmp", bit.band(counter, 0xffff))
end

local Source = {}
Source.__index = Source

-- new(port, key) — build a completion source bound to `port` (an
-- io.iocompletion object) carrying association key `key` (default 0).
--
-- Creates the scratch file and writes PAYLOAD through a synchronous
-- handle (which is never associated, so it produces no completions),
-- then opens a separate ASYNCHRONOUS handle, associates it with the
-- port, and keeps it open as the I/O source. The async handle holds
-- FILE_DELETE_ON_CLOSE, so close() removes the scratch file.
function M.new(port, key)
    local path = fresh_path()

    -- 1. Create + populate the scratch file synchronously.
    local wh = fs.NtCreateFile(
        bit.bor(fs.FILE_GENERIC_WRITE, fs.SYNCHRONIZE),
        oa.path(path).oa,
        nil, fs.FILE_ATTRIBUTE_NORMAL,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        fs.FILE_OVERWRITE_IF,
        bit.bor(fs.FILE_NON_DIRECTORY_FILE, fs.FILE_SYNCHRONOUS_IO_NONALERT),
        nil, 0)
    fs.NtWriteFile(wh, PAYLOAD, #PAYLOAD, nil)
    wh:close()

    -- 2. Re-open ASYNCHRONOUS (no FILE_SYNCHRONOUS_IO_* option, so the
    --    file object is not FO_SYNCHRONOUS_IO — the association below
    --    would otherwise be rejected). FILE_DELETE_ON_CLOSE ties the
    --    file's lifetime to this handle. FILE_READ_DATA is all the
    --    access needed: for the reads here, and (post-P13 fix) for the
    --    FileCompletionInformation association in step 3.
    local ah = fs.NtOpenFile(
        bit.bor(fs.FILE_READ_DATA, fs.DELETE),
        oa.path(path).oa,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        bit.bor(fs.FILE_NON_DIRECTORY_FILE, fs.FILE_DELETE_ON_CLOSE))

    -- 3. Associate the async handle with the port.
    fs.set_completion_port(ah, port:handle(), key or 0)

    return setmetatable({
        _ah       = ah,
        _path     = path,
        _key      = key or 0,
        _inflight = {},      -- keeps per-read buf/iosb/offset cdata alive
    }, Source)
end

-- emit(apc) — issue one async read that completes, queuing exactly one
-- packet on the port. `apc` is the ApcContext cookie (a non-zero
-- integer) echoed back by NtRemoveIoCompletion; it MUST be non-NULL or
-- the kernel frees the IRP without queuing a packet.
function Source:emit(apc)
    assert(apc and apc ~= 0, "iosrc: emit() needs a non-NULL ApcContext cookie")

    -- Each outstanding read owns its own buffer / IOSB / offset; the
    -- kernel writes them on completion, so they must outlive the I/O.
    local io = {
        buf  = ffi.new('char[?]', M.PAYLOAD_LEN),
        iosb = ffi.new('IO_STATUS_BLOCK'),
        off  = ffi.new('LARGE_INTEGER'),
    }
    io.off.QuadPart = 0
    self._inflight[#self._inflight + 1] = io

    local st = err.normalize(ntdll.NtReadFile(
        handle.raw(self._ah),
        nil,                          -- Event
        nil,                          -- ApcRoutine — must be NULL for IOCP
        ffi.cast('void *', apc),      -- ApcContext — non-NULL → packet queues
        io.iosb,
        io.buf, M.PAYLOAD_LEN,
        io.off,                       -- explicit ByteOffset (async handle)
        nil))                         -- Key
    -- STATUS_SUCCESS (synchronous completion) and STATUS_PENDING are
    -- both expected; only a hard error is a problem.
    if err.is_error(st) then err.raise('NtReadFile', st) end
    return st
end

-- close() — drop the async handle; FILE_DELETE_ON_CLOSE removes the
-- scratch file. Drain all emitted completions before calling this.
function Source:close()
    if self._ah then
        self._ah:close()
        self._ah = nil
    end
    self._inflight = {}
end

M.Source = Source

return M
