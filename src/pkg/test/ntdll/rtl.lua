-- nt.dll.rtl -- RtlCaptureContext.  The routine already lived in the RTL lib
-- (xcptmisc.asm); the work here was exporting it from ntdll so kernel32 can
-- forward it (std backtrace/panic code calls kernel32!RtlCaptureContext).
--
-- The asm fills Eip/Ebp/Esp from the caller's frame pointer, so the captured
-- frame is whatever invoked us (LuaJIT's FFI call gate).  We assert the
-- snapshot is sane rather than checking exact values: every field non-zero and
-- in the user-mode half of the address space, and the call returns without
-- faulting (a bad ebp deref would have crashed here).

local ffi = require('ffi')
local t   = require('test')
local rtl = require('nt.dll.rtl')

local function ptr_nonzero(p) return tonumber(ffi.cast('uintptr_t', p)) ~= 0 end

t.suite("rtl")

t.test("RtlCaptureContext returns a sane register snapshot", function()
    local ctx = rtl.RtlCaptureContext()

    t.ok(tonumber(ctx.Eip)   ~= 0, "Eip captured (non-zero)")
    t.ok(tonumber(ctx.Esp)   ~= 0, "Esp captured (non-zero)")
    t.ok(tonumber(ctx.Ebp)   ~= 0, "Ebp captured (non-zero)")
    t.ok(tonumber(ctx.SegCs) ~= 0, "SegCs captured")

    -- User-mode code/stack live below the 0x80000000 kernel boundary.
    t.ok(tonumber(ctx.Eip) < 0x80000000, "Eip is a user-mode address")
    t.ok(tonumber(ctx.Esp) < 0x80000000, "Esp is a user-mode address")
end)

-- Vectored exception handler registration (the process-wide list + lock in
-- ntdll dll\vectxcpt.c, initialized by LdrpInitializeProcess).  We exercise the
-- list mechanics here; the never-invoked callback means no exception is raised,
-- so this is crash-free.  The dispatch path itself (RtlDispatchException calling
-- the handler on a real exception) is verified by the actual exception oracle
-- -- a real Win32 program's startup VEH -- not by re-entering LuaJIT from an
-- exception context here.
local function noop_handler() return rtl.EXCEPTION_CONTINUE_SEARCH end

t.test("vectored handler: add returns a handle, remove succeeds", function()
    local h, cb = rtl.add_vectored_handler(true, noop_handler)
    t.ok(ptr_nonzero(h), "RtlAddVectoredExceptionHandler returned a handle")
    t.ok(rtl.remove_vectored_handler(h), "RtlRemoveVectoredExceptionHandler succeeded")
    local _ = cb                              -- keep the callback alive until removed
end)

t.test("vectored handler: removing a bogus handle fails", function()
    t.eq(rtl.remove_vectored_handler(ffi.cast('void *', 0xDEAD)), false,
         "unknown handle is rejected")
end)

t.test("vectored handler: two handlers add and remove independently", function()
    local h1, c1 = rtl.add_vectored_handler(true,  noop_handler)
    local h2, c2 = rtl.add_vectored_handler(false, noop_handler)
    t.ok(ptr_nonzero(h1) and ptr_nonzero(h2), "both registered")
    t.ok(rtl.remove_vectored_handler(h2), "remove second")
    t.ok(rtl.remove_vectored_handler(h1), "remove first")
    t.eq(rtl.remove_vectored_handler(h1), false, "double-remove rejected")
    local _ = c1; local _ = c2
end)
