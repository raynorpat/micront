-- test.fuzz.npfs — adversarial edge-case tests for the named-pipe file
-- system (npfs) create surface.
--
-- Phase 4 of test/fuzz/iocp-plan.md, and the first slice of a broader
-- goal: prove usermode cannot bugcheck the kernel. npfs.sys is a
-- fully-privileged kernel driver reachable straight from usermode via
-- NtCreateNamedPipeFile — a malformed call that faults npfs is a
-- kernel bug in the same class as the IOCP findings.
--
-- Raw-ntdll surface (cf. test/fuzz/se.lua, test/fuzz/iocp.lua): hands
-- NtCreateNamedPipeFile deliberately malformed pointers and
-- out-of-range parameters. Invariant: every call returns a clean
-- NTSTATUS and never bugchecks — survival of the in-process runner to
-- t.summary() is itself the assertion.
--
-- Scope: NtCreateNamedPipeFile, the server-create syscall. Client
-- opens (NtCreateFile on \Device\NamedPipe\...) and the pipe FSCTLs
-- are a later increment — every further test deepens the picture.

local bit   = require('bit')
local ffi   = require('ffi')
local t     = require('test')
local ntdll = require('nt.dll')
local fs    = require('nt.dll.fs')      -- registers the NtCreateNamedPipeFile cdef
local oa    = require('nt.dll.oa')
local ke    = require('nt.dll.ke')
local err   = require('nt.dll.errors')
require('nt.dll.handle')                -- registers NtClose

local STATUS_SUCCESS = 0x00000000

local function hex(st) return string.format("0x%08x", st) end

t.suite("npfs: hardening (raw NtCreateNamedPipeFile)")

-- Sane defaults for a named-pipe server end.
local DEFAULT_ACCESS  = bit.bor(fs.FILE_GENERIC_READ, fs.FILE_GENERIC_WRITE)
local SHARE           = bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE)
local FILE_OPEN_IF    = 3
-- A first pipe instance needs a default timeout (used by FSCTL_PIPE_WAIT
-- when no explicit timeout is given). Relative 500 ms — built once.
local DEFAULT_TIMEOUT = ke.timeout(0.5)

-- Fresh \Device\NamedPipe path per call — a unique name keeps repeated
-- creates from colliding on an existing instance. The returned wrapper
-- owns the name buffer; the caller must hold it across the syscall.
local namecount = 0
local function pipe_name()
    namecount = namecount + 1
    return "\\Device\\NamedPipe\\fuzznp" .. namecount
end
local function pipe_oa()
    return oa.path(pipe_name())
end

-- Call NtCreateNamedPipeFile. `p` overrides any field; anything absent
-- uses a sane default. Returns the normalised NTSTATUS; if the create
-- succeeded and we owned the handle slot, the handle is closed (which
-- tears the pipe instance down).
local function create(p)
    p = p or {}
    local own_h = (p.FileHandle == nil)
    local h     = p.FileHandle    or ffi.new('HANDLE[1]')
    local iosb  = p.IoStatusBlock or ffi.new('IO_STATUS_BLOCK')
    local st = err.normalize(ntdll.NtCreateNamedPipeFile(
        h,
        p.DesiredAccess     or DEFAULT_ACCESS,
        p.ObjectAttributes,                       -- nil → NULL
        iosb,
        p.ShareAccess       or SHARE,
        p.CreateDisposition or FILE_OPEN_IF,
        p.CreateOptions     or 0,
        p.NamedPipeType     or 0,                 -- 0 = byte stream
        p.ReadMode          or 0,                 -- 0 = byte mode
        p.CompletionMode    or 0,                 -- 0 = queue (blocking)
        p.MaximumInstances  or 1,
        p.InboundQuota      or 4096,
        p.OutboundQuota     or 4096,
        p.DefaultTimeout    or DEFAULT_TIMEOUT))
    if st == STATUS_SUCCESS and own_h then
        ntdll.NtClose(h[0])
    end
    return st
end

-- Reaching this line means no bugcheck. npfs may accept the value (the
-- handle is closed by create()) or reject it — both are fine; the
-- security invariant under test is only that the kernel did not crash.
local function survived(label, st)
    t.ok(true, label .. " → " .. hex(st) .. " (clean NTSTATUS, no bugcheck)")
end

-- ------------------------------------------------------------------
-- Baseline — a sane create must succeed, so the fuzz below is known to
-- actually reach npfs rather than failing in front of it.
-- ------------------------------------------------------------------

t.test("a valid named pipe creates and closes cleanly", function()
    -- The valid-path baseline goes through the idiomatic wrapper; the
    -- adversarial cases below drop to raw ntdll. (Same split as
    -- test/fuzz/se.lua — idiomatic setup, raw fuzzed syscall.)
    local h = fs.create_named_pipe{ name = pipe_name() }
    t.ok(h ~= nil, "fs.create_named_pipe returned a handle")
    h:close()
end)

-- ------------------------------------------------------------------
-- Output-pointer faults — IoCreateFile probes FileHandle and
-- IoStatusBlock for write before reaching npfs. A bad pointer must be
-- surfaced as the service status, not dereferenced.
-- ------------------------------------------------------------------

local OOR = {
    { name = "NULL",         make = function(ct) return ffi.cast(ct, 0) end },
    { name = "kernel-range", make = function(ct) return ffi.cast(ct, 0x80000000) end },
}

for _, bad in ipairs(OOR) do
    t.test("rejects FileHandle = " .. bad.name .. " pointer", function()
        local noa = pipe_oa()
        local st  = create{ FileHandle = bad.make('HANDLE *'),
                            ObjectAttributes = noa.oa }
        t.ne(st, STATUS_SUCCESS, "bad FileHandle must not succeed")
        t.ok(st >= 0xC0000000, "expected an error NTSTATUS, got " .. hex(st))
    end)

    t.test("rejects IoStatusBlock = " .. bad.name .. " pointer", function()
        local noa = pipe_oa()
        local st  = create{ IoStatusBlock = bad.make('IO_STATUS_BLOCK *'),
                            ObjectAttributes = noa.oa }
        t.ne(st, STATUS_SUCCESS, "bad IoStatusBlock must not succeed")
        t.ok(st >= 0xC0000000, "expected an error NTSTATUS, got " .. hex(st))
    end)
end

-- ------------------------------------------------------------------
-- DefaultTimeout fault — the syscall itself (CREATE.C:220) probes the
-- optional DefaultTimeout for read. NULL is valid (= not specified); a
-- non-NULL bad pointer must fault cleanly.
-- ------------------------------------------------------------------

local dt_pad = ffi.new('char[64]')
local DT_BAD = {
    { name = "kernel-range",
      ptr  = ffi.cast('LARGE_INTEGER *', 0x80000000) },
    { name = "unaligned",
      ptr  = ffi.cast('LARGE_INTEGER *', ffi.cast('char *', dt_pad) + 1) },
}

for _, bad in ipairs(DT_BAD) do
    t.test("rejects DefaultTimeout = " .. bad.name .. " pointer", function()
        local noa = pipe_oa()
        local st  = create{ ObjectAttributes = noa.oa, DefaultTimeout = bad.ptr }
        t.ne(st, STATUS_SUCCESS, "bad DefaultTimeout must not succeed")
        t.ok(st >= 0x80000000, "expected a probe rejection, got " .. hex(st))
    end)
end

-- ------------------------------------------------------------------
-- ObjectAttributes / pipe name.
-- ------------------------------------------------------------------

t.test("rejects a NULL ObjectAttributes", function()
    local st = create{}                       -- no ObjectAttributes → NULL
    t.ne(st, STATUS_SUCCESS, "NULL OA must not succeed")
    t.ok(st >= 0xC0000000, "expected an error NTSTATUS, got " .. hex(st))
end)

t.test("rejects an empty pipe name (device root, no pipe component)", function()
    local noa = oa.path("\\Device\\NamedPipe")
    local st  = create{ ObjectAttributes = noa.oa }
    t.ne(st, STATUS_SUCCESS, "device root with no pipe name must not succeed")
    t.ok(st >= 0x80000000, "expected an error NTSTATUS, got " .. hex(st))
end)

t.test("survives a 4 KB pipe name", function()
    local noa = oa.path("\\Device\\NamedPipe\\" .. string.rep("A", 4096))
    survived("4 KB pipe name", create{ ObjectAttributes = noa.oa })
end)

-- ------------------------------------------------------------------
-- Out-of-range mode scalars — NamedPipeType / ReadMode / CompletionMode
-- are each really a 0/1 enum. npfs may reject or clamp; either is fine
-- so long as it does not bugcheck.
-- ------------------------------------------------------------------

for _, v in ipairs({ 2, 0xFFFFFFFF }) do
    t.test(string.format("survives NamedPipeType = 0x%x", v), function()
        local noa = pipe_oa()
        survived("NamedPipeType=" .. hex(v),
                 create{ ObjectAttributes = noa.oa, NamedPipeType = v })
    end)
    t.test(string.format("survives ReadMode = 0x%x", v), function()
        local noa = pipe_oa()
        survived("ReadMode=" .. hex(v),
                 create{ ObjectAttributes = noa.oa, ReadMode = v })
    end)
    t.test(string.format("survives CompletionMode = 0x%x", v), function()
        local noa = pipe_oa()
        survived("CompletionMode=" .. hex(v),
                 create{ ObjectAttributes = noa.oa, CompletionMode = v })
    end)
end

-- ------------------------------------------------------------------
-- Instance count and pool quotas — InboundQuota / OutboundQuota size a
-- pool reservation; a hostile 4 GB request must fail gracefully
-- (STATUS_INSUFFICIENT_RESOURCES, or capped), never bugcheck or
-- actually exhaust the pool.
-- ------------------------------------------------------------------

t.test("survives MaximumInstances = 0", function()
    local noa = pipe_oa()
    survived("MaximumInstances=0",
             create{ ObjectAttributes = noa.oa, MaximumInstances = 0 })
end)

t.test("survives MaximumInstances = unlimited (0xFFFFFFFF)", function()
    local noa = pipe_oa()
    survived("MaximumInstances=0xffffffff",
             create{ ObjectAttributes = noa.oa, MaximumInstances = 0xFFFFFFFF })
end)

for _, q in ipairs({ 0, 0xFFFFFFFF }) do
    t.test(string.format("survives InboundQuota = 0x%x", q), function()
        local noa = pipe_oa()
        survived("InboundQuota=" .. hex(q),
                 create{ ObjectAttributes = noa.oa, InboundQuota = q })
    end)
    t.test(string.format("survives OutboundQuota = 0x%x", q), function()
        local noa = pipe_oa()
        survived("OutboundQuota=" .. hex(q),
                 create{ ObjectAttributes = noa.oa, OutboundQuota = q })
    end)
end
