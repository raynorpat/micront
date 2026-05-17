-- test.fuzz.cm — kernel-range pointer-slot sweep for CM (registry) syscalls.
--
-- Part of the deref-before-probe sweep (the bug class written up as
-- NT-BUGS.md entry #5): a syscall that reads a field of an untrusted
-- caller pointer before ProbeForRead/Write -- or a self-probing
-- capture helper -- has validated it. A kernel-range pointer faults
-- past __try and bugchecks 0x50/0x1E; only the probe's range check,
-- which rejects the pointer as data before any deref, stops it.
--
-- A dedicated P14 prologue audit of all 18 CM syscalls (NTAPI.C) found
-- the *retail* subsystem clean: every syscall probes its caller
-- pointers (ProbeForWriteHandle, ProbeForWrite, ProbeForWriteUlong,
-- ProbeAndReadUnicodeString, ProbeAndReadLargeInteger) inside the
-- mode-checked try, or hands OBJECT_ATTRIBUTES to ObOpenObjectByName /
-- CmpNameFromAttributes (which capture internally). The only
-- deref-before-probe sites were the CMLOG/KdPrint argument-logging
-- macros in each prologue -- and those are dead code in the shipped
-- DBG=0 build (KdPrint discards its arguments when DBG=0). They were
-- stripped from NTAPI.C in the same change as this suite, so CM is now
-- clean in both retail and checked builds. This suite is the
-- confirm-net locking that in.
--
-- For every pointer argument of each bridged pointer-bearing CM
-- syscall we hand the kernel a kernel-range pointer (0x80000000,
-- dword-aligned so the range check -- not the alignment check -- is
-- the rejecting condition) in that one slot while every other argument
-- stays valid, then assert a clean error NTSTATUS. As with the other
-- fuzz suites the deeper assertion is survival: the in-process runner
-- reaching t.summary() means no probe regressed into a bugcheck.
--
-- The query/enumerate/value syscalls reference the key handle before
-- probing, so the suite opens \Registry\Machine\System (read access)
-- as scaffolding. NtSetValueKey and NtDeleteValueKey re-reference that
-- handle asking for KEY_SET_VALUE, which the read-only scaffold lacks,
-- so for those two the access check is the rejecting condition rather
-- than the probe -- survival to t.summary() is the assertion either
-- way. The handle-only CM syscalls (NtDeleteKey, NtFlushKey) have no
-- caller pointer to sweep; the unbridged CM syscalls are out of scope
-- here -- their prologues audited clean too. Cover them when bridged.

local t      = require('test')
local cm     = require('nt.dll.cm')       -- registers the CM cdefs
local oa     = require('nt.dll.oa')
local str    = require('nt.dll.str')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')
local ntdll  = require('nt.dll')
local ffi    = require('ffi')

-- First byte past MmUserProbeAddress. dword-aligned: the range check,
-- not the alignment check, is what must reject this.
local KERNEL_PTR = ffi.cast('void *', 0x80000000)

-- KEY_QUERY_VALUE | KEY_ENUMERATE_SUB_KEYS -- enough for the query and
-- enumerate syscalls to clear their handle-access check and reach the
-- probe under test.
local KEY_READ_ACCESS = 0x9

t.suite("cm: hardening (kernel-range pointer-slot sweep)")

-- Assert a syscall return is a clean error NTSTATUS. Reaching this
-- assertion at all means the kernel rejected the pointer as data and
-- did not fault on it.
local function rejects(st, slot)
    t.ok(st >= 0xC0000000,
         slot .. ": expected error NTSTATUS, got "
         .. string.format("0x%08x", st))
end

-- Valid scratch. Each returns a fresh cdata the caller holds for the
-- duration of the syscall (no ffi.cast indirection -> no GC dangle).
local function hslot() return ffi.new('HANDLE[1]')        end
local function ulong() return ffi.new('ULONG[1]')         end
local function bytes(n) return ffi.new('unsigned char[?]', n or 256) end

-- A valid OBJECT_ATTRIBUTES naming an existing key. oa.path(...).oa is
-- the proven idiom (see test/cm.lua); the .oa cdata anchors its own
-- backing memory.
local function valid_oa() return oa.path("\\Registry\\Machine\\System").oa end

-- A valid UNICODE_STRING value name, held module-wide so its backing
-- buffer stays alive for every syscall that uses it.
local VALID_VN = str.to_utf16("FuzzProbeValue")

-- A real KEY-object handle for the syscalls that reference the handle
-- before probing.
local key_h
do
    local ok, h = pcall(cm.NtOpenKey, KEY_READ_ACCESS, valid_oa())
    if ok then key_h = h end
end

local function key_raw()
    assert(key_h,
           "test.fuzz.cm: could not open \\Registry\\Machine\\System scratch handle")
    return handle.raw(key_h)
end

-- ---- NtOpenKey -- OUT KeyHandle, IN ObjectAttributes ----
-- Prologue probes KeyHandle (ProbeForWriteHandle); ObjectAttributes
-- flows into ObOpenObjectByName, whose ObpCaptureObjectAttributes
-- probes it.

t.test("NtOpenKey rejects kernel-range KeyHandle", function()
    local st = err.normalize(ntdll.NtOpenKey(
        KERNEL_PTR, KEY_READ_ACCESS, valid_oa()))
    rejects(st, "NtOpenKey/KeyHandle")
end)

t.test("NtOpenKey rejects kernel-range ObjectAttributes", function()
    local st = err.normalize(ntdll.NtOpenKey(
        hslot(), KEY_READ_ACCESS, KERNEL_PTR))
    rejects(st, "NtOpenKey/ObjectAttributes")
end)

-- ---- NtCreateKey -- OUT KeyHandle, IN ObjectAttributes, IN Class,
--                     OUT Disposition ----
-- Prologue probes KeyHandle -> Class (ProbeAndReadUnicodeString) ->
-- Disposition (ProbeForWriteUlong); ObjectAttributes flows into the
-- parse/ObCreateObject path. Every poisoned call is rejected before a
-- key is created.

t.test("NtCreateKey rejects kernel-range KeyHandle", function()
    local st = err.normalize(ntdll.NtCreateKey(
        KERNEL_PTR, KEY_READ_ACCESS, valid_oa(), 0, nil, 0, ulong()))
    rejects(st, "NtCreateKey/KeyHandle")
end)

t.test("NtCreateKey rejects kernel-range ObjectAttributes", function()
    local st = err.normalize(ntdll.NtCreateKey(
        hslot(), KEY_READ_ACCESS, KERNEL_PTR, 0, nil, 0, ulong()))
    rejects(st, "NtCreateKey/ObjectAttributes")
end)

t.test("NtCreateKey rejects kernel-range Class", function()
    local st = err.normalize(ntdll.NtCreateKey(
        hslot(), KEY_READ_ACCESS, valid_oa(), 0, KERNEL_PTR, 0, ulong()))
    rejects(st, "NtCreateKey/Class")
end)

t.test("NtCreateKey rejects kernel-range Disposition", function()
    local st = err.normalize(ntdll.NtCreateKey(
        hslot(), KEY_READ_ACCESS, valid_oa(), 0, nil, 0, KERNEL_PTR))
    rejects(st, "NtCreateKey/Disposition")
end)

-- ---- NtQueryKey -- OUT KeyInformation, OUT ResultLength ----
-- Both probed (ProbeForWrite, ProbeForWriteUlong) after the handle is
-- referenced; class 0 (KeyBasicInformation) selects the post-probe
-- branch.

t.test("NtQueryKey rejects kernel-range KeyInformation", function()
    local st = err.normalize(ntdll.NtQueryKey(
        key_raw(), cm.KeyBasicInformation, KERNEL_PTR, 256, ulong()))
    rejects(st, "NtQueryKey/KeyInformation")
end)

t.test("NtQueryKey rejects kernel-range ResultLength", function()
    local st = err.normalize(ntdll.NtQueryKey(
        key_raw(), cm.KeyBasicInformation, bytes(256), 256, KERNEL_PTR))
    rejects(st, "NtQueryKey/ResultLength")
end)

-- ---- NtEnumerateKey -- OUT KeyInformation, OUT ResultLength ----

t.test("NtEnumerateKey rejects kernel-range KeyInformation", function()
    local st = err.normalize(ntdll.NtEnumerateKey(
        key_raw(), 0, cm.KeyBasicInformation, KERNEL_PTR, 256, ulong()))
    rejects(st, "NtEnumerateKey/KeyInformation")
end)

t.test("NtEnumerateKey rejects kernel-range ResultLength", function()
    local st = err.normalize(ntdll.NtEnumerateKey(
        key_raw(), 0, cm.KeyBasicInformation, bytes(256), 256, KERNEL_PTR))
    rejects(st, "NtEnumerateKey/ResultLength")
end)

-- ---- NtEnumerateValueKey -- OUT KeyValueInformation, OUT ResultLength ----

t.test("NtEnumerateValueKey rejects kernel-range KeyValueInformation", function()
    local st = err.normalize(ntdll.NtEnumerateValueKey(
        key_raw(), 0, cm.KeyValueFullInformation, KERNEL_PTR, 256, ulong()))
    rejects(st, "NtEnumerateValueKey/KeyValueInformation")
end)

t.test("NtEnumerateValueKey rejects kernel-range ResultLength", function()
    local st = err.normalize(ntdll.NtEnumerateValueKey(
        key_raw(), 0, cm.KeyValueFullInformation, bytes(256), 256, KERNEL_PTR))
    rejects(st, "NtEnumerateValueKey/ResultLength")
end)

-- ---- NtQueryValueKey -- IN ValueName, OUT KeyValueInformation,
--                         OUT ResultLength ----
-- ValueName is probed via ProbeAndReadUnicodeString; the output buffer
-- and ResultLength via ProbeForWrite / ProbeForWriteUlong.

t.test("NtQueryValueKey rejects kernel-range ValueName", function()
    local st = err.normalize(ntdll.NtQueryValueKey(
        key_raw(), KERNEL_PTR, cm.KeyValueFullInformation,
        bytes(256), 256, ulong()))
    rejects(st, "NtQueryValueKey/ValueName")
end)

t.test("NtQueryValueKey rejects kernel-range KeyValueInformation", function()
    local st = err.normalize(ntdll.NtQueryValueKey(
        key_raw(), VALID_VN.us, cm.KeyValueFullInformation,
        KERNEL_PTR, 256, ulong()))
    rejects(st, "NtQueryValueKey/KeyValueInformation")
end)

t.test("NtQueryValueKey rejects kernel-range ResultLength", function()
    local st = err.normalize(ntdll.NtQueryValueKey(
        key_raw(), VALID_VN.us, cm.KeyValueFullInformation,
        bytes(256), 256, KERNEL_PTR))
    rejects(st, "NtQueryValueKey/ResultLength")
end)

-- ---- NtSetValueKey -- IN ValueName, IN Data ----
-- The read-only scaffold handle lacks KEY_SET_VALUE, so the handle
-- access check rejects ahead of the ValueName/Data probes; the
-- assertion here is survival (a clean NTSTATUS, no bugcheck).

t.test("NtSetValueKey rejects kernel-range ValueName", function()
    local st = err.normalize(ntdll.NtSetValueKey(
        key_raw(), KERNEL_PTR, 0, cm.REG_BINARY, bytes(16), 16))
    rejects(st, "NtSetValueKey/ValueName")
end)

t.test("NtSetValueKey rejects kernel-range Data", function()
    local st = err.normalize(ntdll.NtSetValueKey(
        key_raw(), VALID_VN.us, 0, cm.REG_BINARY, KERNEL_PTR, 16))
    rejects(st, "NtSetValueKey/Data")
end)

-- ---- NtDeleteValueKey -- IN ValueName ----

t.test("NtDeleteValueKey rejects kernel-range ValueName", function()
    local st = err.normalize(ntdll.NtDeleteValueKey(
        key_raw(), KERNEL_PTR))
    rejects(st, "NtDeleteValueKey/ValueName")
end)
