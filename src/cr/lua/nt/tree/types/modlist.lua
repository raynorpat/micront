-- ModuleList — synthetic at \System\Modules. Yields one Module Node
-- per loaded kernel-mode module from NtQuerySystemInformation
-- (SystemModuleInformation = class 11). Each entry covers ntoskrnl,
-- hal, and every loaded driver (.sys).

local ffi  = require('ffi')
local tree = require('nt.tree')
local sys  = require('nt.dll.sys')

local function join(path, name)
    if path == "\\" or path == "" then return "\\" .. name end
    return path .. "\\" .. name
end

-- FullPathName is a UCHAR[256] buffer — DOS ANSI-ish. Convert to Lua
-- string by stopping at the first NUL. OffsetToFileName points to the
-- leaf (basename) in the same buffer.
local function path_from_buf(buf)
    return ffi.string(buf)
end

local function basename(info)
    local p = ffi.cast('char *', info.FullPathName) + info.OffsetToFileName
    return ffi.string(p)
end

local M = {}

function M.children(node)
    return coroutine.wrap(function()
        for info in sys.each_module() do
            local name = basename(info)
            local full = path_from_buf(info.FullPathName)
            local mn = tree.Node.new(node, name, join(node.path, name), "Module")
            mn.__image_path     = full
            mn.__mapped_base    = tonumber(ffi.cast('uintptr_t', info.MappedBase))
            mn.__image_base     = tonumber(ffi.cast('uintptr_t', info.ImageBase))
            mn.__image_size     = info.ImageSize
            mn.__flags          = info.Flags
            mn.__load_order     = info.LoadOrderIndex
            mn.__init_order     = info.InitOrderIndex
            mn.__load_count     = info.LoadCount
            coroutine.yield(mn)
        end
    end)
end

return M
