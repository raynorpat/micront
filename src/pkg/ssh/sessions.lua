-- ssh.sessions — what runs on an opened SSH session channel.
--
-- A session handler is `function(S, sess)`: S is the connection's scheduler
-- and `sess` is the channel presented as an nt.term transport —
--
--   sess.tin          read inbound bytes (client keystrokes); nil at EOF
--   sess.tout         write outbound bytes; :close() ends the channel
--   sess.exec         a one-shot command string, or nil for an interactive shell
--   sess.exit_status  report the program's exit code (so the client sees it,
--                     not the 255 "no exit-status" fallback)
--   sess.defer        register cleanup to run after the reactor stops
--   sess.log          logger
--
-- A handler spawns its own task(s) on S and returns; it signals completion by
-- closing sess.tout.  Three handlers cover the three ways to attach work:
--
--   shell  — spawn a real program (nt.term.child) and bridge it to the channel
--            through the cooked line discipline (echo + editing).  Aim 3.
--   repl   — an in-process Lua line REPL over nt.term.line, no child.  Aim 2.
--   echo   — raw in-process loop, no terminal layer at all.  Aim 1.

local child  = require('nt.term.child')
local bridge = require('nt.term.bridge')
local line   = require('nt.term.line')

local M = {}

-- ---- aim 3: a launched program as the shell --------------------------
-- shell{ exe, cmdline, cwd, dll_path, env, prompt }
--   exe      NT image path (required), e.g. "\\SystemRoot\\System32\\lua.exe"
--   cmdline  the child's command line (default: exe)
--   prompt   the cooked line-editor prompt shown to the remote user
-- The child's stdio is bridged cooked to the channel: keystrokes are echoed
-- and line-edited server-side (an SSH client without local cooking expects
-- this) and only whole lines reach the child — mirroring nt.term.run.cooked
-- for the serial console.
function M.shell(o)
    assert(o and o.exe, "ssh.sessions.shell: opts.exe required")
    return function(S, sess)
        local cmdline = o.cmdline
        if sess.exec and o.exec_cmdline then cmdline = o.exec_cmdline(sess.exec) end
        local c = child.spawn{
            exe = o.exe, cmdline = cmdline or o.exe,
            cwd = o.cwd, dll_path = o.dll_path, env = o.env,
        }
        sess.log('session: spawned %s', o.exe)
        bridge.cooked(S, sess.tin, sess.tout, c, {
            prompt  = o.prompt or "",
            onlcr   = sess.pty,                  -- raw-mode pty client needs \n -> \r\n
            on_done = function()                 -- child's stdout hit EOF: it exited
                sess.exit_status(c:wait())       -- report its status to the client
                sess.tout:close()                -- EOF + CLOSE; mux drains + stops
            end,
        })
        -- Single authoritative teardown, after the reactor stops for ANY reason
        -- (clean exit, client disconnect, error).  terminate() is the safety
        -- net: if the client dropped and the program ignored its stdin EOF, the
        -- on_done chain never fired and the child is still running — kill it so
        -- it can't outlive the session, then close handles.
        sess.defer(function()
            c:terminate()
            c:close()
            sess.log('session: child reaped')
        end)
    end
end

-- ---- aim 2: an in-process line REPL ----------------------------------
-- repl{ eval, banner, prompt }
--   eval(line) -> string   evaluate one input line (default: a Lua REPL)
-- Runs the nt.term line editor over the channel, so the remote user gets
-- echo + in-line editing without a child process.  A bare "exit"/"quit"
-- ends the session.
local function lua_eval(src)
    local chunk, e = loadstring("return " .. src)
    if not chunk then chunk, e = loadstring(src) end
    if not chunk then return "! parse: " .. tostring(e) end
    local ok, res = pcall(chunk)
    if not ok then return "! " .. tostring(res) end
    if res == nil then return "ok" end
    return tostring(res)
end

function M.repl(o)
    o = o or {}
    local eval = o.eval or lua_eval
    return function(S, sess)
        S:spawn(function()
            if sess.exec then                    -- ssh host "cmd": one-shot
                sess.tout:write(eval(sess.exec) .. "\r\n")
                sess.exit_status(0)
                sess.tout:close()
                return
            end
            if o.banner then sess.tout:write(o.banner) end
            local rl = line.new{ input = sess.tin, output = sess.tout,
                                 prompt = o.prompt or "micront> " }
            while true do
                local ln = rl:read()
                if ln == nil then break end
                ln = (ln:gsub("%s+$", ""))
                if ln == "exit" or ln == "quit" then break end
                if ln ~= "" then sess.tout:write(eval(ln) .. "\r\n") end
            end
            sess.exit_status(0)
            sess.tout:close()
        end)
    end
end

-- ---- aim 1: raw in-process echo --------------------------------------
-- No terminal layer: inbound bytes are written straight back.  The simplest
-- thing that proves the channel byte path end-to-end.
function M.echo()
    return function(S, sess)
        S:spawn(function()
            while true do
                local d = sess.tin:read()
                if d == nil then break end
                sess.tout:write(d)
            end
            sess.exit_status(0)
            sess.tout:close()
        end)
    end
end

return M
