-- test.fuzz.lpc — adversarial edge-case tests for the LPC syscall
-- surface (NTOS/LPC, reachable from usermode via the Nt*Port calls).
--
-- Part of the bugcheck-resistance goal: LPC runs inside ntoskrnl and is
-- reachable straight from usermode — a malformed Nt*Port call that
-- faults the kernel is a kernel bug. Invariant: every call returns a
-- clean NTSTATUS and never bugchecks; survival of the in-process runner
-- to t.summary() is itself the assertion.
--
-- Raw-ntdll surface (cf. test/fuzz/se.lua, iocp.lua, npfs.lua). The
-- idiomatic round-trip lives in test/lpc.lua.
--
-- BLOCKING HAZARD — five LPC syscalls block with NO timeout on NT 3.5:
-- NtListenPort, NtConnectPort, NtRequestWaitReplyPort,
-- NtReplyWaitReceivePort, NtReplyWaitReplyPort. A blocked call here
-- would hang the whole selftest. So every case against those keeps a
-- param the kernel validates BEFORE the wait (the handle, or a probed
-- pointer) corrupted — there is deliberately no all-valid case.

local ffi    = require('ffi')
local t      = require('test')
local ntdll  = require('nt.dll')
local lpc    = require('nt.dll.lpc')      -- registers the LPC cdefs + helpers
local oa     = require('nt.dll.oa')
local str    = require('nt.dll.str')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

local STATUS_SUCCESS = 0x00000000

local function hex(st) return string.format("0x%08x", st) end

t.suite("lpc: hardening (raw LPC syscalls)")

-- Out-of-range pointers — rejected by every probe / handle-ref path.
local OOR = {
    { name = "NULL",         make = function(ct) return ffi.cast(ct, 0) end },
    { name = "kernel-range", make = function(ct) return ffi.cast(ct, 0x80000000) end },
}

-- Bad handle values. NULL and a never-allocated garbage value both
-- fail ObReferenceObjectByHandle before any port logic runs.
local BAD_HANDLES = {
    { name = "NULL",    h = ffi.cast('HANDLE', 0) },
    { name = "garbage", h = ffi.cast('HANDLE', 0xCCCCCCCC) },
}

-- A real connection port — a valid handle for cases that fuzz some
-- *other* parameter. Kept alive for the whole suite. Never the target
-- of a blocking call with otherwise-valid arguments.
local vport  = lpc.NtCreatePort(oa.path("\\MicroNTLpcFz").oa)
local VPORT  = handle.raw(vport)

-- Assert a malformed call was rejected cleanly (and, implicitly, did
-- not bugcheck — we reached this line).
local function rejects(label, st)
    t.ne(st, STATUS_SUCCESS, label .. " must not succeed")
    t.ok(st >= 0x80000000,
         label .. " — expected an error NTSTATUS, got " .. hex(st))
end

-- ------------------------------------------------------------------
-- NtCreatePort — named connection port creation.
-- ------------------------------------------------------------------

for _, bad in ipairs(OOR) do
    t.test("NtCreatePort rejects PortHandle = " .. bad.name .. " pointer", function()
        local noa = oa.path("\\MicroNTLpcFzC")
        local st  = err.normalize(ntdll.NtCreatePort(
            bad.make('HANDLE *'), noa.oa, 0, 256, 0))
        rejects("NtCreatePort/bad-handle", st)
    end)

    t.test("NtCreatePort rejects ObjectAttributes = " .. bad.name .. " pointer", function()
        local h  = ffi.new('HANDLE[1]')
        local st = err.normalize(ntdll.NtCreatePort(
            h, bad.make('OBJECT_ATTRIBUTES *'), 0, 256, 0))
        rejects("NtCreatePort/bad-oa", st)
    end)
end

t.test("NtCreatePort survives extreme length parameters", function()
    -- MaxConnectionInfoLength / MaxMessageLength / MaxPoolUsage all
    -- saturated — must be capped or rejected, never bugcheck.
    local h   = ffi.new('HANDLE[1]')
    local noa = oa.path("\\MicroNTLpcFzX")
    local st  = err.normalize(ntdll.NtCreatePort(
        h, noa.oa, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF))
    t.ne(st, nil, "returned a clean NTSTATUS (" .. hex(st) .. "), no bugcheck")
    if st == STATUS_SUCCESS then
        require('nt.dll.handle')   -- NtClose cdef
        ntdll.NtClose(h[0])
    end
end)

-- ------------------------------------------------------------------
-- (HANDLE, PORT_MESSAGE *) family — bad handle, and bad message
-- pointer against the valid connection port. Both fail before any
-- blocking wait (handle-ref / probe run first).
-- ------------------------------------------------------------------

local MSG_SYSCALLS = {
    "NtListenPort", "NtReplyPort", "NtReplyWaitReplyPort",
    "NtImpersonateClientOfPort",
}

for _, name in ipairs(MSG_SYSCALLS) do
    for _, bh in ipairs(BAD_HANDLES) do
        t.test(name .. " rejects a " .. bh.name .. " handle", function()
            local msg = lpc.new_message(64)
            lpc.init_message(msg, 64, 0)
            local st = err.normalize(ntdll[name](
                bh.h, ffi.cast('PORT_MESSAGE *', msg)))
            rejects(name .. "/bad-handle", st)
        end)
    end
    for _, bad in ipairs(OOR) do
        t.test(name .. " rejects a " .. bad.name .. " message pointer", function()
            local st = err.normalize(ntdll[name](
                VPORT, bad.make('PORT_MESSAGE *')))
            rejects(name .. "/bad-message", st)
        end)
    end
end

-- ------------------------------------------------------------------
-- NtReplyWaitReceivePort — (HANDLE, void **ctx, PORT_MESSAGE *reply,
-- PORT_MESSAGE *receive). Blocking: only bad-handle / bad-receive
-- cases, never a valid call (would block on the empty port forever).
-- ------------------------------------------------------------------

for _, bh in ipairs(BAD_HANDLES) do
    t.test("NtReplyWaitReceivePort rejects a " .. bh.name .. " handle", function()
        local recv = lpc.new_message(64)
        local st = err.normalize(ntdll.NtReplyWaitReceivePort(
            bh.h, nil, nil, ffi.cast('PORT_MESSAGE *', recv)))
        rejects("NtReplyWaitReceivePort/bad-handle", st)
    end)
end

for _, bad in ipairs(OOR) do
    t.test("NtReplyWaitReceivePort rejects a " .. bad.name .. " receive buffer", function()
        local st = err.normalize(ntdll.NtReplyWaitReceivePort(
            VPORT, nil, nil, bad.make('PORT_MESSAGE *')))
        rejects("NtReplyWaitReceivePort/bad-receive", st)
    end)
end

-- ------------------------------------------------------------------
-- NtRequestWaitReplyPort — (HANDLE, request, reply). Blocking: a
-- valid request to a real port would send and block for a reply, so
-- every case keeps the handle or a probed message pointer bad.
-- ------------------------------------------------------------------

for _, bh in ipairs(BAD_HANDLES) do
    t.test("NtRequestWaitReplyPort rejects a " .. bh.name .. " handle", function()
        local req   = lpc.new_message(64); lpc.init_message(req, 64, 0)
        local reply = lpc.new_message(64)
        local st = err.normalize(ntdll.NtRequestWaitReplyPort(
            bh.h, ffi.cast('PORT_MESSAGE *', req),
                  ffi.cast('PORT_MESSAGE *', reply)))
        rejects("NtRequestWaitReplyPort/bad-handle", st)
    end)
end

for _, bad in ipairs(OOR) do
    t.test("NtRequestWaitReplyPort rejects a " .. bad.name .. " request pointer", function()
        local reply = lpc.new_message(64)
        local st = err.normalize(ntdll.NtRequestWaitReplyPort(
            VPORT, bad.make('PORT_MESSAGE *'),
                   ffi.cast('PORT_MESSAGE *', reply)))
        rejects("NtRequestWaitReplyPort/bad-request", st)
    end)

    t.test("NtRequestWaitReplyPort rejects a " .. bad.name .. " reply pointer", function()
        local req = lpc.new_message(64); lpc.init_message(req, 64, 0)
        local st = err.normalize(ntdll.NtRequestWaitReplyPort(
            VPORT, ffi.cast('PORT_MESSAGE *', req),
                   bad.make('PORT_MESSAGE *')))
        rejects("NtRequestWaitReplyPort/bad-reply", st)
    end)
end

-- ------------------------------------------------------------------
-- NtRequestPort — fire-and-forget datagram; never blocks. The vehicle
-- for malformed-PORT_MESSAGE fuzzing: a corrupt header against a valid
-- handle must be validated and rejected, not faulted.
-- ------------------------------------------------------------------

for _, bh in ipairs(BAD_HANDLES) do
    t.test("NtRequestPort rejects a " .. bh.name .. " handle", function()
        local msg = lpc.new_message(64); lpc.init_message(msg, 64, 0)
        local st = err.normalize(ntdll.NtRequestPort(
            bh.h, ffi.cast('PORT_MESSAGE *', msg)))
        rejects("NtRequestPort/bad-handle", st)
    end)
end

-- Malformed PORT_MESSAGE headers. DataLength / TotalLength are signed
-- shorts — negatives and oversizes must all be caught.
local BAD_MESSAGES = {
    { name = "TotalLength saturated",  apply = function(m) m.hdr.u1.s1.TotalLength = 0x7FFF end },
    { name = "TotalLength negative",   apply = function(m) m.hdr.u1.s1.TotalLength = -1 end },
    { name = "DataLength > TotalLength", apply = function(m) m.hdr.u1.s1.DataLength = 0x7FFF end },
    { name = "DataLength negative",    apply = function(m) m.hdr.u1.s1.DataLength = -1 end },
    { name = "Type garbage",           apply = function(m) m.hdr.u2.s2.Type = 0x7FFF end },
    { name = "DataInfoOffset garbage", apply = function(m) m.hdr.u2.s2.DataInfoOffset = 0x7FFF end },
}

for _, bm in ipairs(BAD_MESSAGES) do
    t.test("NtRequestPort rejects PORT_MESSAGE with " .. bm.name, function()
        local msg = lpc.new_message(64)
        lpc.init_message(msg, 64, 0)
        bm.apply(msg)
        local st = err.normalize(ntdll.NtRequestPort(
            VPORT, ffi.cast('PORT_MESSAGE *', msg)))
        -- Reaching here = no bugcheck. The kernel may reject with any
        -- error; a malformed message must never be accepted as valid.
        t.ne(st, STATUS_SUCCESS,
             "malformed message must not succeed (got " .. hex(st) .. ")")
    end)
end

-- ------------------------------------------------------------------
-- NtConnectPort — client connect. Blocking once a real port is found,
-- so cases use bad pointers or a nonexistent name (name lookup fails
-- before any connect/block).
-- ------------------------------------------------------------------

for _, bad in ipairs(OOR) do
    t.test("NtConnectPort rejects PortHandle = " .. bad.name .. " pointer", function()
        local name = str.to_utf16("\\NoSuchLpcPortXYZ")
        local qos  = lpc.default_qos()
        local st = err.normalize(ntdll.NtConnectPort(
            bad.make('HANDLE *'), name.us, qos,
            nil, nil, nil, nil, nil))
        rejects("NtConnectPort/bad-handle", st)
    end)

    t.test("NtConnectPort rejects PortName = " .. bad.name .. " pointer", function()
        local h   = ffi.new('HANDLE[1]')
        local qos = lpc.default_qos()
        local st = err.normalize(ntdll.NtConnectPort(
            h, bad.make('UNICODE_STRING *'), qos,
            nil, nil, nil, nil, nil))
        rejects("NtConnectPort/bad-name", st)
    end)
end

t.test("NtConnectPort rejects a nonexistent port name", function()
    local h    = ffi.new('HANDLE[1]')
    local name = str.to_utf16("\\NoSuchLpcPortZZZ")
    local qos  = lpc.default_qos()
    local st = err.normalize(ntdll.NtConnectPort(
        h, name.us, qos, nil, nil, nil, nil, nil))
    rejects("NtConnectPort/nonexistent-name", st)
end)

-- ------------------------------------------------------------------
-- NtAcceptConnectPort — (HANDLE *out, ctx, PORT_MESSAGE *connreq,
-- accept, views). Non-blocking. Fuzz the out-handle and the
-- connection-request message pointer.
-- ------------------------------------------------------------------

for _, bad in ipairs(OOR) do
    t.test("NtAcceptConnectPort rejects PortHandle = " .. bad.name .. " pointer", function()
        local connreq = lpc.new_message(64)
        local st = err.normalize(ntdll.NtAcceptConnectPort(
            bad.make('HANDLE *'), nil,
            ffi.cast('PORT_MESSAGE *', connreq), 1, nil, nil))
        rejects("NtAcceptConnectPort/bad-handle", st)
    end)

    t.test("NtAcceptConnectPort rejects ConnectionRequest = " .. bad.name .. " pointer", function()
        local h = ffi.new('HANDLE[1]')
        local st = err.normalize(ntdll.NtAcceptConnectPort(
            h, nil, bad.make('PORT_MESSAGE *'), 1, nil, nil))
        rejects("NtAcceptConnectPort/bad-connreq", st)
    end)
end

-- ------------------------------------------------------------------
-- NtCompleteConnectPort — (HANDLE). Non-blocking; only a handle to fuzz.
-- ------------------------------------------------------------------

for _, bh in ipairs(BAD_HANDLES) do
    t.test("NtCompleteConnectPort rejects a " .. bh.name .. " handle", function()
        local st = err.normalize(ntdll.NtCompleteConnectPort(bh.h))
        rejects("NtCompleteConnectPort/bad-handle", st)
    end)
end

-- ------------------------------------------------------------------
-- NtReadRequestData / NtWriteRequestData — (HANDLE, msg, index, buf,
-- size, *out). Non-blocking. Fuzz handle, message pointer, and an
-- extreme data-entry index.
-- ------------------------------------------------------------------

for _, name in ipairs({ "NtReadRequestData", "NtWriteRequestData" }) do
    for _, bh in ipairs(BAD_HANDLES) do
        t.test(name .. " rejects a " .. bh.name .. " handle", function()
            local msg = lpc.new_message(64); lpc.init_message(msg, 64, 0)
            local buf = ffi.new('unsigned char[64]')
            local ret = ffi.new('ULONG[1]')
            local st = err.normalize(ntdll[name](
                bh.h, ffi.cast('PORT_MESSAGE *', msg), 0, buf, 64, ret))
            rejects(name .. "/bad-handle", st)
        end)
    end

    t.test(name .. " rejects a saturated DataEntryIndex", function()
        local msg = lpc.new_message(64); lpc.init_message(msg, 64, 0)
        local buf = ffi.new('unsigned char[64]')
        local ret = ffi.new('ULONG[1]')
        local st = err.normalize(ntdll[name](
            VPORT, ffi.cast('PORT_MESSAGE *', msg), 0xFFFFFFFF, buf, 64, ret))
        t.ne(st, STATUS_SUCCESS,
             name .. "/huge-index must not succeed (got " .. hex(st) .. ")")
    end)
end

-- ------------------------------------------------------------------
-- NtQueryInformationPort — (HANDLE, class, buf, len, *ret).
-- ------------------------------------------------------------------

for _, bh in ipairs(BAD_HANDLES) do
    t.test("NtQueryInformationPort rejects a " .. bh.name .. " handle", function()
        local buf = ffi.new('unsigned char[64]')
        local ret = ffi.new('ULONG[1]')
        local st = err.normalize(ntdll.NtQueryInformationPort(
            bh.h, 0, buf, 64, ret))
        rejects("NtQueryInformationPort/bad-handle", st)
    end)
end

for _, bad in ipairs(OOR) do
    t.test("NtQueryInformationPort rejects Information = " .. bad.name .. " pointer", function()
        local ret = ffi.new('ULONG[1]')
        local st = err.normalize(ntdll.NtQueryInformationPort(
            VPORT, 0, bad.make('void *'), 64, ret))
        rejects("NtQueryInformationPort/bad-buffer", st)
    end)
end

t.test("NtQueryInformationPort rejects a garbage info class", function()
    local buf = ffi.new('unsigned char[64]')
    local ret = ffi.new('ULONG[1]')
    local st = err.normalize(ntdll.NtQueryInformationPort(
        VPORT, 0x7FFFFFFF, buf, 64, ret))
    t.ne(st, STATUS_SUCCESS,
         "garbage info class must not succeed (got " .. hex(st) .. ")")
end)
