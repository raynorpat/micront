local ex = require('nt.dll.ex')
local oa = require('nt.dll.oa')

local TIMER_QUERY_STATE = 0x0001

return {
    open = function(node)
        return ex.NtOpenTimer(TIMER_QUERY_STATE, oa.path(node.path).oa)
    end,
}
