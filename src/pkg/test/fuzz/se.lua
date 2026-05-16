-- test.fuzz.se — adversarial edge-case tests for SE syscalls.
--
-- These cover the SeCapture{Sid,Luid}AndAttributesArray bottom-of-the-
-- funnel cap added in SE/CAPTURE.C: hostile element counts on every
-- syscall that feeds those helpers must be rejected before any
-- multiply, allocation, or per-element loop runs.
--
-- The reach list (see docs-wip/syscall-audit/SUMMARY.md, pattern P3):
--   NtAdjustGroupsToken      via SeCaptureSidAndAttributesArray
--   NtAdjustPrivilegesToken  via SeCaptureLuidAndAttributesArray
--   NtPrivilegeCheck         via SeCaptureLuidAndAttributesArray
-- NtCreateToken also passes through both helpers but needs a fully-
-- formed TOKEN_USER + TOKEN_PRIMARY_GROUP to reach the count check;
-- the three syscalls above already exercise both helpers from each
-- side, so adding NtCreateToken would be redundant coverage at higher
-- buffer-shaping cost.
--
-- All three paths short-circuit on STATUS_INVALID_PARAMETER (0xC000000D)
-- when the count exceeds SEP_MAX_CAPTURE_COUNT (0x10000). Wrap-shaped
-- counts (0x15555556 for LUID arrays, 0x20000001 for SID arrays) and
-- saturated counts (MAXULONG) all funnel through the same cap.

local t      = require('test')
local se     = require('nt.dll.se')
local handle = require('nt.dll.handle')
local errmod = require('nt.dll.errors')
local ntdll  = require('nt.dll')
local ffi    = require('ffi')

local STATUS_INVALID_PARAMETER = 0xC000000D
local STATUS_SUCCESS           = 0x00000000

-- SEP_MAX_CAPTURE_COUNT in CAPTURE.C. Counts at or below this slip past
-- the cap; counts above are rejected outright. Pick representative
-- hostile counts that exercise wrap (for both element sizes) and
-- saturation.
local CAP_LIMIT = 0x10000
local HOSTILE_COUNTS = {
    { name = "cap+1",     count = CAP_LIMIT + 1 },
    { name = "wrap-luid", count = 0x15555556 },   -- *12 wraps a ULONG
    { name = "wrap-sid",  count = 0x20000001 },   -- *8  wraps a ULONG
    { name = "saturated", count = 0xFFFFFFFF },
}

t.suite("se: hardening (capture-helper cap)")

-- ------------------------------------------------------------------
-- NtAdjustPrivilegesToken — hostile PrivilegeCount.
--
-- TOKEN_PRIVILEGES on the wire is { ULONG PrivilegeCount;
-- LUID_AND_ATTRIBUTES Privileges[1]; }. We allocate a fully-readable
-- 256-byte buffer (well past sizeof(TOKEN_PRIVILEGES)) so the upfront
-- header probe doesn't fault.
--
-- TOKENADJ.C:191-199 then derives a second probe length from the
-- attacker-controlled count: ParameterLength = sizeof(TOKEN_PRIVILEGES)
-- + (count - 1) * sizeof(LUID_AND_ATTRIBUTES).  Depending on the count,
-- that value either lands in user space (probe passes -> capture cap
-- fires -> STATUS_INVALID_PARAMETER) or exceeds MmUserProbeAddress
-- (probe rejects -> STATUS_ACCESS_VIOLATION).  Both are clean
-- rejections; the test asserts the security property (no crash, error
-- NTSTATUS) rather than the specific rejecting layer.
-- ------------------------------------------------------------------

local function with_proc_token(access, fn)
    local tok = se.open_process_token{ access = access }
    local ok, ret = pcall(fn, tok)
    tok:close()
    if not ok then error(ret, 0) end
    return ret
end

for _, hc in ipairs(HOSTILE_COUNTS) do
    t.test(string.format(
        "NtAdjustPrivilegesToken rejects PrivilegeCount=%s (0x%x)",
        hc.name, hc.count), function()
        with_proc_token(
            se.TOKEN_QUERY + se.TOKEN_ADJUST_PRIVILEGES,
            function(tok)
                local buf = ffi.new('unsigned char[?]', 256)
                local hdr = ffi.cast('TOKEN_PRIVILEGES_HDR *', buf)
                hdr.PrivilegeCount = hc.count
                local st = errmod.normalize(
                    ntdll.NtAdjustPrivilegesToken(
                        handle.raw(tok), 0, buf, 256, nil, nil))
                t.ok(st >= 0xC0000000,
                     "expected error NTSTATUS, got "
                     .. string.format("0x%08x", st))
            end)
    end)
end

-- DisableAllPrivileges=TRUE with no NewState must still succeed
-- (no capture helper invoked). Confirms the cap doesn't regress
-- the no-input fast path.
t.test("NtAdjustPrivilegesToken disable-all still succeeds", function()
    with_proc_token(
        se.TOKEN_QUERY + se.TOKEN_ADJUST_PRIVILEGES,
        function(tok)
            local st = errmod.normalize(
                ntdll.NtAdjustPrivilegesToken(
                    handle.raw(tok), 1, nil, 0, nil, nil))
            t.eq(st, STATUS_SUCCESS,
                 "disable-all path, got " .. string.format("0x%08x", st))
        end)
end)

-- ------------------------------------------------------------------
-- NtAdjustGroupsToken — hostile GroupCount.
-- ------------------------------------------------------------------

for _, hc in ipairs(HOSTILE_COUNTS) do
    t.test(string.format(
        "NtAdjustGroupsToken rejects GroupCount=%s (0x%x)",
        hc.name, hc.count), function()
        with_proc_token(
            se.TOKEN_QUERY + se.TOKEN_ADJUST_GROUPS,
            function(tok)
                local buf = ffi.new('unsigned char[?]', 256)
                local hdr = ffi.cast('TOKEN_GROUPS_HDR *', buf)
                hdr.GroupCount = hc.count
                local st = errmod.normalize(
                    ntdll.NtAdjustGroupsToken(
                        handle.raw(tok), 0, buf, 256, nil, nil))
                t.eq(st, STATUS_INVALID_PARAMETER,
                     "expected STATUS_INVALID_PARAMETER, got "
                     .. string.format("0x%08x", st))
            end)
    end)
end

-- ResetToDefault=TRUE with no NewState must still succeed.
t.test("NtAdjustGroupsToken reset-to-default still succeeds", function()
    with_proc_token(
        se.TOKEN_QUERY + se.TOKEN_ADJUST_GROUPS,
        function(tok)
            local st = errmod.normalize(
                ntdll.NtAdjustGroupsToken(
                    handle.raw(tok), 1, nil, 0, nil, nil))
            t.eq(st, STATUS_SUCCESS,
                 "reset-to-default path, got " .. string.format("0x%08x", st))
        end)
end)

-- ------------------------------------------------------------------
-- NtPrivilegeCheck — hostile PrivilegeCount in PRIVILEGE_SET.
--
-- PRIVILEGE_SET = { ULONG PrivilegeCount; ULONG Control;
--                   LUID_AND_ATTRIBUTES Privilege[1]; }
-- Same dual-rejection shape as NtAdjustPrivilegesToken above: the
-- count-derived probe in PRIVILEG.C:339-347 either passes (cap fires
-- -> STATUS_INVALID_PARAMETER) or rejects with access violation;
-- both are clean.
-- ------------------------------------------------------------------

for _, hc in ipairs(HOSTILE_COUNTS) do
    t.test(string.format(
        "NtPrivilegeCheck rejects PrivilegeCount=%s (0x%x)",
        hc.name, hc.count), function()
        with_proc_token(se.TOKEN_QUERY, function(tok)
            local buf = ffi.new('unsigned char[?]', 256)
            local hdr = ffi.cast('PRIVILEGE_SET_HDR *', buf)
            hdr.PrivilegeCount = hc.count
            hdr.Control        = 0
            local result = ffi.new('BOOLEAN[1]')
            local st = errmod.normalize(
                ntdll.NtPrivilegeCheck(handle.raw(tok), buf, result))
            t.ok(st >= 0xC0000000,
                 "expected error NTSTATUS, got " .. string.format("0x%08x", st))
        end)
    end)
end

-- PrivilegeCount = 0 is a legitimate edge case: the capture helper
-- early-returns *CapturedArray=NULL with STATUS_SUCCESS, then the
-- success-path release in PRIVILEG.C:418 calls
-- SeReleaseLuidAndAttributesArray(NULL, ...).  Without the NULL
-- guard in the release helpers this bug-checks BAD_POOL_CALLER.
t.test("NtPrivilegeCheck succeeds on PrivilegeCount=0 (NULL-release path)", function()
    with_proc_token(se.TOKEN_QUERY, function(tok)
        local buf = ffi.new('unsigned char[?]', 16)
        local hdr = ffi.cast('PRIVILEGE_SET_HDR *', buf)
        hdr.PrivilegeCount = 0
        hdr.Control        = 0
        local result = ffi.new('BOOLEAN[1]')
        local st = errmod.normalize(
            ntdll.NtPrivilegeCheck(handle.raw(tok), buf, result))
        t.eq(st, STATUS_SUCCESS,
             "expected STATUS_SUCCESS, got " .. string.format("0x%08x", st))
        t.eq(result[0], 0,
             "empty privilege set with Control=0 -> not held")
    end)
end)

-- ------------------------------------------------------------------
-- NtDuplicateToken — TokenType validation.
--
-- TOKENDUP.C:150 originally used && where || was meant, making the
-- "is TokenType in {Primary, Impersonation}" check dead code.  Invalid
-- values silently passed through to SepDuplicateToken which is
-- fail-soft on unknown types.  Now they reject with
-- STATUS_INVALID_PARAMETER.
-- ------------------------------------------------------------------

local INVALID_TYPES = {
    { name = "zero",      value = 0 },
    { name = "out-of-range", value = 3 },
    { name = "saturated", value = 0xFFFFFFFF },
}

for _, it in ipairs(INVALID_TYPES) do
    t.test(string.format(
        "NtDuplicateToken rejects TokenType=%s (0x%x)", it.name, it.value),
    function()
        with_proc_token(se.TOKEN_QUERY + se.TOKEN_DUPLICATE, function(tok)
            local new_handle = ffi.new('HANDLE[1]')
            local st = errmod.normalize(ntdll.NtDuplicateToken(
                handle.raw(tok),
                se.TOKEN_ALL_ACCESS,
                nil,
                0,
                it.value,
                new_handle))
            t.eq(st, STATUS_INVALID_PARAMETER,
                 "expected STATUS_INVALID_PARAMETER, got "
                 .. string.format("0x%08x", st))
        end)
    end)
end

-- ==================================================================
-- se: hardening (kernel-range pointer-slot sweep)
--
-- A regression net for the deref-before-probe bug class -- pattern
-- P14 in docs-wip/syscall-audit/SUMMARY.md, written up as NT-BUGS.md
-- entry #5. The SE subsystem audited clean: every token syscall
-- probes each caller pointer with ProbeForRead/ProbeForWrite -- or
-- routes it through a self-probing SeCapture* helper -- before the
-- kernel dereferences it. These tests lock that in.
--
-- For every pointer argument of every audited SE token syscall, we
-- hand the kernel a kernel-range pointer in that one slot while every
-- other argument stays valid, then assert the call returns a clean
-- error NTSTATUS.
--
-- The property under test is bugcheck resistance. A kernel-range
-- fault is NOT catchable by __try: it bugchecks 0x50 or 0x1E straight
-- past SEH (see NT-BUGS.md #5). Only a ProbeForRead/Write range check
-- -- which runs *before* the deref and rejects the pointer as data --
-- stops it. So the in-process runner reaching t.summary() at all is
-- itself the assertion: a regression here removes a probe, the next
-- kernel-range slot faults, and the whole runner goes down with a STOP
-- screen instead of printing a failure line.
--
-- One hostile value (0x80000000, the first byte past
-- MmUserProbeAddress) suffices: when the probe is present every
-- kernel-range address is rejected identically by the same range
-- check; when it is absent any of them bugchecks. The value is kept
-- dword-aligned so the range check -- not the alignment check -- is
-- unambiguously the rejecting condition.
--
-- NtCreateToken is intentionally excluded, consistent with the cap
-- suite above: the eight syscalls swept here already exercise every
-- prologue probe shape (ProbeForRead, ProbeForWrite, ...Handle,
-- ...Ulong, ...Boolean, the count-derived re-probe, SeCaptureSecurityQos)
-- and both capture helpers; NtCreateToken would add heavy buffer
-- shaping for redundant coverage.
-- ------------------------------------------------------------------

t.suite("se: hardening (kernel-range pointer-slot sweep)")

-- First byte past MmUserProbeAddress. dword-aligned: the range check,
-- not the alignment check, is what must reject this.
local KERNEL_PTR = ffi.cast('void *', 0x80000000)

-- NT pseudo-handles -- NtCurrentProcess()/NtCurrentThread(). The Open*
-- token syscalls reference these only *after* probing TokenHandle, so
-- they stay valid enough to reach the probe under test.
local NtCurrentProcess = ffi.cast('void *', -1)
local NtCurrentThread  = ffi.cast('void *', -2)

-- Combined token access for the sweep. The four bits do not overlap,
-- so the file's existing `+` idiom is exact here.
local SWEEP_ACCESS = se.TOKEN_QUERY
                   + se.TOKEN_ADJUST_PRIVILEGES
                   + se.TOKEN_ADJUST_GROUPS
                   + se.TOKEN_DUPLICATE

-- Assert a syscall return is a clean error NTSTATUS. Reaching this
-- assertion at all means the kernel rejected the pointer as data and
-- did not fault on it.
local function rejects(st, slot)
    t.ok(st >= 0xC0000000,
         slot .. ": expected error NTSTATUS, got "
         .. string.format("0x%08x", st))
end

-- ---- NtOpenProcessToken / NtOpenThreadToken -- OUT TokenHandle ----
-- TokenHandle is probed (ProbeForWriteHandle) before the process/
-- thread handle is referenced, so a bad pseudo-handle is irrelevant.

t.test("NtOpenProcessToken rejects kernel-range TokenHandle", function()
    local st = errmod.normalize(ntdll.NtOpenProcessToken(
        NtCurrentProcess, se.TOKEN_QUERY, KERNEL_PTR))
    rejects(st, "NtOpenProcessToken/TokenHandle")
end)

t.test("NtOpenThreadToken rejects kernel-range TokenHandle", function()
    local st = errmod.normalize(ntdll.NtOpenThreadToken(
        NtCurrentThread, se.TOKEN_QUERY, 0, KERNEL_PTR))
    rejects(st, "NtOpenThreadToken/TokenHandle")
end)

-- ---- NtQueryInformationToken -- OUT TokenInformation, ReturnLength ----
-- Both are probed before the TokenInformationClass branch runs, so the
-- class value (1 = TokenUser) does not gate reaching the probe.

t.test("NtQueryInformationToken rejects kernel-range TokenInformation", function()
    with_proc_token(se.TOKEN_QUERY, function(tok)
        local ret_len = ffi.new('ULONG[1]')
        local st = errmod.normalize(ntdll.NtQueryInformationToken(
            handle.raw(tok), 1, KERNEL_PTR, 256, ret_len))
        rejects(st, "NtQueryInformationToken/TokenInformation")
    end)
end)

t.test("NtQueryInformationToken rejects kernel-range ReturnLength", function()
    with_proc_token(se.TOKEN_QUERY, function(tok)
        local buf = ffi.new('unsigned char[?]', 256)
        local st = errmod.normalize(ntdll.NtQueryInformationToken(
            handle.raw(tok), 1, buf, 256, KERNEL_PTR))
        rejects(st, "NtQueryInformationToken/ReturnLength")
    end)
end)

-- ---- NtSetInformationToken -- IN TokenInformation ----
-- ProbeForRead fires before the class-validity check, so an
-- unsettable class would still reach the probe first.

t.test("NtSetInformationToken rejects kernel-range TokenInformation", function()
    with_proc_token(se.TOKEN_QUERY, function(tok)
        local st = errmod.normalize(ntdll.NtSetInformationToken(
            handle.raw(tok), 1, KERNEL_PTR, 256))
        rejects(st, "NtSetInformationToken/TokenInformation")
    end)
end)

-- ---- NtAdjustPrivilegesToken -- IN NewState, OUT PreviousState/ReturnLength ----

t.test("NtAdjustPrivilegesToken rejects kernel-range NewState", function()
    with_proc_token(SWEEP_ACCESS, function(tok)
        -- DisableAllPrivileges=FALSE so NewState is reached and probed.
        local st = errmod.normalize(ntdll.NtAdjustPrivilegesToken(
            handle.raw(tok), 0, KERNEL_PTR, 0, nil, nil))
        rejects(st, "NtAdjustPrivilegesToken/NewState")
    end)
end)

t.test("NtAdjustPrivilegesToken rejects kernel-range PreviousState", function()
    with_proc_token(SWEEP_ACCESS, function(tok)
        -- PrivilegeCount=1 keeps the count-derived re-probe length
        -- equal to sizeof(TOKEN_PRIVILEGES) -- no (count-1) wrap -- so
        -- the prologue clears NewState and goes on to PreviousState.
        local nbuf = ffi.new('unsigned char[?]', 256)
        ffi.cast('TOKEN_PRIVILEGES_HDR *', nbuf).PrivilegeCount = 1
        local ret_len = ffi.new('ULONG[1]')
        local st = errmod.normalize(ntdll.NtAdjustPrivilegesToken(
            handle.raw(tok), 0, nbuf, 256, KERNEL_PTR, ret_len))
        rejects(st, "NtAdjustPrivilegesToken/PreviousState")
    end)
end)

t.test("NtAdjustPrivilegesToken rejects kernel-range ReturnLength", function()
    with_proc_token(SWEEP_ACCESS, function(tok)
        local nbuf = ffi.new('unsigned char[?]', 256)
        ffi.cast('TOKEN_PRIVILEGES_HDR *', nbuf).PrivilegeCount = 1
        local pbuf = ffi.new('unsigned char[?]', 256)
        local st = errmod.normalize(ntdll.NtAdjustPrivilegesToken(
            handle.raw(tok), 0, nbuf, 256, pbuf, KERNEL_PTR))
        rejects(st, "NtAdjustPrivilegesToken/ReturnLength")
    end)
end)

-- ---- NtAdjustGroupsToken -- IN NewState, OUT PreviousState/ReturnLength ----

t.test("NtAdjustGroupsToken rejects kernel-range NewState", function()
    with_proc_token(SWEEP_ACCESS, function(tok)
        -- ResetToDefault=FALSE so NewState is reached and probed.
        local st = errmod.normalize(ntdll.NtAdjustGroupsToken(
            handle.raw(tok), 0, KERNEL_PTR, 0, nil, nil))
        rejects(st, "NtAdjustGroupsToken/NewState")
    end)
end)

t.test("NtAdjustGroupsToken rejects kernel-range PreviousState", function()
    with_proc_token(SWEEP_ACCESS, function(tok)
        -- GroupCount=0: NewState clears its fixed-size probe and the
        -- capture helper early-returns, so the prologue advances to
        -- the PreviousState probe.
        local nbuf = ffi.new('unsigned char[?]', 256)
        ffi.cast('TOKEN_GROUPS_HDR *', nbuf).GroupCount = 0
        local ret_len = ffi.new('ULONG[1]')
        local st = errmod.normalize(ntdll.NtAdjustGroupsToken(
            handle.raw(tok), 0, nbuf, 256, KERNEL_PTR, ret_len))
        rejects(st, "NtAdjustGroupsToken/PreviousState")
    end)
end)

t.test("NtAdjustGroupsToken rejects kernel-range ReturnLength", function()
    with_proc_token(SWEEP_ACCESS, function(tok)
        local nbuf = ffi.new('unsigned char[?]', 256)
        ffi.cast('TOKEN_GROUPS_HDR *', nbuf).GroupCount = 0
        local pbuf = ffi.new('unsigned char[?]', 256)
        local st = errmod.normalize(ntdll.NtAdjustGroupsToken(
            handle.raw(tok), 0, nbuf, 256, pbuf, KERNEL_PTR))
        rejects(st, "NtAdjustGroupsToken/ReturnLength")
    end)
end)

-- ---- NtPrivilegeCheck -- IN RequiredPrivileges, OUT Result ----
-- NtPrivilegeCheck is the one SE syscall that references its handle
-- *before* probing pointers, so the token must be valid to reach
-- either probe.

t.test("NtPrivilegeCheck rejects kernel-range RequiredPrivileges", function()
    with_proc_token(se.TOKEN_QUERY, function(tok)
        local result = ffi.new('BOOLEAN[1]')
        local st = errmod.normalize(ntdll.NtPrivilegeCheck(
            handle.raw(tok), KERNEL_PTR, result))
        rejects(st, "NtPrivilegeCheck/RequiredPrivileges")
    end)
end)

t.test("NtPrivilegeCheck rejects kernel-range Result", function()
    with_proc_token(se.TOKEN_QUERY, function(tok)
        -- Valid empty PRIVILEGE_SET so the prologue clears
        -- RequiredPrivileges and goes on to probe Result.
        local buf = ffi.new('unsigned char[?]', 16)
        local hdr = ffi.cast('PRIVILEGE_SET_HDR *', buf)
        hdr.PrivilegeCount = 0
        hdr.Control        = 0
        local st = errmod.normalize(ntdll.NtPrivilegeCheck(
            handle.raw(tok), buf, KERNEL_PTR))
        rejects(st, "NtPrivilegeCheck/Result")
    end)
end)

-- ---- NtDuplicateToken -- IN ObjectAttributes, OUT NewTokenHandle ----
-- TokenType is validated before the probes, so it is kept valid
-- (1 = TokenPrimary) to reach them.

t.test("NtDuplicateToken rejects kernel-range NewTokenHandle", function()
    with_proc_token(SWEEP_ACCESS, function(tok)
        local st = errmod.normalize(ntdll.NtDuplicateToken(
            handle.raw(tok), se.TOKEN_ALL_ACCESS, nil, 0, 1, KERNEL_PTR))
        rejects(st, "NtDuplicateToken/NewTokenHandle")
    end)
end)

t.test("NtDuplicateToken rejects kernel-range ObjectAttributes", function()
    with_proc_token(SWEEP_ACCESS, function(tok)
        -- NewTokenHandle valid so the prologue reaches
        -- SeCaptureSecurityQos, which probes ObjectAttributes.
        local new_handle = ffi.new('HANDLE[1]')
        local st = errmod.normalize(ntdll.NtDuplicateToken(
            handle.raw(tok), se.TOKEN_ALL_ACCESS, KERNEL_PTR, 0, 1,
            new_handle))
        rejects(st, "NtDuplicateToken/ObjectAttributes")
    end)
end)

-- ---- NtAccessCheck -- five prologue-probed pointers ----
--
-- SecurityDescriptor is intentionally not swept: it is OPTIONAL and
-- captured deep in the body by the shared SeCaptureSecurityDescriptor
-- helper, not by a prologue probe -- it is not a P14 prologue
-- deref-before-probe surface. The five pointers below are all probed
-- in the prologue, before ClientToken is referenced, so the call
-- never reaches the token-type check and a primary token is fine.

local ACCESSCHECK_SLOTS = {
    "AccessStatus", "GrantedAccess", "PrivilegeSetLength",
    "PrivilegeSet", "GenericMapping",
}

for _, slot in ipairs(ACCESSCHECK_SLOTS) do
    t.test("NtAccessCheck rejects kernel-range " .. slot, function()
        with_proc_token(se.TOKEN_QUERY, function(tok)
            -- All-valid scratch; the one slot under test is poisoned.
            -- PrivilegeSetLength points to 256 so the kernel probes
            -- exactly the 256-byte PrivilegeSet buffer.
            local gmap     = ffi.new('GENERIC_MAPPING[1]')
            local pset     = ffi.new('unsigned char[?]', 256)
            local pset_len = ffi.new('ULONG[1]', 256)
            local granted  = ffi.new('ACCESS_MASK[1]')
            local status   = ffi.new('NTSTATUS[1]')

            local a_gmap     = (slot == "GenericMapping")     and KERNEL_PTR or gmap
            local a_pset     = (slot == "PrivilegeSet")       and KERNEL_PTR or pset
            local a_pset_len = (slot == "PrivilegeSetLength") and KERNEL_PTR or pset_len
            local a_granted  = (slot == "GrantedAccess")      and KERNEL_PTR or granted
            local a_status   = (slot == "AccessStatus")       and KERNEL_PTR or status

            local st = errmod.normalize(ntdll.NtAccessCheck(
                nil, handle.raw(tok), 1, a_gmap, a_pset, a_pset_len,
                a_granted, a_status))
            rejects(st, "NtAccessCheck/" .. slot)
        end)
    end)
end

