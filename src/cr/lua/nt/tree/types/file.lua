-- File / Device — both open via NtOpenFile. Devices in the object
-- manager (\Device\Serial0, \Device\Null, ...) respond to the same
-- fs-layer syscalls; the Device handler is a thin alias.
--
-- Access / share / options chosen for generic read-only browse:
--   FILE_READ_DATA | SYNCHRONIZE → basic read + waitable handle
--   FILE_SHARE_READ | FILE_SHARE_WRITE → don't break other openers
--   FILE_SYNCHRONOUS_IO_NONALERT → blocking reads; matches :read()

local ffi = require('ffi')
local fs  = require('nt.dll.fs')
local oa  = require('nt.dll.oa')

local FILE_READ_DATA               = 0x0001
local FILE_SHARE_READ              = 0x0001
local FILE_SHARE_WRITE             = 0x0002
local SYNCHRONIZE                  = 0x00100000
local FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020

local M = {}

function M.open(node)
    local h = fs.NtOpenFile(
        FILE_READ_DATA + SYNCHRONIZE,
        oa.path(node.path).oa,
        FILE_SHARE_READ + FILE_SHARE_WRITE,
        FILE_SYNCHRONOUS_IO_NONALERT)
    return h
end

M.methods = {
    read = function(node, length)
        local buf = ffi.new('char[?]', length)
        local n = fs.NtReadFile(node:open(), buf, length, nil)
        return ffi.string(buf, n)
    end,
}

M.descriptions = {
    read = "read(n) → Lua string of up to n bytes from this handle.",
}

return M
