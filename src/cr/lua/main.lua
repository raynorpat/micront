-- main.lua — MicroNT initial user process.
--
-- First live exercise of the nt.dll.* sub-modules: walk the NT object
-- namespace from \ and print (name, type) for every entry. Recurses
-- into sub-directories. Surfaces what we're missing in ob/fs/etc.

local ffi   = require('ffi')
local ntdll = require('nt.dll')
local str   = require('nt.dll.str')
local oa    = require('nt.dll.oa')
local ob    = require('nt.dll.ob')
local cm    = require('nt.dll.cm')

-- Shutdown primitives — raw ffi for now, one-off use. Move to nt.dll.ex
-- (Executive) if/when we grow more of that surface.
ffi.cdef[[
NTSTATUS __stdcall RtlAdjustPrivilege(ULONG Privilege,
                                      unsigned char Enable,
                                      unsigned char Client,
                                      unsigned char *WasEnabled);
NTSTATUS __stdcall NtShutdownSystem(int Action);
]]

-- Structs returned by the enumeration syscalls. All of them end with a
-- variable-length array we index past element 0; each Info*Length field
-- is in BYTES (not wchars), per NT convention.
ffi.cdef[[
typedef struct _OBJECT_DIRECTORY_INFORMATION {
    UNICODE_STRING Name;
    UNICODE_STRING TypeName;
} OBJECT_DIRECTORY_INFORMATION;

typedef struct _KEY_BASIC_INFORMATION {
    LARGE_INTEGER LastWriteTime;
    ULONG TitleIndex;
    ULONG NameLength;
    wchar_t Name[1];
} KEY_BASIC_INFORMATION;

typedef struct _KEY_VALUE_FULL_INFORMATION {
    ULONG TitleIndex;
    ULONG Type;
    ULONG DataOffset;
    ULONG DataLength;
    ULONG NameLength;
    wchar_t Name[1];
} KEY_VALUE_FULL_INFORMATION;
]]

-- REG_RESOURCE_LIST / REG_FULL_RESOURCE_DESCRIPTOR — driver hardware
-- resource bindings. The format is a flattened tree:
--   CM_RESOURCE_LIST        ULONG Count; CM_FULL_RESOURCE_DESCRIPTOR[Count]
--     CM_FULL_RESOURCE_DESCRIPTOR                                -- 8-byte header
--         int InterfaceType; ULONG BusNumber;
--         CM_PARTIAL_RESOURCE_LIST                               -- 8-byte header
--             USHORT Version; USHORT Revision; ULONG Count;
--             CM_PARTIAL_RESOURCE_DESCRIPTOR[Count]              -- 16 bytes each
-- Both the outer and partial-list arrays are variable-length; we walk
-- them with pointer arithmetic.
--
-- pack(4): NT 3.5 kernel ABI aligns 8-byte values (PHYSICAL_ADDRESS) on
-- 4-byte boundaries. Without this, LuaJIT's default would push the
-- LARGE_INTEGER inside Port.Start to offset 8 and break the 16-byte
-- descriptor size.
ffi.cdef[[
#pragma pack(push, 4)
typedef struct _CM_PHYS_ADDR {
    ULONG LowPart;
    long  HighPart;
} CM_PHYS_ADDR;

typedef struct _CM_PARTIAL_RESOURCE_DESCRIPTOR {
    unsigned char  Type;
    unsigned char  ShareDisposition;
    unsigned short Flags;
    union {
        struct { CM_PHYS_ADDR Start; ULONG Length; }                  Port;
        struct { ULONG Level; ULONG Vector; ULONG Affinity; }          Interrupt;
        struct { CM_PHYS_ADDR Start; ULONG Length; }                  Memory;
        struct { ULONG Channel; ULONG Port; ULONG Reserved1; }        Dma;
        struct { ULONG DataSize; ULONG Reserved1; ULONG Reserved2; }  DeviceSpecificData;
    } u;
} CM_PARTIAL_RESOURCE_DESCRIPTOR;

typedef struct _CM_PARTIAL_RESOURCE_LIST {
    unsigned short Version;
    unsigned short Revision;
    ULONG Count;
    /* CM_PARTIAL_RESOURCE_DESCRIPTOR PartialDescriptors[Count] follows */
} CM_PARTIAL_RESOURCE_LIST;

typedef struct _CM_FULL_RESOURCE_DESCRIPTOR {
    int   InterfaceType;
    ULONG BusNumber;
    CM_PARTIAL_RESOURCE_LIST PartialResourceList;
} CM_FULL_RESOURCE_DESCRIPTOR;

typedef struct _CM_RESOURCE_LIST {
    ULONG Count;
    /* CM_FULL_RESOURCE_DESCRIPTOR List[Count] follows (variable length) */
} CM_RESOURCE_LIST;
#pragma pack(pop)
]]

local DIR_ACCESS             = 0x3        -- DIRECTORY_QUERY | DIRECTORY_TRAVERSE
local SYMBOLIC_LINK_QUERY    = 0x1
local KEY_READ_ACCESS        = 0x9        -- KEY_QUERY_VALUE | KEY_ENUMERATE_SUB_KEYS
local STATUS_NO_MORE_ENTRIES = 0x8000001A
local STATUS_BUFFER_OVERFLOW = 0x80000005

local KeyBasicInformation       = 0
local KeyValueFullInformation   = 1

-- Registry data type codes.
local REG_NONE, REG_SZ, REG_EXPAND_SZ, REG_BINARY, REG_DWORD = 0, 1, 2, 3, 4
local REG_MULTI_SZ                = 7
local REG_RESOURCE_LIST           = 8
local REG_FULL_RESOURCE_DESCRIPTOR = 9

-- INTERFACE_TYPE enum — names of the buses referenced by
-- CM_FULL_RESOURCE_DESCRIPTOR.InterfaceType.
local INTERFACE_TYPE_NAMES = {
    [-1] = "Undef",    [0]  = "Internal", [1]  = "Isa",
    [2]  = "Eisa",     [3]  = "MChannel", [4]  = "TurboCh",
    [5]  = "PCIBus",   [6]  = "VMEBus",   [7]  = "NuBus",
    [8]  = "PCMCIA",   [9]  = "CBus",     [10] = "MPIBus",
    [11] = "MPSABus",  [12] = "ProcInt",  [13] = "IntPower",
    [14] = "PNPISA",   [15] = "PNPBus",
}

-- OBJECT_ATTRIBUTES construction lives in nt.dll.oa (returns a fused
-- NT_OA_PATH — single cdata, no Shape 1 aliasing). We just call it.

local function walk(path, depth)
    local indent = string.rep("  ", depth)
    local noa    = oa.path(path)

    local ok, dir = pcall(ob.NtOpenDirectoryObject, DIR_ACCESS, noa.oa)
    if not ok then
        print(string.format("%s[%s] OPEN FAILED: %s",
                            indent, path, tostring(dir)))
        return
    end

    local buf   = ffi.new('char[4096]')
    local ctx   = ffi.new('ULONG[1]')
    local first = true

    while true do
        local ok2, ret_len, st = pcall(ob.NtQueryDirectoryObject,
                                       dir, buf, 4096, true, first, ctx)
        if not ok2 then
            print(string.format("%s  QUERY FAILED: %s",
                                indent, tostring(ret_len)))
            break
        end
        first = false
        if st == STATUS_NO_MORE_ENTRIES or ret_len == 0 then break end

        local info       = ffi.cast('OBJECT_DIRECTORY_INFORMATION *', buf)
        local name       = str.from_utf16(info.Name)
        local type_name  = str.from_utf16(info.TypeName)
        local child_path = path == "\\" and ("\\" .. name)
                                         or (path .. "\\" .. name)

        if type_name == "SymbolicLink" then
            local lnoa = oa.path(child_path)
            local ok, lh = pcall(ob.NtOpenSymbolicLinkObject,
                                 SYMBOLIC_LINK_QUERY, lnoa.oa)
            if ok then
                local ok2, target = pcall(ob.NtQuerySymbolicLinkObject, lh)
                ob.NtClose(lh)
                if ok2 then
                    print(string.format("%s%-24s  <%s>  → %s",
                                        indent, name, type_name, target))
                else
                    print(string.format("%s%-24s  <%s>  (query failed: %s)",
                                        indent, name, type_name, tostring(target)))
                end
            else
                print(string.format("%s%-24s  <%s>  (open failed: %s)",
                                    indent, name, type_name, tostring(lh)))
            end
        else
            print(string.format("%s%-24s  <%s>", indent, name, type_name))
            if type_name == "Directory" then
                walk(child_path, depth + 1)
            end
        end
    end

    ob.NtClose(dir)
end

-- ---------------------------------------------------------------------
-- Registry walk.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- CM_RESOURCE_LIST decoder (REG_RESOURCE_LIST / REG_FULL_RESOURCE_DESCRIPTOR).
-- ---------------------------------------------------------------------

-- One CM_PARTIAL_RESOURCE_DESCRIPTOR → short human string.
local function render_partial(p)
    local t = p.Type
    if t == 1 then         -- CmResourceTypePort
        local s, l = p.u.Port.Start.LowPart, p.u.Port.Length
        return string.format("Port 0x%x..0x%x", s, s + l - 1)
    elseif t == 2 then     -- CmResourceTypeInterrupt
        return string.format("IRQ %d", p.u.Interrupt.Level)
    elseif t == 3 then     -- CmResourceTypeMemory
        local s, l = p.u.Memory.Start.LowPart, p.u.Memory.Length
        return string.format("Mem 0x%08x..0x%08x", s, s + l - 1)
    elseif t == 4 then     -- CmResourceTypeDma
        return string.format("DMA ch%d", p.u.Dma.Channel)
    elseif t == 5 then     -- CmResourceTypeDeviceSpecific
        return string.format("DevSpec[%d]", p.u.DeviceSpecificData.DataSize)
    else
        return string.format("type%d", t)
    end
end

-- Render one CM_FULL_RESOURCE_DESCRIPTOR at fd_ptr. Returns "Isa.0 [Port ..., IRQ n]".
-- Variable trailing partials start at fd_ptr + 16 (8-byte full header +
-- 8-byte partial-list header).
local function render_full(fd_ptr)
    local fd     = ffi.cast('CM_FULL_RESOURCE_DESCRIPTOR *', fd_ptr)
    local iface  = INTERFACE_TYPE_NAMES[fd.InterfaceType]
                   or tostring(fd.InterfaceType)
    local n      = fd.PartialResourceList.Count
    local base   = ffi.cast('char *', fd_ptr) + 16
    local parts  = {}
    for i = 0, n - 1 do
        local pd = ffi.cast('CM_PARTIAL_RESOURCE_DESCRIPTOR *',
                             base + i * 16)
        parts[i+1] = render_partial(pd)
    end
    return string.format("%s.%d [%s]",
        iface, fd.BusNumber, table.concat(parts, ", "))
end

-- Render REG_RESOURCE_LIST at base (dp for the value). ULONG Count
-- prefix, then `Count` variable-length CM_FULL_RESOURCE_DESCRIPTORs.
local function render_resource_list(dp)
    local rl = ffi.cast('CM_RESOURCE_LIST *', dp)
    if rl.Count == 0 then return "RESLIST empty" end
    local ptr = ffi.cast('char *', dp) + 4      -- past ULONG Count
    local parts = {}
    for f = 0, rl.Count - 1 do
        parts[f+1] = render_full(ptr)
        local fd = ffi.cast('CM_FULL_RESOURCE_DESCRIPTOR *', ptr)
        ptr = ptr + 16 + fd.PartialResourceList.Count * 16
    end
    return "RESLIST " .. table.concat(parts, "; ")
end

-- Render a registry value. Takes the KEY_VALUE_FULL_INFORMATION and a
-- char* to the start of the info struct (so we can reach the data at
-- info.DataOffset).
local function render_value(info, base)
    local typ = info.Type
    local len = info.DataLength
    local dp  = base + info.DataOffset

    if typ == REG_DWORD and len == 4 then
        return string.format("DWORD  0x%08x", ffi.cast('uint32_t *', dp)[0])
    elseif typ == REG_SZ or typ == REG_EXPAND_SZ then
        local wp = ffi.cast('wchar_t *', dp)
        local n  = len / 2
        if n > 0 and wp[n-1] == 0 then n = n - 1 end   -- drop trailing NUL
        return string.format("%-6s %q",
            typ == REG_SZ and "SZ" or "EXPAND", str.from_wchars(wp, n))
    elseif typ == REG_MULTI_SZ then
        local wp = ffi.cast('wchar_t *', dp)
        local n  = len / 2
        local strs = {}
        local start = 0
        for j = 0, n - 1 do
            if wp[j] == 0 then
                if j > start then
                    strs[#strs+1] = string.format("%q",
                        str.from_wchars(wp + start, j - start))
                end
                start = j + 1
            end
        end
        return string.format("MULTI  [%s]", table.concat(strs, ", "))
    elseif typ == REG_BINARY then
        local parts = {}
        local preview = len < 16 and len or 16
        for j = 0, preview - 1 do
            parts[j+1] = string.format("%02x", dp[j])
        end
        return string.format("BIN[%d] %s%s",
            len, table.concat(parts, " "), len > 16 and " ..." or "")
    elseif typ == REG_RESOURCE_LIST then
        return render_resource_list(dp)
    elseif typ == REG_FULL_RESOURCE_DESCRIPTOR then
        return "FULLDESC " .. render_full(dp)
    else
        return string.format("TYPE=%d LEN=%d", typ, len)
    end
end

local function walk_reg(path, depth)
    local indent = string.rep("  ", depth)
    local noa    = oa.path(path)

    local ok, key = pcall(cm.NtOpenKey, KEY_READ_ACCESS, noa.oa)
    if not ok then
        print(string.format("%s[%s] OPEN FAILED: %s",
                            indent, path, tostring(key)))
        return
    end

    -- Values first, then subkeys — easier to read when both are present.
    local vbuf = ffi.new('char[4096]')
    local vidx = 0
    while true do
        local ok2, len, st = pcall(cm.NtEnumerateValueKey,
                                   key, vidx, KeyValueFullInformation,
                                   vbuf, 4096)
        if not ok2 then
            print(string.format("%s  VALUE QUERY FAILED: %s",
                                indent, tostring(len)))
            break
        end
        if st == STATUS_NO_MORE_ENTRIES then break end
        if st == STATUS_BUFFER_OVERFLOW then
            print(string.format("%s  (value %d skipped — needs >4K buffer)",
                                indent, vidx))
        else
            local info = ffi.cast('KEY_VALUE_FULL_INFORMATION *', vbuf)
            local name = str.from_wchars(info.Name, info.NameLength / 2)
            if name == "" then name = "(default)" end
            print(string.format("%s  = %-20s %s",
                                indent, name,
                                render_value(info, ffi.cast('char *', vbuf))))
        end
        vidx = vidx + 1
    end

    -- Subkeys.
    local kbuf = ffi.new('char[4096]')
    local kidx = 0
    while true do
        local ok2, len, st = pcall(cm.NtEnumerateKey,
                                   key, kidx, KeyBasicInformation,
                                   kbuf, 4096)
        if not ok2 then
            print(string.format("%s  SUBKEY QUERY FAILED: %s",
                                indent, tostring(len)))
            break
        end
        if st == STATUS_NO_MORE_ENTRIES then break end
        if st == STATUS_BUFFER_OVERFLOW then
            print(string.format("%s  (subkey %d skipped — needs >4K buffer)",
                                indent, kidx))
        else
            local info = ffi.cast('KEY_BASIC_INFORMATION *', kbuf)
            local name = str.from_wchars(info.Name, info.NameLength / 2)
            print(string.format("%s%s\\", indent, name))
            walk_reg(path .. "\\" .. name, depth + 1)
        end
        kidx = kidx + 1
    end

    ob.NtClose(key)
end

-- ---------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------

print("MicroNT: walking NT object namespace from \\")
print("---")
local ok, err = pcall(walk, "\\", 0)
if not ok then
    print("NAMESPACE WALK ABORTED: " .. tostring(err))
end
print("--- end of namespace walk ---")
print("")
print("MicroNT: walking registry from \\Registry")
print("---")
local rok, rerr = pcall(walk_reg, "\\Registry", 0)
if not rok then
    print("REGISTRY WALK ABORTED: " .. tostring(rerr))
end
print("--- end of registry walk ---")

-- Shut down cleanly. NT 3.5 requires SeShutdownPrivilege (value 19
-- per ntseapi.h); our init process runs under the kernel's token so
-- RtlAdjustPrivilege will enable it. ShutdownPowerOff routes through
-- HalReturnToFirmware; without ACPI, NT 3.5 falls back to halting.
print("")
print("Shutting down...")
local was = ffi.new('unsigned char[1]')
ntdll.RtlAdjustPrivilege(19 --[[ SE_SHUTDOWN_PRIVILEGE ]], 1, 0, was)
local st = ntdll.NtShutdownSystem(2 --[[ ShutdownPowerOff ]])

-- Only reached if shutdown rejects us.
print(string.format("NtShutdownSystem returned 0x%08x", st < 0 and st + 0x100000000 or st))
while true do end
