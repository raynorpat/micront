-- EX coverage completionist suite -- the remaining NTOS/EX
-- syscalls bound in nt.dll.ex that don't slot naturally into
-- test/sync.lua (sync primitives), test/iocp.lua (IoCompletion),
-- test/harderr.lua (hard-error port), or test/sys.lua (system info).
--
-- Covers:
--   SYSTIME.C:  NtSetSystemTime, NtQueryTimerResolution, NtSetTimerResolution
--   PROFILE.C:  NtCreateProfile + Start/Stop, NtSetIntervalProfile, NtQueryIntervalProfile
--   EVENTPR.C:  NtSetHighWaitLowThread, NtSetLowWaitHighThread (per-thread variants)
--   DBGCTRL.C:  NtSystemDebugControl (bind-only smoke)
--   SYSENV.C:   NtQuerySystemEnvironmentValue / NtSetSystemEnvironmentValue (smoke)

local ffi    = require('ffi')
local bit    = require('bit')
local t      = require('test')
local ex     = require('nt.dll.ex')
local ke     = require('nt.dll.ke')
local se     = require('nt.dll.se')
local errs   = require('nt.dll.errors')
local ntdll  = require('nt.dll')

t.suite("ex_misc")

-- ------------------------------------------------------------------
-- SYSTIME.C
-- ------------------------------------------------------------------

t.test("NtQueryTimerResolution returns sane max/min/current", function()
    local r = ex.NtQueryTimerResolution()
    -- Typical NT 3.5 PIT values: max ~156250 (15.625ms), min ~10000
    -- (1ms).  Current is between them.  We just assert the ordering
    -- invariant and that current is in range -- not exact values
    -- since the HAL (microvm vs piix vs ...) sets the actual clock
    -- rate.
    t.ok(r.max > 0,           "max > 0")
    t.ok(r.min > 0,           "min > 0")
    t.ok(r.current > 0,       "current > 0")
    t.ok(r.min <= r.max,      "min <= max (finer res = smaller number)")
    t.ok(r.current >= r.min,  "current >= min")
    t.ok(r.current <= r.max,  "current <= max")
end)

t.test("NtSetTimerResolution request + release", function()
    local before = ex.NtQueryTimerResolution()
    -- set=true requests the kernel honour `desired` (which it clamps
    -- to its supported range and returns as ActualTime).
    local actual_set = ex.NtSetTimerResolution(before.min, true)
    t.ok(actual_set > 0,
         "ActualTime after set=true: " .. tostring(actual_set))
    -- set=false releases the request -- legal AFTER a set=true call.
    -- Without a prior set=true the kernel returns
    -- STATUS_TIMER_RESOLUTION_NOT_SET, which is the correct error
    -- but isn't what we want to verify here.
    local actual_rel = ex.NtSetTimerResolution(before.min, false)
    t.ok(actual_rel > 0,
         "ActualTime after release: " .. tostring(actual_rel))
    local after = ex.NtQueryTimerResolution()
    t.eq(after.max, before.max, "max stable across set/release")
    t.eq(after.min, before.min, "min stable across set/release")
end)

t.test("NtSetSystemTime read-back round-trip preserves the clock", function()
    -- Query the current wall-clock, set it to that exact value,
    -- verify the PreviousTime out-param matches what we just read.
    -- Doesn't actually move the clock so the rest of the selftest's
    -- monotonic-time assumptions stay valid.
    -- SeSystemtimePrivilege is required.  with_privileges enables
    -- for the body and drops afterwards so other suites can't
    -- inherit the privilege accidentally.
    local now = ffi.new('LARGE_INTEGER')
    ntdll.NtQuerySystemTime(now)
    local prev = se.with_privileges({"SeSystemtimePrivilege"}, function()
        return ex.NtSetSystemTime(now)
    end)
    -- prev should be within a few ticks of `now` (the kernel grabbed
    -- the old value at syscall entry; some ticks may have elapsed).
    -- 50_000_000 ticks = 5 seconds (1 tick = 100ns).
    local delta = (prev.QuadPart > now.QuadPart)
        and (prev.QuadPart - now.QuadPart)
        or  (now.QuadPart - prev.QuadPart)
    t.ok(delta < 50000000,
         "previous time within 5s of queried time: delta=" .. tostring(delta))
end)

-- ------------------------------------------------------------------
-- PROFILE.C
-- ------------------------------------------------------------------

t.test("NtSetIntervalProfile + NtQueryIntervalProfile roundtrip", function()
    -- NT 3.5 has exactly one profile source (the timer).  Save the
    -- current interval, set a known value, query it back, restore.
    -- Kernel clamps to its supported range, so the returned value
    -- may differ slightly from what we set; just verify the call
    -- chain works.
    local original = ex.NtQueryIntervalProfile()
    t.ok(original > 0, "original interval > 0")

    -- 100000 ticks = 10ms in 100ns ticks.
    ex.NtSetIntervalProfile(100000)
    local got = ex.NtQueryIntervalProfile()
    t.ok(got > 0, "queried interval after set > 0: " .. tostring(got))

    -- Restore (some implementations clamp aggressively; the restore
    -- call must not raise even if the value gets clamped).
    ex.NtSetIntervalProfile(original)
end)

-- Shared lifecycle exerciser for both per-process and system-wide
-- profile paths.  Caller controls how the profile object is created;
-- the rest of the lifecycle (set interval, start, busy-loop, stop,
-- walk buffer) is identical.  The test is structured around "did the
-- syscall chain succeed" rather than "did the sampler catch a hit" --
-- catching hits in a 200ms busy loop calling NtQuerySystemTime is
-- flaky because most CPU goes through the kernel for that syscall
-- and only the user-mode call+ret stub falls in our profile range.
-- We log the hit count for diagnostic visibility but don't fail on 0.
local function exercise_profile(label, create_fn)
    local handle  = require('nt.dll.handle')
    local fn_addr = tonumber(ffi.cast('uintptr_t', ntdll.NtQuerySystemTime))
    local PROFILE_SIZE     = 0x10000   -- 64 KB
    local BUCKET_SIZE_LOG2 = 6         -- 2^6 = 64-byte buckets
    local NUM_BUCKETS      = PROFILE_SIZE / (2 ^ BUCKET_SIZE_LOG2)
    local base_addr = bit.band(fn_addr - 0x1000, bit.bnot(0xfff))
    local base_ptr  = ffi.cast('void *', base_addr)
    local buffer    = ffi.new('ULONG[?]', NUM_BUCKETS)

    local profile = create_fn{
        base             = base_ptr,
        size             = PROFILE_SIZE,
        bucket_size_log2 = BUCKET_SIZE_LOG2,
        buffer           = buffer,
        buffer_size      = NUM_BUCKETS * ffi.sizeof('ULONG'),
    }
    t.ok(profile, label .. ": NtCreateProfile returned a handle")

    local res = ex.NtQueryTimerResolution()
    ex.NtSetIntervalProfile(res.min)

    ex.NtStartProfile(profile)

    local deadline = ffi.new('LARGE_INTEGER')
    ntdll.NtQuerySystemTime(deadline)
    deadline.QuadPart = deadline.QuadPart + 2000000  -- +200ms
    local now = ffi.new('LARGE_INTEGER')
    local iters = 0
    while true do
        ntdll.NtQuerySystemTime(now)
        if now.QuadPart >= deadline.QuadPart then break end
        iters = iters + 1
    end
    t.ok(iters > 100, label .. ": tight loop ran enough iterations: " .. iters)

    ex.NtStopProfile(profile)

    -- Hit-count diagnostic.  Not asserted -- the sampler may catch
    -- zero EIP samples in our user-mode ntdll-stub range during the
    -- busy loop (most time spent in kernel servicing the syscall).
    local total_hits = 0
    for i = 0, NUM_BUCKETS - 1 do
        total_hits = total_hits + tonumber(buffer[i])
    end
    -- Logged for visibility; pass-only assertion.
    t.ok(true,
         label .. ": lifecycle complete (hits=" .. total_hits ..
         " across " .. NUM_BUCKETS .. " buckets, " ..
         iters .. " loop iters)")

    profile:close()
end

-- Per-process path: Process != NULL.  No privilege required;
-- PROFILE.C:379-394 ObReferenceObjectByHandle's the target process
-- and proceeds.
t.test("NtCreateProfile per-process (Process=NtCurrentProcess)", function()
    local handle = require('nt.dll.handle')
    exercise_profile("per-process", function(opts)
        opts.process = handle.NtCurrentProcess()
        return ex.NtCreateProfile(opts)
    end)
end)

-- System-wide path: Process == NULL.  PROFILE.C:355-376 requires
-- SeSystemProfilePrivilege when RangeBase is in user-mode space
-- (our ntdll window is).  with_privileges enables for the body and
-- drops afterwards.  Stock NT 3.5's SeMakeSystemToken didn't include
-- this privilege in the system token's assigned set (csrss was
-- expected to get it from SAM at logon); MicroNT's SE/TOKEN.C now
-- assigns it directly to the system token so the selftest can
-- enable it.
t.test("NtCreateProfile system-wide (Process=NULL + SeSystemProfilePrivilege)", function()
    se.with_privileges({"SeSystemProfilePrivilege"}, function()
        exercise_profile("system-wide", function(opts)
            opts.process = nil   -- NULL = profile all processes
            return ex.NtCreateProfile(opts)
        end)
    end)
end)

-- ------------------------------------------------------------------
-- EVENTPR.C -- thread-side EventPair variants.
--
-- These require csrss to have attached an EventPair to the thread
-- via NtSetInformationThread(ThreadEventPair).  MicroNT never does
-- so; the calls return STATUS_NO_EVENT_PAIR (0xC000014E).
-- ------------------------------------------------------------------

t.test("NtSetHighWaitLowThread fails cleanly without thread EventPair", function()
    local ok, e = pcall(ex.NtSetHighWaitLowThread)
    t.ok(not ok, "NtSetHighWaitLowThread should fail without csrss setup")
    -- Whatever the exact NTSTATUS (STATUS_NO_EVENT_PAIR is the
    -- documented one), the call surfaces an err.raise table; the
    -- important property is that the binding is reachable and we
    -- get a structured error not a crash.
    t.ok(type(e) == 'table' or type(e) == 'string',
         "error surfaced as table/string: " .. tostring(e))
end)

t.test("NtSetLowWaitHighThread also fails cleanly", function()
    local ok, e = pcall(ex.NtSetLowWaitHighThread)
    t.ok(not ok, "NtSetLowWaitHighThread should fail without csrss setup")
    t.ok(type(e) == 'table' or type(e) == 'string',
         "error surfaced as table/string: " .. tostring(e))
end)

-- ------------------------------------------------------------------
-- DBGCTRL.C -- NtSystemDebugControl, bind-only smoke.
-- ------------------------------------------------------------------

t.test("NtSystemDebugControl is bound (symbol resolves)", function()
    t.ok(type(ex.NtSystemDebugControl) == 'function',
         "ex.NtSystemDebugControl should be a function")
    -- Invoking it requires either KD-attached or SeDebugPrivilege +
    -- a valid command/buffer pair.  We don't test the call here; the
    -- binding is what we needed.
end)

-- ------------------------------------------------------------------
-- SYSENV.C -- firmware environment, bind-only smoke.
-- ------------------------------------------------------------------

t.test("NtQuerySystemEnvironmentValue is bound and rejects cleanly", function()
    -- MicroNT's HAL doesn't expose firmware env vars; the call
    -- returns STATUS_NOT_IMPLEMENTED (0xC0000002) or similar.  We
    -- just verify the binding doesn't crash and returns an error
    -- status via the second-return-value channel.
    local val, st = ex.NtQuerySystemEnvironmentValue("BootOptions")
    t.eq(val, nil, "no value returned (firmware vars unimplemented)")
    t.ok(st ~= 0, "status is non-success: 0x" .. bit.tohex(st or 0))
end)

t.test("NtSetSystemEnvironmentValue is bound and rejects cleanly", function()
    local st = ex.NtSetSystemEnvironmentValue("BootOptions", "discard-me")
    t.ok(st ~= 0, "set returns non-success on missing firmware: 0x"
                  .. bit.tohex(st or 0))
end)

-- ------------------------------------------------------------------
-- SYSINFO.C -- default-locale Query/Set.
-- ------------------------------------------------------------------

t.test("NtQueryDefaultLocale returns a non-zero LCID", function()
    -- System default.  NT 3.5 boot stamps a default at init time
    -- (typically 0x0409 = en-US absent a registry override).
    local sys_lcid = ex.NtQueryDefaultLocale(false)
    t.ok(sys_lcid ~= 0, "system LCID non-zero: 0x" .. bit.tohex(sys_lcid))

    -- Per-user default (kernel returns the same value if no user
    -- registry override).
    local usr_lcid = ex.NtQueryDefaultLocale(true)
    t.ok(usr_lcid ~= 0, "user LCID non-zero: 0x" .. bit.tohex(usr_lcid))
end)

t.test("NtSetDefaultLocale round-trip + restore", function()
    -- Save -> set to same value -> verify query returns it.  Doesn't
    -- actually move the locale so concurrent code that reads the
    -- LCID still sees the right thing.
    --
    -- System path (user_profile=false) writes to
    --   HKLM\System\CurrentControlSet\Control\Nls\Language!Default
    -- which our core layer seeds with "00000409" (en-US) -- see
    -- src/pkg/ntosbe/layers/core.lua.  Requires SeSystemtimePrivilege
    -- (assigned-but-disabled in our system token; with_privileges
    -- enables for the body and drops afterwards).
    --
    -- The per-user path (user_profile=true) writes to HKCU which
    -- doesn't exist on MicroNT ([[project_advapi32_owned]]: HKCU
    -- deferred) -- not tested here.
    local before = ex.NtQueryDefaultLocale(false)
    se.with_privileges({"SeSystemtimePrivilege"}, function()
        ex.NtSetDefaultLocale(false, before)
    end)
    local after = ex.NtQueryDefaultLocale(false)
    t.eq(after, before, "round-trip preserved LCID 0x" .. bit.tohex(before))
end)
