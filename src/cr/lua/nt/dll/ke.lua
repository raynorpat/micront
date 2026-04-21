-- nt.dll.ke — NT kernel executive: synchronisation primitives, wait,
-- thread alerts and delay. Maps to NTOS/KE on the kernel side.
--
-- Bridging convention (uniform across the nt.dll.* tree):
--   - OUT pointer arguments surface as return values.
--   - NTSTATUS < 0 raises a structured error (see nt.errors).
--     Callers inspect err.status directly — no string parsing.
--   - Positive NTSTATUS values (STATUS_TIMEOUT = 0x102, STATUS_ALERTED
--     = 0x101, STATUS_USER_APC = 0xC0, ...) are returned to the caller;
--     they are not errors.
--   - Lua booleans bridge to NT BOOLEAN: true → 1, false/nil → 0.
--
-- Callers still build OBJECT_ATTRIBUTES, LARGE_INTEGER timeouts etc.
-- by hand via ffi.new. For anything not wrapped here, require('nt.dll')
-- for the raw handle.

local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

ffi.cdef[[
NTSTATUS __stdcall NtCreateEvent(HANDLE *EventHandle,
                                 ULONG DesiredAccess,
                                 OBJECT_ATTRIBUTES *ObjectAttributes,
                                 int EventType,
                                 unsigned char InitialState);
NTSTATUS __stdcall NtSetEvent      (HANDLE EventHandle, long *PreviousState);
NTSTATUS __stdcall NtResetEvent    (HANDLE EventHandle, long *PreviousState);
NTSTATUS __stdcall NtPulseEvent    (HANDLE EventHandle, long *PreviousState);
NTSTATUS __stdcall NtClearEvent    (HANDLE EventHandle);
NTSTATUS __stdcall NtWaitForSingleObject(HANDLE Object,
                                         unsigned char Alertable,
                                         LARGE_INTEGER *Timeout);
NTSTATUS __stdcall NtWaitForMultipleObjects(ULONG Count,
                                            HANDLE *Handles,
                                            int WaitType,
                                            unsigned char Alertable,
                                            LARGE_INTEGER *Timeout);
NTSTATUS __stdcall NtDelayExecution(unsigned char Alertable,
                                    LARGE_INTEGER *DelayInterval);
NTSTATUS __stdcall NtAlertThread   (HANDLE ThreadHandle);
]]

local M = {}

function M.NtCreateEvent(access, oa, event_type, initial_state)
    local h = ffi.new('HANDLE[1]')
    local st = ntdll.NtCreateEvent(h, access, oa, event_type,
                                   initial_state and 1 or 0)
    if err.is_error(st) then err.raise('NtCreateEvent', st) end
    return handle.wrap(h[0])
end

function M.NtSetEvent(h)
    local st = ntdll.NtSetEvent(handle.raw(h), nil)
    if err.is_error(st) then err.raise('NtSetEvent', st) end
end

function M.NtResetEvent(h)
    local st = ntdll.NtResetEvent(handle.raw(h), nil)
    if err.is_error(st) then err.raise('NtResetEvent', st) end
end

function M.NtPulseEvent(h)
    local st = ntdll.NtPulseEvent(handle.raw(h), nil)
    if err.is_error(st) then err.raise('NtPulseEvent', st) end
end

function M.NtClearEvent(h)
    local st = ntdll.NtClearEvent(handle.raw(h))
    if err.is_error(st) then err.raise('NtClearEvent', st) end
end

function M.NtWaitForSingleObject(h, alertable, timeout)
    local st = ntdll.NtWaitForSingleObject(handle.raw(h),
                                           alertable and 1 or 0,
                                           timeout)
    if err.is_error(st) then err.raise('NtWaitForSingleObject', st) end
    return err.normalize(st)
end

-- `handles` is a Lua table of NT_HANDLE wrappers. We extract each
-- into a fresh HANDLE[n] array inside this function — the table stays
-- on the Lua stack during our call, pinning the wrappers (and thus
-- their raw HANDLE values) through to kernel dispatch. A reactor with
-- a persistent wait set should bypass this wrapper and call
-- `ntdll.NtWaitForMultipleObjects` directly against its own array.
function M.NtWaitForMultipleObjects(handles, wait_type, alertable, timeout)
    local n   = #handles
    local arr = ffi.new('HANDLE[?]', n)
    for i = 1, n do
        arr[i-1] = handle.raw(handles[i])
    end
    local st = ntdll.NtWaitForMultipleObjects(n, arr, wait_type,
                                              alertable and 1 or 0,
                                              timeout)
    if err.is_error(st) then err.raise('NtWaitForMultipleObjects', st) end
    return err.normalize(st)
end

function M.NtDelayExecution(alertable, delay_interval)
    local st = ntdll.NtDelayExecution(alertable and 1 or 0, delay_interval)
    if err.is_error(st) then err.raise('NtDelayExecution', st) end
end

function M.NtAlertThread(thread_handle)
    local st = ntdll.NtAlertThread(handle.raw(thread_handle))
    if err.is_error(st) then err.raise('NtAlertThread', st) end
end

return M
