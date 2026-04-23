local ex = require('nt.dll.ex')
local oa = require('nt.dll.oa')

local SECTION_QUERY = 0x0001

return {
    open = function(node)
        return ex.NtOpenSection(SECTION_QUERY, oa.path(node.path).oa)
    end,
}
