-- nt.dll.rng — NtGenerateSecureRandom, the in-kernel CSPRNG draw path.
--
-- Bottoms out in the RNG subsystem's Xoodyak pool (NTOS/RNG). The syscall
-- probes the caller's buffer, squeezes into a kernel staging buffer, and
-- copies out under SEH, so a bad pointer returns an error rather than
-- faulting the system.

local ffi   = require('ffi')
local ntdll = require('nt.dll')
local err   = require('nt.dll.errors')

ffi.cdef[[
NTSTATUS __stdcall NtGenerateSecureRandom(void *Buffer, ULONG Length);
]]

local M = {}

-- Raw form: fill the caller's cdata buffer; returns the normalized NTSTATUS
-- (0 == STATUS_SUCCESS). Lets callers test failure without raising.
function M.generate(buffer, length)
    return err.normalize(ntdll.NtGenerateSecureRandom(buffer, length))
end

-- Convenience: return `length` cryptographically-strong bytes as a Lua
-- string. Raises on error.
function M.bytes(length)
    if length <= 0 then
        return ""
    end
    local buf = ffi.new('unsigned char[?]', length)
    local st  = ntdll.NtGenerateSecureRandom(buf, length)
    if err.is_error(st) then
        err.raise('NtGenerateSecureRandom', st)
    end
    return ffi.string(buf, length)
end

return M
