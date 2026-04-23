-- ProcessList — synthetic virtual at \Processes. Yields one Process
-- Node per entry from NtQuerySystemInformation(SystemProcessInformation).
--
-- At yield time we capture:
--   - Fixed process fields (pid, parent_pid, image, priority, timings,
--     VM/pool/pagefile counters, IO counters).
--   - A frozen copy of the trailing SYSTEM_THREAD_INFORMATION[] as a
--     Lua array of tables — sys.each_process's buffer goes away when
--     the iterator ends, so threads have to be materialized eagerly.
--
-- The Process handler's children() then yields Thread Nodes from that
-- snapshot; no re-query is needed.

local ffi  = require('ffi')
local tree = require('nt.tree')
local sys  = require('nt.dll.sys')
local str  = require('nt.dll.str')

local function join(path, name)
    if path == "\\" or path == "" then return "\\" .. name end
    return path .. "\\" .. name
end

local function pid_of(h)
    return tonumber(ffi.cast('intptr_t', h))
end

-- Copy thread records out of the kernel buffer into plain Lua tables so
-- the Process Node doesn't depend on the sys.each_process buffer's
-- lifetime.
local function snapshot_threads(threads_ptr, count)
    local out = {}
    for i = 0, count - 1 do
        local t = threads_ptr[i]
        out[i+1] = {
            tid              = pid_of(t.ClientId.UniqueThread),
            pid              = pid_of(t.ClientId.UniqueProcess),
            start_address    = tonumber(ffi.cast('uintptr_t', t.StartAddress)),
            priority         = t.Priority,
            base_priority    = t.BasePriority,
            context_switches = t.ContextSwitches,
            thread_state     = t.ThreadState,
            wait_reason      = t.WaitReason,
            wait_time        = t.WaitTime,
            kernel_time      = t.KernelTime.QuadPart,
            user_time        = t.UserTime.QuadPart,
            create_time      = t.CreateTime.QuadPart,
        }
    end
    return out
end

local M = {}

function M.children(node)
    return coroutine.wrap(function()
        for info, threads in sys.each_process() do
            local pid    = pid_of(info.UniqueProcessId)
            local parent = pid_of(info.InheritedFromUniqueProcessId)
            local image
            if info.ImageName.Length > 0 and info.ImageName.Buffer ~= nil then
                image = str.from_utf16(info.ImageName)
            else
                image = "(System)"
            end
            local name = tostring(pid)
            local n = tree.Node.new(node, name, join(node.path, name), "Process")
            n.__pid          = pid
            n.__parent_pid   = parent
            n.__image        = image
            n.__priority     = info.BasePriority
            n.__thread_count = info.NumberOfThreads
            n.__create_time  = info.CreateTime.QuadPart
            n.__user_time    = info.UserTime.QuadPart
            n.__kernel_time  = info.KernelTime.QuadPart
            -- Memory / IO counters
            n.__virtual_size     = info.VirtualSize
            n.__peak_virtual     = info.PeakVirtualSize
            n.__working_set      = info.WorkingSetSize
            n.__peak_working_set = info.PeakWorkingSetSize
            n.__page_faults      = info.PageFaultCount
            n.__paged_pool       = info.QuotaPagedPoolUsage
            n.__non_paged_pool   = info.QuotaNonPagedPoolUsage
            n.__pagefile         = info.PagefileUsage
            n.__peak_pagefile    = info.PeakPagefileUsage
            n.__private_pages    = info.PrivatePageCount
            n.__io_read_ops      = info.ReadOperationCount
            n.__io_write_ops     = info.WriteOperationCount
            n.__io_other_ops     = info.OtherOperationCount
            n.__io_read_bytes    = info.ReadTransferCount.QuadPart
            n.__io_write_bytes   = info.WriteTransferCount.QuadPart
            n.__io_other_bytes   = info.OtherTransferCount.QuadPart
            -- Frozen thread snapshot
            n.__threads = snapshot_threads(threads, info.NumberOfThreads)
            coroutine.yield(n)
        end
    end)
end

return M
