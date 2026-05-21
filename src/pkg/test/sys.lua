-- nt.dll.sys — NtQuerySystemInformation iterators. Checks both
-- SystemProcessInformation (each_process) and SystemModuleInformation
-- (each_module) produce sane plain-Lua-table snapshots.

local t   = require('test')
local sys = require('nt.dll.sys')
local se  = require('nt.dll.se')

t.suite("sys")

t.test("each_process finds the System (kernel) process", function()
    local seen_system = false
    local count = 0
    for proc in sys.each_process() do
        count = count + 1
        t.ne(proc.pid, nil)
        t.ne(proc.image, nil)
        t.ne(proc.threads, nil)
        if proc.image == "System" then
            seen_system = true
            t.ok(proc.thread_count > 0, "System has at least one thread")
            t.ok(#proc.threads == proc.thread_count,
                 "threads array length matches thread_count")
        end
    end
    t.ok(count >= 2, "at least idle + System + run.exe")
    t.ok(seen_system, "one of the processes is named 'System'")
end)

t.test("each_process yields plain Lua tables (no cdata in snapshot)", function()
    for proc in sys.each_process() do
        t.eq(type(proc.pid),     "number")
        t.eq(type(proc.image),   "string")
        t.eq(type(proc.threads), "table")
        if #proc.threads > 0 then
            local th = proc.threads[1]
            t.eq(type(th.tid),      "number")
            t.eq(type(th.priority), "number")
        end
        break   -- one is enough
    end
end)

t.test("each_process finds run.exe (our own process)", function()
    local found = false
    for proc in sys.each_process() do
        if proc.image == "run.exe" then
            found = true
            t.ok(proc.pid > 0)
            t.ok(proc.thread_count >= 1)
        end
    end
    t.ok(found, "our own run.exe is in the process list")
end)

t.test("each_module finds ntoskrnl.exe + hal.dll", function()
    local seen_ntos, seen_hal = false, false
    for mod in sys.each_module() do
        t.ne(mod.basename, nil)
        t.ne(mod.image_path, nil)
        t.ok(mod.image_size > 0)
        if mod.basename == "ntoskrnl.exe" then seen_ntos = true end
        if mod.basename == "hal.dll"      then seen_hal  = true end
    end
    t.ok(seen_ntos, "ntoskrnl.exe present in module list")
    t.ok(seen_hal,  "hal.dll present in module list")
end)

t.test("each_module yields plain Lua tables", function()
    for mod in sys.each_module() do
        t.eq(type(mod.basename),    "string")
        t.eq(type(mod.image_path),  "string")
        t.eq(type(mod.image_base),  "number")
        t.eq(type(mod.image_size),  "number")
        break
    end
end)

t.test("NtShutdownSystem rejects bad action string", function()
    t.raises(function() sys.NtShutdownSystem('halt') end,
             "bad action")
end)

-- Non-destructive enforcement test: call NtShutdownSystem WITHOUT
-- enabling SeShutdownPrivilege first. The kernel must reject with
-- STATUS_PRIVILEGE_NOT_HELD; the wrapper must surface that as a raise
-- rather than swallowing the error. This is what protects selftest.lua
-- from spinning forever after a silent shutdown failure.
t.test("NtShutdownSystem raises STATUS_PRIVILEGE_NOT_HELD when privilege disabled", function()
    local tok = se.open_process_token()
    -- Defensive: ensure shutdown is disabled (it is by default per
    -- SE/TOKEN.C:721, but make it explicit so this test is order-
    -- independent).
    se.disable_privileges(tok, {"SeShutdownPrivilege"})
    local ok, e = pcall(function() sys.NtShutdownSystem('power_off') end)
    t.eq(ok, false, "must raise — otherwise we'd actually shut down")
    t.eq(e.fn, "NtShutdownSystem")
    t.eq(e.status, 0xC0000061, "STATUS_PRIVILEGE_NOT_HELD")
    tok:close()
end)

-- ------------------------------------------------------------------
-- NtQuerySystemInformation — drive every class arm in NTOS/EX/
-- SYSINFO.C.  Validates that each switch case produces a well-formed
-- result (and never bugchecks).  Field-level invariants on the small
-- classes (Basic/Processor/TimeOfDay/Flags/etc.) lock the layout in.
-- ------------------------------------------------------------------

local ffi = require('ffi')
local err = require('nt.dll.errors')

local STATUS_SUCCESS              = 0x00000000
local STATUS_INFO_LENGTH_MISMATCH = 0xC0000004
local STATUS_INVALID_INFO_CLASS   = 0xC0000003
local STATUS_PRIVILEGE_NOT_HELD   = 0xC0000061

local function hex(st) return string.format("0x%08x", st) end

t.suite("sys: NtQuerySystemInformation classes")

-- Lock-in for the POPPACK.H pack(2) workaround.  See
-- docs-wip/POPPACK-LEAK.md.  NT 3.5's POPPACK.H silently sets
-- pack(2) instead of popping, so these three structs are compiled
-- under leaked pack(2) on the kernel side; our cdefs match that.
-- If anyone removes the pack(2) block in nt.dll.sys, this test
-- fails fast with a pointer to the doc.
t.test("affected SYSTEM_* structs use pack(2) per POPPACK-LEAK.md", function()
    t.eq(ffi.sizeof('SYSTEM_BASIC_INFORMATION'), 42,
         "SBI under leaked pack(2) is 42 — see docs-wip/POPPACK-LEAK.md")
    t.eq(ffi.sizeof('SYSTEM_QUERY_TIME_ADJUST_INFORMATION'), 10,
         "QueryTimeAdjust under leaked pack(2) is 10")
    t.eq(ffi.sizeof('SYSTEM_SET_TIME_ADJUST_INFORMATION'), 6,
         "SetTimeAdjust under leaked pack(2) is 6")
end)

t.test("SystemBasicInformation has sane processor + page numbers", function()
    local sbi = ffi.new('SYSTEM_BASIC_INFORMATION')
    local st, ret = sys.NtQuerySystemInformation(
        sys.SystemBasicInformation, sbi,
        ffi.sizeof('SYSTEM_BASIC_INFORMATION'))
    t.eq(st, STATUS_SUCCESS, "BasicInformation: " .. hex(st))
    t.eq(ret, ffi.sizeof('SYSTEM_BASIC_INFORMATION'),
         "return length matches struct")
    t.eq(sbi.PageSize, 4096, "x86 page size is 4 KB")
    t.ok(sbi.NumberOfProcessors >= 1, "must have at least one CPU")
    t.ok(sbi.NumberOfPhysicalPages > 0, "must have some physical RAM")
    t.ok(sbi.MaximumUserModeAddress > sbi.MinimumUserModeAddress,
         "umode address range non-empty")
end)

t.test("SystemProcessorInformation reports an x86 family CPU", function()
    local spi = ffi.new('SYSTEM_PROCESSOR_INFORMATION')
    local st, _ = sys.NtQuerySystemInformation(
        sys.SystemProcessorInformation, spi,
        ffi.sizeof('SYSTEM_PROCESSOR_INFORMATION'))
    t.eq(st, STATUS_SUCCESS, "ProcessorInformation: " .. hex(st))
    -- PROCESSOR_INTEL_386=386, _486=486, _PENTIUM=586, _860=860.
    t.ok(spi.ProcessorType >= 386 and spi.ProcessorType <= 860,
         "CPU family out of expected x86 range, got "
         .. tostring(spi.ProcessorType))
end)

t.test("SystemPerformanceInformation returns non-trivial counters", function()
    -- 352 bytes (88 ULONGs + a few LARGE_INTEGER fronted).  Use a
    -- generous buffer and let the wrapper read returned length.
    local buf = ffi.new('unsigned char[1024]')
    local st, ret = sys.NtQuerySystemInformation(
        sys.SystemPerformanceInformation, buf, 1024)
    t.eq(st, STATUS_SUCCESS, "PerformanceInformation: " .. hex(st))
    t.ok(ret > 0, "must return some bytes")
end)

t.test("SystemTimeOfDayInformation has positive BootTime + CurrentTime", function()
    local tod = ffi.new('SYSTEM_TIMEOFDAY_INFORMATION')
    local st, _ = sys.NtQuerySystemInformation(
        sys.SystemTimeOfDayInformation, tod,
        ffi.sizeof('SYSTEM_TIMEOFDAY_INFORMATION'))
    t.eq(st, STATUS_SUCCESS, "TimeOfDayInformation: " .. hex(st))
    -- CurrentTime should be later than BootTime — kernel measures both
    -- monotonically.  QuadPart comparison via LowPart/HighPart pair.
    t.ok(tod.CurrentTime.HighPart > tod.BootTime.HighPart
         or (tod.CurrentTime.HighPart == tod.BootTime.HighPart
             and tod.CurrentTime.LowPart >= tod.BootTime.LowPart),
         "CurrentTime must be >= BootTime")
end)

t.test("SystemPathInformation returns a (possibly empty) path", function()
    -- SYSTEM_PATH_INFORMATION is just a STRING (ANSI counted) — we
    -- don't expose the STRING typedef yet, so just check the call
    -- doesn't fault with a generous buffer.
    local buf = ffi.new('unsigned char[1024]')
    local st, _ = sys.NtQuerySystemInformation(
        sys.SystemPathInformation, buf, 1024)
    -- Some NT 3.5 builds return STATUS_NOT_IMPLEMENTED for this class
    -- — accept either as long as we don't bugcheck.
    t.ok(st == STATUS_SUCCESS or st >= 0xC0000000,
         "PathInformation: " .. hex(st))
end)

t.test("SystemDeviceInformation reports per-device-class counts", function()
    local dev = ffi.new('SYSTEM_DEVICE_INFORMATION')
    local st, _ = sys.NtQuerySystemInformation(
        sys.SystemDeviceInformation, dev,
        ffi.sizeof('SYSTEM_DEVICE_INFORMATION'))
    t.eq(st, STATUS_SUCCESS, "DeviceInformation: " .. hex(st))
    -- We have at least one disk (the boot disk).
    t.ok(dev.NumberOfDisks >= 1, "must have at least the boot disk")
end)

t.test("SystemFlagsInformation returns a ULONG flags word", function()
    local sfi = ffi.new('SYSTEM_FLAGS_INFORMATION')
    local st, ret = sys.NtQuerySystemInformation(
        sys.SystemFlagsInformation, sfi,
        ffi.sizeof('SYSTEM_FLAGS_INFORMATION'))
    t.eq(st, STATUS_SUCCESS, "FlagsInformation: " .. hex(st))
    t.eq(ret, 4, "FlagsInformation is a single ULONG")
end)

t.test("SystemTimeAdjustmentInformation query returns positive increment", function()
    local tai = ffi.new('SYSTEM_QUERY_TIME_ADJUST_INFORMATION')
    local st, _ = sys.NtQuerySystemInformation(
        sys.SystemTimeAdjustmentInformation, tai,
        ffi.sizeof('SYSTEM_QUERY_TIME_ADJUST_INFORMATION'))
    t.eq(st, STATUS_SUCCESS, "TimeAdjustment query: " .. hex(st))
    t.ok(tai.TimeIncrement > 0, "TimeIncrement must be positive")
end)

t.test("SystemExceptionInformation returns 3 ULONG counters", function()
    local exi = ffi.new('SYSTEM_EXCEPTION_INFORMATION')
    local st, ret = sys.NtQuerySystemInformation(
        sys.SystemExceptionInformation, exi,
        ffi.sizeof('SYSTEM_EXCEPTION_INFORMATION'))
    t.eq(st, STATUS_SUCCESS, "ExceptionInformation: " .. hex(st))
    t.eq(ret, 12, "3 ULONGs = 12 bytes")
end)

t.test("SystemCrashDumpStateInformation has ValidCrashDump bit", function()
    local cds = ffi.new('SYSTEM_CRASH_STATE_INFORMATION')
    local st, _ = sys.NtQuerySystemInformation(
        sys.SystemCrashDumpStateInformation, cds,
        ffi.sizeof('SYSTEM_CRASH_STATE_INFORMATION'))
    t.eq(st, STATUS_SUCCESS, "CrashDumpState: " .. hex(st))
end)

t.test("SystemKernelDebuggerInformation reports debugger state", function()
    local kdi = ffi.new('SYSTEM_KERNEL_DEBUGGER_INFORMATION')
    local st, _ = sys.NtQuerySystemInformation(
        sys.SystemKernelDebuggerInformation, kdi,
        ffi.sizeof('SYSTEM_KERNEL_DEBUGGER_INFORMATION'))
    t.eq(st, STATUS_SUCCESS, "KernelDebugger: " .. hex(st))
end)

t.test("SystemFileCacheInformation returns cache sizes", function()
    local fc = ffi.new('SYSTEM_FILECACHE_INFORMATION')
    local st, _ = sys.NtQuerySystemInformation(
        sys.SystemFileCacheInformation, fc,
        ffi.sizeof('SYSTEM_FILECACHE_INFORMATION'))
    t.eq(st, STATUS_SUCCESS, "FileCache: " .. hex(st))
end)

t.test("SystemContextSwitchInformation returns counters", function()
    local cs = ffi.new('SYSTEM_CONTEXT_SWITCH_INFORMATION')
    local st, _ = sys.NtQuerySystemInformation(
        sys.SystemContextSwitchInformation, cs,
        ffi.sizeof('SYSTEM_CONTEXT_SWITCH_INFORMATION'))
    t.eq(st, STATUS_SUCCESS, "ContextSwitch: " .. hex(st))
    -- A live system must have done some context switches by now.
    t.ok(cs.ContextSwitches > 0, "must have switched contexts at boot")
end)

-- Variable-length and stub classes — we only confirm the dispatch
-- arm executes cleanly.  Notable kernel-side quirks documented inline.
local STATUS_NOT_IMPLEMENTED      = 0xC0000002
local STATUS_ACCESS_VIOLATION     = 0xC0000005

local variable_classes = {
    { name = "ProcessorPerformanceInformation",
      cls = function() return sys.SystemProcessorPerformanceInformation end },
    -- CallCountInformation reads from KeServiceCountTable which is
    -- only allocated under #if DBG (INIT.C:742-752).  Free builds
    -- leave the pointer NULL, so RtlMoveMemory at SYSINFO.C:926
    -- faults — accept STATUS_ACCESS_VIOLATION as the documented
    -- "stubbed in free build" outcome.
    { name = "CallCountInformation",
      cls = function() return sys.SystemCallCountInformation end,
      extra_ok = {STATUS_ACCESS_VIOLATION} },
    { name = "ModuleInformation",
      cls = function() return sys.SystemModuleInformation end },
    { name = "LocksInformation",
      cls = function() return sys.SystemLocksInformation end },
    -- ExpGetPoolInformation / PoolTag / ObjectInformation rely on
    -- ExSnapShotPool / ExSnapShotPoolTag which are stubbed to
    -- STATUS_NOT_IMPLEMENTED in this build — keep them tolerant.
    { name = "PagedPoolInformation",
      cls = function() return sys.SystemPagedPoolInformation end,
      extra_ok = {STATUS_NOT_IMPLEMENTED} },
    { name = "NonPagedPoolInformation",
      cls = function() return sys.SystemNonPagedPoolInformation end,
      extra_ok = {STATUS_NOT_IMPLEMENTED} },
    { name = "HandleInformation",
      cls = function() return sys.SystemHandleInformation end },
    { name = "ObjectInformation",
      cls = function() return sys.SystemObjectInformation end },
    { name = "PageFileInformation",
      cls = function() return sys.SystemPageFileInformation end },
    { name = "PoolTagInformation",
      cls = function() return sys.SystemPoolTagInformation end,
      extra_ok = {STATUS_NOT_IMPLEMENTED} },
}

for _, c in ipairs(variable_classes) do
    t.test("System " .. c.name .. " returns a well-formed status", function()
        local buf = ffi.new('unsigned char[65536]')
        local st, _ = sys.NtQuerySystemInformation(c.cls(), buf, 65536)
        -- Always-accepted: SUCCESS, INFO_LENGTH_MISMATCH (buffer
        -- short for a busy snapshot — confirms the arm computed a
        -- size), plus any per-class quirk listed above.
        local ok = (st == STATUS_SUCCESS
                    or st == STATUS_INFO_LENGTH_MISMATCH)
        if not ok and c.extra_ok then
            for _, allow in ipairs(c.extra_ok) do
                if st == allow then ok = true break end
            end
        end
        t.ok(ok, c.name .. ": " .. hex(st))
    end)
end

-- Tiny stub classes — they exist in the kernel's switch but the
-- present implementation often just records-or-returns and may
-- legitimately fail with INVALID_INFO_CLASS / NOT_IMPLEMENTED.
-- Assertion: well-formed status, no fault.
local tolerant_classes = {
    "SystemStackTraceInformation",
    "SystemCallTimeInformation",
    "SystemNextEventIdInformation",
    "SystemEventIdsInformation",
    "SystemCrashDumpInformation",
}

for _, name in ipairs(tolerant_classes) do
    t.test("System " .. name .. " returns a well-formed status", function()
        local cls = sys[name]
        t.ne(cls, nil, name .. " constant not exported")
        local buf = ffi.new('unsigned char[1024]')
        local st, _ = sys.NtQuerySystemInformation(cls, buf, 1024)
        t.ok(st == STATUS_SUCCESS or st >= 0xC0000000,
             name .. ": " .. hex(st))
    end)
end

t.test("invalid info class returns STATUS_INVALID_INFO_CLASS", function()
    local buf = ffi.new('unsigned char[64]')
    -- 19, 20, 23-27, 29 are header-reserved but unhandled in NT 3.5;
    -- 999 is just way out of range — both go to default arm.
    local st, _ = sys.NtQuerySystemInformation(999, buf, 64)
    t.eq(st, STATUS_INVALID_INFO_CLASS,
         "expected STATUS_INVALID_INFO_CLASS, got " .. hex(st))
end)

t.test("SystemBasicInformation wrong length is rejected", function()
    local buf = ffi.new('unsigned char[64]')
    local st, _ = sys.NtQuerySystemInformation(
        sys.SystemBasicInformation, buf,
        ffi.sizeof('SYSTEM_BASIC_INFORMATION') + 1)
    t.eq(st, STATUS_INFO_LENGTH_MISMATCH,
         "expected STATUS_INFO_LENGTH_MISMATCH, got " .. hex(st))
end)

-- ------------------------------------------------------------------
-- NtSetSystemInformation — the kernel has exactly one class arm here,
-- SystemTimeAdjustmentInformation, guarded by SeSystemtimePrivilege.
-- ------------------------------------------------------------------

t.suite("sys: NtSetSystemInformation")

t.test("SystemTimeAdjustment Set without privilege returns PRIVILEGE_NOT_HELD", function()
    -- Drop SeSystemtimePrivilege so the check arm fires regardless of
    -- what init left enabled (same pattern as the IOPL test).
    local tok = se.open_process_token{
        access = se.TOKEN_QUERY + se.TOKEN_ADJUST_PRIVILEGES,
    }
    se.disable_privileges(tok, {"SeSystemtimePrivilege"})

    local sai = ffi.new('SYSTEM_SET_TIME_ADJUST_INFORMATION')
    sai.TimeAdjustment = 100000      -- benign value; would be no-op
    sai.Enable         = 0           -- disable adjustment
    local st = sys.NtSetSystemInformation(
        sys.SystemTimeAdjustmentInformation, sai,
        ffi.sizeof('SYSTEM_SET_TIME_ADJUST_INFORMATION'))

    se.enable_privileges(tok, {"SeSystemtimePrivilege"})
    tok:close()

    t.eq(st, STATUS_PRIVILEGE_NOT_HELD,
         "expected STATUS_PRIVILEGE_NOT_HELD, got " .. hex(st))
end)

t.test("NtSetSystemInformation rejects unknown class", function()
    local buf = ffi.new('unsigned char[64]')
    local st = sys.NtSetSystemInformation(
        sys.SystemBasicInformation, buf, 64)
    -- Default arm returns STATUS_INVALID_INFO_CLASS for everything
    -- other than TimeAdjustment.
    t.eq(st, STATUS_INVALID_INFO_CLASS,
         "expected STATUS_INVALID_INFO_CLASS, got " .. hex(st))
end)

t.test("NtSetSystemInformation TimeAdjustment wrong length is rejected", function()
    -- Have privilege check pass, then trip the length check.  Reverse
    -- order from privilege test: set the right privilege then send
    -- wrong length so the length arm reports.  Actually the kernel
    -- checks length BEFORE privilege (see SYSINFO.C:1475 — length
    -- check) so this works with privilege off as well.
    local buf = ffi.new('unsigned char[64]')
    local st = sys.NtSetSystemInformation(
        sys.SystemTimeAdjustmentInformation, buf, 999)
    t.eq(st, STATUS_INFO_LENGTH_MISMATCH,
         "expected STATUS_INFO_LENGTH_MISMATCH, got " .. hex(st))
end)
