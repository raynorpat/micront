-- nt.thread — spawn an OS thread that runs Lua code in its own fresh
-- lua_State. The new thread shares the parent's process (same handle
-- table, same heap, same modules-on-disk) but has a completely
-- independent VM: separate GC, separate JIT, separate stack. There is
-- no shared mutable Lua state between parent and child.
--
-- Usage:
--   local thread = require('nt.thread')
--   local th = thread.run([[
--       local ffi = require('ffi')
--       -- PAYLOAD is a string set by the parent; "" if none passed.
--       return "child saw: " .. PAYLOAD
--   ]], "hello")
--   th:wait()
--   local status, result = th:result()  -- "ok", "child saw: hello"
--   th:close()
--
-- Sharing handles with the child:
--   Same process = same kernel handle table. Pass the integer handle
--   value through PAYLOAD; the child casts it back to HANDLE and uses
--   it directly with ntdll calls. The parent retains ownership; the
--   child must not NtClose handles it borrowed.
--
--     local ev = ke.event()
--     local h_int = tonumber(ffi.cast('intptr_t',
--                                     require('nt.dll.handle').raw(
--                                         ev:handle())))
--     thread.run([[
--         local ffi = require('ffi')
--         local ntdll = require('nt.dll')
--         local h = ffi.cast('HANDLE', tonumber(PAYLOAD))
--         ntdll.NtWaitForSingleObject(h, 0, nil)
--         return "got it"
--     ]], tostring(h_int))
--
-- Lifetime:
--   Every byte the spawned thread sees lives on the process heap, not
--   on Lua's GC heap. The Thread wrapper owns release; closing the
--   wrapper while the thread is still running drops the parent's
--   reference but never blocks and never NtTerminateThreads — the
--   thread keeps its own ref and frees ctx itself when it exits (or
--   the parent claims its ref via crash detection if the thread died
--   before reaching its exit path).
--
-- Reactor compatibility:
--   The C side exposes only non-blocking primitives (spawn, handle,
--   done, result, close). All actual waiting happens on the Lua side
--   via `nt.dll.ke.NtWaitForSingleObject` over a borrowed handle, so a
--   future reactor can replace `:wait` (or shadow the metatable) to
--   yield the calling coroutine instead of blocking the OS thread.
--   Reactor code SHOULD NOT call `:wait` from inside a coroutine —
--   use the reactor's own wait verb on `:handle()` instead.

local ffi    = require('ffi')
local ke     = require('nt.dll.ke')
local handle = require('nt.dll.handle')

ffi.cdef[[
typedef struct CR_THREAD CR_THREAD;

CR_THREAD * _cr_thread_spawn(const char *chunk,   unsigned long chunk_len,
                             const char *payload, unsigned long payload_len);
void *      _cr_thread_handle(CR_THREAD *t);
int         _cr_thread_done  (CR_THREAD *t);
int         _cr_thread_result(CR_THREAD *t,
                              const char **out_buf, unsigned long *out_len);
void        _cr_thread_close (CR_THREAD *t);

/* Owner cdata: holds the CR_THREAD*, runs _cr_thread_close on __gc.
 * Kept separate from the Lua-table wrapper so the cleanup path is
 * deterministic regardless of how the wrapper is dropped. */
typedef struct _CR_THREAD_OWNER {
    CR_THREAD *t;
} CR_THREAD_OWNER;
]]

local C = ffi.C

ffi.metatype('CR_THREAD_OWNER', {
    __gc = function(self)
        if self.t ~= nil then
            C._cr_thread_close(self.t)
            self.t = nil
        end
    end,
})

local Thread = {}
Thread.__index = Thread

-- BLOCKING wait for the thread to finish. seconds=nil → block forever.
-- Returns true if the thread terminated, false on timeout.
--
-- Implemented in pure Lua over `nt.dll.ke.NtWaitForSingleObject` so a
-- reactor can shadow this method (or skip it entirely in favour of a
-- coroutine-yielding wait verb) without touching the C side. DO NOT
-- call this from inside a reactor coroutine — it'd block the entire
-- reactor thread. Use the reactor's own wait verb on `:handle()`.
function Thread:wait(seconds)
    if self._owner.t == nil then
        error("nt.thread:wait: thread already closed", 2)
    end
    local st = ke.NtWaitForSingleObject(self._h, false, ke.timeout(seconds))
    return st == 0       -- 0 = STATUS_SUCCESS; 0x102 = STATUS_TIMEOUT
end

-- Non-blocking poll. Returns true if the thread has terminated, false
-- if still running. Reactor code uses this to short-circuit a wait
-- when the thread already finished between scheduling decisions.
function Thread:done()
    if self._owner.t == nil then return true end   -- closed = done
    local rc = C._cr_thread_done(self._owner.t)
    if rc < 0 then error("nt.thread:done: kernel error", 2) end
    return rc == 1
end

-- Read the chunk's return value. If the thread is still running,
-- raises (caller must wait first — :wait, :done, or via the reactor).
-- Returns (status, value):
--   status = "ok"     value = string returned by the chunk
--   status = "error"  value = pcall error message
--   status = "panic"  value = "" (couldn't create lua_State)
--   status = "crash"  value = "" (thread terminated before its exit
--                                 path ran — uncaught native exception,
--                                 stack overflow, chunk-self-terminate,
--                                 or any path that bypasses pcall and
--                                 our cleanup. The chunk got SOME of
--                                 the way through but not to return.)
-- Cached after first call.
function Thread:result()
    if self._cached_status then
        return self._cached_status, self._cached_value
    end
    if self._owner.t == nil then
        error("nt.thread:result: thread already closed", 2)
    end
    if not self:done() then
        error("nt.thread:result: thread not done; wait for it first", 2)
    end
    local out_buf = ffi.new('const char *[1]')
    local out_len = ffi.new('unsigned long[1]')
    local rc = C._cr_thread_result(self._owner.t, out_buf, out_len)
    local s
    if     rc == 0 then s = "ok"
    elseif rc == 1 then s = "error"
    elseif rc == 2 then s = "panic"
    else                s = "crash"
    end
    local v = ffi.string(out_buf[0], out_len[0])
    self._cached_status = s
    self._cached_value  = v
    return s, v
end

-- Underlying NT thread HANDLE wrapped as a non-owning NT_HANDLE.
-- Suitable for passing into nt.dll.* APIs (NtWaitForMultipleObjects
-- in a reactor wait set, etc.).
--
-- Lifetime: the wrapper does NOT own the kernel handle — this Thread
-- wrapper does. If you stash this handle in a long-lived data
-- structure (e.g. a reactor's wait set), keep the parent Thread
-- wrapper alive for at least as long, otherwise its __gc will
-- NtClose the underlying handle out from under your wait set.
function Thread:handle()
    if self._owner.t == nil then return nil end
    return self._h
end

-- Explicit release. Force-terminates the thread first if still running.
-- Idempotent. The wrapper's __gc does the same path; call this for
-- deterministic cleanup.
function Thread:close()
    if self._owner.t ~= nil then
        C._cr_thread_close(self._owner.t)
        self._owner.t = nil
    end
end

local M = {}

-- Spawn a thread that runs `chunk` (Lua source) in a fresh lua_State,
-- with `payload` (string, optional) exposed as the global PAYLOAD.
-- Returns a Thread wrapper.
function M.run(chunk, payload)
    if type(chunk) ~= "string" then
        error("nt.thread.run: chunk must be a string, got " .. type(chunk), 2)
    end
    payload = payload or ""
    if type(payload) ~= "string" then
        error("nt.thread.run: payload must be a string or nil, got "
              .. type(payload), 2)
    end
    local t = C._cr_thread_spawn(chunk, #chunk, payload, #payload)
    if t == nil then
        error("nt.thread.run: spawn failed (heap or thread create)", 2)
    end
    local owner = ffi.new('CR_THREAD_OWNER')
    owner.t = t
    -- Cache a non-owning NT_HANDLE around the thread handle so :wait
    -- (and any caller wanting an NT_HANDLE for nt.dll.* APIs) doesn't
    -- reallocate per call. The kernel handle's lifetime stays with
    -- the CR_THREAD ctx; the borrowed wrapper has __owned=0 so its
    -- own __gc is a no-op.
    local h = handle.borrow(C._cr_thread_handle(t))
    return setmetatable({ _owner = owner, _h = h }, Thread)
end

return M
