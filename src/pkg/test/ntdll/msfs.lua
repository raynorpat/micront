-- test.msfs — functional mailslot round-trips through msfs.sys.
--
-- Mailslots are datagram IPC: the server (read) end is created with
-- NtCreateMailslotFile, the client (write) end opens the same
-- \Device\Mailslot\<name> path. One write = one message; one read
-- returns one whole message, FIFO. Messages flow client -> server only.
--
-- This suite drives the mailslot FS end to end — create, open, message
-- round-trip and ordering, info query, peek, timeout behaviour,
-- zero-length and oversize-buffer edges, and the \Device\Mailslot
-- directory — exercising CREATE.C, CREATEMS.C, READ.C, WRITE.C,
-- READSUP.C, WRITESUP.C, DATASUP.C, FILEINFO.C, FSCONTRL.C and DIR.C,
-- which the (previously nonexistent) test coverage left almost entirely
-- dark. See [[project_kernel_coverage_tests]].
--
-- Mostly single-threaded: the client write queues the datagram before the
-- server read runs, and a server created with read_timeout=0 returns
-- immediately (with the message if queued, STATUS_IO_TIMEOUT if not), so
-- nothing blocks. The exception is the pending-read async tests, where a
-- worker thread issues a blocking read that the main thread satisfies with
-- a later write (the only path that exercises a queued reader).

local ffi    = require('ffi')
local bit    = require('bit')
local t      = require('test')
local fs     = require('nt.dll.fs')
local msfs   = require('nt.dll.msfs')
local oa     = require('nt.dll.oa')
local se     = require('nt.dll.se')
local ke     = require('nt.dll.ke')
local thread = require('nt.thread')
local handle = require('nt.dll.handle')

t.suite("msfs: functional round-trips")

-- Fresh mailslot name per test so instances never collide on a re-run.
local namecount = 0
local function fresh()
    namecount = namecount + 1
    return "fms" .. namecount, "\\Device\\Mailslot\\fms" .. namecount
end

local function readstr(h, n)
    local buf = ffi.new('char[?]', n)
    local got = fs.NtReadFile(h, buf, n, nil)
    return ffi.string(buf, got)
end

-- A connected server+client pair on a fresh mailslot. `sopts` is passed
-- to create_mailslot; read_timeout defaults to 0 (immediate) so reads
-- never block the in-process runner.
local function pair(sopts)
    local _, path = fresh()
    sopts = sopts or {}
    sopts.name = path
    if sopts.read_timeout == nil then sopts.read_timeout = 0 end
    local server = msfs.create_mailslot(sopts)
    local client = msfs.open_mailslot(path)
    return server, client, path
end

-- ------------------------------------------------------------------
-- Single message round-trip.
-- ------------------------------------------------------------------

t.test("client write -> server read delivers one message", function()
    local server, client = pair()
    t.defer(function() server:close() end)
    t.defer(function() client:close() end)

    fs.NtWriteFile(client, "datagram", 8, nil)
    t.eq(readstr(server, 64), "datagram", "message delivered")
end)

-- ------------------------------------------------------------------
-- FIFO ordering + info query (counts and next-size before draining).
-- ------------------------------------------------------------------

t.test("multiple messages are FIFO; query reports counts/size", function()
    local server, client = pair{ max_message_size = 1024 }
    t.defer(function() server:close() end)
    t.defer(function() client:close() end)

    fs.NtWriteFile(client, "first",    5, nil)
    fs.NtWriteFile(client, "second!!", 8, nil)

    local info = msfs.mailslot_info(server)
    t.eq(info.MessagesAvailable,  2,    "two messages queued")
    t.eq(info.NextMessageSize,    5,    "next message size = len(first)")
    t.eq(info.MaximumMessageSize, 1024, "max message size round-trips")

    t.eq(readstr(server, 64), "first",    "first out")
    t.eq(readstr(server, 64), "second!!", "second out")
end)

t.test("empty mailslot reports MAILSLOT_NO_MESSAGE next size", function()
    local server = pair()
    t.defer(function() server:close() end)
    local info = msfs.mailslot_info(server)
    t.eq(info.MessagesAvailable, 0, "no messages")
    t.eq(info.NextMessageSize, msfs.MAILSLOT_NO_MESSAGE, "next size sentinel")
end)

-- ------------------------------------------------------------------
-- Peek — must not consume.
-- ------------------------------------------------------------------

t.test("peek reports the next message without consuming it", function()
    local server, client = pair()
    t.defer(function() server:close() end)
    t.defer(function() client:close() end)

    fs.NtWriteFile(client, "peekme", 6, nil)
    local pk = msfs.mailslot_peek(server, 64)
    t.eq(pk.message_length, 6, "peeked next message length")
    t.ok(pk.messages >= 1,     "at least one message visible")
    -- Still there: the real read returns it.
    t.eq(readstr(server, 64), "peekme", "peek did not consume")
end)

-- ------------------------------------------------------------------
-- Timeout behaviour — immediate read with no message.
-- ------------------------------------------------------------------

t.test("read with no message and timeout 0 is IO_TIMEOUT", function()
    local server = pair()    -- read_timeout = 0, nothing written
    t.defer(function() server:close() end)

    local ok, e = pcall(readstr, server, 64)
    t.ok(not ok, "read on an empty mailslot must fail (no block)")
    t.ok(tostring(e):match("c00000b5"),
         "expected IO_TIMEOUT, got " .. tostring(e))
end)

t.test("set_mailslot_timeout adjusts the read timeout", function()
    local server, client = pair()
    t.defer(function() server:close() end)
    t.defer(function() client:close() end)

    -- Re-arm to immediate (idempotent) — just exercise the set path; a
    -- queued message still reads back fine afterwards.
    msfs.set_mailslot_timeout(server, 0)
    fs.NtWriteFile(client, "after-set", 9, nil)
    t.eq(readstr(server, 64), "after-set", "read works after set timeout")
end)

t.test("read with a finite timeout expires via the timer DPC", function()
    -- A short positive read timeout with no message queued: the read
    -- pends, a timer is armed, and when it fires the DPC (msfs DPC.C)
    -- completes the IRP with STATUS_IO_TIMEOUT. This is the timed path
    -- the timeout=0 (immediate) case above never reaches.
    local _, path = fresh()
    local server = msfs.create_mailslot{ name = path, read_timeout = 0.1 }
    t.defer(function() server:close() end)

    local ok, e = pcall(readstr, server, 64)
    t.ok(not ok, "a finite-timeout read on an empty mailslot must time out")
    t.ok(tostring(e):match("c00000b5"),
         "expected IO_TIMEOUT, got " .. tostring(e))
end)

-- ------------------------------------------------------------------
-- Security and volume info — light up SEINFO.C and VOLINFO.C, which the
-- data round-trips never touch.
-- ------------------------------------------------------------------

t.test("NtQuerySecurityObject returns the mailslot's security descriptor", function()
    local server = pair()
    t.defer(function() server:close() end)
    local sd = se.get_object_security(server)
    t.ok(sd ~= nil, "got a security descriptor")
end)

t.test("FileFsAttributeInformation reports the FS name MSFS", function()
    -- msfs answers volume queries on the VCB only (MsCommonQueryVolume-
    -- Information rejects any other node type) — so open the file-system
    -- volume object itself: "\Device\Mailslot" with NO trailing name.
    local voa = oa.path("\\Device\\Mailslot")
    local vcb = fs.NtOpenFile(
        bit.bor(fs.FILE_GENERIC_READ, fs.SYNCHRONIZE), voa.oa,
        bit.bor(fs.FILE_SHARE_READ, fs.FILE_SHARE_WRITE),
        fs.FILE_SYNCHRONOUS_IO_NONALERT)
    t.defer(function() vcb:close() end)
    local vi = fs.volume_attribute_info(vcb)
    t.eq(vi.fs_name, "MSFS", "file-system name")
end)

-- ------------------------------------------------------------------
-- Edge cases — zero-length message, oversize-message vs small buffer.
-- ------------------------------------------------------------------

t.test("a zero-length message round-trips as zero bytes", function()
    local server, client = pair()
    t.defer(function() server:close() end)
    t.defer(function() client:close() end)

    fs.NtWriteFile(client, "", 0, nil)
    local info = msfs.mailslot_info(server)
    t.eq(info.MessagesAvailable, 1, "the empty message is queued")
    t.eq(info.NextMessageSize,   0, "next message size = 0")
    t.eq(readstr(server, 64), "", "reads back as zero bytes")
end)

t.test("reading into too small a buffer is BUFFER_TOO_SMALL", function()
    local server, client = pair()
    t.defer(function() server:close() end)
    t.defer(function() client:close() end)

    fs.NtWriteFile(client, "toolong", 7, nil)
    -- Buffer smaller than the message: the read fails and the message is
    -- NOT consumed (msfs READSUP.C).
    local ok, e = pcall(readstr, server, 3)
    t.ok(not ok, "undersized read must fail")
    t.ok(tostring(e):match("c0000023"),
         "expected BUFFER_TOO_SMALL, got " .. tostring(e))
    -- Message survived: a properly sized read still gets it.
    t.eq(readstr(server, 64), "toolong", "message not consumed by failed read")
end)

-- ------------------------------------------------------------------
-- Directory enumeration of the \Device\Mailslot root (msfs DIR.C).
-- ------------------------------------------------------------------

-- ------------------------------------------------------------------
-- Pending reads — a read with a non-zero timeout on an empty mailslot
-- queues the read IRP and BLOCKS; a later write satisfies it. These are
-- the genuinely async paths the timeout-0 round-trips never reach (READ.C
-- queues the reader; WRITESUP.C / MsWriteDataQueue completes it). The
-- reader runs on its own thread so the blocking read can't stall the
-- in-process runner; the main thread does the satisfying write. See
-- [[project_npfs_mailslot_ipc]].
--
-- The worker borrows TWO handles by value (same process => same handle
-- table): the server (read) handle and a "started" event. It signals
-- `started` immediately before the blocking read, so the main thread waits
-- on a real event for the worker to reach its read — no fixed "sleep and
-- hope it pended" delay. It returns "ok:<data>" / "err:<msg>" so a result
-- can never arrive empty (cr_thread marshals strings only).
-- ------------------------------------------------------------------

local MS_READER = [[
local ffi    = require('ffi')
local fs     = require('nt.dll.fs')
local ke     = require('nt.dll.ke')
local handle = require('nt.dll.handle')
-- PAYLOAD = "<read-handle>,<started-event-handle>" (two borrowed handles).
local rh, eh  = PAYLOAD:match("([^,]+),([^,]+)")
local server  = handle.from_payload(rh)
local started = handle.from_payload(eh)
local ok, res = pcall(function()
    local buf = ffi.new('char[?]', 64)
    ke.NtSetEvent(started)        -- "about to issue the blocking read"
    local n = fs.NtReadFile(server, buf, 64, nil)
    return ffi.string(buf, n)
end)
return ok and ("ok:" .. res) or ("err:" .. tostring(res))
]]

-- satisfy_pending_read(read_h, write_fn) -> (status, value). Drives the
-- pending-read async path deterministically: spawn MS_READER on `read_h`,
-- wait on a real event until the worker is at its blocking read, assert the
-- read is genuinely still outstanding, then run write_fn() to satisfy it.
-- No fixed delays — every timeout here is only a deadlock guard on a real
-- completion/signal event.
local function satisfy_pending_read(read_h, write_fn)
    local started = ke.event{ notify = true }
    local th = thread.run(MS_READER,
        handle.to_payload(read_h) .. "," .. handle.to_payload(started:handle()))
    t.ok(started:wait(2), "reader reached its blocking read")
    t.ok(not th:done(),   "read is still outstanding when the write lands")
    write_fn()
    t.ok(th:wait(2), "reader completed once the write satisfied it")
    local status, val = th:result()
    th:close()
    started:close()
    return status, val
end

t.test("an infinite-wait read is satisfied by a later write", function()
    -- read_timeout = forever: READ.C queues the read IRP with NO timer
    -- (the MAILSLOT_WAIT_FOREVER branch) and pends. The write then
    -- completes it through MsWriteDataQueue's reader loop with
    -- workContext == NULL (no timer to cancel).
    local _, path = fresh()
    local server = msfs.create_mailslot{ name = path,
                                       read_timeout = msfs.MAILSLOT_WAIT_FOREVER }
    local client = msfs.open_mailslot(path)
    t.defer(function() server:close() end)
    t.defer(function() client:close() end)

    local status, val = satisfy_pending_read(server, function()
        fs.NtWriteFile(client, "wakeup", 6, nil)
    end)
    t.eq(status, "ok", "reader thread status: " .. tostring(val))
    t.eq(val, "ok:wakeup", "the pending read returned the written datagram")
end)

t.test("a finite-timeout read is satisfied by a write before the timer fires", function()
    -- read_timeout = 5s: READ.C queues the read AND arms a KTIMER/DPC. The
    -- write completes the read through MsWriteDataQueue and takes the
    -- KeCancelTimer success branch (workContext != NULL) — the complement
    -- of the "timer expires via the DPC" test above. The 5s is only a
    -- ceiling the write beats; it never actually elapses.
    local _, path = fresh()
    local server = msfs.create_mailslot{ name = path, read_timeout = 5 }
    local client = msfs.open_mailslot(path)
    t.defer(function() server:close() end)
    t.defer(function() client:close() end)

    local status, val = satisfy_pending_read(server, function()
        fs.NtWriteFile(client, "beat-timer", 10, nil)
    end)
    t.eq(status, "ok", "reader thread status: " .. tostring(val))
    t.eq(val, "ok:beat-timer", "write satisfied the read; the timer was cancelled")
end)

t.test("\\Device\\Mailslot enumerates open mailslots", function()
    local leaf, path = fresh()
    local server = msfs.create_mailslot{ name = path, read_timeout = 0 }
    t.defer(function() server:close() end)

    -- Trailing backslash → the root DCB (a directory); "\Device\Mailslot"
    -- with no slash opens the FS volume object, which isn't enumerable.
    local names = fs.list_dir("\\Device\\Mailslot\\")
    local seen = false
    for _, n in ipairs(names) do
        if n == leaf then seen = true break end
    end
    t.ok(seen, "our mailslot '" .. leaf .. "' appears in the device directory")
end)
