-- nt.dll.rtl — pure-userland Rtl* helpers exported from ntdll.
--
-- These are not syscalls; the kernel knows nothing about them. They are
-- standalone routines linked into ntdll for everyone (kernel32, user
-- code) to share — calendar arithmetic, privilege adjustment, string
-- decoding, etc. Subsystem-prefixed Nt* wrappers live in their own
-- modules (ke / mm / ob / ...); this is the home for ntdll utilities
-- that don't belong to any subsystem.
--
-- Currently:
--   RtlTimeToTimeFields            LARGE_INTEGER (100ns since 1601, UTC)
--                                  → TIME_FIELDS calendar struct (raw
--                                  cdata interface; rare).
--   RtlTimeFieldsToTime            inverse. Returns nil + reason on
--                                  invalid fields.
--   query_env(name)                lookup an environment variable in
--                                  the current process. Wraps
--                                  RtlQueryEnvironmentVariable_U +
--                                  the buffer-too-small grow loop.
--   li_to_unix(li)                 LARGE_INTEGER (NT 100ns) → Unix
--                                  seconds (Lua number).
--   unix_to_table(secs)            Unix seconds → calendar table with
--                                  Lua-style fields (year, month, day,
--                                  hour, min, sec, wday, yday).
--   table_to_unix(t)               inverse; nil + reason on bad fields.
--
-- The Unix-epoch math (EPOCH_BIAS_SEC = 11_644_473_600 between
-- 1601-01-01 and 1970-01-01) lives here rather than in user code so
-- the same constant doesn't get copy-pasted into every consumer.
--
-- TIME_FIELDS layout matches NTOS/INC/ntoskrnl.h: SHORTs in
-- year/month/day/hour/min/sec/msec/weekday order. The cdef stays
-- internal — Lua code paths use the table API above and never
-- ffi.new('TIME_FIELDS') directly.

local ffi    = require('ffi')
local ntdll  = require('nt.dll')
local err    = require('nt.dll.errors')
local str    = require('nt.dll.str')
local handle = require('nt.dll.handle')

ffi.cdef[[
typedef struct _TIME_FIELDS {
    short Year;
    short Month;
    short Day;
    short Hour;
    short Minute;
    short Second;
    short Milliseconds;
    short Weekday;
} TIME_FIELDS;

void          __stdcall RtlTimeToTimeFields(LARGE_INTEGER *Time, TIME_FIELDS *TimeFields);
unsigned char __stdcall RtlTimeFieldsToTime(TIME_FIELDS *TimeFields, LARGE_INTEGER *Time);

NTSTATUS __stdcall RtlQueryEnvironmentVariable_U(void *Environment,
                                                 UNICODE_STRING *Name,
                                                 UNICODE_STRING *Value);

/* RtlSetEnvironmentVariable_U(EnvBlock**, Name, Value) — Environment
 * is a void** so ntdll can resize/reallocate the env block.  Pass NULL
 * for current process (uses PEB->ProcessParameters->Environment). */
NTSTATUS __stdcall RtlSetEnvironmentVariable(void **Environment,
                                             UNICODE_STRING *Name,
                                             UNICODE_STRING *Value);

/* DOS path → NT-namespace path.  Caller passes a NUL-terminated
 * UTF-16 DOS path (e.g. "C:\foo\bar"); ntdll fills in NtFileName as
 * a UNICODE_STRING with a heap-allocated Buffer that the caller must
 * free via RtlFreeUnicodeString.  Knows about all the DOS quirks
 * (drive letters, UNC paths, "\\?\..." escapes, current-dir
 * resolution).  Returns TRUE on success. */
unsigned char __stdcall RtlDosPathNameToNtPathName_U(
    const wchar_t  *DosFileName,
    UNICODE_STRING *NtFileName,
    wchar_t       **FilePart,
    void           *RelativeName);

void __stdcall RtlFreeUnicodeString(UNICODE_STRING *s);
]]

local STATUS_BUFFER_TOO_SMALL    = 0xC0000023
local STATUS_VARIABLE_NOT_FOUND  = 0xC0000100

-- NT system time / RTL_USER_PROCESS_PARAMETERS env block work in
-- 100ns ticks and UTF-16 wchars respectively. Name the magic numbers
-- so reading sites don't have to remember why "1e7" or "* 2".
local NT_TICKS_PER_SEC = 1e7
local WCHAR_BYTES      = ffi.sizeof('wchar_t')

local M = {}

-- LARGE_INTEGER (100ns-since-1601) → TIME_FIELDS. Returns a fresh cdata.
-- li must remain reachable for the duration of this call (pass a Lua
-- local), but the returned TIME_FIELDS does not alias it — fully copied.
function M.RtlTimeToTimeFields(li)
    local tf = ffi.new('TIME_FIELDS')
    ntdll.RtlTimeToTimeFields(li, tf)
    return tf
end

-- TIME_FIELDS → LARGE_INTEGER. Returns the LARGE_INTEGER, or nil + reason
-- on invalid input. NT validates the fields as a unit (Feb 30 is rejected
-- even if Year/Month/Day are individually in range).
function M.RtlTimeFieldsToTime(tf)
    local li = ffi.new('LARGE_INTEGER')
    if ntdll.RtlTimeFieldsToTime(tf, li) == 0 then
        return nil, "invalid time fields"
    end
    return li
end

-- ------------------------------------------------------------------
-- Lua-friendly time API. Hides TIME_FIELDS / LARGE_INTEGER from
-- callers — they pass / receive Lua numbers and tables.
-- ------------------------------------------------------------------

-- NT system time is 100ns intervals since 1601-01-01 UTC. Unix epoch
-- is 11_644_473_600 seconds later. Same constant is used by C-side
-- libc_time.c — keep them in sync if it ever changes.
local EPOCH_BIAS_SEC = 11644473600
M.EPOCH_BIAS_SEC   = EPOCH_BIAS_SEC
M.NT_TICKS_PER_SEC = NT_TICKS_PER_SEC

local DAYS_IN_MONTH = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

local function is_leap(year)
    return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function day_of_year(month, day, year)
    local doy = day
    for i = 1, month - 1 do
        local d = DAYS_IN_MONTH[i]
        if i == 2 and is_leap(year) then d = 29 end
        doy = doy + d
    end
    return doy
end

-- LARGE_INTEGER (NT 100ns ticks since 1601) → Unix seconds. Pure math;
-- the cdata stays alive for the QuadPart access only — caller may drop
-- it immediately after this returns.
function M.li_to_unix(li)
    local secs_since_1601 = (tonumber(li.QuadPart) / NT_TICKS_PER_SEC)
    return secs_since_1601 - EPOCH_BIAS_SEC
end

-- Unix seconds → fresh LARGE_INTEGER cdata. Caller owns the result.
-- Raises if the resulting NT time would be pre-1601 — NT's tick range
-- doesn't go negative.
function M.unix_to_li(secs)
    local secs_since_1601 = (secs + EPOCH_BIAS_SEC)
    local nt_ticks        = (secs_since_1601 * NT_TICKS_PER_SEC)
    if nt_ticks < 0 then
        error("rtl.unix_to_li: time before 1601-01-01 not representable", 2)
    end
    local li = ffi.new('LARGE_INTEGER')
    li.QuadPart = nt_ticks
    return li
end

-- Unix seconds → calendar table. Keys match Lua's os.date "*t" form
-- (year, month, day, hour, min, sec, wday=1..7, yday=1..366) so the
-- consumer doesn't have to translate. The TIME_FIELDS cdata is purely
-- internal — never escapes this function.
function M.unix_to_table(secs)
    local li = M.unix_to_li(secs)
    local tf = M.RtlTimeToTimeFields(li)
    return {
        year  = tf.Year,
        month = tf.Month,
        day   = tf.Day,
        hour  = tf.Hour,
        min   = tf.Minute,
        sec   = tf.Second,
        wday  = tf.Weekday + 1,                   -- Lua: 1=Sun..7=Sat
        yday  = day_of_year(tf.Month, tf.Day, tf.Year),
    }
end

-- Calendar table → Unix seconds. `year`, `month`, `day` are required;
-- `hour` (default 12), `min` (0), `sec` (0) are optional. Returns nil
-- + reason on missing/invalid fields. Lua-style key names match
-- unix_to_table's output so the round-trip composes cleanly.
function M.table_to_unix(t)
    if type(t) ~= "table" then
        return nil, "table expected"
    end
    if not t.year or not t.month or not t.day then
        return nil, "table missing year/month/day"
    end
    local tf = ffi.new('TIME_FIELDS')
    tf.Year         = t.year
    tf.Month        = t.month
    tf.Day          = t.day
    tf.Hour         = t.hour or 12
    tf.Minute       = t.min  or 0
    tf.Second       = t.sec  or 0
    tf.Milliseconds = 0
    tf.Weekday      = 0                           -- ignored on input
    local li, why = M.RtlTimeFieldsToTime(tf)
    if not li then return nil, why end
    return M.li_to_unix(li)
end

-- ------------------------------------------------------------------
-- Environment
-- ------------------------------------------------------------------

-- Look up an environment variable in the current process. Takes a UTF-8
-- name; returns a UTF-8 value, or nil if the name isn't set. Other
-- syscall errors raise. NULL Environment = current-process env block.
--
-- ns_name and ns_value are kept as Lua locals through the syscall so
-- the inline UNICODE_STRING (.us) and the inline data buffer stay
-- reachable until the call returns; both are fused single-cdata via
-- nt.dll.str's NT_STRING type.
function M.query_env(name)
    local ns_name = str.to_utf16(name)
    local capacity = 256                      -- wchars; enough for typical values
    while true do
        local ns_value = str.new_utf16(capacity)
        local st  = ntdll.RtlQueryEnvironmentVariable_U(nil, ns_name.us, ns_value.us)
        local stu = err.normalize(st)
        if stu == STATUS_VARIABLE_NOT_FOUND then
            return nil
        elseif stu == STATUS_BUFFER_TOO_SMALL then
            -- ns_value.Length now holds the required size in bytes (no NUL).
            local needed_wchars = math.floor(ns_value.us.Length / WCHAR_BYTES)
            -- Grow with slack so a racing env update doesn't loop us forever.
            capacity = (needed_wchars * 2)
            if capacity > 32768 then
                error("query_env: value too large (>32K wchars) for "
                      .. tostring(name), 2)
            end
        elseif err.is_error(st) then
            err.raise('RtlQueryEnvironmentVariable_U', st)
        else
            return str.from_utf16(ns_value.us)
        end
    end
end

-- DOS path → NT-namespace path via ntdll's canonical conversion.
-- Returns a `UNICODE_STRING[1]` cdata with a finalizer that releases
-- ntdll's heap allocation when the cdata is collected — caller can
-- treat it as a UNICODE_STRING * for FFI calls and forget about
-- memory ownership.  Use for image paths, file paths, anything that
-- crosses from DOS-form into a kernel syscall:
--
--   local nt = rtl.dos_to_nt_path("C:\\pkg\\msvc20\\NMAKE.EXE")
--   ntdll.NtCreateFile(handle, ..., oa_with(nt), ...)
--   -- nt freed when GC reclaims the local
--
-- The Lua-side path is UTF-8; we widen to UTF-16 internally.  The
-- to_utf16'd buffer must stay live through the ntdll call (it's the
-- DosFileName arg); we capture it in a local that the closure-style
-- caller naturally retains.
function M.dos_to_nt_path(dos_path)
    local wpath = str.to_utf16(dos_path)
    local us    = ffi.new('UNICODE_STRING[1]')
    if ntdll.RtlDosPathNameToNtPathName_U(
            wpath.us.Buffer, us, nil, nil) == 0 then
        error("RtlDosPathNameToNtPathName_U failed for " .. dos_path, 2)
    end
    return ffi.gc(us, function(p) ntdll.RtlFreeUnicodeString(p) end)
end

-- Set or unset an environment variable in the current process.  Pass
-- value=nil to delete.  Mirrors query_env's UTF-8 contract.
--
-- ntdll may reallocate the env block under us (when the new value
-- doesn't fit in current capacity); we pass nil for Environment so
-- ntdll uses PEB->ProcessParameters->Environment as both source and
-- target.  Return value: nothing on success, raises on error.
function M.set_env(name, value)
    local ns_name  = str.to_utf16(name)
    local ns_value = value and str.to_utf16(value) or nil
    local st = ntdll.RtlSetEnvironmentVariable(
        nil, ns_name.us, ns_value and ns_value.us or nil)
    if err.is_error(st) then err.raise('RtlSetEnvironmentVariable', st) end
end

-- ------------------------------------------------------------------
-- PEB / ProcessParameters readers — environ() and getcwd().
--
-- Both walk: NtQueryInformationProcess(self, BasicInformation) →
-- PebBaseAddress → ProcessParameters → header.  The PEB_HEAD and
-- RTL_USER_PROCESS_PARAMETERS_HEADER cdefs live in nt.dll.ps; we just
-- consume them.  Requiring ps here is fine: ps doesn't reach for rtl.
-- ------------------------------------------------------------------

require('nt.dll.ps')                     -- PEB_HEAD + ProcParams cdefs

-- Cache the ProcessParameters header pointer.  Stable for the process's
-- lifetime — the kernel allocates it once at process startup; ntdll's
-- RtlSetEnvironmentVariable may reallocate the *Environment block*
-- inside it, but the header itself doesn't move.
local pp_header_ptr

local function get_pp_header()
    if pp_header_ptr ~= nil then return pp_header_ptr end
    local pbi = ffi.new('PROCESS_BASIC_INFORMATION')
    local ret = ffi.new('ULONG[1]')
    -- handle.NtCurrentProcess() is the canonical NT_HANDLE wrapper;
    -- pull the raw value out for the ntdll FFI call.
    local st = ntdll.NtQueryInformationProcess(
        handle.raw(handle.NtCurrentProcess()), 0,  -- ProcessBasicInformation
        pbi, ffi.sizeof('PROCESS_BASIC_INFORMATION'), ret)
    if err.is_error(st) then
        err.raise('NtQueryInformationProcess(self) for PEB', st)
    end
    local peb = ffi.cast('PEB_HEAD *', pbi.PebBaseAddress)
    if peb == nil or peb.ProcessParameters == nil then
        error("rtl.environ/getcwd: PEB.ProcessParameters is NULL", 2)
    end
    pp_header_ptr = ffi.cast('RTL_USER_PROCESS_PARAMETERS_HEADER *',
                             peb.ProcessParameters)
    return pp_header_ptr
end

-- environ() → array of "KEY=VALUE" UTF-8 strings.  Walks the env block
-- pointed at by ProcessParameters.Environment — UTF-16 layout
-- "KEY=VALUE\0KEY=VALUE\0\0".  Returns {} if no env block exists.
function M.environ()
    local hdr = get_pp_header()
    local block = ffi.cast('uint16_t *', hdr.Environment)
    if block == nil then return {} end

    local out = {}
    local i = 0
    -- Find the end of each NUL-terminated UTF-16 entry.  Block ends
    -- with a double-NUL (an empty entry), so a single-iteration where
    -- block[i] == 0 at start means we're done.
    while block[i] ~= 0 do
        local start = i
        while block[i] ~= 0 do i = i + 1 end
        -- Copy [start..i-1] as wchars and decode to UTF-8.
        local n = i - start
        out[#out + 1] = str.from_wchars(block + start, n)
        i = i + 1                          -- skip the NUL terminator
    end
    return out
end

-- getcwd() → UTF-8 path string from PEB.ProcessParameters
-- .CurrentDirectory.DosPath.  Always present at process start (kernel
-- inherits parent's or the image's directory).  Returns "" if the
-- field is empty (shouldn't happen in practice).
function M.getcwd()
    local hdr = get_pp_header()
    if hdr.CurrentDirectoryDosPath.Length == 0 then return "" end
    return str.from_utf16(hdr.CurrentDirectoryDosPath)
end

return M
