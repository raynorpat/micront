-- test.iocp — idiomatic I/O completion port tests.
--
-- The Lua-idiomatic surface (ex.iocompletion → :depth() / :remove()),
-- driven by test.iosrc, which manufactures real completions by issuing
-- async reads on a scratch file associated with the port. The raw-ntdll
-- adversarial cases live in test/fuzz/iocp.lua.
--
-- NT 3.5 has no NtSetIoCompletion — completions only land on a port via
-- file-handle association + async I/O (see test/fuzz/iocp-plan.md).

local t      = require('test')
local ffi    = require('ffi')
local ex     = require('nt.dll.ex')
local ke     = require('nt.dll.ke')
local handle = require('nt.dll.handle')
local iosrc  = require('test.iosrc')
local thread = require('nt.thread')

t.suite("iocp")

-- Numeric value of a void* completion cookie, for comparison against
-- the integer keys/contexts the test handed in.
local function ptr_value(p) return tonumber(ffi.cast('uintptr_t', p)) end

-- ------------------------------------------------------------------
-- Empty port
-- ------------------------------------------------------------------

t.test("empty port has depth 0", function()
    local c = ex.iocompletion{ concurrent_threads = 1 }
    t.eq(c:depth(), 0)
    c:close()
end)

t.test("remove on empty port times out and returns nil", function()
    local c = ex.iocompletion{ concurrent_threads = 1 }
    t.eq(c:remove(0.05), nil, "empty remove → nil on timeout")
    c:close()
end)

-- ------------------------------------------------------------------
-- Round-trip — a real completion delivered through the port
-- ------------------------------------------------------------------

t.test("a real completion round-trips key/apc/status", function()
    local c   = ex.iocompletion{ concurrent_threads = 1 }
    local src = iosrc.new(c, 0xABCD)         -- association key
    src:emit(0x2222)                         -- ApcContext cookie

    -- remove() waits out the (small) async window if the read pended.
    local key, apc, status, info = c:remove(1.0)
    t.ne(key, nil, "a completion was delivered")
    t.eq(ptr_value(key), 0xABCD, "KeyContext = the association key")
    t.eq(ptr_value(apc), 0x2222, "ApcContext = the read's cookie")
    t.eq(status, 0, "the I/O completed STATUS_SUCCESS")
    t.eq(tonumber(info), iosrc.PAYLOAD_LEN, "Information = bytes read")
    t.eq(c:depth(), 0, "port drained")

    src:close()
    c:close()
end)

t.test("completions drain in FIFO order", function()
    local c   = ex.iocompletion{ concurrent_threads = 1 }
    local src = iosrc.new(c, 0xABCD)
    -- Reads on one file object serialize, so completions queue in
    -- issue order — the drain must come back in the same order.
    src:emit(0x1001)
    src:emit(0x1002)
    src:emit(0x1003)
    for _, want in ipairs({ 0x1001, 0x1002, 0x1003 }) do
        local _key, apc = c:remove(1.0)
        t.eq(apc and ptr_value(apc), want, "FIFO drain order")
    end
    t.eq(c:depth(), 0, "all three drained")

    src:close()
    c:close()
end)

-- ------------------------------------------------------------------
-- Concurrency — N completions, K consumer threads racing to drain.
--
-- The crux of an IOCP port: many threads call NtRemoveIoCompletion on
-- one port and KeRemoveQueue must hand each queued entry to exactly
-- one of them — no loss, no duplication. cr_thread (nt.thread) gives
-- each consumer its own lua_State on its own OS thread; the port
-- HANDLE is shared by value (same process = same handle table).
-- ------------------------------------------------------------------

-- Consumer chunk — runs in a fresh lua_State on its own thread.
-- PAYLOAD is the port's raw HANDLE value as a decimal string. The
-- consumer drains until the port is idle for a full timeout, then
-- returns the ApcContext cookies it observed as a comma-joined string.
local CONSUMER = [[
-- cr_thread sibling states run luaL_openlibs (wrapped) → the runtime
-- preamble sets package.path + searcher + io/os here too.
local ffi    = require('ffi')
local ex     = require('nt.dll.ex')
local handle = require('nt.dll.handle')

-- Same process → the port handle is valid in this thread. Borrow it
-- (non-owning: the parent owns and closes the real handle).
local porth = handle.borrow(ffi.cast('HANDLE', tonumber(PAYLOAD)))
local port  = setmetatable({ _h = porth }, ex.IoCompletion)

local seen = {}
while true do
    local key, apc = port:remove(1.0)        -- 1s idle = port drained
    if key == nil then break end
    seen[#seen + 1] = tostring(tonumber(ffi.cast('uintptr_t', apc)))
end
return table.concat(seen, ",")
]]

t.test("N completions drain across K consumer threads, exactly once", function()
    local N = 24      -- completions produced, cookies 1..N
    local K = 4       -- consumer threads racing to drain

    local c   = ex.iocompletion{ concurrent_threads = K }
    local src = iosrc.new(c, 0xC0DE)

    -- Produce N completions with distinct ApcContext cookies 1..N.
    for i = 1, N do src:emit(i) end

    -- Wait until all N are queued, so this is purely a consumer race —
    -- some async reads may still be in flight right after emit().
    local queued = false
    for _ = 1, 500 do
        if c:depth() == N then queued = true break end
    end
    t.ok(queued, "all " .. N .. " completions queued (depth=" .. c:depth() .. ")")

    -- Spawn K consumers racing to drain the same port.
    local porth  = tostring(ptr_value(handle.raw(c:handle())))
    local consumers = {}
    for k = 1, K do
        consumers[k] = thread.run(CONSUMER, porth)
    end

    -- Join, collect every cookie, assert an exact partition of 1..N.
    local seen = {}
    for k = 1, K do
        local finished = consumers[k]:wait(10.0)
        t.ok(finished, "consumer " .. k .. " finished within 10s")
        if finished then
            local status, value = consumers[k]:result()
            t.eq(status, "ok",
                 "consumer " .. k .. " status (" .. tostring(value) .. ")")
            for tok in tostring(value):gmatch("[^,]+") do
                local cookie = tonumber(tok)
                t.eq(seen[cookie], nil,
                     "cookie " .. tostring(cookie) .. " consumed exactly once")
                seen[cookie] = true
            end
        end
        consumers[k]:close()
    end

    for i = 1, N do
        t.ok(seen[i], "cookie " .. i .. " was consumed (no loss)")
    end
    t.eq(c:depth(), 0, "port fully drained")

    src:close()
    c:close()
end)

-- ------------------------------------------------------------------
-- Concurrency under fault injection — production overlapping
-- consumption, with consumers that periodically hand the kernel a
-- malformed output buffer.
--
-- A faulting NtRemoveIoCompletion is caught by COMPLETE.C's outer
-- probe BEFORE KeRemoveQueue dequeues anything, so it consumes no
-- entry — the invariant under test is that a consumer issuing such
-- faulting removes (concurrently with honest consumers, while the
-- producer is still feeding the port) corrupts nothing: every
-- produced completion is still consumed exactly once. This is the
-- security property P9 is about; note it does not single out the P9
-- inner re-queue arm, which is TOCTOU-only (see iocp-plan.md 2b/3b).
-- ------------------------------------------------------------------

-- Consumer chunk. PAYLOAD = "<port>:<done_event>:<inject 0|1>".
-- Drains via raw NtRemoveIoCompletion; an injector issues a faulting
-- remove (kernel-range IoStatusBlock) before each real attempt. Stops
-- once the producer has signalled done AND a full remove timeout sees
-- the port empty. Returns "<faultcount>;<cookie,cookie,...>".
local INJECT_CONSUMER = [[
-- package.path/searcher/io/os set by the runtime preamble (sibling
-- states run the wrapped luaL_openlibs too).
local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local ex     = require('nt.dll.ex')      -- registers the IOCP cdefs
local ke     = require('nt.dll.ke')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

local pa, ea, ia = PAYLOAD:match("^(%d+):(%d+):(%d+)$")
local porth  = ffi.cast('HANDLE', tonumber(pa))
local doneh  = handle.borrow(ffi.cast('HANDLE', tonumber(ea)))
local inject = (ia == "1")

local STATUS_TIMEOUT = 0x102

local function done()
    return ke.NtWaitForSingleObject(doneh, false, ke.timeout(0)) == 0
end

-- One raw NtRemoveIoCompletion. `bad` points IoStatusBlock at a
-- kernel-range address: the outer probe must reject it cleanly,
-- dequeuing nothing.
local function remove(secs, bad)
    local key  = ffi.new('void *[1]')
    local apc  = ffi.new('void *[1]')
    local iosb = bad and ffi.cast('IO_STATUS_BLOCK *', 0x80000000)
                     or  ffi.new('IO_STATUS_BLOCK')
    local st = err.normalize(ntdll.NtRemoveIoCompletion(
        porth, key, apc, iosb, ke.timeout(secs)))
    if st == STATUS_TIMEOUT then return nil, "timeout" end
    if st == 0 then return tonumber(ffi.cast('uintptr_t', apc[0])), "ok" end
    return nil, "fault"
end

local seen, faults = {}, 0
while true do
    -- Injector: a faulting remove before every real attempt. It must
    -- fault at the probe and consume nothing — done unconditionally so
    -- even a consumer that arrives late (port already drained) still
    -- exercises the fault path at least once.
    if inject then
        local _, kind = remove(0.0, true)
        if kind == "fault" then faults = faults + 1 end
    end
    local cookie, kind = remove(0.2, false)
    if kind == "ok" then
        seen[#seen + 1] = tostring(cookie)
    elseif done() then
        break                                -- empty 0.2s after producer done
    end
end
return tostring(faults) .. ";" .. table.concat(seen, ",")
]]

t.test("concurrent producer + consumers + fault injection: exactly once", function()
    local N = 48      -- completions produced, cookies 1..N
    local K = 4       -- consumers; even-indexed ones inject faults

    local c    = ex.iocompletion{ concurrent_threads = K }
    local src  = iosrc.new(c, 0xC0DE)
    local done = ke.event()      -- notification event: set when production ends

    local port_int = tostring(ptr_value(handle.raw(c:handle())))
    local done_int = tostring(ptr_value(handle.raw(done:handle())))

    -- Consumers start FIRST so they drain while the producer feeds.
    local consumers = {}
    for k = 1, K do
        local flag = (k % 2 == 0) and "1" or "0"
        consumers[k] = thread.run(INJECT_CONSUMER,
            port_int .. ":" .. done_int .. ":" .. flag)
    end

    -- Produce N completions concurrently with the running consumers,
    -- then mark production complete.
    for i = 1, N do src:emit(i) end
    done:signal()

    -- Join, collect every cookie, assert an exact partition of 1..N.
    local seen, total_faults = {}, 0
    for k = 1, K do
        local finished = consumers[k]:wait(15.0)
        t.ok(finished, "consumer " .. k .. " finished within 15s")
        if finished then
            local status, value = consumers[k]:result()
            t.eq(status, "ok",
                 "consumer " .. k .. " status (" .. tostring(value) .. ")")
            local fstr, cstr = tostring(value):match("^(%d+);(.*)$")
            total_faults = total_faults + (tonumber(fstr) or 0)
            for tok in (cstr or ""):gmatch("[^,]+") do
                local cookie = tonumber(tok)
                t.eq(seen[cookie], nil,
                     "cookie " .. tostring(cookie) .. " consumed exactly once")
                seen[cookie] = true
            end
        end
        consumers[k]:close()
    end

    for i = 1, N do
        t.ok(seen[i], "cookie " .. i .. " consumed (no loss)")
    end
    t.eq(c:depth(), 0, "port fully drained")
    t.ok(total_faults > 0,
         "fault injector actually faulted removes (" .. total_faults .. ")")

    done:close()
    src:close()
    c:close()
end)
