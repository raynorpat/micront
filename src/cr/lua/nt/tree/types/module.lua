-- Module — synthetic Node under \System\Modules. Pure leaf (no
-- children, no open — modules aren't openable by name from user mode).
-- Fields expose the snapshot captured at enumeration time.

local M = {}

M.fields = {
    image_path  = function(n) return n.__image_path  end,
    image_base  = function(n) return n.__image_base  end,
    mapped_base = function(n) return n.__mapped_base end,
    image_size  = function(n) return n.__image_size  end,
    flags       = function(n) return n.__flags       end,
    load_order  = function(n) return n.__load_order  end,
    init_order  = function(n) return n.__init_order  end,
    load_count  = function(n) return n.__load_count  end,
}

M.descriptions = {
    image_path  = "Full NT path of the module image (e.g. \\SystemRoot\\System32\\ntoskrnl.exe).",
    image_base  = "Base virtual address of the loaded image.",
    mapped_base = "Address the module's sections are mapped at (may equal image_base).",
    image_size  = "Module size in bytes.",
    flags       = "Loader flags bitmask.",
    load_order  = "Index in the kernel's load-order list.",
    init_order  = "Index in the kernel's init-order list.",
    load_count  = "Reference count (drivers can be loaded/unloaded multiple times).",
}

return M
