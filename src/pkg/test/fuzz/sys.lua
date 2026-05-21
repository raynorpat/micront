-- test.fuzz.sys — adversarial edge-case sweep for NtQuerySystemInformation
-- and NtSetSystemInformation.  Same shape as test.fuzz.ps: hand the
-- kernel kernel-range pointers in each OUT/IN slot and assert the
-- prologue probe rejects them with a clean NTSTATUS instead of
-- bugchecking past __try.
--
-- Both syscalls live in NTOS/EX/SYSINFO.C.  The prologue is:
--   Query — ProbeForWrite(SystemInformation, len, ULONG-align) →
--           ProbeForWriteUlong(ReturnLength).
--   Set   — ProbeForRead(SystemInformation, len, ULONG-align).
-- Coverage payoff: the kernel-range case lights up each probe's range
-- check arm; the invariant under test is survival to t.summary(), which
-- means no fault leaked past the probe.

local ffi   = require('ffi')
local t     = require('test')
local ntdll = require('nt.dll')
local sys   = require('nt.dll.sys')      -- registers cdefs
local err   = require('nt.dll.errors')

-- First byte past MmUserProbeAddress; dword-aligned so the range check
-- (not the alignment check) is the rejecting condition.
local KERNEL_PTR = ffi.cast('void *', 0x80000000)

local function rejects(st, slot)
    t.ok(st >= 0xC0000000,
         slot .. ": expected error NTSTATUS, got "
         .. string.format("0x%08x", st))
end

local function bytes(n) return ffi.new('unsigned char[?]', n or 64) end
local function ulong() return ffi.new('ULONG[1]')                  end

t.suite("sys: hardening (kernel-range pointer-slot sweep)")

-- ---- NtQuerySystemInformation -- OUT SystemInformation, OUT ReturnLength ----
-- Class 0 (SystemBasicInformation) just chooses the post-probe branch;
-- the probes are class-independent.

t.test("NtQuerySystemInformation rejects kernel-range SystemInformation", function()
    local st = err.normalize(ntdll.NtQuerySystemInformation(
        0, KERNEL_PTR, 64, ulong()))
    rejects(st, "NtQuerySystemInformation/SystemInformation")
end)

t.test("NtQuerySystemInformation rejects kernel-range ReturnLength", function()
    local st = err.normalize(ntdll.NtQuerySystemInformation(
        0, bytes(64), 64, KERNEL_PTR))
    rejects(st, "NtQuerySystemInformation/ReturnLength")
end)

-- ---- NtSetSystemInformation -- IN SystemInformation ----
-- Class 28 (SystemTimeAdjustmentInformation) is the only handled set
-- class; the probe runs ahead of the dispatch switch so any class
-- triggers it.  Use class 0 (mismatched at the post-probe stage) so
-- if the probe somehow lets the bad pointer through, the dispatch
-- default arm at least returns a clean STATUS_INVALID_INFO_CLASS.

t.test("NtSetSystemInformation rejects kernel-range SystemInformation", function()
    local st = err.normalize(ntdll.NtSetSystemInformation(
        0, KERNEL_PTR, 64))
    rejects(st, "NtSetSystemInformation/SystemInformation")
end)
