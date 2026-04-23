-- Process — synthetic Node under \Processes. Carries pid + snapshot
-- fields captured at enumeration time (proclist.lua populates them).
-- :open() goes via NtOpenProcess using CLIENT_ID, so :info() works
-- against a live handle (returns NtQueryObject data scoped to the
-- process object, not the SystemProcessInformation snapshot).

local ffi    = require('ffi')
local ps     = require('nt.dll.ps')

local PROCESS_QUERY_INFORMATION = 0x0400

local M = {}

function M.open(node)
    local cid = ffi.new('CLIENT_ID')
    cid.UniqueProcess = ffi.cast('HANDLE', node.__pid)
    cid.UniqueThread  = nil
    return ps.NtOpenProcess(PROCESS_QUERY_INFORMATION, ps.empty_oa(), cid)
end

M.fields = {
    pid         = function(n) return n.__pid         end,
    parent_pid  = function(n) return n.__parent_pid  end,
    image       = function(n) return n.__image      end,
    threads     = function(n) return n.__threads     end,
    handles     = function(n) return n.__handles     end,
    priority    = function(n) return n.__priority    end,
    create_time = function(n) return n.__create_time end,
    user_time   = function(n) return n.__user_time   end,
    kernel_time = function(n) return n.__kernel_time end,
}

M.descriptions = {
    pid         = "Process ID.",
    parent_pid  = "PID of the process that created this one.",
    image       = "Image file name (e.g. smss.exe). '(System)' for kernel-owned PIDs.",
    threads     = "Current thread count (from snapshot).",
    handles     = "Current handle count (from snapshot).",
    priority    = "Base priority (KPRIORITY).",
    create_time = "Creation time as NT 100ns ticks since 1601-01-01.",
    user_time   = "Total user-mode CPU time (100ns units).",
    kernel_time = "Total kernel-mode CPU time (100ns units).",
}

return M
