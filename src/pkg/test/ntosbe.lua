-- test.ntosbe — self-host probe.
--
-- Runs inside the booted guest, after the rest of the selftest suite
-- has confirmed the kernel + ntdll surface is healthy.  Goal: exercise
-- the build system in-OS, ratcheting from "modules load" through
-- "platform primitives work" through "ntosbe.build can drive NMAKE".
--
-- Today's coverage (round 1):
--   - the staged NT source tree is reachable at \SystemRoot\src
--   - ntosbe.platform loads without on_host crashing (NT branch =
--     todo() stubs, but `require` itself must work)
--   - ntosbe.build loads as a regular module
--
-- Future rounds extend this in place — once platform.lua's NT branch
-- has read_file / list_dir / spawn_wait wired, we'll exercise them
-- here and then attempt `ntosbe.build.main{...}` for one focused
-- target (likely null.sys).

local bit    = require('bit')
local ffi    = require('ffi')
local t      = require('test')
local fs     = require('nt.dll.fs')
local oa     = require('nt.dll.oa')

t.suite("ntosbe")

local function nt_path_exists(nt_path)
    local noa = oa.path(nt_path)
    local ok, h = pcall(fs.NtOpenFile,
        bit.bor(fs.FILE_GENERIC_READ, fs.SYNCHRONIZE),
        noa.oa,
        fs.FILE_SHARE_READ,
        fs.FILE_SYNCHRONOUS_IO_NONALERT)
    if ok then h:close() end
    return ok
end

t.test("staged source: \\SystemRoot\\src exists", function()
    t.ok(nt_path_exists("\\SystemRoot\\src"),
         "ide.lua should stage the NT source tree under \\SystemRoot\\src")
end)

t.test("staged source: NULL driver SOURCES file readable", function()
    -- One representative file from the simplest build target.
    -- If this passes, the on-disk layout matches what ntosbe.build
    -- expects relative to script_dir = "/SystemRoot/src".
    t.ok(nt_path_exists(
        "\\SystemRoot\\src\\NT\\PRIVATE\\NTOS\\DD\\NULL\\SOURCES"),
         "null.sys's SOURCES file should be on disk")
end)

t.test("staged source: PUBLIC SDK headers reachable", function()
    -- NTDEF.H is the smallest representative header that every driver
    -- build pulls in; if it isn't here the staging walk dropped too
    -- much or PUBLIC/SDK/INC didn't ship.  NTDDK.H lives under
    -- PRIVATE/NTOS/INC on this tree, not PUBLIC.
    t.ok(nt_path_exists(
        "\\SystemRoot\\src\\NT\\PUBLIC\\SDK\\INC\\NTDEF.H"),
         "PUBLIC/SDK/INC must contain NTDEF.H for any driver build")
end)

t.test("ntosbe.platform module loads", function()
    -- platform.lua's NT branch is currently todo() stubs; loading
    -- the module must still succeed.  When primitives go live this
    -- test just continues to pass.
    local platform = require('ntosbe.platform')
    t.ok(platform ~= nil, "module returned")
    t.eq(platform.on_host, false, "on_host should be false on guest")
end)

t.test("ntosbe.build module loads", function()
    -- The orchestrator depends on platform + sources + tchain + codegen.
    -- Loading proves the import graph is intact in the staged copy.
    -- main() is NOT invoked here — that needs the platform NT branch.
    local build = require('ntosbe.build')
    t.ok(build ~= nil, "module returned")
    t.ok(type(build.main) == 'function', "build.main exists")
end)

-- ------------------------------------------------------------------
-- Round 2: nt.dll primitives that the platform NT branch will consume.
-- ------------------------------------------------------------------

local FILE_ATTRIBUTE_DIRECTORY = 0x10

t.test("fs.query_attributes: file present", function()
    local info = fs.query_attributes(
        "\\SystemRoot\\src\\NT\\PRIVATE\\NTOS\\DD\\NULL\\SOURCES")
    t.ok(info ~= nil, "SOURCES exists in staged tree")
    -- FileAttributes & DIRECTORY should be 0 for a regular file.
    local is_dir = bit.band(info.FileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0
    t.ok(not is_dir, "SOURCES is not a directory")
    t.ok(info.LastWriteTime.QuadPart ~= 0, "LastWriteTime populated")
end)

t.test("fs.query_attributes: directory present", function()
    local info = fs.query_attributes("\\SystemRoot\\src")
    t.ok(info ~= nil, "\\SystemRoot\\src exists")
    local is_dir = bit.band(info.FileAttributes, FILE_ATTRIBUTE_DIRECTORY) ~= 0
    t.ok(is_dir, "\\SystemRoot\\src is a directory")
end)

t.test("fs.query_attributes: missing path returns nil", function()
    local info = fs.query_attributes("\\SystemRoot\\does_not_exist_zzz")
    t.eq(info, nil, "nil for missing path")
end)

t.test("fs.list_dir: NULL driver source dir", function()
    -- This NULL/ holds NLS.C (the driver source on this tree),
    -- NULL.RC, SOURCES, MAKEFILE.  The original NT 3.5 source ships
    -- the driver as NLS.C, not NULL.C — kept that way so we don't
    -- diverge from the upstream tree.
    local names = fs.list_dir(
        "\\SystemRoot\\src\\NT\\PRIVATE\\NTOS\\DD\\NULL")
    local seen = {}
    for _, n in ipairs(names) do seen[n:upper()] = true end
    t.ok(seen["NLS.C"],    "NLS.C (driver source) present")
    t.ok(seen["SOURCES"],  "SOURCES present")
    t.ok(seen["MAKEFILE"], "MAKEFILE present")
    t.ok(not seen["."]  and not seen[".."],
         ". and .. filtered out by iter_dir")
end)

t.test("fs.list_dir: paginates across iter_dir refills", function()
    -- PUBLIC/SDK/INC has ~340 entries, well past one 8 KB buffer's
    -- worth — exercises the refill loop in fs.iter_dir.
    local names = fs.list_dir("\\SystemRoot\\src\\NT\\PUBLIC\\SDK\\INC")
    t.ok(#names > 100, "expect >100 entries; got " .. #names)
end)

local rtl = require('nt.dll.rtl')

t.test("rtl.environ: non-empty, contains SystemRoot", function()
    local env = rtl.environ()
    t.ok(#env > 0, "env block has entries")
    -- Match prefix only — the value can be `\WINNT`, `C:\…`, `\??\…`
    -- depending on how the loader publishes it.  Just confirm the
    -- key is present (case-insensitive).
    local found
    for _, kv in ipairs(env) do
        if kv:upper():sub(1, 11) == "SYSTEMROOT=" then
            found = kv
            break
        end
    end
    t.ok(found ~= nil,
         "SystemRoot= present (got " .. tostring(found) .. ")")
end)

t.test("rtl.set_env / query_env / unset round-trip", function()
    local NAME, VAL = "NTOSBE_TEST_VAR", "hello-world-42"
    -- Pre-condition: not set.
    t.eq(rtl.query_env(NAME), nil, "unset before test")
    rtl.set_env(NAME, VAL)
    t.eq(rtl.query_env(NAME), VAL, "set then query roundtrip")
    rtl.set_env(NAME, nil)
    t.eq(rtl.query_env(NAME), nil, "unset by passing nil")
end)

t.test("rtl.getcwd: non-empty current directory", function()
    local cwd = rtl.getcwd()
    t.ok(type(cwd) == 'string' and #cwd > 0,
         "getcwd returned non-empty string: " .. tostring(cwd))
end)

local ps = require('nt.dll.ps')

t.test("ps.wait_exit: replaces manual resume+wait+query", function()
    -- ML.EXE /? is the same target msvc.lua's manual sequence uses;
    -- here we exercise the helper that promotes that pattern to ps.
    local proc = ps.spawn{
        exe     = "\\SystemRoot\\pkg\\msvc20\\ML.EXE",
        cmdline = "ML.EXE /?",
    }
    local exit_status = ps.wait_exit(proc)
    -- ML.EXE /? prints usage and exits with status 0 or 1; either is
    -- a successful "process ran and exited" signal.  STATUS_PENDING
    -- (0x103) would mean wait_exit returned before the child finished.
    t.ok(exit_status ~= 0x103, "child exited (not STATUS_PENDING)")
end)

t.test("ps.spawn{env}: explicit env block delivered to child", function()
    -- ML.EXE doesn't read user-set env vars in a way we can probe
    -- without parsing its output.  The point of this test is the
    -- env-block path doesn't crash and the child still runs cleanly.
    -- A future extension can spawn a tiny test exe that echoes
    -- getenv("X") to stdout and assert the value.
    local proc = ps.spawn{
        exe     = "\\SystemRoot\\pkg\\msvc20\\ML.EXE",
        cmdline = "ML.EXE /?",
        env     = {
            "FOO=bar",
            "BAZ=qux=embedded-equals",
            "EMPTY=",
        },
    }
    local exit_status = ps.wait_exit(proc)
    t.ok(exit_status ~= 0x103, "spawn{env=...} child ran to completion")
end)

-- ------------------------------------------------------------------
-- Round 3: platform.lua NT branch wired end-to-end.  These tests
-- exercise the consumer surface — read/list/spawn round-trips
-- through ntosbe.platform — and finish with a real build attempt.
-- ------------------------------------------------------------------

local platform = require('ntosbe.platform')

t.test("platform.read_file: reads a staged source file", function()
    -- Forward-slash form: build code's internal path convention.
    local data = platform.read_file(
        "/SystemRoot/src/NT/PRIVATE/NTOS/DD/NULL/SOURCES")
    t.ok(data and #data > 0, "SOURCES content readable: " .. tostring(data and #data))
    -- SOURCES files start with `#` or `MAJORCOMP=` etc.
    t.ok(data:find("MAJORCOMP") or data:find("TARGETNAME"),
         "looks like a SOURCES file (found MAJORCOMP/TARGETNAME)")
end)

t.test("platform.file_exists / is_dir on staged tree", function()
    t.ok(platform.file_exists("/SystemRoot/src"), "/SystemRoot/src exists")
    t.ok(platform.is_dir("/SystemRoot/src"),       "/SystemRoot/src is a dir")
    t.ok(platform.file_exists(
        "/SystemRoot/src/NT/PRIVATE/NTOS/DD/NULL/SOURCES"),
         "NULL/SOURCES exists via /-form")
    t.ok(not platform.file_exists("/SystemRoot/no_such_thing"),
         "missing path → false")
end)

t.test("platform.list_dir: NULL driver dir", function()
    local names = platform.list_dir(
        "/SystemRoot/src/NT/PRIVATE/NTOS/DD/NULL")
    t.ok(#names > 0, "non-empty listing: " .. #names)
end)

t.test("platform.write_file + read_file round-trip", function()
    local path = "/SystemRoot/ntosbe_test_rt.txt"
    local payload = "hello world\n12345\n"
    platform.write_file(path, payload)
    local got = platform.read_file(path)
    t.eq(got, payload, "round-trip preserves bytes")
    platform.unlink(path)
    t.ok(not platform.file_exists(path), "unlink removes file")
end)

t.test("platform.mkdir_p: deep path", function()
    -- Build runs always create obj/i386 under each component dir.
    -- Exercise the same shape with a throwaway path under SystemRoot.
    local deep = "/SystemRoot/ntosbe_mkdir_test/a/b/c"
    platform.mkdir_p(deep)
    t.ok(platform.is_dir(deep), "deep path created")
    -- Cleanup.
    platform.rmrf("/SystemRoot/ntosbe_mkdir_test")
    t.ok(not platform.file_exists("/SystemRoot/ntosbe_mkdir_test"),
         "rmrf cleaned up")
end)

t.test("platform.spawn_wait: ML.EXE through platform layer", function()
    -- Same target as the ps tests, but via platform's argv-array
    -- shape (matches host signature).
    local rc = platform.spawn_wait{
        argv = { "/SystemRoot/pkg/msvc20/ML.EXE", "/?" },
    }
    t.ok(rc ~= 0x103, "ML.EXE ran through platform.spawn_wait, rc=" .. tostring(rc))
end)

t.test("cmd-stub: runs natively via /C invocation", function()
    -- cmd-stub is the same Win32 PE we use under wibo on host —
    -- imports only kernel32 + CRTDLL.  This probe verifies it runs
    -- on guest before NMAKE's COMSPEC indirection relies on it
    -- (NMAKE shells out for inline @if/&&/redirection commands).
    --
    -- /C echo hello is the simplest invocation: cmd-stub parses /C,
    -- treats the rest as the command line, runs `echo hello` via its
    -- builtin echo, exits 0.  Anything other than rc=0 means the
    -- COMSPEC path is broken even before NMAKE gets to it.
    local rc = platform.spawn_wait{
        argv = { "C:\\pkg\\msvc20\\cmd.exe", "/C", "echo", "hello" },
    }
    t.eq(rc, 0, "cmd.exe /C echo exited 0")
end)

t.test("ntosbe.build: 'null' target on guest", function()
    -- Drive the relocated build.lua against the staged source tree.
    -- null.sys is the simplest target: 2 source files, no codegen
    -- prereqs, no host-only deps.  This now genuinely fails on
    -- non-zero rc — earlier rounds were diagnostic-only and used
    -- t.ok(true) to keep the suite green while we wired primitives.
    local build = require('ntosbe.build')
    -- Guest paths use DOS form (C:\…) so Win32 toolchain children's
    -- CRT fopen / GetCurrentDirectoryW / GetModuleFileNameW work
    -- through stock RtlDosPathNameToNtPathName_U → \DosDevices\C:
    -- → boot volume.  The \DosDevices\C: symlink is published from
    -- Lua by nt.boot.run() (since our HAL has no IoAssignDriveLetters).
    -- path_strip drops the leading "/SystemRoot" so what becomes "C:"
    -- + "\foo" rather than "C:\SystemRoot\foo" (which would be valid
    -- DOS but route the toolchain through a longer path with no
    -- benefit).
    local ok, rc = pcall(build.main, {
        script_dir = "/SystemRoot/src",
        repo_root  = "/SystemRoot",
        wibo_tools = "/SystemRoot/pkg/msvc20",
        drive_root = "C:",
        path_strip = "/SystemRoot",
        args       = { "null" },
    })
    t.ok(ok, "build.main didn't raise (got: " .. tostring(rc) .. ")")
    t.eq(rc, 0, "null target exited 0")
end)
