-- sshd.lua — the SSH server program (a deployment entry point, not library).
--
-- pkg/ssh is a library: it knows SSH over a socket and nothing else.  This
-- entry is the application around it — it brings up the NIC, listens, and for
-- each connection calls ssh.serve() with the policy this deployment wants: the
-- host key, who is authorized, and what runs on the channel.  Network setup
-- and the choice of shell live HERE, where deployment decisions belong.
--
-- Launched by the universal launcher:  launch.lua sshd [port]   (default 22).
--
-- TEST RIG: fixed host-key seed (stable K_S / known_hosts, NOT a secret) and
-- any signature-verified key is accepted.  Real authorization (an allowed-keys
-- set, per-user shell) is a policy layer to add on top — it slots into the
-- authorize/session opts without touching the library.

local boot = require('nt.boot')
local dhcp = require('nt.net.dhcp')
local afd  = require('nt.net.afd')
local ssh  = require('ssh')

local LUA_EXE      = "\\SystemRoot\\System32\\lua.exe"
local HOSTKEY_SEED = string.rep("\42", 32)

local function log(fmt, ...) print('[sshd] ' .. string.format(fmt, ...)) end

-- The shell for this deployment: spawn lua.exe (MicroNT's interpreter is its
-- shell — there is no cmd.exe).  A `shell` request gets the interactive REPL:
-- "-i" forces it, because lua's stdin here is a pipe, not a tty, and without
-- it LuaJIT reads all of stdin as one batch script instead of a REPL.  An
-- `exec` request runs the requested command (lua.exe -e) and exits.
local SESSION = ssh.sessions.shell{
    exe          = LUA_EXE,
    cmdline      = "lua.exe -i",
    exec_cmdline = function(cmd) return 'lua.exe -e "' .. cmd .. '"' end,
}

local function main(port)
    port = tonumber(port) or 22
    boot.run()

    -- DHCP so the forwarded host port reaches the guest (retry: it can race
    -- the NIC coming up).
    local got
    for attempt = 1, 12 do
        if pcall(dhcp.acquire, { timeout = 5 }) then got = true; break end
        log('dhcp attempt %d/12 failed; retrying', attempt)
    end
    log(got and 'dhcp ok' or 'WARNING: no DHCP lease; binding anyway')

    local hostkey = { seed = HOSTKEY_SEED,
                      pub  = ssh.crypto.ed25519_pubkey(HOSTKEY_SEED) }

    local listener = afd.tcp()
    afd.bind(listener, "0.0.0.0", port)
    afd.listen(listener, 5)
    log('listening on 0.0.0.0:%d', port)

    while true do
        local ok, client = pcall(afd.accept, listener)   -- nil timeout = block
        if not ok then
            log('accept error: %s', tostring(client))
        else
            log('--- connection accepted ---')
            -- ssh.serve owns the socket (wraps it as a stream, closes it on
            -- exit) and never raises; the pcall only guards setup-time errors.
            local sok, serr = pcall(ssh.serve, client, {
                hostkey = hostkey,
                session = SESSION,
                log     = log,
            })
            if not sok then log('connection failed: %s', tostring(serr)) end
        end
    end
end

return main
