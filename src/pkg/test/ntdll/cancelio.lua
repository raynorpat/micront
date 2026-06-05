-- test.ntdll.cancelio — NtCancelIoFileEx: cancel a single pending async request
-- by its issuing IO_STATUS_BLOCK (backs Win32 CancelIoEx and mio's poll cancel).
-- Maps to NTOS/IO/MISC.C.
--
-- A cancellable pending IRP is manufactured with a raw async recv on a
-- connected loopback socket that has no data waiting: it stays STATUS_PENDING
-- on the calling thread until we cancel it. nt.net.afd just supplies the
-- socket pair; the NtCancelIoFileEx syscall is what's under test.

local t      = require('test')
local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local fs     = require('nt.dll.fs')        -- registers NtCancelIoFileEx + NtReadFile
local afd    = require('nt.net.afd')        -- connected-pair fixture
local handle = require('nt.dll.handle')
local err    = require('nt.dll.errors')

t.suite("cancelio (NtCancelIoFileEx)")

local STATUS_SUCCESS        = 0x00000000
local STATUS_PENDING        = 0x00000103
local STATUS_CANCELLED      = 0xC0000120
local STATUS_INVALID_HANDLE = 0xC0000008
local STATUS_NOT_FOUND      = 0xC0000225

-- A connected loopback TCP pair; returns the accepted server-side socket (which
-- we issue the pending recv on). All sockets are deferred-closed.
local function connected_peer()
    local listener = afd.tcp(); t.defer(function() listener:close() end)
    afd.bind(listener, "127.0.0.1", 0)
    afd.listen(listener, 1)
    local _, port = afd.getsockname(listener)

    local client = afd.tcp(); t.defer(function() client:close() end)
    afd.bind(client, "127.0.0.1", 0)
    afd.connect(client, "127.0.0.1", port, 2.0)

    local peer = afd.accept(listener, 2.0); t.defer(function() peer:close() end)
    return peer
end

-- Issue a raw async recv that pends (no data, blocking socket). The iosb/buf
-- must outlive the I/O, so return them. ApcContext is NULL: the IRP simply
-- pends on this thread's pending-I/O list, which is what NtCancelIoFileEx walks.
local function pending_recv(sock)
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local buf  = ffi.new('char[16]')
    local off  = ffi.new('LARGE_INTEGER')   -- non-NULL ByteOffset (async-handle probe)
    local st = err.normalize(ntdll.NtReadFile(
        handle.raw(sock), nil, nil, nil, iosb, buf, 16, off, nil))
    return iosb, buf, st
end

t.test("cancels a specific pending read by its IOSB", function()
    local peer = connected_peer()
    local iosb, _buf, st = pending_recv(peer)
    t.eq(st, STATUS_PENDING, "recv with no data pends")

    local out = ffi.new('IO_STATUS_BLOCK')
    local cst = err.normalize(ntdll.NtCancelIoFileEx(handle.raw(peer), iosb, out))
    t.eq(cst, STATUS_SUCCESS, "the matching pending read was cancelled")
    t.eq(err.normalize(iosb.Status), STATUS_CANCELLED, "read completed STATUS_CANCELLED")
end)

t.test("NULL IoRequestToCancel cancels all the caller's pending reads", function()
    local peer = connected_peer()
    local iosb, _buf, st = pending_recv(peer)
    t.eq(st, STATUS_PENDING)

    local out = ffi.new('IO_STATUS_BLOCK')
    local cst = err.normalize(ntdll.NtCancelIoFileEx(handle.raw(peer), nil, out))
    t.eq(cst, STATUS_SUCCESS, "cancel-all found the pending read")
    t.eq(err.normalize(iosb.Status), STATUS_CANCELLED)
end)

t.test("returns STATUS_NOT_FOUND when no request matches the IOSB", function()
    local peer  = connected_peer()
    local bogus = ffi.new('IO_STATUS_BLOCK')   -- no in-flight IRP carries this
    local out   = ffi.new('IO_STATUS_BLOCK')
    t.eq(err.normalize(ntdll.NtCancelIoFileEx(handle.raw(peer), bogus, out)),
         STATUS_NOT_FOUND, "no matching IRP -> NOT_FOUND")
end)

-- ------------------------------------------------------------------
-- Adversarial
-- ------------------------------------------------------------------

t.test("rejects a NULL handle", function()
    local out = ffi.new('IO_STATUS_BLOCK')
    t.eq(err.normalize(ntdll.NtCancelIoFileEx(ffi.cast('HANDLE', 0), nil, out)),
         STATUS_INVALID_HANDLE)
end)

t.test("rejects a kernel-range IoStatusBlock OUT pointer", function()
    local peer = connected_peer()
    local st = err.normalize(ntdll.NtCancelIoFileEx(
        handle.raw(peer), nil, ffi.cast('IO_STATUS_BLOCK *', 0x80000000)))
    t.ok(st >= 0xC0000000,
         "kernel-range OUT pointer rejected, got " .. string.format("0x%08x", st))
end)
