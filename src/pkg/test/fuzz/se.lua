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

