-- nt.term.stream — an overlapped byte-transport over an NT handle.
--
-- This is the kernel backend behind the scheduler's blocking read/write.
-- It wraps ANY overlapped NT handle — a serial console (nt.term.console),
-- a pipe to a child (nt.term.child), or a socket — and presents the same
-- transport read()/write() the pure stack already uses over channels.
--
-- The handle MUST be opened overlapped (no FILE_SYNCHRONOUS_IO_*): a
-- synchronous handle would block the whole OS thread inside the syscall
-- and stall every coroutine.  Here read() issues an overlapped read and
-- parks the calling task on its completion event via sched.await; the
-- scheduler's one kernel wait resumes it.  No thread is ever blocked
-- while a task could run, and there is no polling.
--
--   local s = stream.wrap(nt_handle, { offset = true })   -- serial
--   local s = stream.wrap(pipe_handle)                     -- pipe (no offset)
--   local data = s:read([max])   -- bytes, or nil at end of stream
--   s:write(data)
--   s:close()
--
-- opts.offset: pass true for devices that REQUIRE a ByteOffset on async
--   I/O (serial and other non-pipe devices reject a NULL one); pipes and
--   mailslots are exempt and leave it nil.
-- opts.rsize: read chunk size (default 4096).

local ffi    = require('ffi')
local sched  = require('nt.term.sched')
local ke     = require('nt.dll.ke')
local ntdll  = require('nt.dll')
local handle = require('nt.dll.handle')
local err    = require('nt.dll.errors')

local STATUS_PENDING = 0x00000103

local M = {}

local S = {}
S.__index = S

function M.wrap(h, opts)
    opts = opts or {}
    local rev = ke.event{ notify = false }   -- auto-reset read-completion
    local wev = ke.event{ notify = false }   -- auto-reset write-completion
    local rsize = opts.rsize or 4096
    return setmetatable({
        h      = h,
        raw    = handle.raw(h),
        rev_h  = rev:handle(),  rraw = handle.raw(rev:handle()),
        wev_h  = wev:handle(),  wraw = handle.raw(wev:handle()),
        riosb  = ffi.new('IO_STATUS_BLOCK'),
        wiosb  = ffi.new('IO_STATUS_BLOCK'),
        rbuf   = ffi.new('char[?]', rsize),
        rsize  = rsize,
        offset = opts.offset and ffi.new('LARGE_INTEGER') or nil,  -- QuadPart 0
        pend   = "",                          -- bytes read but not yet returned
        pi     = 1,
        eof    = false,
    }, S)
end

local function take(self, max)
    local avail = #self.pend - self.pi + 1
    local n = (max and max < avail) and max or avail
    local s = self.pend:sub(self.pi, self.pi + n - 1)
    self.pi = self.pi + n
    return s
end

-- read([max]) → bytes (<= max if given), or nil at end of stream.  Parks
-- the calling task until the overlapped read completes.
function S:read(max)
    if self.pi <= #self.pend then return take(self, max) end
    if self.eof then return nil end

    local st = err.normalize(ntdll.NtReadFile(
        self.raw, self.rraw, nil, nil, self.riosb,
        self.rbuf, self.rsize, self.offset, nil))
    if st == STATUS_PENDING then
        sched.await(self.rev_h)
        st = err.normalize(self.riosb.Status)
    end

    -- Trust Information ONLY on STATUS_SUCCESS.  A synchronous failure
    -- (PIPE_CLOSING/BROKEN when the peer has gone) does NOT write the
    -- IOSB, so reading Information then would re-copy the previous read's
    -- stale bytes from rbuf — that double-delivered the last chunk.  Any
    -- non-success status (EOF, broken, cancelled, error) ends the stream.
    if st == 0 then                            -- STATUS_SUCCESS
        local n = tonumber(self.riosb.Information)
        if n and n > 0 then
            self.pend, self.pi = ffi.string(self.rbuf, n), 1
            return take(self, max)
        end
    end
    self.eof = true
    return nil
end

-- write(data) — overlapped write; parks the task until it completes.
-- `wbuf` stays referenced across the await, so the kernel's copy is safe
-- regardless of buffered vs direct I/O.
function S:write(data)
    if #data == 0 then return self end
    local n = #data
    local wbuf = ffi.new('char[?]', n)
    ffi.copy(wbuf, data, n)
    local st = err.normalize(ntdll.NtWriteFile(
        self.raw, self.wraw, nil, nil, self.wiosb,
        wbuf, n, self.offset, nil))
    if st == STATUS_PENDING then
        sched.await(self.wev_h)
    end
    return self
end

function S:close()
    if self.h     then self.h:close();     self.h     = nil end
    if self.rev_h then self.rev_h:close();  self.rev_h = nil end
    if self.wev_h then self.wev_h:close();  self.wev_h = nil end
end

return M
