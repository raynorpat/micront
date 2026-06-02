-- nt.term.child — spawn a child process under overlapped pipe stdio.
--
-- This is the spawn helper kept out of the terminal core (ps stays the
-- process layer; this just wires pipes to it).  It hands back the child's
-- stdin/stdout as overlapped nt.term.stream transports, so the scheduler
-- drives them asynchronously alongside everything else — a child's I/O is
-- just two more streams to a bridge.
--
--   local c = child.spawn{ exe = LUA_EXE, cmdline = '"lua.exe" -e "..."',
--                          cwd = , dll_path = , env = }
--   c.stdin   -- WE write -> the child reads (overlapped)
--   c.stdout  -- the child writes -> WE read (overlapped)
--   c.proc    -- the ps.spawn record
--   c:wait()  -- block until exit, returns the exit status
--
-- Pipe names are unique per (process, thread, call) via the current
-- ClientId — NOT a module-local counter, which collides across lua_State
-- workers and processes (the old nt.tty _seq bug).

local stream = require('nt.term.stream')
local npfs   = require('nt.dll.npfs')
local fs     = require('nt.dll.fs')
local ps     = require('nt.dll.ps')
local handle = require('nt.dll.handle')

-- Disambiguates multiple children spawned from the SAME thread; the
-- PID/TID prefix below makes it unique across threads and processes.
local _n = 0

local function unique_tag()
    local me = ps.thread_basic_info(handle.NtCurrentThread())
    _n = _n + 1
    return string.format("\\Device\\NamedPipe\\term-%d-%d-%d", me.pid, me.tid, _n)
end

local M = {}

local Child = {}
Child.__index = Child

function M.spawn(opts)
    assert(opts and opts.exe, "child.spawn: opts.exe (NT path to image) required")
    local tag = unique_tag()

    -- stdin: our server end is overlapped (we write async); the child's
    -- client end is synchronous (it uses ordinary ReadFile).
    local in_srv  = npfs.create_named_pipe{ name = tag .. "i" }
    local in_cli  = npfs.open_pipe(tag .. "i",
                                   { options = fs.FILE_SYNCHRONOUS_IO_NONALERT })
    -- stdout (and stderr): child writes synchronously, we read overlapped.
    local out_srv = npfs.create_named_pipe{ name = tag .. "o" }
    local out_cli = npfs.open_pipe(tag .. "o",
                                   { options = fs.FILE_SYNCHRONOUS_IO_NONALERT })

    local proc = ps.spawn{
        exe      = opts.exe,    cmdline = opts.cmdline,
        cwd      = opts.cwd,    dll_path = opts.dll_path, env = opts.env,
        stdin    = in_cli,      stdout = out_cli,         stderr = out_cli,
    }
    -- The child inherited the client ends at creation; drop our copies so
    -- the ONLY holders are the child — that's what makes our reads see EOF
    -- when it exits.  Then start it (ps.spawn creates it suspended).
    in_cli:close(); out_cli:close()
    ps.NtResumeThread(proc.thread)

    return setmetatable({
        stdin  = stream.wrap(in_srv),
        stdout = stream.wrap(out_srv),
        proc   = proc,
    }, Child)
end

-- Block until the child exits; returns its exit status.  Synchronous (a
-- one-shot wait, not part of the reactor) — call it after the bridge
-- tasks have drained, or from a task via the process handle if you need
-- it cooperatively.
function Child:wait()
    return ps.wait_exit(self.proc)
end

function Child:close()
    self.stdin:close()
    self.stdout:close()
    if self.proc.thread  then self.proc.thread:close()  end
    if self.proc.process then self.proc.process:close() end
end

return M
