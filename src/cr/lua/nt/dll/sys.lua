-- nt.dll.sys — NtQuerySystemInformation. System-wide introspection:
-- process list, handle list, module list, performance counters.
--
-- For now we only bridge SystemProcessInformation (class 5) — the
-- canonical path taskmgr / perfmon / PSAPI take under the hood.
--
-- SystemProcessInformation returns a linked list in one flat buffer:
-- each SYSTEM_PROCESS_INFORMATION is variable-length (the fixed header
-- is followed by SYSTEM_THREAD_INFORMATION[NumberOfThreads], and the
-- UNICODE_STRING ImageName's Buffer points into the same buffer).
-- Walk via NextEntryOffset; 0 marks the last entry.
--
-- Size-query: we don't know the full size up-front (process count can
-- race between calls). Start at 32KB, double on STATUS_INFO_LENGTH_MISMATCH
-- until it fits or we exceed a safety cap.
--
-- NT 3.5's SYSTEM_PROCESS_INFORMATION is smaller than modern Windows's
-- (no SessionId, no IoCounters, no VM counters) — we stop at HandleCount
-- which is the last field guaranteed present. Later Windows versions
-- just leave the extra fields we don't read at the end of the record,
-- still reachable via NextEntryOffset.

local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local err    = require('nt.dll.errors')

ffi.cdef[[
typedef long KPRIORITY;

typedef struct _SYSTEM_PROCESS_INFORMATION {
    ULONG          NextEntryOffset;
    ULONG          NumberOfThreads;
    LARGE_INTEGER  Reserved[3];
    LARGE_INTEGER  CreateTime;
    LARGE_INTEGER  UserTime;
    LARGE_INTEGER  KernelTime;
    UNICODE_STRING ImageName;
    KPRIORITY      BasePriority;
    HANDLE         UniqueProcessId;
    HANDLE         InheritedFromUniqueProcessId;
    ULONG          HandleCount;
} SYSTEM_PROCESS_INFORMATION;

NTSTATUS __stdcall NtQuerySystemInformation(
    int SystemInformationClass,
    void *SystemInformation,
    ULONG SystemInformationLength,
    ULONG *ReturnLength);
]]

local SystemProcessInformation   = 5
local STATUS_INFO_LENGTH_MISMATCH = 0xC0000004

local M = {}

-- Low-level: returns a char[?] buffer filled by the kernel. Caller
-- holds the buffer; pointer-walks into it stay valid while buf is alive.
local function query_processes_buffer()
    local size = 32768
    local buf  = ffi.new('char[?]', size)
    local ret  = ffi.new('ULONG[1]')
    for _ = 1, 10 do
        local st = ntdll.NtQuerySystemInformation(
            SystemProcessInformation, buf, size, ret)
        local stu = err.normalize(st)
        if stu == STATUS_INFO_LENGTH_MISMATCH then
            -- Grow to max(2*size, reported-required). The reported size
            -- can still be short of the next attempt's actual need
            -- (processes race) so doubling on top of it gives slack.
            local needed = ret[0]
            size = needed > size and needed * 2 or size * 2
            buf  = ffi.new('char[?]', size)
        elseif err.is_error(st) then
            err.raise('NtQuerySystemInformation', st)
        else
            return buf
        end
    end
    error('NtQuerySystemInformation: buffer did not converge after 10 grows')
end

-- Iterate all processes. Yields one SYSTEM_PROCESS_INFORMATION pointer
-- per step; fields like ImageName.Buffer stay valid until the iterator
-- is dropped (the backing buffer is captured in the coroutine upvalue).
function M.each_process()
    local buf = query_processes_buffer()
    return coroutine.wrap(function()
        local ptr = ffi.cast('char *', buf)
        while true do
            local info = ffi.cast('SYSTEM_PROCESS_INFORMATION *', ptr)
            coroutine.yield(info)
            if info.NextEntryOffset == 0 then return end
            ptr = ptr + info.NextEntryOffset
        end
    end)
end

return M
