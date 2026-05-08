-- os — Lua-side os module over nt.dll (ke + rtl + ps + fs).
--
-- Time helpers use deterministic fixed Unix epochs so the round-trip
-- through NtQuerySystemTime / RtlTimeToTimeFields / RtlTimeFieldsToTime
-- is exact-equality-checkable (no flaky "current time" assertions).
--
-- Lifetime audit while reading these tests:
--   * os.remove and os.rename internally open a handle (NT_HANDLE),
--     issue NtSetInformationFile, then close. Failure paths use pcall
--     inside os.lua so we get nil + errmsg here instead of an unwound
--     structured error.
--   * os.getenv passes UTF-8 through to RtlQueryEnvironmentVariable_U
--     via the str.to_utf16 / str.from_utf16 fused-cdata path. No raw
--     buffers leak across the syscall boundary.

local t  = require('test')
local os = require('os')
local ke = require('nt.dll.ke')

t.suite("os")

-- Per-run-unique scratch names: prevents pollution across runs when a
-- test fails before its post-cleanup runs.  Earlier runs' SCRATCH_B
-- could leak with a SD that denies even DELETE, breaking
-- reset_scratch and cascading NAME_COLLISION into later tests.  Tag
-- on os.time() so each invocation is its own namespace.
local _RUN_TAG  = tostring(os.time())
local SCRATCH_A = "\\SystemRoot\\__test_os_" .. _RUN_TAG .. "_a.tmp"
local SCRATCH_B = "\\SystemRoot\\__test_os_" .. _RUN_TAG .. "_b.tmp"

local function reset_scratch()
    os.remove(SCRATCH_A)
    os.remove(SCRATCH_B)
end

-- ------------------------------------------------------------------
-- time / date / difftime
-- ------------------------------------------------------------------

t.test("os.time() returns a number; skip post-2026 check if no RTC", function()
    local now = os.time()
    t.eq(type(now), "number")
    -- The RTC isn't wired up in this build — the kernel boots SYSTEM_TIME
    -- at 0 (1601-01-01) and only advances it by uptime ticks. Once an
    -- RTC driver lands and we see post-Unix-epoch values, tighten this
    -- assertion to `now >= 1767225600` (2026-01-01).
    if now < 0 then
        t.skip("system time pre-1970 (no RTC) — got " .. tostring(now))
    end
    t.ok(now >= 1767225600, "now=" .. tostring(now))
end)

t.test("os.time(table) round-trips through os.date('*t')", function()
    -- 2026-04-25 12:34:56 UTC.
    local secs = os.time{year=2026, month=4, day=25,
                         hour=12, min=34, sec=56}
    t.eq(type(secs), "number")
    local tab = os.date("*t", secs)
    t.eq(tab.year,  2026)
    t.eq(tab.month, 4)
    t.eq(tab.day,   25)
    t.eq(tab.hour,  12)
    t.eq(tab.min,   34)
    t.eq(tab.sec,   56)
    t.eq(tab.isdst, false)
    -- 2026-04-25 was a Saturday → Lua wday=7.
    t.eq(tab.wday,  7)
    -- Day of year: Jan(31)+Feb(28)+Mar(31)+Apr 25 = 115. 2026 is not leap.
    t.eq(tab.yday,  115)
end)

t.test("os.time on invalid table fields raises", function()
    t.raises(function()
        os.time{year=2026, month=13, day=1}    -- month=13 is bogus
    end, "fields")
end)

t.test("os.time table missing required fields raises", function()
    t.raises(function() os.time{year=2026} end, "year/month/day")
end)

t.test("os.date format string emits %Y/%m/%d/%H/%M/%S", function()
    local secs = os.time{year=2024, month=2, day=29,         -- leap day
                         hour=23, min=59, sec=58}
    t.eq(os.date("%Y-%m-%d %H:%M:%S", secs), "2024-02-29 23:59:58")
end)

t.test("os.date format string handles %a/%A/%b/%B/%j/%p/%%", function()
    local secs = os.time{year=2024, month=2, day=29,         -- Thursday
                         hour=15, min=0, sec=0}
    t.eq(os.date("%a", secs), "Thu")
    t.eq(os.date("%A", secs), "Thursday")
    t.eq(os.date("%b", secs), "Feb")
    t.eq(os.date("%B", secs), "February")
    t.eq(os.date("%j", secs), "060",   "31 (Jan) + 29 (Feb leap day)")
    t.eq(os.date("%p", secs), "PM")
    t.eq(os.date("%% literal", secs), "% literal")
end)

t.test("os.date('!*t') matches os.date('*t') (UTC-only platform)", function()
    local secs = os.time{year=2026, month=4, day=25, hour=12, min=0, sec=0}
    local utc   = os.date("!*t", secs)
    local local_t = os.date("*t",  secs)
    t.eq(utc.year,  local_t.year)
    t.eq(utc.month, local_t.month)
    t.eq(utc.day,   local_t.day)
    t.eq(utc.hour,  local_t.hour)
    t.eq(utc.min,   local_t.min)
    t.eq(utc.sec,   local_t.sec)
end)

t.test("os.date with no fmt defaults to %c", function()
    -- Just check it returns a string with the year in it; the exact
    -- formatting of %c is non-essential to test.
    local s = os.date(nil, os.time{year=2026, month=1, day=1,
                                    hour=0, min=0, sec=0})
    t.ok(s:match("2026"), "%c output contains the year: " .. s)
end)

t.test("os.difftime", function()
    t.eq(os.difftime(100, 40), 60)
    t.eq(os.difftime(0, 1), -1)
end)

-- ------------------------------------------------------------------
-- clock — monotonic
-- ------------------------------------------------------------------

t.test("os.clock is monotonic across a sleep", function()
    local a = os.clock()
    -- 50ms — long enough to advance any reasonable clock backend.
    ke.NtDelayExecution(false, ke.timeout(0.05))
    local b = os.clock()
    t.ok(b >= a, string.format("a=%g b=%g", a, b))
    t.ok(b - a >= 0.04,
         string.format("expected >= 40ms elapsed, got %g", b - a))
end)

-- ------------------------------------------------------------------
-- getenv
-- ------------------------------------------------------------------

t.test("os.getenv on missing variable returns nil", function()
    t.eq(os.getenv("__definitely_not_set__"), nil)
end)

t.test("os.getenv returns a string when the var is set", function()
    -- We can't predict what's in the env on this VM; SystemRoot / Path
    -- are written to the registry but propagation to per-process env
    -- depends on smss/init wiring. Check whichever is actually there;
    -- skip if neither is populated.
    local sr = os.getenv("SystemRoot")
    local pa = os.getenv("Path")
    if sr == nil and pa == nil then
        t.skip("no env vars propagated to this process")
    end
    if sr ~= nil then t.eq(type(sr), "string") end
    if pa ~= nil then t.eq(type(pa), "string") end
end)

t.test("os.getenv rejects non-string argument", function()
    t.raises(function() os.getenv(42) end, "string")
end)

-- ------------------------------------------------------------------
-- remove / rename
-- ------------------------------------------------------------------

t.test("os.remove on nonexistent file returns nil + errmsg", function()
    reset_scratch()
    local ok, errmsg = os.remove("\\SystemRoot\\__nope_" ..
                                  tostring(os.time()) .. ".tmp")
    t.eq(ok, nil)
    t.ok(errmsg and #errmsg > 0)
end)

t.test("os.remove deletes an existing file", function()
    reset_scratch()
    local io = require('io')
    local f = io.open(SCRATCH_A, "wb"); f:write("scratch"); f:close()
    -- Confirm it exists by reopening for read.
    local r = io.open(SCRATCH_A, "rb")
    t.ne(r, nil)
    r:close()

    t.eq(os.remove(SCRATCH_A), true)

    -- Now opening it should fail.
    local r2, _err = io.open(SCRATCH_A, "rb")
    t.eq(r2, nil, "file is gone after os.remove")
end)

t.test("DELETE-access open + close (no rename) preserves access", function()
    -- Isolate the "open A with DELETE access then close" step from
    -- the rename pipeline, without doing a rename in between.  If
    -- THIS test passes, the DELETE open-close is harmless and the
    -- bug is specific to set_rename.  If it fails, the bug is in
    -- the DELETE-access open-close itself (something about closing
    -- a DELETE-access handle is corrupting/swapping the file's SD).
    reset_scratch()
    local io  = require('io')
    local fs  = require('nt.dll.fs')
    local oa  = require('nt.dll.oa')
    local bit = require('bit')

    local f = io.open(SCRATCH_A, "wb"); f:write("payload"); f:close()

    -- Open with DELETE+SYNCHRONIZE -- exactly what os.rename does --
    -- but immediately close without invoking set_rename.
    local h = fs.NtOpenFile(
        bit.bor(fs.DELETE, fs.SYNCHRONIZE),
        oa.path(SCRATCH_A).oa,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        fs.FILE_SYNCHRONOUS_IO_NONALERT)
    h:close()

    -- Now reopen for read: should work since SD wasn't touched.
    local r, err = io.open(SCRATCH_A, "rb")
    t.ne(r, nil, "reopen A after DELETE open-close: " .. tostring(err))
    if r then
        t.eq(r:read("*a"), "payload", "content preserved")
        r:close()
    end
    os.remove(SCRATCH_A)
end)


t.test("os.rename moves an existing file", function()
    -- Diagnostic-heavy version while we chase why post-rename opens
    -- fail with STATUS_ACCESS_DENIED.  We probe multiple access masks
    -- on B and use NtQueryAttributesFile (which doesn't open a handle)
    -- to confirm the file is on disk and queryable independent of any
    -- access check.  Cross-test state leaks are avoided via per-run-
    -- unique SCRATCH_* names.
    reset_scratch()
    local io  = require('io')
    local fs  = require('nt.dll.fs')
    local oa  = require('nt.dll.oa')
    local bit = require('bit')

    local f = io.open(SCRATCH_A, "wb"); f:write("payload"); f:close()

    -- Helper: list \SystemRoot and find an entry whose name ends with
    -- our test tag.  Returns {found, name, attrs} for diagnostic.
    local function find_entry(want_basename)
        local ok_p, names = pcall(function()
            local fs2 = require('nt.dll.fs')
            return fs2.list_dir("\\SystemRoot\\")
        end)
        if not ok_p then return {ok=false, err=tostring(names)} end
        for _, n in ipairs(names) do
            if n == want_basename then
                return {ok=true, found=true, name=n}
            end
        end
        return {ok=true, found=false, count=#names}
    end

    -- Control: open A with FILE_READ_ATTRIBUTES BEFORE the rename, to
    -- confirm the freshly-created file's SD does grant minimal access.
    local ctrl_h, ctrl_err = pcall(fs.NtOpenFile,
        bit.bor(fs.FILE_READ_ATTRIBUTES, fs.SYNCHRONIZE),
        oa.path(SCRATCH_A).oa,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        fs.FILE_SYNCHRONOUS_IO_NONALERT)
    -- pcall(fs.NtOpenFile, ...) returns (true, NT_HANDLE_cdata) on
    -- success.  NT_HANDLE is FFI cdata, type() == "cdata" -- the
    -- old "userdata" check was always false and produced bogus
    -- error reports.
    if ctrl_h then ctrl_err:close() end

    -- Pre-rename: confirm A appears in directory listing.
    local pre_a = find_entry(SCRATCH_A:match("[^\\]+$"))

    local ok, errmsg = os.rename(SCRATCH_A, SCRATCH_B)
    t.eq(ok, true, "rename failed: " .. tostring(errmsg))

    -- Post-rename: confirm B appears (and A doesn't) in directory listing.
    local post_a = find_entry(SCRATCH_A:match("[^\\]+$"))
    local post_b = find_entry(SCRATCH_B:match("[^\\]+$"))

    -- ---- Probes (all run regardless of individual outcomes) ----
    local function probe_open(label, access)
        local ok_p, h_or_err = pcall(fs.NtOpenFile,
            bit.bor(access, fs.SYNCHRONIZE),
            oa.path(SCRATCH_B).oa,
            bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
            fs.FILE_SYNCHRONOUS_IO_NONALERT)
        if ok_p then
            h_or_err:close()
            return label .. ": ok"
        end
        return label .. ": err=" .. tostring(h_or_err)
    end

    -- (0) Pre-rename control on A.
    local ctrl_msg = ctrl_h and "ok" or ("err=" .. tostring(ctrl_err))

    -- (1) NtQueryAttributesFile on B: doesn't open a handle.
    local attr_ok, attr_val = pcall(function()
        return fs.query_attributes(SCRATCH_B)
    end)
    local attr_msg = attr_ok
        and (attr_val and ("ok, attrs=" .. tostring(attr_val.FileAttributes))
                      or  "nil (NOT_FOUND)")
        or  ("err=" .. tostring(attr_val))

    -- (2..5) Various access masks.
    local read_attr_msg = probe_open("FILE_READ_ATTRIBUTES",  fs.FILE_READ_ATTRIBUTES)
    local read_data_msg = probe_open("FILE_READ_DATA",        fs.FILE_READ_DATA)
    local generic_msg   = probe_open("FILE_GENERIC_READ",     fs.FILE_GENERIC_READ)
    local delete_msg    = probe_open("DELETE",                fs.DELETE)

    -- (6) Source A post-rename.
    local r_a, err_a = io.open(SCRATCH_A, "rb")
    if r_a then r_a:close() end
    local a_msg = r_a and "openable (rename did NOT move)" or
                          ("nil, err=" .. tostring(err_a))

    -- (7) Sibling sanity probe.  If the parent directory \SystemRoot's
    --     own SD got corrupted by the rename's index write, traverse
    --     access for ALL files under \SystemRoot would be denied.
    --     Open a known-good unrelated file as the canary.  If THIS
    --     fails too, the rename is corrupting the parent dir, not the
    --     renamed file.
    local sibling_h, sibling_err = pcall(fs.NtOpenFile,
        bit.bor(fs.FILE_READ_ATTRIBUTES, fs.SYNCHRONIZE),
        oa.path("\\SystemRoot\\SYSTEM32\\KERNEL32.DLL").oa,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        fs.FILE_SYNCHRONOUS_IO_NONALERT)
    if sibling_h and type(sibling_err) == 'userdata' then sibling_err:close() end
    local sibling_msg = sibling_h and "ok (parent dir SD intact)" or
                                      ("err=" .. tostring(sibling_err))

    -- Single combined report.  All probe data appears here regardless
    -- of which individual probes failed.  The assertion succeeds only
    -- if the simple case (FILE_GENERIC_READ on B) works -- otherwise
    -- the failure surface dumps every probe so we see the full
    -- accessibility profile of the post-rename file.
    local function dir_msg(d)
        if not d.ok then return "list err: " .. d.err end
        if d.found then return "FOUND ('" .. d.name .. "')" end
        return "MISSING (out of " .. d.count .. " entries)"
    end

    t.ok(generic_msg == "FILE_GENERIC_READ: ok",
         "\n  pre-rename A FILE_READ_ATTRIBUTES: " .. ctrl_msg ..
         "\n  pre-rename dir listing has A:      " .. dir_msg(pre_a) ..
         "\n  post-rename dir listing has A:     " .. dir_msg(post_a) ..
         "\n  post-rename dir listing has B:     " .. dir_msg(post_b) ..
         "\n  B query_attributes:                " .. attr_msg ..
         "\n  B " .. read_attr_msg ..
         "\n  B " .. read_data_msg ..
         "\n  B " .. generic_msg ..
         "\n  B " .. delete_msg ..
         "\n  A post-rename:                     " .. a_msg ..
         "\n  sibling kernel32.dll:              " .. sibling_msg)
end)

t.test("os.rename on nonexistent source returns nil + errmsg", function()
    reset_scratch()
    local ok, errmsg = os.rename(
        "\\SystemRoot\\__not_there_" .. tostring(os.time()) .. ".tmp",
        SCRATCH_B)
    t.eq(ok, nil)
    t.ok(errmsg and #errmsg > 0)
end)

-- ------------------------------------------------------------------
-- Rename triangulation tests
-- ------------------------------------------------------------------
--
-- The "os.rename moves an existing file" test reopens via the new full
-- path "\SystemRoot\__test_os_b.tmp" and currently fails with
-- STATUS_ACCESS_DENIED.  Whether the bug is in NT 3.5's full-path
-- rename pipe (IopOpenLinkOrRenameTarget) or in the post-rename open
-- path is unclear from the failure alone.  These tests narrow it down.
--
-- Probes go through nt.dll.fs / nt.dll.oa directly so we can vary
-- exactly the rename target shape (basename vs full path) and the
-- post-rename access pattern without bouncing through os.rename.

t.test("rename: same-dir, basename-only target", function()
    -- If THIS works and the full-path equivalent fails, the bug lives
    -- in the I/O manager's full-path rename target resolution
    -- (IopOpenLinkOrRenameTarget) or NTFS's TargetFileObject branch
    -- in NtfsFindTargetElements -- not in the rename core or the
    -- post-rename open.
    --
    -- Use independent scratch names so this test isn't poisoned when
    -- the prior "os.rename moves an existing file" test leaks its
    -- SCRATCH_B (its post-rename cleanup can't run when an earlier
    -- assertion fires; B's stuck SD then denies reset_scratch).
    local SRC = "\\SystemRoot\\__test_basename_" .. _RUN_TAG .. "_src.tmp"
    local DST = "\\SystemRoot\\__test_basename_" .. _RUN_TAG .. "_dst.tmp"
    os.remove(SRC); os.remove(DST)

    local io  = require('io')
    local fs  = require('nt.dll.fs')
    local oa  = require('nt.dll.oa')
    local bit = require('bit')

    local f = io.open(SRC, "wb"); f:write("payload"); f:close()

    -- Open SRC with DELETE access, set rename to *just* the basename
    -- of DST (no leading backslash).  NT interprets this as "rename
    -- within the source's parent directory", skipping the
    -- IopOpenLinkOrRenameTarget code path entirely.  Wrap the
    -- set_rename call in pcall + always-close so a NAME_COLLISION /
    -- ACCESS_DENIED raise doesn't leak the handle.
    local h = fs.NtOpenFile(
        bit.bor(fs.DELETE, fs.SYNCHRONIZE),
        oa.path(SRC).oa,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        fs.FILE_SYNCHRONOUS_IO_NONALERT)
    local dst_basename = DST:match("[^\\]+$")
    local rename_ok, rename_err = pcall(fs.set_rename, h, dst_basename, false)
    h:close()
    t.ok(rename_ok, "basename rename: " .. tostring(rename_err))
    if not rename_ok then return end

    -- SRC should be gone, DST should be openable.
    local r_a, err_a = io.open(SRC, "rb")
    t.eq(r_a, nil, "SRC still openable after basename-rename: " .. tostring(err_a))
    local r_b, err_b = io.open(DST, "rb")
    t.ne(r_b, nil, "DST not openable after basename-rename: " .. tostring(err_b))
    if r_b then
        t.eq(r_b:read("*a"), "payload", "DST content preserved")
        r_b:close()
    end
    os.remove(DST)
end)


t.test("rename: across directories preserves content", function()
    -- Cross-directory rename: source and destination live in different
    -- parents, so the I/O manager must walk the destination path
    -- through IopOpenLinkOrRenameTarget and NTFS must update both
    -- parent indexes.  Distinct from the same-dir basename case.
    local fs  = require('nt.dll.fs')
    local PA  = "\\SystemRoot\\__xrn_" .. _RUN_TAG .. "_a"
    local PB  = "\\SystemRoot\\__xrn_" .. _RUN_TAG .. "_b"
    local hA, _ = fs.create_dir(PA); hA:close()
    local hB, _ = fs.create_dir(PB); hB:close()
    local SRC = PA .. "\\src.tmp"
    local DST = PB .. "\\dst.tmp"
    local io  = require('io')
    local f = io.open(SRC, "wb"); f:write("crossing"); f:close()

    local ok, errmsg = os.rename(SRC, DST)
    t.eq(ok, true, "cross-dir rename failed: " .. tostring(errmsg))

    -- Source dir is empty; destination dir has just dst.tmp.
    t.eq(#fs.list_dir(PA), 0, "src dir has no entries after rename")
    local dstlist = fs.list_dir(PB)
    t.eq(#dstlist, 1, "dst dir has exactly one entry")
    t.eq(dstlist[1], "dst.tmp")

    -- Content survived.
    local r = io.open(DST, "rb")
    t.ne(r, nil, "DST not openable after cross-dir rename")
    if r then
        t.eq(r:read("*a"), "crossing", "content preserved across rename")
        r:close()
    end
end)

-- ------------------------------------------------------------------
-- Stubbed / unsupported surface
-- ------------------------------------------------------------------

t.test("os.setlocale returns 'C'", function()
    t.eq(os.setlocale(),     "C")
    t.eq(os.setlocale("en_US"), "C")
end)

t.test("os.execute / popen / tmpname / tmpfile raise", function()
    t.raises(os.execute, "execute")
    t.raises(os.popen,   "popen")
    t.raises(os.tmpname, "tmpname")
    t.raises(os.tmpfile, "tmpfile")
end)

-- os.exit is intentionally not tested — it terminates the process and
-- would take the test runner with it. The wrapper is exercised at
-- selftest end via the existing NtShutdownSystem path.
