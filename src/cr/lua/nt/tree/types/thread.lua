-- Thread — synthetic Node under \Processes\<pid>\<tid>. Carries the
-- snapshot fields copied out of SYSTEM_THREAD_INFORMATION. :open()
-- goes via NtOpenThread using the (pid, tid) CLIENT_ID so :info()
-- works against a live handle.

local ffi = require('ffi')
local ps  = require('nt.dll.ps')

local THREAD_QUERY_INFORMATION = 0x0040

-- THREAD_STATE enum (from NT source). Values may vary slightly across
-- versions; these match NT 3.5 ke.h.
local THREAD_STATES = {
    [0] = "Initialized", [1] = "Ready",      [2] = "Running",
    [3] = "Standby",     [4] = "Terminated", [5] = "Wait",
    [6] = "Transition",
}

-- KWAIT_REASON enum.
local WAIT_REASONS = {
    [0]  = "Executive",      [1]  = "FreePage",      [2]  = "PageIn",
    [3]  = "PoolAllocation", [4]  = "DelayExecution",[5]  = "Suspended",
    [6]  = "UserRequest",    [7]  = "WrExecutive",   [8]  = "WrFreePage",
    [9]  = "WrPageIn",       [10] = "WrPoolAllocation",
    [11] = "WrDelayExecution",[12] = "WrSuspended",  [13] = "WrUserRequest",
    [14] = "WrEventPair",    [15] = "WrQueue",       [16] = "WrLpcReceive",
    [17] = "WrLpcReply",     [18] = "WrVirtualMemory",[19] = "WrPageOut",
    [20] = "WrRendezvous",
}

local M = {}

function M.open(node)
    local cid = ffi.new('CLIENT_ID')
    cid.UniqueProcess = ffi.cast('HANDLE', node.__pid)
    cid.UniqueThread  = ffi.cast('HANDLE', node.__tid)
    return ps.NtOpenThread(THREAD_QUERY_INFORMATION, ps.empty_oa(), cid)
end

M.fields = {
    tid              = function(n) return n.__tid end,
    pid              = function(n) return n.__pid end,
    start_address    = function(n) return n.__start_address end,
    priority         = function(n) return n.__priority end,
    base_priority    = function(n) return n.__base_priority end,
    context_switches = function(n) return n.__context_switches end,
    thread_state     = function(n)
        return THREAD_STATES[n.__thread_state] or n.__thread_state
    end,
    wait_reason      = function(n)
        return WAIT_REASONS[n.__wait_reason] or n.__wait_reason
    end,
    wait_time        = function(n) return n.__wait_time end,
    create_time      = function(n) return n.__create_time end,
    user_time        = function(n) return n.__user_time end,
    kernel_time      = function(n) return n.__kernel_time end,
}

M.descriptions = {
    tid              = "Thread ID.",
    pid              = "Owning process ID.",
    start_address    = "Thread entry-point address.",
    priority         = "Current scheduler priority.",
    base_priority    = "Base priority (set by SetThreadPriority).",
    context_switches = "Cumulative context-switch count.",
    thread_state     = "Scheduler state (Running/Ready/Wait/...).",
    wait_reason      = "Reason for wait when thread_state == Wait.",
    wait_time        = "Time spent in current wait (ticks).",
    create_time      = "Creation time (NT 100ns ticks since 1601-01-01).",
    user_time        = "User-mode CPU time (100ns units).",
    kernel_time      = "Kernel-mode CPU time (100ns units).",
}

return M
