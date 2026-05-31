-- nt.tty — a userspace cooked-mode console (line discipline) over the
-- raw serial port.
--
-- MicroNT has no console subsystem (no conhost/csrss console): the serial
-- port is a raw byte pipe, so a program that inherits it as stdio gets
-- un-echoed, un-edited input where Enter arrives as CR (0x0D) and
-- backspace as DEL (0x7F).  Line-oriented programs — a Python REPL, a
-- shell — want canonical input: keystrokes echoed, in-line editing, and
-- lines terminated by \n.  (Python 2.5 on Windows has no `readline`, so
-- its REPL does ZERO editing of its own — whatever we provide here is the
-- only editing the user gets.)
--
-- This is the missing line discipline, in userspace.  It runs the raw
-- serial console through a small terminal state machine — think "telnet
-- line mode with local echo" — and hands the cooked result to a child
-- over pipes:
--
--    serial RX --raw bytes--> [line discipline] --cooked line\n--> child stdin (pipe)
--    serial TX <----echo------[              ]                      child stdout (pipe)
--    serial TX <---------------------- bytes --------------------- child stdout (pipe)
--
-- The child sees an ordinary pipe for stdin/stdout/stderr; because a pipe
-- is not a tty, run block-buffered programs UNBUFFERED (python -u) or
-- their prompts never flush.  Pass -i too so the REPL stays interactive
-- despite stdin not being a tty.
--
-- Two pieces, deliberately separated so the terminal logic is testable
-- without any kernel objects:
--   tty.lineedit()  pure line-discipline state machine (no I/O); unit
--                   tested in test/tty.lua.
--   tty.run(opts)   take over the serial console (reopen it overlapped),
--                   spawn opts.exe under pipes, and run an event-driven
--                   reactor cooking serial <-> pipes.  Returns the child's
--                   exit status (NTSTATUS number).

local M = {}

-- ===================================================================
-- Line discipline — pure, no I/O.
-- ===================================================================
-- feed() consumes ONE raw input byte and returns (echo, line):
--   echo  bytes to write back to the terminal (may be "").
--   line  a completed input line WITHOUT its terminator when Enter was
--         pressed, else nil.  The caller appends "\n" before sending it
--         to the child.
--
-- v1 scope ("telnet echo mode"): printable echo, CR/LF commit, BS/DEL
-- erase, ^C line-cancel, and SWALLOW of CSI/SS3 escape sequences
-- (arrows, Home, PgUp, …) so a stray VT100 burst can't corrupt the line.
-- In-line cursor editing and history are a future v2 that slots into
-- this same object without changing tty.run.

local CR, LF, ESC, DEL, BS, ETX = 0x0D, 0x0A, 0x1B, 0x7F, 0x08, 0x03

local LineEdit = {}
LineEdit.__index = LineEdit

-- esc states: 0 = normal, 1 = saw ESC (expect '[' CSI or 'O' SS3),
-- 2 = inside a CSI/SS3 sequence (consume until a final byte 0x40-0x7E).
function M.lineedit()
    return setmetatable({ buf = {}, esc = 0 }, LineEdit)
end

function LineEdit:feed(c)
    if self.esc == 1 then
        -- ESC just seen: a CSI ('[') or SS3 ('O') introducer opens a
        -- multi-byte sequence; anything else was a lone ESC — drop it.
        self.esc = (c == 0x5B or c == 0x4F) and 2 or 0
        return "", nil
    elseif self.esc == 2 then
        -- Parameter/intermediate bytes are 0x20-0x3F; the final byte is
        -- 0x40-0x7E and ends the sequence.  v1 discards the whole thing.
        if c >= 0x40 and c <= 0x7E then self.esc = 0 end
        return "", nil
    end

    if c == ESC then
        self.esc = 1
        return "", nil
    elseif c == CR or c == LF then               -- Enter — commit the line
        local line = table.concat(self.buf)
        self.buf = {}
        return "\r\n", line
    elseif c == DEL or c == BS then              -- erase one glyph
        if #self.buf > 0 then
            self.buf[#self.buf] = nil
            return "\b \b", nil                  -- back, overwrite, back
        end
        return "", nil
    elseif c == ETX then                         -- Ctrl-C — cancel the line
        self.buf = {}
        return "^C\r\n", nil
    elseif c >= 0x20 and c < 0x7F then           -- printable — buffer + echo
        local ch = string.char(c)
        self.buf[#self.buf + 1] = ch
        return ch, nil
    else
        -- Other control bytes (Tab, Ctrl-*): ignored in v1.
        return "", nil
    end
end

-- ===================================================================
-- tty.run — event-driven console reactor.
-- ===================================================================

local ffi    = require('ffi')
local bit    = require('bit')
local fs     = require('nt.dll.fs')
local npfs   = require('nt.dll.npfs')
local oa     = require('nt.dll.oa')
local ps     = require('nt.dll.ps')
local ke     = require('nt.dll.ke')
local err    = require('nt.dll.errors')
local ntdll  = require('nt.dll')
local handle = require('nt.dll.handle')
local io     = require('io')

local PIPE_BUF        = 16384
local SERIAL_READ_LEN = 256       -- per overlapped serial read; crunch-down
                                  -- returns on the first byte, so this just
                                  -- caps a paste burst per completion.
local WAIT_ANY        = 1         -- OBJECT_WAIT_TYPE: WaitAnyObject

-- Console handle access: read + write + (implicit) SYNCHRONIZE.  bit.bor, not
-- +, because FILE_GENERIC_READ and _WRITE share the SYNCHRONIZE/READ_CONTROL
-- bits and + would carry.
local SERIAL_ACCESS = bit.bor(fs.FILE_GENERIC_READ, fs.FILE_GENERIC_WRITE)

-- "Crunch down to one, wait forever for the first byte": Interval &
-- Multiplier = MAXULONG select the SERIAL driver's first-byte-return mode;
-- Constant = MAXULONG-1 is the ~49-day ceiling INIT.C uses (0 would EOF, and
-- all three MAXULONG is rejected by the IOCTL).  On the overlapped handle a
-- read pends until a key arrives and completes on it — no timeout, no poll.
-- This is also exactly the mode we restore so the next inheritor matches init.
local SERIAL_TIMEOUTS = {
    ReadIntervalTimeout        = 0xFFFFFFFF,
    ReadTotalTimeoutMultiplier = 0xFFFFFFFF,
    ReadTotalTimeoutConstant   = 0xFFFFFFFE,
}

-- Monotonic suffix so repeat tty.run calls get distinct pipe names.
local _seq = 0

-- Create a one-way byte-stream pipe.  (agent_end, child_end) as owning
-- NT_HANDLEs; the caller closes the child_end after ps.spawn dups it so the
-- only surviving copy lives in the child (that's what lets the read side see
-- EOF on child exit).  server_sync picks the agent end's mode:
--   true   synchronous — blocking writes (the to-child stdin pipe).
--   false  overlapped — its reads complete to an event we wait on alongside
--          the serial port (the from-child stdout pipe).
local function make_pipe(name, agent_access, child_access, server_sync)
    local server = npfs.create_named_pipe{
        name = name, access = agent_access, max_instances = 1,
        options = server_sync and fs.FILE_SYNCHRONOUS_IO_NONALERT or 0,
        inbound_quota = PIPE_BUF, outbound_quota = PIPE_BUF,
    }
    -- The child's end is a plain open on the same \Device\NamedPipe path;
    -- npfs connects it to the listening server instance.  Synchronous so the
    -- child's ordinary CRT ReadFile/WriteFile behave as it expects.
    local noa = oa.path(name)
    local client = fs.NtCreateFile(child_access, noa.oa, nil,
        fs.FILE_ATTRIBUTE_NORMAL,
        fs.FILE_SHARE_READ + fs.FILE_SHARE_WRITE,
        fs.FILE_OPEN,
        fs.FILE_SYNCHRONOUS_IO_NONALERT + fs.FILE_NON_DIRECTORY_FILE,
        nil, 0)
    return server, client
end

-- tty.run — spawn opts.exe under the line discipline, event-driven.
--
-- The console is one \Device\Serial0 handle init opened
-- FILE_SYNCHRONOUS_IO_NONALERT for all of stdin/stdout/stderr (INIT.C).  A
-- synchronous file object serialises every I/O through its lock, so a blocked
-- read on it starves a concurrent write — the deadlock that forced the old
-- single-thread poll.  We want a second, OVERLAPPED handle (read + write
-- outstanding at once, no lock).
--
-- Serial is an EXCLUSIVE device (SERIAL.SYS calls IoCreateDevice with
-- Exclusive=TRUE), so a second open BY NAME while init's handle is open gets
-- STATUS_ACCESS_DENIED (IopParseDevice's exclusivity check, PARSE.C).  But a
-- RELATIVE open — RootDirectory = the inherited handle, empty name — is exempt
-- (`op->RelatedFileObject != NULL`), so it yields a second handle to the same
-- exclusive device.  We open that one overlapped and leave init's synchronous
-- handle untouched for the rest of the process; nothing is closed or restored.
--
-- The reactor waits on two read completions — serial-in (a keystroke) and the
-- from-child pipe (output) — plus a serial-write completion used only to pace
-- one write at a time.
--
-- No missed events: these are auto-reset (synchronization) event objects,
-- which LATCH.  The I/O manager clears each event at issue (READ.C) and sets
-- it on completion (synchronous OR asynchronous); WaitAny returns the lowest
-- signalled and resets only that one, so simultaneous completions are
-- serviced on consecutive iterations.  Each outstanding op has its own event
-- AND its own IO_STATUS_BLOCK (never shared), and the event is treated purely
-- as a wake — results are read from the IOSB, and we re-arm immediately.
function M.run(opts)
    assert(opts and opts.exe, "tty.run: opts.exe required")
    assert(io.stdout and io.stdout._h, "tty.run: no console handle")
    local log = opts.log or function() end

    -- Second, overlapped handle to the (exclusive) console via a relative
    -- open against the inherited handle (empty name + RootDirectory).  No
    -- FILE_SYNCHRONOUS_IO_NONALERT => read and write can be outstanding at
    -- once.  `rel` stays referenced until NtCreateFile captures the name.
    local rel = oa.path("", 0, io.stdout._h)
    local ser = fs.NtCreateFile(SERIAL_ACCESS, rel.oa, nil,
        fs.FILE_ATTRIBUTE_NORMAL,
        fs.FILE_SHARE_READ + fs.FILE_SHARE_WRITE,
        fs.FILE_OPEN, fs.FILE_NON_DIRECTORY_FILE, nil, 0)
    fs.serial_set_timeouts(ser, SERIAL_TIMEOUTS)     -- first-byte-return reads
    local raw_ser = handle.raw(ser)
    log("opened overlapped console (relative)")

    local ok, result = pcall(function()
        _seq = _seq + 1
        local tag = "\\Device\\NamedPipe\\tty" .. _seq
        -- to-child: we write cooked lines, child reads stdin (sync server).
        local in_srv,  in_cli  = make_pipe(tag .. "i",
            fs.FILE_GENERIC_WRITE, fs.FILE_GENERIC_READ, true)
        -- from-child: child writes stdout/stderr, we wait on it (overlapped).
        local out_srv, out_cli = make_pipe(tag .. "o",
            fs.FILE_GENERIC_READ, fs.FILE_GENERIC_WRITE, false)
        local raw_out = handle.raw(out_srv)

        local proc = ps.spawn{
            exe = opts.exe, cmdline = opts.cmdline, cwd = opts.cwd,
            dll_path = opts.dll_path, env = opts.env,
            stdin = in_cli, stdout = out_cli, stderr = out_cli,
        }
        in_cli:close(); out_cli:close()
        ps.NtResumeThread(proc.thread)
        log("spawned + resumed")

        -- One auto-reset event + one IOSB per outstanding operation.
        local ev_rs = ke.event{ notify = false }   -- serial read  (keystroke)
        local ev_rp = ke.event{ notify = false }   -- pipe read    (child out)
        local ev_ws = ke.event{ notify = false }   -- serial write (pacing)
        local raw_rs = handle.raw(ev_rs:handle())
        local raw_rp = handle.raw(ev_rp:handle())
        local raw_ws = handle.raw(ev_ws:handle())
        local io_rs  = ffi.new('IO_STATUS_BLOCK')
        local io_rp  = ffi.new('IO_STATUS_BLOCK')
        local io_ws  = ffi.new('IO_STATUS_BLOCK')
        local sbuf   = ffi.new('unsigned char[?]', SERIAL_READ_LEN)
        local pbuf   = ffi.new('char[?]', PIPE_BUF)
        -- Async (non-FILE_SYNCHRONOUS) reads/writes on a device that isn't a
        -- named pipe/mailslot REQUIRE a ByteOffset — NtReadFile/NtWriteFile
        -- reject a NULL one with STATUS_INVALID_PARAMETER (READ.C:497).  Serial
        -- ignores the value, but it must be present; a zero offset satisfies it.
        -- (The pipe ops keep a NULL offset — FO_NAMED_PIPE is exempt.)
        local ser_off = ffi.new('LARGE_INTEGER')   -- QuadPart = 0

        -- Serial output write queue.  Coalesce into a Lua string and keep ONE
        -- write in flight: that paces us against a flooding child (bounding
        -- kernel write IRPs) and lets us reuse one scratch buffer.  Serial is
        -- DO_BUFFERED_IO, so the kernel snapshots the buffer inside NtWriteFile
        -- — the buffer's free to reuse the moment a write is allowed; ev_ws is
        -- purely "a write slot freed", not buffer-lifetime.
        local q, qn, busy = {}, 0, false
        local wbuf, wcap = nil, 0
        local function try_write()
            if busy or qn == 0 then return end
            local chunk = table.concat(q); q, qn = {}, 0
            local n = #chunk
            if n > wcap then wcap = n; wbuf = ffi.new('char[?]', n) end
            ffi.copy(wbuf, chunk, n)
            busy = true
            ntdll.NtWriteFile(raw_ser, raw_ws, nil, nil, io_ws, wbuf, n, ser_off, nil)
        end
        local function emit(s)
            if #s == 0 then return end
            q[#q + 1] = s; qn = qn + #s
            try_write()
        end
        local function to_child(s)
            local cb = ffi.new('char[?]', #s); ffi.copy(cb, s, #s)
            pcall(fs.NtWriteFile, in_srv, cb, #s, nil)
        end

        local ed = M.lineedit()
        local waitset = ffi.new('HANDLE[3]', raw_rs, raw_rp, raw_ws)

        -- Prime the two reads.  We never inline-process the return value: the
        -- event is set on synchronous completion too, so the wait picks each
        -- completion up exactly once via its IOSB.
        ntdll.NtReadFile(raw_ser, raw_rs, nil, nil, io_rs, sbuf, SERIAL_READ_LEN, ser_off, nil)
        ntdll.NtReadFile(raw_out, raw_rp, nil, nil, io_rp, pbuf, PIPE_BUF, nil, nil)
        log("reactor: entering wait")

        local done = false
        while not done do
            local w = ntdll.NtWaitForMultipleObjects(3, waitset, WAIT_ANY, 0, nil)
            if w == 0 then                                  -- keystroke(s)
                local n = tonumber(io_rs.Information)
                for i = 0, n - 1 do
                    local echo, line = ed:feed(sbuf[i])
                    if #echo > 0 then emit(echo) end
                    if line ~= nil then to_child(line .. "\n") end
                end
                ntdll.NtReadFile(raw_ser, raw_rs, nil, nil, io_rs, sbuf, SERIAL_READ_LEN, ser_off, nil)
            elseif w == 1 then                              -- child output / exit
                local n   = tonumber(io_rp.Information)
                local stu = err.normalize(io_rp.Status)
                if n > 0 then emit(ffi.string(pbuf, n)) end
                if stu == npfs.STATUS_PIPE_BROKEN
                   or stu == npfs.STATUS_PIPE_CLOSING
                   or stu == fs.STATUS_END_OF_FILE then
                    done = true
                else
                    ntdll.NtReadFile(raw_out, raw_rp, nil, nil, io_rp, pbuf, PIPE_BUF, nil, nil)
                end
            elseif w == 2 then                              -- a serial write finished
                busy = false
                try_write()
            else
                done = true                                 -- unexpected wait result
            end
        end
        log("child stdout closed")

        -- Flush any serial output still queued / in flight before we hand the
        -- port back, so the child's final burst isn't lost to the reopen.
        while busy or qn > 0 do
            if busy then
                ke.NtWaitForSingleObject(ev_ws:handle(), false, ke.timeout(2.0))
                busy = false
            end
            try_write()
        end

        ke.NtWaitForSingleObject(proc.process, false, nil)
        local status = ps.NtQueryInformationProcess_Basic(proc.process).exit_status
        proc.thread:close(); proc.process:close()
        in_srv:close(); out_srv:close()
        return status
    end)

    -- Drop our overlapped handle; init's synchronous console handle is
    -- untouched, so the rest of the process keeps working with no restore.
    pcall(function() ser:close() end)
    if not ok then error(result, 0) end
    log("child exited status=0x" .. string.format("%08x", result))
    return result
end

return M
