-- nt.dll.ex — Executive primitives (sync objects, memory sections).
-- Maps to NTOS/EX on the kernel side. Everything here is shaped
-- identically: NtOpenX(HANDLE *out, ACCESS_MASK, OBJECT_ATTRIBUTES *).
--
-- Nothing here sets values, signals, or waits — those live on the
-- opened handle via Nt{Wait,Set,Release,Reset,Pulse}*. Add as real
-- callers show up; for now the object-manager tree only needs the
-- openers so introspection via NtQueryObject works.

local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local err    = require('nt.dll.errors')
local handle = require('nt.dll.handle')

-- Pack(4) to match NT 3.5's LARGE_INTEGER layout (see nt.dll.sys for
-- the reasoning — MSC 8.00 4-aligned long long). Affects TIMER_* and
-- SECTION_BASIC_INFORMATION here.
ffi.cdef[[
#pragma pack(push, 4)

typedef struct _EVENT_BASIC_INFORMATION {
    int  EventType;      /* 0 = Notification, 1 = Synchronization */
    long EventState;     /* 0 = NotSignaled, 1 = Signaled */
} EVENT_BASIC_INFORMATION;

typedef struct _MUTANT_BASIC_INFORMATION {
    long          CurrentCount;
    unsigned char OwnedByCaller;
    unsigned char AbandonedState;
} MUTANT_BASIC_INFORMATION;

typedef struct _SEMAPHORE_BASIC_INFORMATION {
    long CurrentCount;
    long MaximumCount;
} SEMAPHORE_BASIC_INFORMATION;

typedef struct _TIMER_BASIC_INFORMATION {
    LARGE_INTEGER RemainingTime;
    unsigned char TimerState;
} TIMER_BASIC_INFORMATION;

typedef struct _SECTION_BASIC_INFORMATION {
    void *        BaseAddress;
    ULONG         AllocationAttributes;
    LARGE_INTEGER MaximumSize;
} SECTION_BASIC_INFORMATION;

#pragma pack(pop)

NTSTATUS __stdcall NtOpenEvent       (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenEventPair   (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenSection     (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenMutant      (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenSemaphore   (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenTimer       (HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);
NTSTATUS __stdcall NtOpenIoCompletion(HANDLE *h, ULONG Access, OBJECT_ATTRIBUTES *oa);

NTSTATUS __stdcall NtQueryEvent    (HANDLE h, int cls, void *info, ULONG len, ULONG *ret);
NTSTATUS __stdcall NtQueryMutant   (HANDLE h, int cls, void *info, ULONG len, ULONG *ret);
NTSTATUS __stdcall NtQuerySemaphore(HANDLE h, int cls, void *info, ULONG len, ULONG *ret);
NTSTATUS __stdcall NtQueryTimer    (HANDLE h, int cls, void *info, ULONG len, ULONG *ret);
NTSTATUS __stdcall NtQuerySection  (HANDLE h, int cls, void *info, ULONG len, ULONG *ret);
]]

local M = {}

-- All six are the same shape; write one local maker, export six bindings
-- so callers keep distinct NtOpenX names (matches nt.dll.* convention
-- that sub-modules bind real ntdll exports, not abstractions).
local function make_opener(name)
    return function(access, oa)
        local h  = ffi.new('HANDLE[1]')
        local st = ntdll[name](h, access, oa)
        if err.is_error(st) then err.raise(name, st) end
        return handle.wrap(h[0])
    end
end

M.NtOpenEvent        = make_opener('NtOpenEvent')
M.NtOpenEventPair    = make_opener('NtOpenEventPair')
M.NtOpenSection      = make_opener('NtOpenSection')
M.NtOpenMutant       = make_opener('NtOpenMutant')
M.NtOpenSemaphore    = make_opener('NtOpenSemaphore')
M.NtOpenTimer        = make_opener('NtOpenTimer')
M.NtOpenIoCompletion = make_opener('NtOpenIoCompletion')

-- Query wrappers. Each basic-info class has a fixed struct; caller
-- supplies a pre-allocated cdata of the right type. NT 3.5's queries
-- expect Length to exactly match sizeof(struct).
local function make_query(name, struct_name)
    local struct_size = ffi.sizeof(struct_name)
    return function(h)
        local info = ffi.new(struct_name)
        local ret  = ffi.new('ULONG[1]')
        local st = ntdll[name](handle.raw(h), 0 --[[ BasicInformation ]],
                               info, struct_size, ret)
        if err.is_error(st) then err.raise(name, st) end
        return info
    end
end

M.NtQueryEvent     = make_query('NtQueryEvent',     'EVENT_BASIC_INFORMATION')
M.NtQueryMutant    = make_query('NtQueryMutant',    'MUTANT_BASIC_INFORMATION')
M.NtQuerySemaphore = make_query('NtQuerySemaphore', 'SEMAPHORE_BASIC_INFORMATION')
M.NtQueryTimer     = make_query('NtQueryTimer',     'TIMER_BASIC_INFORMATION')
M.NtQuerySection   = make_query('NtQuerySection',   'SECTION_BASIC_INFORMATION')

return M
