-- nt.dll.handle — NT_HANDLE wrap / close / detach semantics.

local ffi    = require('ffi')
local t      = require('test')
local handle = require('nt.dll.handle')
local ob     = require('nt.dll.ob')
local oa     = require('nt.dll.oa')

t.suite("handle")

local DIR_ACCESS = 0x3   -- DIRECTORY_QUERY | DIRECTORY_TRAVERSE

t.test("wrap then close releases cleanly", function()
    local h = ob.NtOpenDirectoryObject(DIR_ACCESS, oa.path("\\").oa)
    t.ne(handle.raw(h), nil)
    h:close()
    -- __owned cleared; raw is nil; subsequent close() is a no-op.
    h:close()
end)

t.test("close is idempotent and safe after __gc path", function()
    local h = ob.NtOpenDirectoryObject(DIR_ACCESS, oa.path("\\").oa)
    h:close()
    h:close()
    h:close()
end)

t.test("detach transfers ownership (skips NtClose on __gc)", function()
    local h = ob.NtOpenDirectoryObject(DIR_ACCESS, oa.path("\\").oa)
    local raw = h:detach()
    t.ne(raw, nil)
    -- After detach, close() is a no-op; raw HANDLE is caller's
    -- responsibility. For the test we close manually via ntdll.
    local ntdll = require('nt.dll')
    ntdll.NtClose(raw)
    h:close()   -- safe: owned flag is 0
end)

t.test("handle.raw rejects non-NT_HANDLE", function()
    t.raises(function() handle.raw(42) end, "expected NT_HANDLE")
    t.raises(function() handle.raw(nil) end, "expected NT_HANDLE")
    t.raises(function() handle.raw("not a handle") end, "expected NT_HANDLE")
end)
