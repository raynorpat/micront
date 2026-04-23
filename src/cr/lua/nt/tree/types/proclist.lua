-- ProcessList — synthetic virtual at \Processes. Yields one Process
-- Node per entry from NtQuerySystemInformation(SystemProcessInformation).
--
-- The Process Nodes carry the fields we sniffed from the syscall's
-- variable-length records, so downstream :info() / :open() doesn't
-- have to re-query. ImageName is copied to a Lua string at enumeration
-- time — the kernel buffer behind SYSTEM_PROCESS_INFORMATION goes away
-- when the coroutine ends.

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

local M = {}

function M.children(node)
    return coroutine.wrap(function()
        for info in sys.each_process() do
            local pid    = pid_of(info.UniqueProcessId)
            local parent = pid_of(info.InheritedFromUniqueProcessId)
            local image
            if info.ImageName.Length > 0 and info.ImageName.Buffer ~= nil then
                image = str.from_utf16(info.ImageName)
            else
                image = "(System)"
            end
            -- Use the pid as the path component — guaranteed unique,
            -- lets tree.resolve("\\Processes\\4") work. Image name is
            -- carried as a field for readability.
            local name = tostring(pid)
            local n = tree.Node.new(node, name, join(node.path, name), "Process")
            n.__pid          = pid
            n.__parent_pid   = parent
            n.__image        = image
            n.__threads      = info.NumberOfThreads
            n.__handles      = info.HandleCount
            n.__priority     = info.BasePriority
            n.__create_time  = info.CreateTime.QuadPart
            n.__user_time    = info.UserTime.QuadPart
            n.__kernel_time  = info.KernelTime.QuadPart
            coroutine.yield(n)
        end
    end)
end

return M
