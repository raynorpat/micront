-- nt.term.sched — a cooperative coroutine scheduler (a tiny async runtime).
--
-- Blocking is `coroutine.yield`; progress is a resume.  There is no
-- polling and no idle spin: a task that can't proceed parks (yields),
-- and is resumed the instant its input exists.  When nothing is runnable
-- the scheduler makes ONE blocking kernel wait on the set of awaited
-- completion objects (NtWaitForMultipleObjects) and resumes whoever
-- fired; if there is nothing to wait on and nothing runnable, every task
-- has finished (or, if some are still parked, that's a deadlock we raise
-- rather than hang on).
--
-- Three ways a task unblocks, all event-driven:
--
--   * in-process, same thread — a `channel`: c:read() with nothing
--     buffered parks the caller; a peer c:write(data) wakes it.  Pure
--     cooperative handoff, no kernel object.  This is the in-process
--     direct-attach path.
--
--   * cross-thread / remote — a kernel byte stream (nt.term.stream):
--     its read() issues an overlapped read then `sched.await(event)`,
--     which parks the task until the I/O completes.
--
--   * cooperative yield — sched.pass() re-queues the caller behind the
--     other ready tasks (a fairness point), without blocking.
--
-- The app sees ONE uniform API regardless of backend: `local data =
-- t:read()` inside a task suspends and resumes correctly whether `t` is
-- a channel, a pipe to another lua_State, or a socket.
--
-- Host-testable: a scenario built only from channels + tasks touches no
-- kernel object, so :await is never reached and ffi/ntdll are never
-- required — the scheduler and channels run on the host and in selftest.

local M = {}

-- Yielded request sentinels.  A task yields one of these to the loop:
--   "park"           parked; an external waker (channel) will re-ready me
--   "pass"           cooperative yield; re-queue me now
--   {event=HANDLE}   wake me when this NT object signals
local PARK, PASS = "park", "pass"

-- ===================================================================
-- await primitives — called from inside a running task.  These just
-- yield a request; whichever scheduler resumed the task handles it
-- (no scheduler reference needed — the yield returns to S:run).
-- ===================================================================

-- Park until an NT waitable (an NT_HANDLE — typically an event the
-- overlapped read completes to) signals.  Returns the 0-based index the
-- kernel wait reported (always 0 for a single object; the scheduler may
-- coalesce several awaits into one wait and routes each result back to
-- the right task).
function M.await(handle)
    return coroutine.yield({ event = handle })
end

-- Cooperative yield: let other ready tasks run, then resume here.
function M.pass()
    return coroutine.yield(PASS)
end

-- ===================================================================
-- Scheduler
-- ===================================================================

local Sched = {}
Sched.__index = Sched

function M.new()
    return setmetatable({
        ready   = {},      -- FIFO of { co, vals, n } resume records
        kwaits  = {},      -- list of { handle, co } awaiting kernel events
        live    = 0,       -- spawned-but-not-finished task count
        current = nil,     -- the coroutine running right now
        stopped = false,   -- set by :stop() to end run() early
    }, Sched)
end

-- End run() at the next loop turn, leaving any still-parked tasks
-- abandoned (their coroutines are GC'd; any pending kernel I/O is
-- cancelled when the caller closes the underlying handle).  For a
-- reactor that must end on a condition — e.g. a child exiting — rather
-- than when every task has finished (a console reader never will).
function Sched:stop()
    self.stopped = true
end

-- Queue a coroutine to be resumed with the given values.
function Sched:_enqueue(co, ...)
    self.ready[#self.ready + 1] = { co = co, vals = { ... }, n = select('#', ...) }
end

-- Wake a parked coroutine (resume value defaults to nil).  Called by
-- channels (on write/close) and by the kernel-wait path.
function Sched:wake(co, ...)
    self:_enqueue(co, ...)
end

-- Spawn a task.  fn(...) runs as a coroutine; extra args are passed to
-- it on first resume.  Returns the coroutine handle.
function Sched:spawn(fn, ...)
    local co = coroutine.create(fn)
    self.live = self.live + 1
    self:_enqueue(co, ...)
    return co
end

-- A channel bound to this scheduler.
function Sched:channel()
    return setmetatable({
        sched  = self,
        buf    = {},
        n      = 0,
        reader = nil,      -- the single parked reader coroutine, if any
        closed = false,
    }, M._Chan)
end

function Sched:_dispatch(co, req)
    if req == PARK then
        return                       -- left parked; a waker will re-ready it
    elseif req == PASS then
        self:_enqueue(co)            -- fairness yield
    elseif type(req) == "table" and req.event then
        self.kwaits[#self.kwaits + 1] = { handle = req.event, co = co }
    else
        error("sched: task yielded an unknown request: " .. tostring(req))
    end
end

-- Block in the kernel on every awaited event until one signals, then
-- ready its task.  Lazy-required so a pure-coroutine run never touches
-- ffi/ntdll (and so this module loads on the host).
function Sched:_kernel_wait()
    local ffi    = require('ffi')
    local handle = require('nt.dll.handle')
    local ntdll  = require('nt.dll')

    local n   = #self.kwaits
    local arr = ffi.new('HANDLE[?]', n)
    for i = 1, n do arr[i - 1] = handle.raw(self.kwaits[i].handle) end

    -- WaitAny (type 1), non-alertable, infinite timeout → returns the
    -- 0-based index of the signalled object.  Auto-reset events reset
    -- themselves on satisfaction; the resumed task re-arms its read.
    local w  = ntdll.NtWaitForMultipleObjects(n, arr, 1, 0, nil)
    local kw = table.remove(self.kwaits, w + 1)
    self:wake(kw.co, w)
end

-- Run until no task can make progress.  Returns when all tasks finish.
function Sched:run()
    while self.live > 0 do
        if self.stopped then break end
        if #self.ready > 0 then
            local item = table.remove(self.ready, 1)
            self.current = item.co
            local res = { coroutine.resume(item.co, unpack(item.vals, 1, item.n)) }
            self.current = nil
            if not res[1] then
                self.live = self.live - 1
                error("sched: task error: " .. tostring(res[2]), 0)
            elseif coroutine.status(item.co) == "dead" then
                self.live = self.live - 1
            else
                self:_dispatch(item.co, res[2])
            end
        elseif #self.kwaits > 0 then
            self:_kernel_wait()
        else
            error(("sched: deadlock — %d task(s) parked with no waker")
                  :format(self.live), 0)
        end
    end
end

-- ===================================================================
-- Channel — an in-process byte stream between two coroutines on one
-- scheduler.  Single reader; any number of writers.  Reads park when
-- empty and resume on the next write or on close (EOF).
-- ===================================================================

local Chan = {}
Chan.__index = Chan
M._Chan = Chan

local function drain(self, max)
    local data = table.concat(self.buf)
    self.buf, self.n = {}, 0
    if max and #data > max then
        local rest = data:sub(max + 1)
        self.buf[1], self.n = rest, #rest
        data = data:sub(1, max)
    end
    return data
end

-- read([max]) → bytes (<= max if given) once any are available, or nil
-- at end of stream (closed and drained).  Parks the caller while empty.
function Chan:read(max)
    while self.n == 0 do
        if self.closed then return nil end
        if self.reader and self.reader ~= self.sched.current then
            error("channel: a second reader tried to park", 2)
        end
        self.reader = self.sched.current
        coroutine.yield(PARK)            -- woken by write/close; loop re-checks
    end
    self.reader = nil
    return drain(self, max)
end

-- write(data) — append bytes and wake a parked reader if there is one.
-- Never blocks (a byte channel is unbounded here; pacing, if ever
-- needed, belongs in a bounded variant, not this one).
function Chan:write(data)
    if self.closed then error("channel: write to a closed channel", 2) end
    if #data == 0 then return self end
    self.buf[#self.buf + 1] = data
    self.n = self.n + #data
    if self.reader then
        local co = self.reader
        self.reader = nil
        self.sched:wake(co)
    end
    return self
end

-- close — no more writes; a parked reader is woken to observe EOF.
function Chan:close()
    if self.closed then return self end
    self.closed = true
    if self.reader then
        local co = self.reader
        self.reader = nil
        self.sched:wake(co)
    end
    return self
end

function Chan:is_closed() return self.closed end

-- ===================================================================
-- Mailbox — a queue of DISCRETE messages between coroutines on one
-- scheduler.  Single reader; any number of writers.  Unlike Chan (a
-- byte stream that concatenates writes), each put() is one message that
-- get() returns whole — what a packet mux needs.  get() parks when
-- empty and resumes on the next put or on close (EOF, returns nil).
-- ===================================================================

local Mbox = {}
Mbox.__index = Mbox
M._Mbox = Mbox

-- get() → the next message, or nil at end of queue (closed and drained).
-- Parks the caller while empty.
function Mbox:get()
    while self.head > self.tail do
        if self.closed then return nil end
        if self.reader and self.reader ~= self.sched.current then
            error("mailbox: a second reader tried to park", 2)
        end
        self.reader = self.sched.current
        coroutine.yield(PARK)            -- woken by put/close; loop re-checks
    end
    self.reader = nil
    self.head = self.head + 1
    local item = self.q[self.head - 1]
    self.q[self.head - 1] = nil
    return item
end

-- put(item) — enqueue one message and wake a parked reader.  A put after
-- close is silently dropped: writers racing teardown shouldn't error.
function Mbox:put(item)
    if self.closed then return self end
    self.tail = self.tail + 1
    self.q[self.tail] = item
    if self.reader then
        local co = self.reader
        self.reader = nil
        self.sched:wake(co)
    end
    return self
end

-- close — no more puts; a parked reader is woken to observe EOF after the
-- queue drains.
function Mbox:close()
    if self.closed then return self end
    self.closed = true
    if self.reader then
        local co = self.reader
        self.reader = nil
        self.sched:wake(co)
    end
    return self
end

function Mbox:is_closed() return self.closed end

-- A message mailbox bound to this scheduler.
function Sched:mailbox()
    return setmetatable({
        sched  = self,
        q      = {},
        head   = 1,        -- next index to read
        tail   = 0,        -- last index written
        reader = nil,
        closed = false,
    }, Mbox)
end

return M
