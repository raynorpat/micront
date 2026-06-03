-- Sync primitives: Event (ke) + Mutex / Semaphore / Timer (ex).
-- Exercises both raw Nt* wrappers and the Lua-idiomatic factory
-- objects with their :method() surface.

local t      = require('test')
local ke     = require('nt.dll.ke')
local ex     = require('nt.dll.ex')
local ps     = require('nt.dll.ps')
local thread = require('nt.thread')
local handle = require('nt.dll.handle')

t.suite("sync")

-- ------------------------------------------------------------------
-- Event
-- ------------------------------------------------------------------

t.test("event: initial state false, signal() makes wait() return true", function()
    local e = ke.event()
    t.eq(e:wait(0), false, "not signaled yet, immediate wait times out")
    e:signal()
    t.eq(e:wait(0), true,  "signaled now, wait returns true")
    e:close()
end)

t.test("event: notify=false auto-resets after single waiter", function()
    local e = ke.event{ notify = false, signaled = true }
    t.eq(e:wait(0), true,  "consumed the initial signal")
    t.eq(e:wait(0), false, "auto-reset left it unsignaled")
    e:close()
end)

t.test("event: timeout returns false, no error", function()
    local e = ke.event()
    t.eq(e:wait(0.05), false, "0.05s timeout on unsignaled event")
    e:close()
end)

t.test("event: reset() clears a signaled notification event", function()
    local e = ke.event{ signaled = true }
    t.eq(e:wait(0), true)
    -- Wait again — still signaled (NotificationEvent = manual reset).
    t.eq(e:wait(0), true)
    e:reset()
    t.eq(e:wait(0), false)
    e:close()
end)

t.test("event: clear() resets state (NtClearEvent vs NtResetEvent)", function()
    -- NtClearEvent and NtResetEvent both reset the event; the
    -- difference is NtResetEvent returns the previous state via an
    -- out-param and NtClearEvent doesn't.  ke.event:clear() wraps
    -- the cheap one.  EX/EVENT.C marked uncovered until this test.
    local e = ke.event{ signaled = true }
    t.eq(e:wait(0), true, "starts signaled")
    e:clear()
    t.eq(e:wait(0), false, "clear() resets state -> wait times out")
    e:close()
end)

t.test("event: pulse() releases waiters then auto-resets", function()
    -- NtPulseEvent: signals + immediately clears.  With no waiter
    -- pending it's a no-op transition (signaled briefly, then
    -- non-signaled).  Test: start unsignaled, pulse, wait must
    -- time out (the brief signaled window already closed).  Then
    -- signal explicitly + pulse + wait must STILL time out (pulse
    -- clears on the way through).
    local e = ke.event()
    e:pulse()
    t.eq(e:wait(0), false, "pulse() on already-clear event leaves clear")

    e:signal()
    t.eq(e:wait(0), true, "signal makes wait return true")
    e:pulse()
    t.eq(e:wait(0), false,
         "pulse() on signaled event releases-and-clears -> wait times out")
    e:close()
end)

-- ------------------------------------------------------------------
-- Mutex
-- ------------------------------------------------------------------

t.test("mutex: lock/unlock round-trip", function()
    local m = ex.mutex()
    t.ok(m:lock(0), "uncontended acquire succeeds")
    m:unlock()
    t.ok(m:lock(0), "re-acquire after unlock succeeds")
    m:unlock()
    m:close()
end)

t.test("mutex: owned=true makes creator the initial owner", function()
    local m = ex.mutex{ owned = true }
    local info = m:query()
    t.eq(info.owned_by_caller, true)
    m:unlock()
    m:close()
end)

t.test("mutex: recursive lock by same thread", function()
    local m = ex.mutex{ owned = true }
    t.ok(m:lock(0), "recursive acquire from owning thread succeeds")
    t.ok(m:lock(0), "and again")
    m:unlock(); m:unlock(); m:unlock()
    m:close()
end)

-- ------------------------------------------------------------------
-- Semaphore
-- ------------------------------------------------------------------

t.test("semaphore: initial slots drain then refill", function()
    local s = ex.semaphore{ initial = 2, maximum = 5 }
    t.ok(s:acquire(0), "got slot 1/2")
    t.ok(s:acquire(0), "got slot 2/2")
    t.eq(s:acquire(0.01), false, "no more slots — times out")
    s:release(2)
    t.ok(s:acquire(0), "refilled, acquire 1")
    t.ok(s:acquire(0), "refilled, acquire 2")
    s:close()
end)

t.test("semaphore: query reports current / maximum", function()
    local s = ex.semaphore{ initial = 3, maximum = 10 }
    local info = s:query()
    t.eq(info.current, 3)
    t.eq(info.maximum, 10)
    s:acquire(0); s:acquire(0)
    t.eq(s:query().current, 1)
    s:close()
end)

t.test("semaphore.release returns previous count", function()
    local s = ex.semaphore{ initial = 0, maximum = 5 }
    t.eq(s:release(1), 0, "previous = 0 before first release")
    t.eq(s:release(2), 1, "previous = 1 before 2-slot release")
    s:close()
end)

t.test("semaphore: missing maximum raises", function()
    t.raises(function() ex.semaphore{ initial = 1 } end,
             "maximum is required")
end)

-- Each waiter runs in its own cr_thread lua_State and borrows the shared
-- semaphore handle (same process => same handle value). It blocks on a slot
-- the semaphore does not have yet, then reports the outcome.
local SEM_WAITER = [[
local ex     = require('nt.dll.ex')
local handle = require('nt.dll.handle')
local sem = setmetatable({ _h = handle.from_payload(PAYLOAD) }, ex.Semaphore)
return sem:acquire(10.0) and "got" or "timeout"
]]

-- The exact contract WaitOnAddress is built on: K threads block, a single
-- release(K) (the WakeByAddressAll path) wakes all K. A counting semaphore
-- gives "no lost wakeups" by construction -- the K released permits persist,
-- so a waiter that has not blocked yet still acquires immediately. Correctness
-- is therefore timing-independent; the delay below only makes the "all
-- genuinely blocked first" case the common one.
t.test("semaphore: release(K) wakes K concurrent waiters, no lost wakeups", function()
    local K = 4
    local s = ex.semaphore{ initial = 0, maximum = K }
    local semh = handle.to_payload(s:handle())

    local waiters = {}
    for i = 1, K do waiters[i] = thread.run(SEM_WAITER, semh) end

    ke.NtDelayExecution(false, ke.timeout(0.1))   -- let them reach acquire()
    t.eq(s:release(K), 0, "count was 0 before the wake-all")

    local got = 0
    for i = 1, K do
        t.ok(waiters[i]:wait(10.0), "waiter " .. i .. " finished")
        local st, v = waiters[i]:result()
        t.eq(st, "ok", "waiter " .. i .. " status (" .. tostring(v) .. ")")
        if v == "got" then got = got + 1 end
        waiters[i]:close()
    end
    t.eq(got, K, "all " .. K .. " waiters acquired exactly one slot")
    s:close()
end)

-- ------------------------------------------------------------------
-- Timer
-- ------------------------------------------------------------------

t.test("timer: one-shot fires within the due interval", function()
    local tm = ex.timer{}
    tm:set(0.05)   -- fire in 50ms
    t.ok(tm:wait(0.5), "fired within 500ms timeout")
    tm:close()
end)

t.test("timer: cancel before fire, wait times out", function()
    local tm = ex.timer{}
    tm:set(5.0)    -- 5s from now
    tm:cancel()
    t.eq(tm:wait(0.1), false, "no fire after cancel")
    tm:close()
end)

-- NT 3.5's NtSetTimer is one-shot only — there is no periodic-timer
-- syscall (KeSetTimerEx / a Period argument arrived in NT 4.0), so
-- there is no periodic case to test here.

-- ------------------------------------------------------------------
-- EventPair
-- ------------------------------------------------------------------

t.test("event_pair: signal high then wait high completes immediately", function()
    local ep = ex.event_pair()
    ep:signal_high()
    ep:wait_high()   -- consumes the signal
    ep:close()
end)

t.test("event_pair: signal low then wait low completes immediately", function()
    local ep = ex.event_pair()
    ep:signal_low()
    ep:wait_low()
    ep:close()
end)

t.test("event_pair: two threads rendezvous via set-and-wait atomics", function()
    local ntdll = require('nt.dll')
    local ep = ex.event_pair()
    -- Spawned thread's entry is ntdll.NtSetLowWaitHighEventPair itself.
    -- Its signature — NTSTATUS __stdcall fn(HANDLE) — matches the
    -- thread-entry contract exactly, so we hand the ntdll function
    -- straight to create_thread. The NT_HANDLE param is extracted by
    -- the wrapper.
    local th = ps.create_thread(ntdll.NtSetLowWaitHighEventPair,
                                ep:handle())

    -- Main thread: atomic signal-high + wait-low. Rendezvous with the
    -- spawned thread's signal-low + wait-high.
    ep:signal_high_wait_low()

    ke.NtWaitForSingleObject(th, false, ke.timeout(1.0))
    th:close()
    ep:close()
end)

-- ------------------------------------------------------------------
-- Yield (ke) — NtYieldExecution, backs Win32 SwitchToThread
-- ------------------------------------------------------------------

t.test("yield: returns a success status, never raises", function()
    local st = ke.NtYieldExecution()
    -- STATUS_SUCCESS when a switch happened, STATUS_NO_YIELD_PERFORMED
    -- when nothing else was runnable. Both are success codes, not errors.
    t.ok(st == 0 or st == 0x40000024,
         "unexpected status 0x" .. string.format("%08X", st))
end)

t.test("yield: a burst of yields completes without hanging", function()
    -- Proves the dispatcher round-robin path returns control to us rather
    -- than losing the thread — if it didn't, the VM would hang here and the
    -- suite would never report.
    for _ = 1, 1000 do ke.NtYieldExecution() end
    t.ok(true, "1000 yields returned")
end)

-- IoCompletion has its own suite — see test/iocp.lua (idiomatic +
-- concurrency) and test/fuzz/iocp.lua (raw-ntdll adversarial cases).

-- Cross-thread Event signaling is covered implicitly: Event signal/wait
-- semantics are tested same-thread above, and cross-thread sync is
-- tested via EventPair's rendezvous. No dedicated test needed.
