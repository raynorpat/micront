-- ps.create_thread — RtlCreateUserThread via the NT_HANDLE-only
-- contract. The thread entry must be a __stdcall function taking a
-- single HANDLE arg; the Lua-side param is an NT_HANDLE (or nil) and
-- the wrapper does the raw extraction.
--
-- Thread entries here are ntdll exports whose shape already matches
-- (one HANDLE arg, stdcall). We use NtSetHighEventPair as the
-- spawned thread's "done" signaler — it matches the entry ABI
-- directly so no C shim is needed.

local ffi   = require('ffi')
local t     = require('test')
local ntdll = require('nt.dll')
local ps    = require('nt.dll.ps')
local ke    = require('nt.dll.ke')
local ex    = require('nt.dll.ex')

t.suite("thread")

t.test("create_thread spawns a thread and runs entry", function()
    -- Spawned thread signals the high side of an EventPair on entry.
    -- Main thread waits on the high side — if it fires, the thread ran.
    local ep = ex.event_pair()
    local th = ps.create_thread(ntdll.NtSetHighEventPair, ep:handle())
    ep:wait_high()
    ke.NtWaitForSingleObject(th, false, ke.timeout(1.0))
    th:close()
    ep:close()
end)

t.test("create_thread with nil param terminates cleanly", function()
    -- Entry (NtSetHighEventPair) runs with a NULL HANDLE — kernel
    -- returns STATUS_INVALID_HANDLE, thread exits with that status.
    -- We only care the wrapper accepted nil and the thread is joinable.
    local th = ps.create_thread(ntdll.NtSetHighEventPair, nil)
    ke.NtWaitForSingleObject(th, false, ke.timeout(1.0))
    th:close()
end)

t.test("create_thread rejects non-NT_HANDLE param", function()
    t.raises(function()
        ps.create_thread(ntdll.NtSetHighEventPair, 42)
    end, "NT_HANDLE")
    t.raises(function()
        ps.create_thread(ntdll.NtSetHighEventPair, "not a handle")
    end, "NT_HANDLE")
end)

t.test("suspended thread runs to completion after resume", function()
    local ep = ex.event_pair()
    local th = ps.create_thread(ntdll.NtSetHighEventPair,
                                ep:handle(),
                                { suspended = true })
    local prev = ps.NtResumeThread(th)
    t.eq(prev, 1, "thread was suspended once; resume returns 1")
    ep:wait_high()   -- thread's NtSetHighEventPair ran after resume
    ke.NtWaitForSingleObject(th, false, ke.timeout(1.0))
    th:close()
    ep:close()
end)
