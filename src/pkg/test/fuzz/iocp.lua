-- test.fuzz.iocp — adversarial edge-case tests for the I/O completion
-- port syscalls (NtRemoveIoCompletion / NtQueryIoCompletion).
--
-- Two API surfaces, by design (see test/fuzz/iocp-plan.md):
--   * test/sync.lua drives the Lua-idiomatic ex.iocompletion object
--     (:depth() / :remove()) — the happy-path surface real callers use.
--   * this file drops to raw ntdll.Nt* calls so it can hand the kernel
--     deliberately malformed pointers, handles and timeouts that the
--     idiomatic wrapper would never construct. Mirrors test/fuzz/se.lua.
--
-- Scope — PHASE 1 of iocp-plan.md. NT 3.5 has no NtSetIoCompletion, so a
-- completion entry only reaches a port via real async I/O on an
-- associated handle. Phase 1 therefore covers only the codepaths
-- reachable with NO completion on the port:
--
--   * outer probe fault       — bad Key/Apc/IoStatusBlock OUT pointer
--   * handle-reference failure — bad / wrong-type / under-privileged handle
--   * empty-port timeout       — the clean STATUS_TIMEOUT anchor
--
-- The success path, the FIFO round-trip and the P9 re-queue arm
-- (COMPLETE.C inner `except` — re-queues the IRP on a faulted user
-- write) all need a real completion source and are verified in Phase 2.
--
-- Invariant under test: every malformed call returns a clean NTSTATUS
-- and never bugchecks. A kernel fault here takes down the whole
-- in-process runner — survival to t.summary() is itself an assertion.

local ffi    = require('ffi')
local t      = require('test')
local ntdll  = require('nt.dll')
local ex     = require('nt.dll.ex')      -- registers the IOCP cdefs
local ke     = require('nt.dll.ke')      -- ke.timeout
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

local STATUS_SUCCESS              = 0x00000000
local STATUS_TIMEOUT              = 0x00000102
local STATUS_INVALID_HANDLE       = 0xC0000008
local STATUS_ACCESS_DENIED        = 0xC0000022
local STATUS_OBJECT_TYPE_MISMATCH = 0xC0000024

-- IoCompletion-object access bits (winnt.h). NtRemoveIoCompletion
-- references the handle for IO_COMPLETION_MODIFY_STATE; a handle granted
-- only QUERY_STATE must be rejected before any dequeue happens.
local IO_COMPLETION_QUERY_STATE  = 0x0001

-- IoCompletionInformationClass — only BasicInformation exists on NT 3.5.
local IoCompletionBasicInformation = 0

local function hex(st) return string.format("0x%08x", st) end

t.suite("iocp: hardening (raw NtRemoveIoCompletion / NtQueryIoCompletion)")

-- ------------------------------------------------------------------
-- Bad-pointer generators.
--
-- Out-of-range pointers are rejected by every probe variant: NULL
-- faults the probe's write-test; 0x80000000 is past MmUserProbeAddress
-- on the 2GB/2GB split so ProbeForWrite rejects it outright.
--
-- The unaligned case is arch-dependent and the two syscalls differ:
--   * NtQueryIoCompletion uses the generic ProbeForWrite(..., 4-byte
--     alignment) — it DOES reject a misaligned buffer.
--   * NtRemoveIoCompletion uses the inline macros ProbeForWriteLong /
--     ProbeForWriteIoStatus — on x86 these are bare write-tests with NO
--     alignment check (x86 tolerates unaligned access; misalignment is
--     a fault only on RISC targets). So an unaligned-but-mapped OUT
--     pointer is NOT a fault there — it is exercised separately below.
-- `base` is real writable memory so the unaligned address is reachable.
-- ------------------------------------------------------------------

local OOR_PTRS = {
    { name = "NULL",         make = function(ct) return ffi.cast(ct, 0) end },
    { name = "kernel-range", make = function(ct) return ffi.cast(ct, 0x80000000) end },
}

local function unaligned(ct, base)
    return ffi.cast(ct, ffi.cast('char *', base) + 1)
end

-- ------------------------------------------------------------------
-- NtRemoveIoCompletion — outer probe fault on each OUT pointer.
--
-- COMPLETE.C:487-490 probes ApcContext, KeyContext and IoStatusBlock
-- for write before referencing the handle or touching the queue. An
-- out-of-range pointer must be caught by that probe and surfaced via
-- the outer `except` (COMPLETE.C:594-595) — not dereferenced. Two of
-- the three OUT slots stay valid each time so the fault is attributable.
-- ------------------------------------------------------------------

local function remove_corrupting(c, which, make_ptr)
    -- All three OUT slots start as valid, writable cdata.
    local key  = ffi.new('void *[1]')
    local apc  = ffi.new('void *[1]')
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local pad  = ffi.new('char[32]')      -- writable backing for "unaligned"

    local p_key, p_apc, p_iosb = key, apc, iosb
    if which == "ApcContext" then
        p_apc  = make_ptr('void **', pad)
    elseif which == "KeyContext" then
        p_key  = make_ptr('void **', pad)
    else -- IoStatusBlock
        p_iosb = make_ptr('IO_STATUS_BLOCK *', pad)
    end

    return err.normalize(ntdll.NtRemoveIoCompletion(
        handle.raw(c:handle()), p_key, p_apc, p_iosb, ke.timeout(0)))
end

for _, param in ipairs({ "ApcContext", "KeyContext", "IoStatusBlock" }) do
    for _, bad in ipairs(OOR_PTRS) do
        t.test(string.format(
            "NtRemoveIoCompletion rejects %s = %s pointer", param, bad.name),
        function()
            local c  = ex.iocompletion{ concurrent_threads = 1 }
            local st = remove_corrupting(c, param, bad.make)
            c:close()
            t.ne(st, STATUS_SUCCESS,
                 "out-of-range OUT pointer must not return success")
            t.ne(st, STATUS_TIMEOUT,
                 "probe fault must pre-empt the queue wait")
            t.ok(st >= 0xC0000000,
                 "expected an error NTSTATUS, got " .. hex(st))
        end)
    end
end

-- An unaligned-but-mapped OUT pointer is NOT a probe fault for
-- NtRemoveIoCompletion on x86 (inline macros skip the alignment check).
-- The call still completes cleanly: empty port -> STATUS_TIMEOUT, no
-- bugcheck, no false success. This locks that arch-specific behaviour.
for _, param in ipairs({ "ApcContext", "KeyContext", "IoStatusBlock" }) do
    t.test(string.format(
        "NtRemoveIoCompletion tolerates an unaligned %s pointer (x86)", param),
    function()
        local c  = ex.iocompletion{ concurrent_threads = 1 }
        local st = remove_corrupting(c, param, unaligned)
        c:close()
        t.eq(st, STATUS_TIMEOUT,
             "unaligned mapped pointer + empty port -> clean timeout")
    end)
end

-- ------------------------------------------------------------------
-- NtRemoveIoCompletion — handle-reference failure.
--
-- With all three OUT pointers valid the probe passes and
-- ObReferenceObjectByHandle (COMPLETE.C:506-511) is reached. It must
-- reject anything that is not an IoCompletion object the caller may
-- modify, before KeRemoveQueue runs.
-- ------------------------------------------------------------------

local function remove_with_handle(rawh)
    local key  = ffi.new('void *[1]')
    local apc  = ffi.new('void *[1]')
    local iosb = ffi.new('IO_STATUS_BLOCK')
    return err.normalize(ntdll.NtRemoveIoCompletion(
        rawh, key, apc, iosb, ke.timeout(0)))
end

t.test("NtRemoveIoCompletion rejects a NULL handle", function()
    t.eq(remove_with_handle(ffi.cast('HANDLE', 0)), STATUS_INVALID_HANDLE,
         "NULL handle")
end)

t.test("NtRemoveIoCompletion rejects a stale (closed) handle", function()
    local c = ex.iocompletion{ concurrent_threads = 1 }
    -- Capture the raw value BEFORE close — afterwards the NT_HANDLE's
    -- __raw is cleared, but the kernel handle value is what we want to
    -- replay, now dangling.
    local rawh = handle.raw(c:handle())
    c:close()
    t.eq(remove_with_handle(rawh), STATUS_INVALID_HANDLE, "stale handle")
end)

t.test("NtRemoveIoCompletion rejects a wrong-type handle (mutant)", function()
    local m  = ex.mutex()
    local st = remove_with_handle(handle.raw(m:handle()))
    m:close()
    t.eq(st, STATUS_OBJECT_TYPE_MISMATCH, "mutant handle, not an IoCompletion")
end)

t.test("NtRemoveIoCompletion rejects a handle without MODIFY_STATE", function()
    -- Granted QUERY_STATE only — NtRemoveIoCompletion references the
    -- handle for IO_COMPLETION_MODIFY_STATE, so the dequeue is denied.
    local c  = ex.iocompletion{ access = IO_COMPLETION_QUERY_STATE,
                                concurrent_threads = 1 }
    local st = remove_with_handle(handle.raw(c:handle()))
    c:close()
    t.eq(st, STATUS_ACCESS_DENIED, "QUERY_STATE-only handle lacks MODIFY_STATE")
end)

-- ------------------------------------------------------------------
-- NtRemoveIoCompletion — empty-port timeout anchor.
--
-- Valid handle, valid buffers, empty port: KeRemoveQueue returns
-- STATUS_TIMEOUT (COMPLETE.C:533) and the syscall must surface it
-- verbatim — not as a fault, not as success. sync.lua covers this via
-- the idiomatic :remove(); this is the raw-surface anchor.
-- ------------------------------------------------------------------

t.test("NtRemoveIoCompletion on an empty port returns STATUS_TIMEOUT", function()
    local c = ex.iocompletion{ concurrent_threads = 1 }
    t.eq(remove_with_handle(handle.raw(c:handle())), STATUS_TIMEOUT,
         "empty port, zero timeout")
    c:close()
end)

-- ------------------------------------------------------------------
-- NtQueryIoCompletion — outer probe fault.
--
-- COMPLETE.C:343-345 probes the Information buffer for write with the
-- generic ProbeForWrite(..., sizeof(ULONG)) — 4-byte alignment, so the
-- unaligned case IS rejected here (unlike NtRemoveIoCompletion above).
-- A malformed Information pointer must be surfaced as the service
-- status, not dereferenced.
-- ------------------------------------------------------------------

local INFO_LEN = ffi.sizeof('IO_COMPLETION_BASIC_INFORMATION')

local QUERY_BAD_PTRS = {
    OOR_PTRS[1], OOR_PTRS[2],
    { name = "unaligned", make = unaligned },
}

for _, bad in ipairs(QUERY_BAD_PTRS) do
    t.test(string.format(
        "NtQueryIoCompletion rejects Information = %s pointer", bad.name),
    function()
        local c    = ex.iocompletion{ concurrent_threads = 1 }
        local pad  = ffi.new('char[32]')      -- backing for "unaligned"
        local info = bad.make('void *', pad)
        local ret  = ffi.new('ULONG[1]')
        local st = err.normalize(ntdll.NtQueryIoCompletion(
            handle.raw(c:handle()), IoCompletionBasicInformation,
            info, INFO_LEN, ret))
        c:close()
        t.ne(st, STATUS_SUCCESS,
             "malformed Information pointer must not return success")
        -- >= warning severity covers STATUS_ACCESS_VIOLATION (NULL,
        -- kernel-range) and STATUS_DATATYPE_MISALIGNMENT (unaligned).
        t.ok(st >= 0x80000000,
             "expected a probe-rejection NTSTATUS, got " .. hex(st))
    end)
end
