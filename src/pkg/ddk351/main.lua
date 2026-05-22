-- ddk351/main.lua — drive a curated set of unmodified Microsoft
-- pre-compiled CLI utilities against our kernel and observe drift.
-- selftest is self-referential by design (we wrote both the kernel
-- side and the test side); this harness isn't.
--
-- Selection bar: each binary must exercise real NT-side surface —
-- native ntdll syscalls, NT struct layout, struct packing.  Pure
-- CRT/kernel32 binaries don't add signal beyond what selftest
-- already covers.
--
-- Active set, by subsystem:
--   DRIVERS  — SystemModuleInformation + RTL_PROCESS_MODULES
--              struct layout (NtQuerySystemInformation arm)
--   FLOATER  — FPU/NPX accuracy + thread context save/restore
--              across the scheduler (multi-thread trig stress)
--   REGDMP   — NtOpenKey / NtEnumerateKey / NtEnumerateValueKey
--              walk of \Registry\Machine\Hardware\Description
--
-- See the ddk351 layer header for the dropped-binaries triage and
-- the win32-layer roadmap that would unlock the next tier (NTSD /
-- CDB / a wider RK ecosystem).

-- package.path + searcher + io/os globals come from the runtime
-- preamble (\SystemRoot\System32\preamble.lua).

local bit    = require('bit')
local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local ps     = require('nt.dll.ps')
local ke     = require('nt.dll.ke')
local se     = require('nt.dll.se')
local sys    = require('nt.dll.sys')
local fs     = require('nt.dll.fs')
local oa     = require('nt.dll.oa')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

-- Same boot prelude main.lua / selftest.lua run — publishes \NLS\
-- named sections and \DosDevices\C:.  Idempotent.
require('nt.boot').run()

print("ddk351 ABI conformance")
print("======================")

-- ------------------------------------------------------------------
-- Output capture via NPFS — anonymous pipe per spawn.
--
-- Each child runs with its stdout/stderr redirected to the write
-- end of a freshly-created NPFS pipe; the parent drains the read
-- end after the child exits.  No disk side-effects; no shared
-- stdio noise on the serial console mixed with our PASS/FAIL
-- reporting.
--
-- inbound_quota is sized large enough (256 KB) that none of the
-- current binaries fill the kernel pipe buffer mid-run.  If a
-- future binary exceeds it the child would block on its write and
-- our wait_for_exit would deadlock — at that point switch to a
-- concurrent reader thread (ps.create_thread + ke.event).
-- ------------------------------------------------------------------
local PIPE_INBOUND_QUOTA = 256 * 1024

-- Pipe-completion statuses for the drain loop — any of these means
-- "no more data coming, stop reading".
local STATUS_END_OF_FILE   = 0xC0000011
local STATUS_PIPE_BROKEN   = 0xC000014B
local STATUS_PIPE_CLOSING  = 0xC0000128

local pipe_counter = 0
local function unique_pipe_name(label)
    pipe_counter = pipe_counter + 1
    return "\\Device\\NamedPipe\\ddk351_" .. label .. "_" .. pipe_counter
end

-- Read everything still buffered on a pipe server handle and return
-- it as a string.  Stops on EOF / PIPE_BROKEN / PIPE_CLOSING / zero-
-- length read.  Uses raw ntdll.NtReadFile to avoid fs.NtReadFile's
-- raise-on-error wrapper (which would throw on the pipe-EOF codes).
local function drain_pipe(server_handle, max_total)
    local buf = ffi.new('unsigned char[?]', 4096)
    local iosb = ffi.new('IO_STATUS_BLOCK')
    local chunks = {}
    local total = 0
    while total < max_total do
        iosb.Status      = 0
        iosb.Information = 0
        local st = ntdll.NtReadFile(handle.raw(server_handle),
                                    nil, nil, nil, iosb,
                                    buf, 4096, nil, nil)
        local stu  = err.normalize(st)
        local n    = tonumber(iosb.Information)
        if n > 0 then
            chunks[#chunks+1] = ffi.string(buf, n)
            total = total + n
        end
        if stu == STATUS_END_OF_FILE
           or stu == STATUS_PIPE_BROKEN
           or stu == STATUS_PIPE_CLOSING
           or (n == 0 and stu ~= 0)
        then
            break
        end
    end
    return table.concat(chunks)
end

-- Spawn a child with its stdout + stderr captured to a fresh pipe.
-- Returns (exit_status, captured_output_string).
local function spawn_and_capture(label, exe, cmdline, dll_path)
    local pipe_name = unique_pipe_name(label)

    -- Server end — we read from this.  outbound_quota is the kernel
    -- buffer for data we'd write to the client; we don't write, so
    -- a small one is fine.  inbound_quota is the buffer for data
    -- coming FROM the client (the child's stdout) — must be large.
    local server = fs.create_named_pipe{
        name           = pipe_name,
        inbound_quota  = PIPE_INBOUND_QUOTA,
        outbound_quota = 4096,
    }

    -- Client end — the child writes into this.  Opened for write +
    -- synchronize so the child's WriteFile path works synchronously.
    local client_oa = oa.path(pipe_name)
    local client = fs.NtOpenFile(
        bit.bor(fs.FILE_GENERIC_WRITE, fs.SYNCHRONIZE),
        client_oa.oa,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        fs.FILE_SYNCHRONOUS_IO_NONALERT)

    -- Spawn with stdout/stderr redirected.  ps.spawn dups the client
    -- handle into the child's process as inheritable; once the child
    -- has its own dup, we close ours so the only remaining write end
    -- belongs to the child.  When the child exits and the kernel
    -- closes its inherited stdio, the pipe sees EOF and our drain
    -- loop terminates cleanly.
    local proc = ps.spawn{
        exe      = exe,
        cmdline  = cmdline,
        dll_path = dll_path,
        stdout   = client,
        stderr   = client,
    }
    client:close()

    ps.NtResumeThread(proc.thread)
    ke.NtWaitForSingleObject(proc.process, false, nil)
    local info = ps.NtQueryInformationProcess_Basic(proc.process)
    proc.thread:close()
    proc.process:close()

    local output = drain_pipe(server, PIPE_INBOUND_QUOTA)
    server:close()

    return info.exit_status, output
end

-- Per-binary entry:
--   name          — display label
--   exe / cmdline — passed to ps.spawn
--   expected      — exit status that counts as success (default 0)
--   must_contain  — array of substrings the captured output must
--                   include.  Failure to find any of them is a FAIL.
--   dll_path      — optional DllPath override (currently unused;
--                   plumbed for the PERL re-enable path).
local binaries = {
    { name     = "DRIVERS.EXE",
      exe      = "\\SystemRoot\\pkg\\ddk351\\DRIVERS.EXE",
      cmdline  = "DRIVERS.EXE",
      expected = 0x37,
      -- DRIVERS dumps a table of all loaded modules; ntoskrnl + hal
      -- are first-row entries, and at least one of our boot drivers
      -- (NTFS or FASTFAT) must appear if the storage stack came up.
      must_contain = { "ntoskrnl.exe", "hal.dll", "NTFS" } },

    { name     = "FLOATER.EXE",
      exe      = "\\SystemRoot\\pkg\\ddk351\\FLOATER.EXE",
      cmdline  = "FLOATER.EXE 100 2",
      -- FLOATER prints exactly this string on a clean run; failure
      -- mode prints "%d errors in results.  This is VERY SERIOUS."
      must_contain = { "No errors in results." } },

    { name     = "REGDMP.EXE",
      exe      = "\\SystemRoot\\pkg\\ddk351\\REGDMP.EXE",
      cmdline  = "REGDMP.EXE \\Registry\\Machine\\Hardware\\Description",
      -- REGDMP emits a tree headed by the key path it dumped.
      -- "System" is the first subkey on x86; "Identifier" is the
      -- standard value under it.
      must_contain = { "Description", "System" } },
}

-- Print the captured child output indented under a failed test so
-- the serial log carries enough context to diagnose.  Capped to a
-- few KB to keep the failure block readable.
local function dump_output(output)
    local snippet = output:sub(1, 4096)
    for line in snippet:gmatch("[^\r\n]+") do
        print("    > " .. line)
    end
    if #output > 4096 then
        print(string.format("    > [...%d more bytes truncated]",
                            #output - 4096))
    end
end

local pass, fail = 0, 0
for _, b in ipairs(binaries) do
    print("")
    print("--- " .. b.name .. " ---")
    local expected = b.expected or 0
    local ok, status, output = pcall(spawn_and_capture,
                                     b.name, b.exe, b.cmdline, b.dll_path)
    if not ok then
        fail = fail + 1
        print("  FAIL (spawn error: " .. tostring(status) .. ")")
    else
        -- Find every must_contain substring before deciding PASS.
        local missing = {}
        for _, needle in ipairs(b.must_contain or {}) do
            if not output:find(needle, 1, true) then
                missing[#missing+1] = needle
            end
        end

        if status == expected and #missing == 0 then
            pass = pass + 1
            print(string.format("  exit_status = 0x%08x  PASS", status))
        else
            fail = fail + 1
            print(string.format("  exit_status = 0x%08x (expected 0x%08x)",
                status, expected))
            if status >= 0x80000000 then
                print("  FAIL (kernel-injected NTSTATUS)")
            elseif status ~= expected then
                print("  FAIL (program-reported error)")
            else
                print("  FAIL (missing output: "
                      .. table.concat(missing, ", ") .. ")")
            end
            dump_output(output)
        end
    end
end

print("")
print(string.format("== %d passed, %d failed ==", pass, fail))
print("")
if fail == 0 then
    print("ALL PASSED — shutting down")
else
    print("FAILURES — shutting down with failure status")
end

-- Clean shutdown — same ladder as selftest.lua.  Defensive revert in
-- case any spawn left us impersonating.
pcall(se.revert_to_self)

local sd_ok, sd_err = pcall(function()
    local tok = se.open_process_token{
        access = se.TOKEN_QUERY + se.TOKEN_ADJUST_PRIVILEGES,
    }
    se.enable_privileges(tok, {"SeShutdownPrivilege"})
    sys.NtShutdownSystem('power_off')
    tok:close()
end)
if not sd_ok then
    print("shutdown failed: " .. tostring(sd_err))
    print("(spinning — kill QEMU manually)")
end
while true do end
