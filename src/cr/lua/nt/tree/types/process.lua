-- Process — synthetic Node under \Processes. Carries snapshot fields
-- captured at enumeration time (proclist.lua populates them).
-- :open() goes via NtOpenProcess using CLIENT_ID; :info() works
-- against a live handle. :children() yields Thread Nodes from the
-- frozen thread snapshot — no re-query per thread.

local ffi  = require('ffi')
local ps   = require('nt.dll.ps')
local tree = require('nt.tree')

local PROCESS_QUERY_INFORMATION = 0x0400

local function join(path, name)
    if path == "\\" or path == "" then return "\\" .. name end
    return path .. "\\" .. name
end

local M = {}

function M.open(node)
    local cid = ffi.new('CLIENT_ID')
    cid.UniqueProcess = ffi.cast('HANDLE', node.__pid)
    cid.UniqueThread  = nil
    return ps.NtOpenProcess(PROCESS_QUERY_INFORMATION, ps.empty_oa(), cid)
end

-- Yield one Thread Node per snapshot entry. Each Thread inherits the
-- parent's __pid so its CLIENT_ID-based open works without re-query.
function M.children(node)
    return coroutine.wrap(function()
        for _, t in ipairs(node.__threads or {}) do
            local name = tostring(t.tid)
            local tn = tree.Node.new(node, name, join(node.path, name), "Thread")
            tn.__tid              = t.tid
            tn.__pid              = node.__pid
            tn.__start_address    = t.start_address
            tn.__priority         = t.priority
            tn.__base_priority    = t.base_priority
            tn.__context_switches = t.context_switches
            tn.__thread_state     = t.thread_state
            tn.__wait_reason      = t.wait_reason
            tn.__wait_time        = t.wait_time
            tn.__kernel_time      = t.kernel_time
            tn.__user_time        = t.user_time
            tn.__create_time      = t.create_time
            coroutine.yield(tn)
        end
    end)
end

M.fields = {
    pid              = function(n) return n.__pid              end,
    parent_pid       = function(n) return n.__parent_pid       end,
    image            = function(n) return n.__image            end,
    threads          = function(n) return n.__thread_count     end,
    priority         = function(n) return n.__priority         end,
    create_time      = function(n) return n.__create_time      end,
    user_time        = function(n) return n.__user_time        end,
    kernel_time      = function(n) return n.__kernel_time      end,
    virtual_size     = function(n) return n.__virtual_size     end,
    peak_virtual     = function(n) return n.__peak_virtual     end,
    working_set      = function(n) return n.__working_set      end,
    peak_working_set = function(n) return n.__peak_working_set end,
    page_faults      = function(n) return n.__page_faults      end,
    paged_pool       = function(n) return n.__paged_pool       end,
    non_paged_pool   = function(n) return n.__non_paged_pool   end,
    pagefile         = function(n) return n.__pagefile         end,
    peak_pagefile    = function(n) return n.__peak_pagefile    end,
    private_pages    = function(n) return n.__private_pages    end,
    io_read_ops      = function(n) return n.__io_read_ops      end,
    io_write_ops     = function(n) return n.__io_write_ops     end,
    io_other_ops     = function(n) return n.__io_other_ops     end,
    io_read_bytes    = function(n) return n.__io_read_bytes    end,
    io_write_bytes   = function(n) return n.__io_write_bytes   end,
    io_other_bytes   = function(n) return n.__io_other_bytes   end,
}

M.descriptions = {
    pid              = "Process ID.",
    parent_pid       = "PID of the process that created this one (0 if parent has exited).",
    image            = "Image file name.",
    threads          = "Thread count at snapshot time.",
    priority         = "Base priority (KPRIORITY).",
    create_time      = "Creation time (NT 100ns ticks since 1601-01-01).",
    user_time        = "Total user-mode CPU time (100ns units).",
    kernel_time      = "Total kernel-mode CPU time (100ns units).",
    virtual_size     = "Committed virtual memory (bytes).",
    peak_virtual     = "Peak committed virtual memory (bytes).",
    working_set      = "Resident set size (bytes).",
    peak_working_set = "Peak resident set size (bytes).",
    page_faults      = "Cumulative page-fault count.",
    paged_pool       = "Paged-pool quota usage (bytes).",
    non_paged_pool   = "Non-paged-pool quota usage (bytes).",
    pagefile         = "Pagefile usage (bytes).",
    peak_pagefile    = "Peak pagefile usage (bytes).",
    private_pages    = "Private committed pages.",
    io_read_ops      = "Read I/O operation count.",
    io_write_ops     = "Write I/O operation count.",
    io_other_ops     = "Other I/O operation count.",
    io_read_bytes    = "Bytes read via file/device I/O.",
    io_write_bytes   = "Bytes written via file/device I/O.",
    io_other_bytes   = "Other I/O bytes transferred.",
}

return M
