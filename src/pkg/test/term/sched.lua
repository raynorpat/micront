-- nt.term.sched — cooperative scheduler + in-process channel.
--
-- Pure coroutine scenarios only: no task here calls sched.await, so the
-- kernel-wait path (ffi/ntdll) is never reached and the whole suite runs
-- on the host.  The kernel-stream integration (await on a real overlapped
-- completion) is exercised on boot once nt.term.stream lands.

local t     = require('test')
local sched = require('nt.term.sched')

t.suite("nt.term.sched: scheduler + channel")

t.test("a task that returns ends the run", function()
    local S, ran = sched.new(), false
    S:spawn(function() ran = true end)
    S:run()
    t.eq(ran, true)
end)

t.test("reader parks, writer wakes it (cooperative handoff)", function()
    local S, c, got = sched.new(), nil, nil
    c = S:channel()
    S:spawn(function() got = c:read() end)   -- parks: channel empty
    S:spawn(function() c:write("hi") end)    -- wakes the parked reader
    S:run()
    t.eq(got, "hi")
end)

t.test("a write before any reader is buffered, then drained", function()
    local S = sched.new()
    local c, got = S:channel(), nil
    S:spawn(function() c:write("hi") end)    -- no reader yet → buffered
    S:spawn(function() got = c:read() end)
    S:run()
    t.eq(got, "hi")
end)

t.test("close wakes a parked reader with EOF (nil)", function()
    local S = sched.new()
    local c, got = S:channel(), "sentinel"
    S:spawn(function() got = c:read() end)   -- parks
    S:spawn(function() c:close() end)        -- wakes → EOF
    S:run()
    t.eq(got, nil)
end)

t.test("read(max) splits and keeps the remainder", function()
    local S = sched.new()
    local c, r = S:channel(), {}
    S:spawn(function() c:write("abcdef") end)
    S:spawn(function() r[1] = c:read(3); r[2] = c:read(3) end)
    S:run()
    t.eq(r[1], "abc")
    t.eq(r[2], "def")
end)

t.test("multiple writes coalesce for one read", function()
    local S = sched.new()
    local c, got = S:channel(), nil
    S:spawn(function() c:write("ab"); c:write("cd") end)
    S:spawn(function() got = c:read() end)
    S:run()
    t.eq(got, "abcd")
end)

t.test("a parked reader with no waker is a deadlock, not a hang", function()
    local S = sched.new()
    local c = S:channel()
    S:spawn(function() c:read() end)         -- parks forever
    t.raises(function() S:run() end, "deadlock")
end)

t.test("pass() is a fairness yield, FIFO order preserved", function()
    local S, log = sched.new(), {}
    S:spawn(function() log[#log+1] = "a1"; sched.pass(); log[#log+1] = "a2" end)
    S:spawn(function() log[#log+1] = "b1"; sched.pass(); log[#log+1] = "b2" end)
    S:run()
    t.eq(table.concat(log, ","), "a1,b1,a2,b2")
end)

t.test("a three-stage pipeline streams end to end", function()
    local S = sched.new()
    local src, dst, out = S:channel(), S:channel(), nil
    S:spawn(function()                       -- producer
        src:write("hello"); src:close()
    end)
    S:spawn(function()                       -- transform stage
        while true do
            local d = src:read()
            if d == nil then dst:close(); break end
            dst:write(d:upper())
        end
    end)
    S:spawn(function()                       -- consumer
        local parts = {}
        while true do
            local d = dst:read()
            if d == nil then break end
            parts[#parts+1] = d
        end
        out = table.concat(parts)
    end)
    S:run()
    t.eq(out, "HELLO")
end)

t.test("a reader woken across several writes sees them in order", function()
    local S = sched.new()
    local c, seen = S:channel(), {}
    S:spawn(function()                       -- reader drains until EOF
        while true do
            local d = c:read()
            if d == nil then break end
            seen[#seen+1] = d
        end
    end)
    S:spawn(function()                       -- writer paces with pass()
        c:write("one"); sched.pass()
        c:write("two"); sched.pass()
        c:close()
    end)
    S:run()
    t.eq(table.concat(seen, "-"), "one-two")
end)

t.test("stop() ends run() even with a task still parked", function()
    local S, reached = sched.new(), false
    S:spawn(function() S:channel():read() end)        -- parks forever
    S:spawn(function() reached = true; S:stop() end)  -- ends the reactor
    S:run()                                           -- returns despite the parked task
    t.eq(reached, true)
end)

t.test("a second reader parking on one channel is rejected", function()
    local S = sched.new()
    local c = S:channel()
    S:spawn(function() c:read() end)                  -- first reader parks
    S:spawn(function()
        t.raises(function() c:read() end, "second reader")
        c:close()                                     -- release the first
    end)
    S:run()
end)
