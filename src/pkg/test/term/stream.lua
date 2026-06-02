-- nt.term.stream — overlapped byte-transport over a real NT handle.
--
-- BOOT-ONLY: this needs live kernel objects (an npfs pipe pair, events,
-- overlapped NtReadFile/NtWriteFile), so it is NOT in test.term.all (the
-- pure aggregator).  It drives the actual event-driven path on MicroNT:
-- a real overlapped read parks a coroutine via sched.await, and the
-- scheduler's NtWaitForMultipleObjects resumes it when the peer's write
-- completes — the same machinery a serial console and a child pipe use.

local t      = require('test')
local sched  = require('nt.term.sched')
local stream = require('nt.term.stream')
local npfs   = require('nt.dll.npfs')
local fs     = require('nt.dll.fs')

t.suite("nt.term.stream: overlapped pipe transport")

-- Make a connected, fully-overlapped duplex pipe pair and wrap each end
-- as a stream.  Both ends overlapped so reads/writes park the coroutine
-- (never block the OS thread).  Returns (server_stream, client_stream).
local function pipe_streams(name)
    local server = npfs.create_named_pipe{ name = name }       -- options 0 = overlapped
    -- open_pipe is (name, opts) positional — NOT a single table.  Drop the
    -- default FILE_SYNCHRONOUS_IO_NONALERT so this end is overlapped too.
    local client = npfs.open_pipe(name, { options = fs.FILE_NON_DIRECTORY_FILE })
    return stream.wrap(server), stream.wrap(client)
end

t.test("a write on one end is read on the other", function()
    local s, c = pipe_streams("\\Device\\NamedPipe\\tstrm-rt")
    t.defer(function() s:close(); c:close() end)
    local S, got = sched.new(), nil
    S:spawn(function() got = s:read() end)        -- parks on a real overlapped read
    S:spawn(function() c:write("hi") end)
    S:run()
    t.eq(got, "hi")
end)

t.test("the pipe is duplex — server can write to client too", function()
    local s, c = pipe_streams("\\Device\\NamedPipe\\tstrm-dx")
    t.defer(function() s:close(); c:close() end)
    local S, got = sched.new(), nil
    S:spawn(function() got = c:read() end)
    S:spawn(function() s:write("pong") end)
    S:run()
    t.eq(got, "pong")
end)

t.test("read(max) returns a slice and keeps the remainder", function()
    local s, c = pipe_streams("\\Device\\NamedPipe\\tstrm-mx")
    t.defer(function() s:close(); c:close() end)
    local S, r = sched.new(), {}
    S:spawn(function() r[1] = s:read(3); r[2] = s:read(3) end)
    S:spawn(function() c:write("abcdef") end)
    S:run()
    t.eq(r[1], "abc")
    t.eq(r[2], "def")
end)

t.test("closing the writer surfaces as EOF after the data drains", function()
    local s, c = pipe_streams("\\Device\\NamedPipe\\tstrm-eof")
    t.defer(function() s:close() end)
    local S, seen = sched.new(), {}
    S:spawn(function()
        while true do
            local d = s:read()
            if d == nil then break end
            seen[#seen+1] = d
        end
    end)
    S:spawn(function() c:write("bye"); c:close() end)
    S:run()
    t.eq(table.concat(seen), "bye")
end)

t.test("a line reader runs over a real pipe end to end", function()
    -- The full stack on kernel transports: the "terminal" side writes
    -- keystrokes into one pipe end; nt.term.line reads/echoes over the
    -- other.  Same readline that the pure channel test exercises, now on
    -- overlapped I/O.
    local line = require('nt.term.line')
    local s, c = pipe_streams("\\Device\\NamedPipe\\tstrm-line")
    t.defer(function() s:close(); c:close() end)
    local S, got = sched.new(), nil
    local rl = line.new{ input = s, output = s, prompt = "> " }   -- duplex end
    S:spawn(function() got = rl:read(); s:close() end)            -- close → drain hits EOF
    S:spawn(function() c:write("hello\r") end)
    -- drain the echo the reader writes back so its writes complete; ends
    -- at EOF once the reader closes its end above.
    S:spawn(function() while c:read() ~= nil do end end)
    S:run()
    t.eq(got, "hello")
end)
