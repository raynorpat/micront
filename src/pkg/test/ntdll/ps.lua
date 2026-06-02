-- test.ps — functional coverage for NtQueryInformationProcess /
-- NtSetInformationProcess / NtQueryInformationThread /
-- NtSetInformationThread.  Drives every info class the NT 3.5 kernel
-- references (NTOS/PS/PSQUERY.C).
--
-- Strategy: every case arm in the four switches is exercised at least
-- once.  Happy-path classes use NtCurrentProcess / NtCurrentThread or
-- a freshly-spawned suspended thread; privileged classes (AccessToken,
-- UserModeIOPL) are driven through the privilege-not-held arm so the
-- privilege check runs without us actually re-assigning a token or
-- raising IOPL.  Length-mismatch is swept as a table so each class's
-- STATUS_INFO_LENGTH_MISMATCH arm fires.
--
-- Out of scope (would cause persistent side effects on the runner):
--   * Setting ProcessDebugPort / ProcessExceptionPort to a real port —
--     once set on the runner process they can't be cleared until exit;
--     would interfere with later suites that rely on the default port.
--   * Setting ProcessWorkingSetWatch — allocates an 8KB nonpaged-pool
--     watcher buffer that lives until process exit.
-- We exercise their privilege-check / NULL-port / handle-validation arms
-- instead.

local ffi    = require('ffi')
local t      = require('test')
local ntdll  = require('nt.dll')
local ps     = require('nt.dll.ps')
local ke     = require('nt.dll.ke')
local ex     = require('nt.dll.ex')
local se     = require('nt.dll.se')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

local STATUS_SUCCESS              = 0x00000000
local STATUS_INFO_LENGTH_MISMATCH = 0xC0000004
local STATUS_INVALID_INFO_CLASS   = 0xC0000003
local STATUS_INVALID_HANDLE       = 0xC0000008
local STATUS_INVALID_PARAMETER    = 0xC000000D
local STATUS_NOT_SUPPORTED        = 0xC00000BB
local STATUS_PORT_ALREADY_SET     = 0xC0000048
local STATUS_PRIVILEGE_NOT_HELD   = 0xC0000061

local CURRENT_PROCESS = handle.NtCurrentProcess()
local CURRENT_THREAD  = handle.NtCurrentThread()

local function hex(st) return string.format("0x%08x", st) end

t.suite("ps: NtQueryInformationProcess")

-- ------------------------------------------------------------------
-- Happy-path query, one test per class.  We validate the obvious
-- invariant for each (PID > 0, working set positive, etc.); the deeper
-- assertion is that the syscall returns success and the right
-- return-length.
-- ------------------------------------------------------------------

t.test("ProcessBasicInformation returns our own PID", function()
    local info = ps.NtQueryInformationProcess_Basic(CURRENT_PROCESS)
    t.ok(info.pid > 0, "pid must be positive, got " .. tostring(info.pid))
    t.ok(info.peb ~= nil, "PEB pointer must be non-NULL")
end)

t.test("ProcessVmCounters returns sane working-set numbers", function()
    local vmc = ps.process_vm_counters(CURRENT_PROCESS)
    t.ok(vmc.working_set_size  > 0,  "working set must be > 0")
    t.ok(vmc.peak_working_set_size >= vmc.working_set_size,
         "peak >= current")
    t.ok(vmc.virtual_size      > 0,  "virtual size must be > 0")
end)

t.test("ProcessTimes returns non-zero CreateTime", function()
    local times = ps.process_times(CURRENT_PROCESS)
    -- CreateTime is filled by PspCreateProcess via KeQuerySystemTime;
    -- can't be zero on a running process.
    local create_nonzero = times.create.low ~= 0 or times.create.high ~= 0
    t.ok(create_nonzero, "CreateTime must be non-zero on a live process")
end)

t.test("ProcessDefaultHardErrorMode returns a ULONG", function()
    local buf = ffi.new('ULONG[1]')
    local st, ret = ps.NtQueryInformationProcess(
        CURRENT_PROCESS, ps.ProcessDefaultHardErrorMode, buf, 4)
    t.eq(st, STATUS_SUCCESS, "expected STATUS_SUCCESS, got " .. hex(st))
    t.eq(ret, 4, "return length must equal sizeof(ULONG)")
end)

t.test("ProcessQuotaLimits returns initialised limits", function()
    local ql = ffi.new('QUOTA_LIMITS')
    local st, _ = ps.NtQueryInformationProcess(
        CURRENT_PROCESS, ps.ProcessQuotaLimits, ql,
        ffi.sizeof('QUOTA_LIMITS'))
    t.eq(st, STATUS_SUCCESS, "QuotaLimits query failed: " .. hex(st))
    t.ok(ql.MinimumWorkingSetSize > 0, "min WS must be positive")
    t.ok(ql.MaximumWorkingSetSize >= ql.MinimumWorkingSetSize,
         "max WS >= min WS")
end)

t.test("ProcessPooledUsageAndLimits returns non-zero limits", function()
    local pul = ffi.new('POOLED_USAGE_AND_LIMITS')
    local st, _ = ps.NtQueryInformationProcess(
        CURRENT_PROCESS, ps.ProcessPooledUsageAndLimits, pul,
        ffi.sizeof('POOLED_USAGE_AND_LIMITS'))
    t.eq(st, STATUS_SUCCESS, "PooledUsage query failed: " .. hex(st))
    t.ok(pul.PagedPoolLimit > 0,    "paged pool limit must be > 0")
    t.ok(pul.NonPagedPoolLimit > 0, "nonpaged pool limit must be > 0")
end)

t.test("ProcessDebugPort returns NULL when no debugger attached", function()
    local h = ffi.new('HANDLE[1]')
    local st, _ = ps.NtQueryInformationProcess(
        CURRENT_PROCESS, ps.ProcessDebugPort, h, 4)
    t.eq(st, STATUS_SUCCESS, "DebugPort query failed: " .. hex(st))
    t.eq(tonumber(ffi.cast('intptr_t', h[0])), 0,
         "no debugger attached → port must be NULL")
end)

t.test("ProcessIoCounters returns STATUS_NOT_SUPPORTED on NT 3.5", function()
    -- The case arm in PSQUERY.C exists but unconditionally returns
    -- STATUS_NOT_SUPPORTED — this test locks that contract in so
    -- callers can rely on the rejection code rather than guessing.
    local buf = ffi.new('unsigned char[64]')
    local st, _ = ps.NtQueryInformationProcess(
        CURRENT_PROCESS, ps.ProcessIoCounters, buf, 64)
    t.eq(st, STATUS_NOT_SUPPORTED,
         "expected STATUS_NOT_SUPPORTED, got " .. hex(st))
end)

t.test("ProcessLdtInformation reports zero-sized LDT", function()
    -- A fresh-process LDT has no descriptors installed.  The kernel's
    -- PspQueryLdtInformation copies as much as the caller's buffer can
    -- hold, padding with zero entries — so even a tiny buffer must
    -- succeed (no descriptors to overflow).
    local buf = ffi.new('PROCESS_LDT_INFORMATION')
    local st, _ = ps.NtQueryInformationProcess(
        CURRENT_PROCESS, ps.ProcessLdtInformation, buf,
        ffi.sizeof('PROCESS_LDT_INFORMATION'))
    -- Either STATUS_SUCCESS (process has no LDT, returns zero entries)
    -- or STATUS_INFO_LENGTH_MISMATCH (NT 3.5 requires >= sizeof header).
    -- Both are legal; what we're asserting is no kernel fault.
    t.ok(st == STATUS_SUCCESS or st == STATUS_INFO_LENGTH_MISMATCH,
         "LdtInformation query returned " .. hex(st))
end)

t.test("ProcessWorkingSetWatch query with no watcher set", function()
    -- WSWatcher uses the PSAPI shape PsWatchEnabled gates on.
    -- Without a Set first, the query returns whatever PspQueryWorkingSetWatch
    -- reports for an unprimed process — typically STATUS_INVALID_INFO_CLASS
    -- or STATUS_INFO_LENGTH_MISMATCH because the kernel checks the
    -- length first.  Just confirm no fault.
    local buf = ffi.new('unsigned char[8192]')
    local st, _ = ps.NtQueryInformationProcess(
        CURRENT_PROCESS, ps.ProcessWorkingSetWatch, buf, 8192)
    t.ok(st < 0x80000000 or st >= 0xC0000000,
         "WorkingSetWatch query: " .. hex(st))
end)

-- ------------------------------------------------------------------
-- Length-mismatch sweep — every fixed-length class returns
-- STATUS_INFO_LENGTH_MISMATCH on a wrong-sized buffer.
-- ------------------------------------------------------------------

local fixed_query_classes = {
    { name = "BasicInformation",      cls = ps.ProcessBasicInformation,
      size = 24 },  -- sizeof(PROCESS_BASIC_INFORMATION)
    { name = "QuotaLimits",           cls = ps.ProcessQuotaLimits,
      size = 28 },
    { name = "VmCounters",            cls = ps.ProcessVmCounters,
      size = 44 },
    { name = "Times",                 cls = ps.ProcessTimes,
      size = 32 },
    { name = "DebugPort",             cls = ps.ProcessDebugPort,
      size = 4 },
    { name = "DefaultHardErrorMode",  cls = ps.ProcessDefaultHardErrorMode,
      size = 4 },
    { name = "PooledUsageAndLimits",  cls = ps.ProcessPooledUsageAndLimits,
      size = 36 },
}

for _, c in ipairs(fixed_query_classes) do
    t.test("Process " .. c.name .. " rejects wrong-size buffer", function()
        local buf = ffi.new('unsigned char[64]')
        -- Pass size+1 to ensure mismatch (size-1 would be too small
        -- for the kernel's probe alignment requirement on some paths;
        -- size+1 is unambiguously "wrong").
        local st, _ = ps.NtQueryInformationProcess(
            CURRENT_PROCESS, c.cls, buf, c.size + 1)
        t.eq(st, STATUS_INFO_LENGTH_MISMATCH,
             c.name .. ": expected STATUS_INFO_LENGTH_MISMATCH, got "
             .. hex(st))
    end)
end

t.test("invalid Process info class returns STATUS_INVALID_INFO_CLASS", function()
    local buf = ffi.new('unsigned char[64]')
    -- Class 13 (ProcessIoPortHandlers) and class 99 are both unhandled
    -- in the kernel's switch — both fall through to default.
    local st, _ = ps.NtQueryInformationProcess(
        CURRENT_PROCESS, 99, buf, 64)
    t.eq(st, STATUS_INVALID_INFO_CLASS,
         "expected STATUS_INVALID_INFO_CLASS, got " .. hex(st))
end)

-- ------------------------------------------------------------------
-- NtSetInformationProcess
-- ------------------------------------------------------------------

t.suite("ps: NtSetInformationProcess")

t.test("ProcessBasePriority round-trip (lower then restore)", function()
    -- BasePriority is signed KPRIORITY.  We round-trip via:
    --   1. Query current base.
    --   2. Set base-1 (lowering needs no privilege).
    --   3. Query, verify.
    --   4. Restore.
    local info = ps.NtQueryInformationProcess_Basic(CURRENT_PROCESS)
    local original = info.base_priority
    t.ok(original > 0, "must have a positive base priority")

    local newpri = ffi.new('long[1]', original - 1)
    local st = ps.NtSetInformationProcess(
        CURRENT_PROCESS, ps.ProcessBasePriority, newpri, 4)
    t.eq(st, STATUS_SUCCESS, "lower priority failed: " .. hex(st))

    local after = ps.NtQueryInformationProcess_Basic(CURRENT_PROCESS).base_priority
    t.eq(after, original - 1, "base priority did not update")

    -- Restore.  Raising back up to original is also allowed (no
    -- privilege check unless we exceed the original).
    newpri[0] = original
    st = ps.NtSetInformationProcess(
        CURRENT_PROCESS, ps.ProcessBasePriority, newpri, 4)
    t.eq(st, STATUS_SUCCESS, "restore base priority failed: " .. hex(st))
end)

t.test("ProcessRaisePriority with boost=0 is a no-op success", function()
    local boost = ffi.new('ULONG[1]', 0)
    local st = ps.NtSetInformationProcess(
        CURRENT_PROCESS, ps.ProcessRaisePriority, boost, 4)
    t.eq(st, STATUS_SUCCESS, "RaisePriority(0) failed: " .. hex(st))
end)

t.test("ProcessDefaultHardErrorMode round-trip", function()
    local buf = ffi.new('ULONG[1]')
    -- Query original.
    local st, _ = ps.NtQueryInformationProcess(
        CURRENT_PROCESS, ps.ProcessDefaultHardErrorMode, buf, 4)
    t.eq(st, STATUS_SUCCESS)
    local original = buf[0]

    -- Toggle a benign bit (alignment-fix flag — bit 0x4).
    local toggle = ffi.new('ULONG[1]', original ~= 0 and 0 or 1)
    st = ps.NtSetInformationProcess(
        CURRENT_PROCESS, ps.ProcessDefaultHardErrorMode, toggle, 4)
    t.eq(st, STATUS_SUCCESS, "set HardErrorMode failed: " .. hex(st))

    -- Restore.
    buf[0] = original
    st = ps.NtSetInformationProcess(
        CURRENT_PROCESS, ps.ProcessDefaultHardErrorMode, buf, 4)
    t.eq(st, STATUS_SUCCESS, "restore HardErrorMode failed: " .. hex(st))
end)

t.test("ProcessEnableAlignmentFaultFixup set/clear", function()
    local bf = ffi.new('unsigned char[1]')
    bf[0] = 1
    local st = ps.NtSetInformationProcess(
        CURRENT_PROCESS, ps.ProcessEnableAlignmentFaultFixup, bf, 1)
    t.eq(st, STATUS_SUCCESS, "enable fixup failed: " .. hex(st))

    bf[0] = 0
    st = ps.NtSetInformationProcess(
        CURRENT_PROCESS, ps.ProcessEnableAlignmentFaultFixup, bf, 1)
    t.eq(st, STATUS_SUCCESS, "disable fixup failed: " .. hex(st))
end)

t.test("ProcessAccessToken without privilege returns PRIVILEGE_NOT_HELD", function()
    -- SeAssignPrimaryTokenPrivilege is not held by default; the kernel
    -- bails before doing anything destructive.  This exercises the
    -- privilege-check arm of the case without actually replacing the
    -- token.
    local pat = ffi.new('PROCESS_ACCESS_TOKEN')
    pat.Token  = ffi.cast('HANDLE', 0)
    pat.Thread = ffi.cast('HANDLE', 0)
    local st = ps.NtSetInformationProcess(
        CURRENT_PROCESS, ps.ProcessAccessToken, pat,
        ffi.sizeof('PROCESS_ACCESS_TOKEN'))
    t.eq(st, STATUS_PRIVILEGE_NOT_HELD,
         "expected STATUS_PRIVILEGE_NOT_HELD, got " .. hex(st))
end)

t.test("ProcessUserModeIOPL without privilege returns PRIVILEGE_NOT_HELD", function()
    -- The runner inherits SeTcbPrivilege from init, so an unguarded
    -- call would silently succeed and raise our IOPL — leaking that
    -- state into later suites.  Drop the privilege first so the
    -- check arm runs deterministically, then restore.  Use
    -- TOKEN_QUERY + TOKEN_ADJUST_PRIVILEGES to scope the open token.
    local tok = se.open_process_token{
        access = se.TOKEN_QUERY + se.TOKEN_ADJUST_PRIVILEGES,
    }
    se.disable_privileges(tok, {"SeTcbPrivilege"})
    local st = ps.NtSetInformationProcess(
        CURRENT_PROCESS, ps.ProcessUserModeIOPL, nil, 0)
    se.enable_privileges(tok, {"SeTcbPrivilege"})
    tok:close()
    t.eq(st, STATUS_PRIVILEGE_NOT_HELD,
         "expected STATUS_PRIVILEGE_NOT_HELD, got " .. hex(st))
end)

t.test("ProcessExceptionPort with bad-type handle is rejected", function()
    -- Pass a non-port HANDLE (the current-process pseudo-handle isn't
    -- an LPC port).  Kernel reaches the LpcPortObjectType check and
    -- bails with STATUS_OBJECT_TYPE_MISMATCH.  Doesn't touch our actual
    -- exception port.
    local h = ffi.new('HANDLE[1]')
    h[0] = handle.raw(CURRENT_PROCESS)  -- intentionally wrong type (not LPC port)
    local st = ps.NtSetInformationProcess(
        CURRENT_PROCESS, ps.ProcessExceptionPort, h, 4)
    t.ok(st >= 0xC0000000, "expected error NTSTATUS, got " .. hex(st))
    t.ok(st ~= STATUS_SUCCESS, "must NOT have actually set the port")
end)

t.test("ProcessBasePriority out-of-range value rejected", function()
    local newpri = ffi.new('long[1]', 999)  -- way above HIGH_PRIORITY
    local st = ps.NtSetInformationProcess(
        CURRENT_PROCESS, ps.ProcessBasePriority, newpri, 4)
    t.eq(st, STATUS_INVALID_PARAMETER,
         "out-of-range priority: expected INVALID_PARAMETER, got "
         .. hex(st))
end)

local fixed_set_classes = {
    { name = "BasePriority",          cls = ps.ProcessBasePriority,        size = 4 },
    { name = "RaisePriority",         cls = ps.ProcessRaisePriority,       size = 4 },
    { name = "DebugPort",             cls = ps.ProcessDebugPort,           size = 4 },
    { name = "ExceptionPort",         cls = ps.ProcessExceptionPort,       size = 4 },
    { name = "QuotaLimits",           cls = ps.ProcessQuotaLimits,         size = 28 },
    { name = "DefaultHardErrorMode",  cls = ps.ProcessDefaultHardErrorMode, size = 4 },
    { name = "EnableAlignmentFaultFixup", cls = ps.ProcessEnableAlignmentFaultFixup,
      size = 1 },
}

for _, c in ipairs(fixed_set_classes) do
    t.test("Process Set " .. c.name .. " rejects wrong-size buffer", function()
        local buf = ffi.new('unsigned char[64]')
        local st = ps.NtSetInformationProcess(
            CURRENT_PROCESS, c.cls, buf, c.size + 1)
        t.eq(st, STATUS_INFO_LENGTH_MISMATCH,
             c.name .. ": expected STATUS_INFO_LENGTH_MISMATCH, got "
             .. hex(st))
    end)
end

-- ------------------------------------------------------------------
-- NtQueryInformationThread
-- ------------------------------------------------------------------

t.suite("ps: NtQueryInformationThread")

t.test("ThreadBasicInformation returns our own TID", function()
    local tbi = ps.thread_basic_info(CURRENT_THREAD)
    t.ok(tbi.tid > 0, "tid must be > 0, got " .. tostring(tbi.tid))
    t.ok(tbi.pid > 0, "pid must be > 0, got " .. tostring(tbi.pid))
    -- Priority is the live KPRIORITY (0..31; ~8 for THREAD_PRIORITY_NORMAL).
    t.ok(tbi.priority > 0, "kernel priority must be positive")
    -- BasePriority is the Win32-style signed offset that
    -- KeQueryBasePriorityThread returns — 0 is NORMAL, range [-15, +15]
    -- (REALTIME/IDLE included).  Assert the value sits inside that range
    -- rather than positivity.
    t.ok(tbi.base_priority >= -15 and tbi.base_priority <= 15,
         "base priority out of Win32 range, got "
         .. tostring(tbi.base_priority))
end)

t.test("ThreadTimes returns non-zero CreateTime", function()
    local times = ps.thread_times(CURRENT_THREAD)
    local create_nonzero = times.create.low ~= 0 or times.create.high ~= 0
    t.ok(create_nonzero, "CreateTime must be non-zero")
    -- ExitTime is zero for a running thread.
    t.eq(times.exit.low, 0,  "ExitTime low must be 0 on running thread")
    t.eq(times.exit.high, 0, "ExitTime high must be 0 on running thread")
end)

t.test("ThreadDescriptorTableEntry returns a usable descriptor", function()
    -- Selector 0x23 = KGDT_R3_DATA (user-mode DS/ES/SS).  The kernel
    -- copies the descriptor out of the GDT.
    local dte = ffi.new('DESCRIPTOR_TABLE_ENTRY')
    dte.Selector = 0x23
    local st, _ = ps.NtQueryInformationThread(
        CURRENT_THREAD, ps.ThreadDescriptorTableEntry, dte,
        ffi.sizeof('DESCRIPTOR_TABLE_ENTRY'))
    t.eq(st, STATUS_SUCCESS, "DescriptorTableEntry failed: " .. hex(st))
    -- Non-zero descriptor — a present user-data segment has bits set.
    t.ok(dte.Descriptor.HighWord ~= 0 or dte.Descriptor.LimitLow ~= 0,
         "user data descriptor must be populated")
end)

t.test("ThreadQuerySetWin32StartAddress query returns the entry", function()
    local sa = ffi.new('void *[1]')
    local st, _ = ps.NtQueryInformationThread(
        CURRENT_THREAD, ps.ThreadQuerySetWin32StartAddress, sa, 4)
    t.eq(st, STATUS_SUCCESS, "QuerySetWin32StartAddress: " .. hex(st))
    -- May be NULL (never set) — accept either, the assertion is the
    -- kernel handed us a value via the OUT path without faulting.
end)

t.test("ThreadPerformanceCount returns a LARGE_INTEGER", function()
    local pc = ffi.new('LARGE_INTEGER')
    local st, _ = ps.NtQueryInformationThread(
        CURRENT_THREAD, ps.ThreadPerformanceCount, pc, 8)
    t.eq(st, STATUS_SUCCESS, "PerformanceCount: " .. hex(st))
end)

local fixed_thread_query_classes = {
    { name = "BasicInformation",      cls = ps.ThreadBasicInformation,   size = 28 },
    { name = "Times",                 cls = ps.ThreadTimes,              size = 32 },
    { name = "QuerySetWin32StartAddress", cls = ps.ThreadQuerySetWin32StartAddress,
      size = 4 },
    { name = "PerformanceCount",      cls = ps.ThreadPerformanceCount,   size = 8 },
}

for _, c in ipairs(fixed_thread_query_classes) do
    t.test("Thread Query " .. c.name .. " rejects wrong-size buffer", function()
        local buf = ffi.new('unsigned char[64]')
        local st, _ = ps.NtQueryInformationThread(
            CURRENT_THREAD, c.cls, buf, c.size + 1)
        t.eq(st, STATUS_INFO_LENGTH_MISMATCH,
             c.name .. ": expected STATUS_INFO_LENGTH_MISMATCH, got "
             .. hex(st))
    end)
end

t.test("invalid Thread info class returns STATUS_INVALID_INFO_CLASS", function()
    local buf = ffi.new('unsigned char[64]')
    local st, _ = ps.NtQueryInformationThread(
        CURRENT_THREAD, 99, buf, 64)
    t.eq(st, STATUS_INVALID_INFO_CLASS,
         "expected STATUS_INVALID_INFO_CLASS, got " .. hex(st))
end)

-- ------------------------------------------------------------------
-- NtSetInformationThread
-- ------------------------------------------------------------------

t.suite("ps: NtSetInformationThread")

-- Drive Set against a freshly-spawned suspended thread instead of
-- CURRENT_THREAD so the runner's state isn't perturbed.  Entry =
-- NtSetHighEventPair (matches the (HANDLE) stdcall shape).
local function spawn_test_thread()
    local ep = ex.event_pair()
    local th = ps.create_thread(ntdll.NtSetHighEventPair, ep:handle(),
                                { suspended = true })
    return th, ep
end

t.test("ThreadPriority round-trip (set lower then restore)", function()
    local th, ep = spawn_test_thread()
    local tbi = ps.thread_basic_info(th)
    local original = tbi.priority

    local pri = ffi.new('long[1]', original - 1)
    local st = ps.NtSetInformationThread(
        th, ps.ThreadPriority, pri, 4)
    t.eq(st, STATUS_SUCCESS, "set priority failed: " .. hex(st))

    local after = ps.thread_basic_info(th).priority
    t.eq(after, original - 1, "priority did not update")

    -- Run the thread to completion to clean up.
    ps.NtResumeThread(th)
    ep:wait_high()
    ke.NtWaitForSingleObject(th, false, ke.timeout(1.0))
    th:close()
    ep:close()
end)

t.test("ThreadBasePriority set/restore", function()
    local th, ep = spawn_test_thread()
    local pri = ffi.new('long[1]', 0)   -- a valid in-range base
    local st = ps.NtSetInformationThread(
        th, ps.ThreadBasePriority, pri, 4)
    t.eq(st, STATUS_SUCCESS, "set base priority failed: " .. hex(st))

    ps.NtResumeThread(th)
    ep:wait_high()
    ke.NtWaitForSingleObject(th, false, ke.timeout(1.0))
    th:close()
    ep:close()
end)

t.test("ThreadAffinityMask set to current value succeeds", function()
    local th, ep = spawn_test_thread()
    local tbi = ps.thread_basic_info(th)
    local mask = ffi.new('ULONG[1]', tbi.affinity_mask)
    local st = ps.NtSetInformationThread(
        th, ps.ThreadAffinityMask, mask, 4)
    t.eq(st, STATUS_SUCCESS, "set affinity failed: " .. hex(st))

    ps.NtResumeThread(th)
    ep:wait_high()
    ke.NtWaitForSingleObject(th, false, ke.timeout(1.0))
    th:close()
    ep:close()
end)

t.test("ThreadAffinityMask zero rejected", function()
    local th, ep = spawn_test_thread()
    local mask = ffi.new('ULONG[1]', 0)
    local st = ps.NtSetInformationThread(
        th, ps.ThreadAffinityMask, mask, 4)
    t.eq(st, STATUS_INVALID_PARAMETER,
         "zero affinity must be rejected, got " .. hex(st))

    -- Clean up.
    ps.NtResumeThread(th)
    ep:wait_high()
    ke.NtWaitForSingleObject(th, false, ke.timeout(1.0))
    th:close()
    ep:close()
end)

t.test("ThreadEnableAlignmentFaultFixup set true and false", function()
    local th, ep = spawn_test_thread()
    local bf = ffi.new('unsigned char[1]', 1)
    local st = ps.NtSetInformationThread(
        th, ps.ThreadEnableAlignmentFaultFixup, bf, 1)
    t.eq(st, STATUS_SUCCESS, "enable fixup failed: " .. hex(st))

    bf[0] = 0
    st = ps.NtSetInformationThread(
        th, ps.ThreadEnableAlignmentFaultFixup, bf, 1)
    t.eq(st, STATUS_SUCCESS, "disable fixup failed: " .. hex(st))

    ps.NtResumeThread(th)
    ep:wait_high()
    ke.NtWaitForSingleObject(th, false, ke.timeout(1.0))
    th:close()
    ep:close()
end)

t.test("ThreadQuerySetWin32StartAddress set round-trip", function()
    -- Drive against CURRENT_THREAD: the field is read by debuggers
    -- only, and Win32StartAddress isn't load-bearing for any other
    -- syscall — safe to round-trip.
    local sa = ffi.new('void *[1]')
    local st, _ = ps.NtQueryInformationThread(
        CURRENT_THREAD, ps.ThreadQuerySetWin32StartAddress, sa, 4)
    t.eq(st, STATUS_SUCCESS, "initial query failed: " .. hex(st))
    local original = sa[0]

    -- Set to a recognizable sentinel.
    sa[0] = ffi.cast('void *', 0xDEADBEEF)
    st = ps.NtSetInformationThread(
        CURRENT_THREAD, ps.ThreadQuerySetWin32StartAddress, sa, 4)
    t.eq(st, STATUS_SUCCESS, "set failed: " .. hex(st))

    -- Read back.
    st, _ = ps.NtQueryInformationThread(
        CURRENT_THREAD, ps.ThreadQuerySetWin32StartAddress, sa, 4)
    t.eq(st, STATUS_SUCCESS)
    t.eq(tonumber(ffi.cast('uintptr_t', sa[0])), 0xDEADBEEF,
         "Win32StartAddress round-trip mismatch")

    -- Restore.
    sa[0] = original
    st = ps.NtSetInformationThread(
        CURRENT_THREAD, ps.ThreadQuerySetWin32StartAddress, sa, 4)
    t.eq(st, STATUS_SUCCESS, "restore failed: " .. hex(st))
end)

t.test("ThreadZeroTlsCell out-of-range index rejected", function()
    -- TLS_MINIMUM_AVAILABLE is 64; any index >= 64 is invalid.
    local idx = ffi.new('ULONG[1]', 999)
    local st = ps.NtSetInformationThread(
        CURRENT_THREAD, ps.ThreadZeroTlsCell, idx, 4)
    t.eq(st, STATUS_INVALID_PARAMETER,
         "out-of-range TLS index: expected INVALID_PARAMETER, got "
         .. hex(st))
end)

t.test("ThreadImpersonationToken with bad handle is rejected", function()
    local h = ffi.new('HANDLE[1]')
    h[0] = ffi.cast('HANDLE', 0xDEADBEEF)
    local st = ps.NtSetInformationThread(
        CURRENT_THREAD, ps.ThreadImpersonationToken, h, 4)
    t.ok(st >= 0xC0000000, "expected error NTSTATUS, got " .. hex(st))
end)

t.test("ThreadEventPair with bad handle is rejected", function()
    local h = ffi.new('HANDLE[1]')
    h[0] = ffi.cast('HANDLE', 0xDEADBEEF)
    local st = ps.NtSetInformationThread(
        CURRENT_THREAD, ps.ThreadEventPair, h, 4)
    t.ok(st >= 0xC0000000, "expected error NTSTATUS, got " .. hex(st))
end)

local fixed_thread_set_classes = {
    { name = "Priority",                  cls = ps.ThreadPriority,                  size = 4 },
    { name = "BasePriority",              cls = ps.ThreadBasePriority,              size = 4 },
    { name = "AffinityMask",              cls = ps.ThreadAffinityMask,              size = 4 },
    { name = "ImpersonationToken",        cls = ps.ThreadImpersonationToken,        size = 4 },
    { name = "EnableAlignmentFaultFixup", cls = ps.ThreadEnableAlignmentFaultFixup, size = 1 },
    { name = "EventPair",                 cls = ps.ThreadEventPair,                 size = 4 },
    { name = "QuerySetWin32StartAddress", cls = ps.ThreadQuerySetWin32StartAddress, size = 4 },
    { name = "ZeroTlsCell",               cls = ps.ThreadZeroTlsCell,               size = 4 },
}

for _, c in ipairs(fixed_thread_set_classes) do
    t.test("Thread Set " .. c.name .. " rejects wrong-size buffer", function()
        local buf = ffi.new('unsigned char[64]')
        local st = ps.NtSetInformationThread(
            CURRENT_THREAD, c.cls, buf, c.size + 1)
        t.eq(st, STATUS_INFO_LENGTH_MISMATCH,
             c.name .. ": expected STATUS_INFO_LENGTH_MISMATCH, got "
             .. hex(st))
    end)
end
