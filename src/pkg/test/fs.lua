-- nt.dll.fs — File / device I/O, info queries, directory enumeration.

local ffi = require('ffi')
local t   = require('test')
local fs  = require('nt.dll.fs')
local oa  = require('nt.dll.oa')
local str = require('nt.dll.str')

t.suite("fs")

-- Constants live in nt.dll.fs — don't shadow them with local
-- redefines.  Pull them off the module by their canonical names.
local bit = require('bit')

local function open_with(access, path)
    return fs.NtOpenFile(bit.bor(access, fs.SYNCHRONIZE), oa.path(path).oa,
                         bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
                         fs.FILE_SYNCHRONOUS_IO_NONALERT)
end

local function open_ro(path)
    return open_with(fs.FILE_READ_DATA, path)
end

t.test("NtOpenFile on \\Device\\Null", function()
    local h = open_ro("\\Device\\Null")
    t.ne(h, nil)
    h:close()
end)

t.test("NtOpenFile on missing path raises", function()
    t.raises(function() open_ro("\\Device\\NoSuchThing") end)
end)

t.test("Null device reads return EOF (0 bytes)", function()
    local h = open_ro("\\Device\\Null")
    local buf = ffi.new('char[16]')
    local n, st = fs.NtReadFile(h, buf, 16, nil)
    -- Some NT versions return 0 bytes with SUCCESS; others with
    -- STATUS_END_OF_FILE. Either is acceptable — we just assert no
    -- data came out.
    t.eq(n, 0)
    t.ok(st == 0 or st == fs.STATUS_END_OF_FILE,
         string.format("status=0x%x", st))
    h:close()
end)

-- Use kernel32.dll as the canonical large PE on \SystemRoot — both
-- ntoskrnl.exe and hal.dll are routed where='esp' (boot-efi reads them
-- pre-handoff) and so don't appear under \SystemRoot in split layouts.
-- kernel32.dll is default-routed (system partition), is a real PE so
-- its MZ magic + size assertions still mean something, and is a more
-- honest target for "the kind of file user-mode actually opens".
t.test("NtQueryInformationFile(Standard) on a real file reports size", function()
    local h = open_ro("\\SystemRoot\\SYSTEM32\\KERNEL32.DLL")
    local info = fs.query_standard(h)
    t.ok(info.EndOfFile.QuadPart > 100000,
         "kernel32.dll is larger than 100KB")
    t.eq(info.Directory, 0, "kernel32.dll is not a directory")
    t.eq(info.NumberOfLinks, 1)
    h:close()
end)

t.test("NtQueryInformationFile(Basic) on kernel32 reports attributes", function()
    -- FileBasicInformation needs FILE_READ_ATTRIBUTES on the handle;
    -- FILE_READ_DATA alone gives STATUS_ACCESS_DENIED on NT 3.5.
    local h = open_with(bit.bor(fs.FILE_READ_DATA, fs.FILE_READ_ATTRIBUTES),
                        "\\SystemRoot\\SYSTEM32\\KERNEL32.DLL")
    local info = fs.query_basic(h)
    -- FILE_ATTRIBUTE_ARCHIVE = 0x20, _DIRECTORY = 0x10. We don't insist
    -- on an exact mask — just that the directory bit is clear.
    t.eq(ffi.cast('uint32_t', info.FileAttributes) % 0x20, 0,
         "directory bit clear")
    h:close()
end)

t.test("NtReadFile reads MZ magic from kernel32", function()
    local h = open_ro("\\SystemRoot\\SYSTEM32\\KERNEL32.DLL")
    local buf = ffi.new('char[2]')
    local n = fs.NtReadFile(h, buf, 2, nil)
    t.eq(n, 2)
    t.eq(buf[0], string.byte("M"))
    t.eq(buf[1], string.byte("Z"))
    h:close()
end)

t.test("NtQueryDirectoryFile enumerates \\SystemRoot\\", function()
    local h = open_ro("\\SystemRoot\\")
    -- Confirm it's flagged as a directory first.
    local info = fs.query_standard(h)
    t.ok(info.Directory ~= 0, "opened \\SystemRoot\\ is a directory")
    local buf   = ffi.new('char[4096]')
    local seen  = {}
    local first = true
    while true do
        local len, st = fs.NtQueryDirectoryFile(h, buf, 4096, first)
        first = false
        if st == fs.STATUS_NO_MORE_FILES or len == 0 then break end
        local off = 0
        while true do
            local e = ffi.cast('FILE_DIRECTORY_INFORMATION *',
                                ffi.cast('char *', buf) + off)
            local name = str.from_wchars(e.FileName, e.FileNameLength / 2)
            if name ~= "." and name ~= ".." then
                -- FS-agnostic indexing: NTFS preserves case ("System32"),
                -- FAT up-cases ("SYSTEM32").  Fold here so the assertions
                -- below work on both.
                seen[name:upper()] = e.FileAttributes
            end
            if e.NextEntryOffset == 0 then break end
            off = off + e.NextEntryOffset
        end
    end
    h:close()
    -- The selftest system partition has System32 / lua / tmp; we index
    -- `seen` upper-cased so this matches whether the FS preserves case
    -- ("System32") or folds it ("SYSTEM32").  pkg/ is NOT asserted: it
    -- is staged only by the msvc layer (the selfhost profile, not
    -- selftest).  EFI lives only on the ESP, which isn't \SystemRoot in
    -- split layouts.
    t.ne(seen.SYSTEM32, nil, "SYSTEM32 present")
    t.ne(seen.LUA,      nil, "LUA present")
end)

t.test("Directory enumeration on non-directory returns empty/fails", function()
    -- Opening a regular file then issuing NtQueryDirectoryFile should
    -- fail with a parameter/device error — our wrapper raises on it.
    local h = open_ro("\\SystemRoot\\SYSTEM32\\KERNEL32.DLL")
    local buf = ffi.new('char[1024]')
    t.raises(function() fs.NtQueryDirectoryFile(h, buf, 1024, true) end)
    h:close()
end)

-- ------------------------------------------------------------------
-- Directory index regression coverage
-- ------------------------------------------------------------------
--
-- These tests exercise INDEXSUP.C's three insert paths in turn:
--   * InsertSimpleRoot           — entry fits in resident $INDEX_ROOT
--   * PushIndexRoot              — root → nonresident migration (~16-20)
--   * InsertSimpleAllocation     — entry fits in an index buffer
--   * InsertWithBufferSplit      — buffer full, split into two (~50-80)
--
-- The bug originally surfaced as "i=1..5 created but invisible to
-- enumeration" — NtfsWriteLog under FRS<cluster passed cluster units,
-- but Vcb->ClustersPerFileRecordSegment is 0 there, so the open
-- attribute table entry was never created and log records were
-- malformed.  NT 4.0 byte-form WriteLog backport fixed it; these
-- tests guard against regression.

t.test("Multi-create stress: probe insert paths through buffer split", function()
    local os  = require('os')
    local tag = tostring(os.time())
    local DIR = "\\SystemRoot\\__idx_stress_" .. tag
    -- 64 entries is enough to cross both the resident → nonresident
    -- transition (PushIndexRoot at ~20) and at least one buffer split
    -- (InsertWithBufferSplit at ~50-80).  All three insert paths in
    -- one run.
    local ENTRIES = 64
    local PAYLOAD = "x"

    local function open_attr(path, access)
        -- pcall returns (true, handle_cdata) on success or
        -- (false, err_string) on raise.  NT_HANDLE is FFI cdata (NOT
        -- userdata!) -- type() returns "cdata", so just trust pcall's
        -- success flag and try to :close the result.
        local ok_p, h_or_err = pcall(fs.NtOpenFile,
            bit.bor(access, fs.SYNCHRONIZE),
            oa.path(path).oa,
            bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
            fs.FILE_SYNCHRONOUS_IO_NONALERT)
        if ok_p then
            h_or_err:close()
            return true
        end
        return false, tostring(h_or_err)
    end

    -- mkdir + verify it's actually a directory.
    local mkok, mkerr = pcall(function()
        local h = fs.NtCreateFile(
            bit.bor(fs.FILE_GENERIC_READ, fs.SYNCHRONIZE),
            oa.path(DIR).oa,
            nil, fs.FILE_ATTRIBUTE_DIRECTORY,
            bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
            fs.FILE_OPEN_IF,
            bit.bor(fs.FILE_DIRECTORY_FILE, fs.FILE_SYNCHRONOUS_IO_NONALERT),
            nil, 0)
        h:close()
    end)
    if not mkok then
        t.ok(false, "mkdir failed: " .. tostring(mkerr))
        return
    end

    local attrs = fs.query_attributes(DIR)
    local is_dir = attrs and (bit.band(attrs.FileAttributes,
                                       fs.FILE_ATTRIBUTE_DIRECTORY) ~= 0)
    if not is_dir then
        t.ok(false, "post-mkdir: query_attributes says it's not a directory")
        return
    end

    -- Sanity: list the empty dir.
    local empty_ok, empty_list = pcall(fs.list_dir, DIR)
    local empty_msg = empty_ok and ("empty list = {" ..
                                    table.concat(empty_list, ", ") .. "}")
                              or  ("empty list FAIL: " .. tostring(empty_list))

    local report = { "post-mkdir is_dir=true; " .. empty_msg }
    local any_fail = false

    -- Loop, do NOT bail on intermediate failures -- collect everything.
    for i = 1, ENTRIES do
        local fname = string.format("f_%03d.tmp", i)
        local fpath = DIR .. "\\" .. fname

        local create_ok, create_err = pcall(function()
            local h = fs.NtCreateFile(
                bit.bor(fs.FILE_GENERIC_WRITE, fs.SYNCHRONIZE),
                oa.path(fpath).oa,
                nil, fs.FILE_ATTRIBUTE_NORMAL,
                bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
                fs.FILE_OVERWRITE_IF,
                bit.bor(fs.FILE_NON_DIRECTORY_FILE, fs.FILE_SYNCHRONOUS_IO_NONALERT),
                nil, 0)
            fs.NtWriteFile(h, PAYLOAD, #PAYLOAD, nil)
            h:close()
        end)
        local create_msg = create_ok and "create=ok"
                                     or  ("create=ERR(" .. tostring(create_err) .. ")")

        local list_ok, list_result = pcall(fs.list_dir, DIR)
        local list_msg
        if list_ok then
            local seen = {}
            for _, n in ipairs(list_result) do seen[n] = true end
            list_msg = string.format("list=%d {%s}",
                                     #list_result,
                                     table.concat(list_result, ","))
            if not seen[fname] then list_msg = list_msg .. " THIS-MISSING" end
        else
            list_msg = "list=ERR(" .. tostring(list_result) .. ")"
        end

        local reopen_ok, reopen_err = open_attr(fpath, fs.FILE_READ_ATTRIBUTES)
        local reopen_msg = reopen_ok and "reopen=ok"
                                     or  ("reopen=ERR(" .. tostring(reopen_err) .. ")")

        local query_ok, query_attrs = pcall(fs.query_attributes, fpath)
        local query_msg
        if query_ok then
            query_msg = query_attrs and "query=ok"
                                    or  "query=NOT_FOUND"
        else
            query_msg = "query=ERR(" .. tostring(query_attrs) .. ")"
        end

        report[#report + 1] = string.format(
            "i=%d %s | %s | %s | %s",
            i, create_msg, list_msg, reopen_msg, query_msg)

        if (not create_ok) or (not list_ok)
           or (not reopen_ok) or (not query_ok) then
            any_fail = true
        end
    end

    t.ok(not any_fail,
         "\n  " .. table.concat(report, "\n  "))
end)

-- Helper: mkdir, returns the path or raises.
local function fresh_dir(prefix)
    local os  = require('os')
    local DIR = "\\SystemRoot\\" .. prefix .. "_" .. tostring(os.time())
    local h, _created = fs.create_dir(DIR)
    h:close()
    return DIR
end

-- Helper: write `content` to a freshly-created file at `path`.
local function write_file(path, content)
    local h = fs.NtCreateFile(
        bit.bor(fs.FILE_GENERIC_WRITE, fs.SYNCHRONIZE),
        oa.path(path).oa,
        nil, fs.FILE_ATTRIBUTE_NORMAL,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        fs.FILE_OVERWRITE_IF,
        bit.bor(fs.FILE_NON_DIRECTORY_FILE, fs.FILE_SYNCHRONOUS_IO_NONALERT),
        nil, 0)
    if #content > 0 then
        fs.NtWriteFile(h, content, #content, nil)
    end
    h:close()
end

-- Helper: read the whole content of `path`.  Returns the bytes as a
-- Lua string.
local function read_file(path)
    local h = fs.NtOpenFile(
        bit.bor(fs.FILE_READ_DATA, fs.SYNCHRONIZE),
        oa.path(path).oa,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        fs.FILE_SYNCHRONOUS_IO_NONALERT)
    local out = {}
    local buf = ffi.new('char[4096]')
    while true do
        local n, st = fs.NtReadFile(h, buf, 4096, nil)
        if n == 0 or st == fs.STATUS_END_OF_FILE then break end
        out[#out + 1] = ffi.string(buf, n)
    end
    h:close()
    return table.concat(out)
end

t.test("Bulk create + read-back roundtrip preserves per-file content", function()
    -- Each file gets a distinct payload tagged with its index.  After
    -- writing all N, read every one back and confirm the payload is
    -- intact and matches the right file.  Catches data/metadata
    -- divergence (e.g. wrong FRS routing under FRS<cluster).
    local DIR = fresh_dir("__rb")
    local N = 32
    for i = 1, N do
        write_file(string.format("%s\\rb_%03d.dat", DIR, i),
                   string.format("payload-of-file-%03d", i))
    end
    -- Verify enumeration count.
    local listed = fs.list_dir(DIR)
    t.eq(#listed, N, "all " .. N .. " entries enumerated")
    -- Verify each file's content end-to-end.
    for i = 1, N do
        local path = string.format("%s\\rb_%03d.dat", DIR, i)
        local got  = read_file(path)
        t.eq(got, string.format("payload-of-file-%03d", i),
             "content of " .. path)
    end
end)

t.test("Mixed insert/delete: every other entry survives", function()
    -- Create 30 files, delete the even-indexed half, confirm the odd
    -- ones are still findable AND only the odd ones come back from
    -- enumeration.  Exercises NtfsDeleteIndexEntry interleaved with
    -- NtfsAddIndexEntry — both go through AddToIndex/DeleteFromIndex
    -- and both write log records via the byte-form NtfsWriteLog.
    local DIR = fresh_dir("__mix")
    local N = 30
    for i = 1, N do
        write_file(string.format("%s\\m_%03d.tmp", DIR, i), "")
    end
    -- Delete even indices.
    for i = 2, N, 2 do
        local fpath = string.format("%s\\m_%03d.tmp", DIR, i)
        local h = fs.NtOpenFile(
            bit.bor(fs.DELETE, fs.SYNCHRONIZE),
            oa.path(fpath).oa,
            bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
            fs.FILE_SYNCHRONOUS_IO_NONALERT)
        fs.set_disposition(h, true)
        h:close()
    end
    -- Build the expected set.
    local expected = {}
    for i = 1, N, 2 do
        expected[string.format("m_%03d.tmp", i)] = true
    end
    -- Enumerate and bucket.
    local seen = {}
    for _, n in ipairs(fs.list_dir(DIR)) do seen[n] = true end
    -- Every odd should be present; every even must be absent.
    for i = 1, N do
        local fname = string.format("m_%03d.tmp", i)
        if i % 2 == 1 then
            t.ok(seen[fname], fname .. " missing")
        else
            t.ok(not seen[fname], fname .. " unexpectedly present")
        end
    end
end)

t.test("Subdirectory tree: nested dir's $INDEX_ROOT independent of parent", function()
    -- Until now the stress tests poked \SystemRoot's index.  This one
    -- exercises a freshly-created (small) directory's resident
    -- $INDEX_ROOT — the on-disk layout is "FRS at MFT slot N" where
    -- N is well past the system files (16+).  If the byte-offset
    -- backport is honoring StreamOffset / NtfsMftOffset correctly,
    -- this should work identically to the root case.
    local PARENT = fresh_dir("__sub")
    local CHILD  = PARENT .. "\\inner"
    local hc, _ = fs.create_dir(CHILD)
    hc:close()
    -- Populate enough to push through all three insert paths.
    local N = 24
    for i = 1, N do
        write_file(string.format("%s\\c_%03d.tmp", CHILD, i),
                   "in-nested-dir")
    end
    local listed = fs.list_dir(CHILD)
    t.eq(#listed, N, "nested dir has all " .. N .. " entries")
    -- Parent should still see exactly one entry: "inner".
    local parent_listed = fs.list_dir(PARENT)
    t.eq(#parent_listed, 1, "parent dir has exactly 1 child")
    t.eq(parent_listed[1], "inner")
end)

t.test("Recursive delete: rmrf-style list_dir walk + post-order rmdir", function()
    -- The direct-delete form of this (open(DELETE)+set_disposition per
    -- known path) passes, so basic nested-empty-dir removal is sound.
    -- This mirrors platform.rmrf instead: enumerate every directory
    -- with list_dir during a walk, THEN delete bottom-up -- isolating
    -- the list_dir-then-delete interaction the selfhost ntosbe.lua
    -- failure points at.  Each rmdir is reported by level.
    local base = fresh_dir("__rmrf")
    local a    = base .. "\\a"
    local b    = a .. "\\b"
    local c    = b .. "\\c"
    for _, d in ipairs({ a, b, c }) do
        local h = fs.create_dir(d)
        h:close()
    end

    local function is_dir(p)
        local i = fs.query_attributes(p)
        return i ~= nil
           and bit.band(i.FileAttributes, fs.FILE_ATTRIBUTE_DIRECTORY) ~= 0
    end

    -- Walk like platform.rmrf: list_dir each directory, collect
    -- pre-order, recurse into subdirectories.
    local dirs = {}
    local function walk(p)
        dirs[#dirs + 1] = p
        for _, name in ipairs(fs.list_dir(p)) do
            local sub = p .. "\\" .. name
            if is_dir(sub) then walk(sub) end
        end
    end
    walk(base)
    t.eq(#dirs, 4, "walk found base + a + b + c")

    -- rmdir = open(DELETE) + set_disposition + close; pcall so a raised
    -- NTSTATUS is reported rather than aborting the test.
    local function rmdir(path)
        return pcall(function()
            local h = fs.NtOpenFile(
                bit.bor(fs.DELETE, fs.SYNCHRONIZE),
                oa.path(path).oa,
                bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
                fs.FILE_SYNCHRONOUS_IO_NONALERT)
            fs.set_disposition(h, true)
            h:close()
        end)
    end

    -- Post-order: deepest dir first, each empty at its turn.
    for i = #dirs, 1, -1 do
        local ok, err = rmdir(dirs[i])
        t.ok(ok, "rmdir " .. dirs[i]
                 .. (ok and "" or " raised " .. tostring(err)))
    end
    t.ok(fs.query_attributes(base) == nil, "whole tree removed")
end)

t.test("MFT bitmap nonresident-extend: 200 file creations in fresh dir", function()
    -- Coverage for the path the 0xCAFE5E7B stub used to guard.  mkntfs
    -- writes $MFT/$BITMAP nonresident at format time, but the kernel
    -- still has to extend the allocation as user files consume bits.
    -- 200 fresh creates + ~100 ambient files crosses BITMAP_EXTEND_
    -- GRANULARITY several times even on a freshly-booted volume.  If
    -- the extend path has a regression, either the create raises or
    -- the post-create enumeration won't see all of them.
    local DIR = fresh_dir("__bm")
    local N = 200
    for i = 1, N do
        write_file(string.format("%s\\b_%04d.tmp", DIR, i),
                   "")
    end
    local listed = fs.list_dir(DIR)
    t.eq(#listed, N, "all " .. N .. " files visible after bulk create")
end)

t.test("Re-create after delete: same name slot reusable", function()
    -- Create, delete, recreate with the same name.  The second create
    -- must succeed (no stale LCB / no NAME_COLLISION).  Then read it
    -- back to confirm it's the new content, not the old.
    local DIR = fresh_dir("__rec")
    local PATH = DIR .. "\\reuse.tmp"
    write_file(PATH, "first")
    -- Delete via DELETE-disposition.
    local h = fs.NtOpenFile(
        bit.bor(fs.DELETE, fs.SYNCHRONIZE),
        oa.path(PATH).oa,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        fs.FILE_SYNCHRONOUS_IO_NONALERT)
    fs.set_disposition(h, true)
    h:close()
    -- Should not be in the dir listing.
    for _, n in ipairs(fs.list_dir(DIR)) do
        t.ne(n, "reuse.tmp", "old entry still present after delete")
    end
    -- Recreate with new content.
    write_file(PATH, "second")
    t.eq(read_file(PATH), "second",
         "recreated file holds new content (not stale)")
end)

t.test("Recursive delete: fresh tree with records in nonresident $MFT", function()
    -- Transposes the selfhost rmrf failure (ntosbe.lua) into selftest.
    -- On selfhost the volume is large, so a freshly-created directory's
    -- file record lands in the nonresident-extended $MFT region; the
    -- lean selftest volume otherwise keeps fresh records resident, and
    -- the bug does not show.  Force the selfhost shape here: bulk-create
    -- files so $MFT extends well past the resident threshold, THEN build
    -- a deep dir tree whose records land in the extended region, and
    -- walk it with list_dir.  If enumerating a fresh directory whose
    -- record lives in nonresident $MFT misses a just-inserted entry,
    -- the walk under-collects -- exactly the selfhost symptom, where
    -- platform.rmrf's walk collected only the root (#dirs == 1).
    local pad = fresh_dir("__mftpad")
    for i = 1, 256 do
        write_file(string.format("%s\\p_%04d.tmp", pad, i), "")
    end
    -- The tree's directories now allocate MFT records past the batch.
    local base = fresh_dir("__rmrf_mft")
    local a, b, c = base .. "\\a", base .. "\\a\\b", base .. "\\a\\b\\c"
    for _, d in ipairs({ a, b, c }) do
        local h = fs.create_dir(d)
        h:close()
    end

    local function is_dir(p)
        local info = fs.query_attributes(p)
        return info ~= nil
           and bit.band(info.FileAttributes, fs.FILE_ATTRIBUTE_DIRECTORY) ~= 0
    end
    local dirs = {}
    local function walk(p)
        dirs[#dirs + 1] = p
        for _, name in ipairs(fs.list_dir(p)) do
            local sub = p .. "\\" .. name
            if is_dir(sub) then walk(sub) end
        end
    end
    walk(base)
    t.eq(#dirs, 4,
         "list_dir walk of fresh tree collected base+a+b+c, got " .. #dirs)

    -- Bottom-up teardown via known paths (independent of what walk found).
    for _, d in ipairs({ c, b, a, base }) do
        local h = fs.NtOpenFile(
            bit.bor(fs.DELETE, fs.SYNCHRONIZE),
            oa.path(d).oa,
            bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
            fs.FILE_SYNCHRONOUS_IO_NONALERT)
        fs.set_disposition(h, true)
        h:close()
    end
end)

-- ----------------------------------------------------------------
-- Directory enumeration with a search pattern.  list_dir's optional
-- name_filter threads a UTF-8 pattern to NtQueryDirectoryFile, which
-- drives the kernel's wildcard / exact-name match path (NTFS
-- NtfsFileIsInExpression, NtfsFileIsEqual, NtfsFileContainsWildcards
-- and the COLATSUP collation routines) — code the unfiltered listing
-- never reaches.
-- ----------------------------------------------------------------

t.test("Directory filter: exact-name pattern matches one entry", function()
    local DIR = fresh_dir("__flt1")
    for _, n in ipairs({ "aa.txt", "ab.txt", "ac.dat" }) do
        write_file(DIR .. "\\" .. n, "x")
    end
    local got = fs.list_dir(DIR, "ab.txt")
    t.eq(#got, 1, "exact pattern returned a single match")
    t.eq(got[1], "ab.txt", "and it is the requested entry")
end)

t.test("Directory filter: '*' lists every entry, like no filter", function()
    local DIR = fresh_dir("__flt2")
    for _, n in ipairs({ "aa.txt", "ab.txt", "ac.dat" }) do
        write_file(DIR .. "\\" .. n, "x")
    end
    local all  = fs.list_dir(DIR)
    local star = fs.list_dir(DIR, "*")
    t.eq(#star, #all, "'*' filter count equals unfiltered count")
    t.eq(#star, 3, "all three entries returned")
end)

t.test("Directory filter: extension wildcard '*.txt'", function()
    local DIR = fresh_dir("__flt3")
    for _, n in ipairs({ "aa.txt", "ab.txt", "ac.dat" }) do
        write_file(DIR .. "\\" .. n, "x")
    end
    local txt = fs.list_dir(DIR, "*.txt")
    table.sort(txt)
    t.eq(#txt, 2, "*.txt matched the two .txt entries")
    t.eq(txt[1], "aa.txt")
    t.eq(txt[2], "ab.txt")
end)

t.test("Directory filter: non-matching pattern yields empty list", function()
    local DIR = fresh_dir("__flt4")
    write_file(DIR .. "\\aa.txt", "x")
    -- A pattern matching nothing: NtQueryDirectoryFile reports
    -- STATUS_NO_SUCH_FILE; list_dir surfaces it as an empty result,
    -- not a raise.
    local got = fs.list_dir(DIR, "zz*")
    t.eq(#got, 0, "non-matching pattern returned no entries")
end)

t.test("Directory filter: '?' matches exactly one character", function()
    -- "?" is a distinct branch in the expression matcher from "*".
    local DIR = fresh_dir("__flt5")
    for _, n in ipairs({ "x1.dat", "x2.dat", "xxx.dat" }) do
        write_file(DIR .. "\\" .. n, "x")
    end
    local got = fs.list_dir(DIR, "x?.dat")
    table.sort(got)
    t.eq(#got, 2, "x?.dat matched the two single-char-stem entries")
    t.eq(got[1], "x1.dat")
    t.eq(got[2], "x2.dat")
end)

t.test("Directory enumeration: long name with generated 8.3 short name", function()
    -- A name that does not fit 8.3 makes NTFS store TWO $FILE_NAME
    -- index entries -- the long (NTFS-namespace) name and a generated
    -- short (DOS-namespace) name.  Enumeration walks both and must
    -- return the long name exactly once -- exercising the DOS-name
    -- pairing path (NtfsRetrieveOtherIndexEntry, DIRCTRL.C ~894-948)
    -- that an all-8.3 directory never reaches.
    local DIR  = fresh_dir("__long")
    local LONG = "this_is_a_long_filename.txt"
    write_file(DIR .. "\\" .. LONG, "x")
    local got = fs.list_dir(DIR)
    t.eq(#got, 1, "one entry -- the long name, not also its 8.3 alias")
    t.eq(got[1], LONG, "the long name is the entry returned")
end)

t.test("Directory filter: pattern survives multi-buffer enumeration", function()
    -- iter_dir's 8 KB buffer holds far fewer than 150 records, so this
    -- spans several NtQueryDirectoryFile calls.  The search pattern is
    -- captured on the restart call only; a continuation must NOT re-send
    -- it (the kernel would read it as resume-after-name).  The .dat
    -- entries confirm the filter actually excludes non-matches.
    local DIR = fresh_dir("__fltbig")
    local N = 150
    for i = 1, N do
        write_file(string.format("%s\\m_%04d.tmp", DIR, i), "")
        write_file(string.format("%s\\o_%04d.dat", DIR, i), "")
    end
    local tmp = fs.list_dir(DIR, "*.tmp")
    t.eq(#tmp, N, "all " .. N .. " .tmp entries returned across refills")
end)

-- ----------------------------------------------------------------
-- The richer FileInformationClass projections.  iter_dir's info_class
-- argument drives NtQueryDirectoryFile's class-specific fill paths in
-- DIRCTRL.C — the BaseLength switch and the per-class record builders
-- — that the default FileDirectoryInformation listing never reaches.
-- ----------------------------------------------------------------

t.test("Directory enumeration: FileBothDirectoryInformation projection", function()
    local DIR = fresh_dir("__both")
    -- A plain 8.3 name plus a long (non-8.3) name: the "both" class
    -- carries each entry's generated short name when one exists.
    for _, n in ipairs({ "plain.txt", "a_long_both_name.dat" }) do
        write_file(DIR .. "\\" .. n, "x")
    end
    local h = fs.create_dir(DIR)
    local seen = {}
    local ok, e = pcall(function()
        for name, info in fs.iter_dir(h, nil, fs.FileBothDirectoryInformation) do
            seen[name] = true
            -- ShortNameLength is bytes; > 0 when NTFS generated a
            -- separate 8.3 alias.  Decode-check it when present.
            local nshort = math.floor(info.ShortNameLength / 2)
            if nshort > 0 then
                local sn = str.from_wchars(
                    ffi.cast('uint16_t *', info.ShortName), nshort)
                t.ok(#sn > 0 and #sn <= 12,
                     "short name '" .. sn .. "' is 8.3-sized")
            end
        end
    end)
    h:close()
    if not ok then error(e, 0) end
    t.ok(seen["plain.txt"] and seen["a_long_both_name.dat"],
         "both entries enumerated via FileBothDirectoryInformation")
end)

t.test("Directory enumeration: FileFullDirectoryInformation projection", function()
    local DIR = fresh_dir("__full")
    for _, n in ipairs({ "f1.txt", "f2.txt" }) do
        write_file(DIR .. "\\" .. n, "data")
    end
    local h = fs.create_dir(DIR)
    local count = 0
    local ok, e = pcall(function()
        for name, info in fs.iter_dir(h, nil, fs.FileFullDirectoryInformation) do
            count = count + 1
            -- EaSize is this class's extra field; the files carry no
            -- extended attributes, so it reads back zero.
            t.eq(tonumber(info.EaSize), 0, name .. " reports no EAs")
        end
    end)
    h:close()
    if not ok then error(e, 0) end
    t.eq(count, 2, "both entries enumerated via FileFullDirectoryInformation")
end)

t.test("Directory enumeration: FileNamesInformation projection", function()
    local DIR = fresh_dir("__names")
    for _, n in ipairs({ "n1.txt", "n2.txt", "n3.txt" }) do
        write_file(DIR .. "\\" .. n, "x")
    end
    local h = fs.create_dir(DIR)
    local names = {}
    local ok, e = pcall(function()
        for name in fs.iter_dir(h, nil, fs.FileNamesInformation) do
            names[#names + 1] = name
        end
    end)
    h:close()
    if not ok then error(e, 0) end
    table.sort(names)
    t.eq(#names, 3, "all entries enumerated via FileNamesInformation")
    t.eq(names[1], "n1.txt")
end)
