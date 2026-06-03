-- ssh.conn — one SSH-2 connection, run as an event-driven reactor.
--
-- The whole connection lives on ONE nt.term.sched: the AFD socket is wrapped
-- as an overlapped nt.term.stream, so every recv/send parks the running task
-- on I/O completion instead of blocking the OS thread.  There is no
-- blocking→async handoff — the handshake reads as straight-line code (each
-- recv()/send() yields transparently through the stream) and the data phase
-- is just more tasks on the same scheduler.
--
-- Phases:
--   handshake  curve25519-sha256 KEX + ssh-ed25519 host key + NEWKEYS, then
--              chacha20-poly1305 turns on, SERVICE_REQUEST/ACCEPT, and
--              publickey userauth.  Strictly request/response — one task.
--   data       once a "session" channel opens and shell/exec starts, fan out:
--                * demux task — recv() every packet, route CHANNEL_DATA to the
--                  session's input, service window/EOF/CLOSE/requests inline;
--                * mux task   — the SINGLE socket writer: drain an outbound
--                  mailbox, seal + write.  All sends funnel here so the two
--                  cipher directions each have exactly one caller (seq stays
--                  monotonic) and concurrent writers can't collide on the
--                  stream's one write slot;
--                * the session — opts.session(S, sess) spawns whatever runs on
--                  the channel (a bridged child, a line REPL, a raw echo).
--
-- The connection ends when the mux drains a closed mailbox (the session said
-- "done" via sess.tout:close()) and stops the scheduler; the demux, still
-- parked on the socket read, is abandoned and its pending read cancelled when
-- serve() closes the stream.  This mirrors nt.term.run.cooked's teardown.

local stream   = require('nt.term.stream')
local sched    = require('nt.term.sched')
local xport    = require('ssh.xport')
local packet   = require('ssh.packet')
local cipoly   = require('ssh.cipoly')
local kex      = require('ssh.kex')
local userauth = require('ssh.userauth')
local channel  = require('ssh.channel')
local consts   = require('ssh.consts')
local crypto   = require('ssh.crypto')
local wire     = require('ssh.wire')
local rng      = require('nt.dll.rng')

local M = {}

local DEFAULT_VERSION = "SSH-2.0-MicroNT_0.1"
local OUR_WIN, OUR_MAXPKT = 1024 * 1024, 32768

-- The cipher transport: byte framing (xport) + the per-direction cipher and
-- sequence counters.  recv()/send() are single-caller per direction (the
-- demux reads, the mux writes), so the cipher state needs no locking.  Both
-- directions start as the cleartext transform and switch to chacha20-poly1305
-- after NEWKEYS; sequence numbers count every packet and do NOT reset there.
local function new_io(xp)
    local io = {
        xp          = xp,
        recv_cipher = packet.none(),
        send_cipher = packet.none(),
        seq_in      = 0,
        seq_out     = 0,
    }
    function io.recv()
        local p = io.recv_cipher:read(io.seq_in, function(n) return io.xp:read(n) end)
        io.seq_in = io.seq_in + 1
        return p
    end
    function io.send(payload)
        io.xp:write(io.send_cipher:seal(io.seq_out, payload))
        io.seq_out = io.seq_out + 1
    end
    return io
end

-- ---- data phase ---------------------------------------------------
-- ctx = { peer_ch, peer_window, peer_maxpkt, exec, user, log }
local function data_phase(S, io, ctx, session_fn, defer)
    local log = ctx.log
    local tin    = S:channel()      -- inbound CHANNEL_DATA bytes -> the session
    local outbox = S:mailbox()      -- outbound SSH payloads -> the one socket writer
    local st = { peer_window = ctx.peer_window, peer_maxpkt = ctx.peer_maxpkt,
                 consumed = 0, our_window = OUR_WIN }

    -- mux: the ONLY socket writer.  Drains the mailbox; when it closes (the
    -- session is finished and EOF/CLOSE are queued), drain the rest then stop.
    -- A write failure means the peer is gone — an expected teardown path, not
    -- an error — so absorb it and stop rather than faulting the reactor.
    S:spawn(function()
        local ok, e = pcall(function()
            while true do
                local payload = outbox:get()
                if payload == nil then break end
                io.send(payload)
            end
        end)
        if not ok then log('mux: %s', tostring(e)) end
        S:stop()
    end)
    local function send(payload) outbox:put(payload) end

    -- tout: the session's output transport.  write() frames bytes into
    -- CHANNEL_DATA (chunked to the peer's max packet); close() ends the
    -- channel (EOF + CLOSE) and lets the mux drain and stop.
    local tout = {
        write = function(_, bytes)
            local i = 1
            while i <= #bytes do
                local chunk = string.sub(bytes, i, i + st.peer_maxpkt - 1)
                send(channel.data(ctx.peer_ch, chunk))
                st.peer_window = st.peer_window - #chunk
                i = i + #chunk
            end
        end,
        close = function(_)
            send(channel.eof(ctx.peer_ch))
            send(channel.close(ctx.peer_ch))
            outbox:close()
        end,
    }

    -- demux: route every inbound packet.  CHANNEL_DATA -> the session input;
    -- window/EOF/CLOSE/mid-session requests serviced here so the session only
    -- ever sees a clean byte stream.  Socket EOF/error ends the stream.
    S:spawn(function()
        local ok, e = pcall(function()
            while true do
                local r  = wire.reader(io.recv())
                local mt = r:u8()
                if mt == consts.msg.CHANNEL_DATA then
                    r:u32()
                    local d = r:string()
                    st.consumed = st.consumed + #d
                    if st.consumed * 2 >= st.our_window then
                        send(channel.window_adjust(ctx.peer_ch, st.consumed))
                        st.consumed = 0
                    end
                    tin:write(d)
                elseif mt == consts.msg.CHANNEL_WINDOW_ADJUST then
                    r:u32(); st.peer_window = st.peer_window + r:u32()
                elseif mt == consts.msg.CHANNEL_EOF then
                    tin:close()
                elseif mt == consts.msg.CHANNEL_CLOSE then
                    tin:close()
                elseif mt == consts.msg.CHANNEL_REQUEST then
                    r:u32(); local rt, want_reply = r:string(), r:boolean()
                    if want_reply then send(channel.req_failure(ctx.peer_ch)) end
                    log('channel: mid-session request %q ignored', rt)
                else
                    log('channel: ignoring msg %d', mt)
                end
            end
        end)
        if not ok then log('demux: %s', tostring(e)) end
        tin:close()                 -- socket gone -> the session sees EOF
    end)

    -- Hand the session its transport.  It spawns its own task(s) and returns;
    -- it signals completion by closing tout (EOF/CLOSE -> mux drains -> stop).
    session_fn(S, {
        tin         = tin,
        tout        = tout,
        exec        = ctx.exec,         -- a one-shot command, or nil for a shell
        pty         = ctx.pty,          -- client requested a pty (raw mode -> needs CRLF)
        user        = ctx.user,
        peer_ch     = ctx.peer_ch,
        maxpkt      = ctx.peer_maxpkt,
        log         = log,
        defer       = defer,            -- register post-reactor cleanup
        send        = send,             -- raw payload enqueue (rarely needed)
        exit_status = function(code) send(channel.exit_status(ctx.peer_ch, code)) end,
    })
end

-- ---- handshake ----------------------------------------------------
-- Runs as one task; on success calls data_phase, which spawns the rest.
local function handshake(S, io, opts, defer)
    local log     = opts.log
    local v_s     = opts.version_id or DEFAULT_VERSION
    local hostkey = opts.hostkey
    local recv, send = io.recv, io.send

    -- (1) version-string exchange (no CR/LF in V_C/V_S — they feed H)
    local v_c = io.xp:exchange_versions(v_s, true)
    log('V_C=%s V_S=%s', v_c, v_s)

    -- (2) KEXINIT both ways + negotiate the suite
    local i_s = kex.build_kexinit(rng.bytes(16))
    send(i_s)
    local i_c    = recv()
    local chosen = kex.negotiate(kex.parse_kexinit(i_c), kex.parse_kexinit(i_s))
    assert(chosen.kex == "curve25519-sha256", "kex not curve25519-sha256")
    assert(chosen.host_key == "ssh-ed25519",  "host key not ssh-ed25519")

    -- (3) client ephemeral Q_C
    local r = wire.reader(recv())
    assert(r:u8() == consts.msg.KEX_ECDH_INIT, "expected KEX_ECDH_INIT")
    local q_c = r:string()
    assert(#q_c == 32, "Q_C must be 32 bytes")

    -- (4) server ephemeral + shared secret, (5) exchange hash, (6) signature
    local s_scalar, q_s = kex.ephemeral(rng.bytes(32))
    local k   = kex.shared_secret(s_scalar, q_c)
    local k_s = kex.ed25519_hostkey_blob(hostkey.pub)
    local H   = kex.exchange_hash{ v_c = v_c, v_s = v_s, i_c = i_c, i_s = i_s,
                                   k_s = k_s, q_c = q_c, q_s = q_s, k = k }
    local sig = crypto.ed25519_sign(H, hostkey.seed, hostkey.pub)

    -- (7) KEX_ECDH_REPLY + (8) NEWKEYS
    send(wire.buf():u8(consts.msg.KEX_ECDH_REPLY)
        :string(k_s):string(q_s):string(kex.ed25519_sig_blob(sig)):tostring())
    send(wire.buf():u8(consts.msg.NEWKEYS):tostring())

    -- (9) client NEWKEYS — sent only if it accepted H + our signature
    assert(wire.reader(recv()):u8() == consts.msg.NEWKEYS, "expected client NEWKEYS")
    log('KEX complete')

    -- (10) cipher on: server SENDS with key_s2c, RECEIVES with key_c2s
    local keys = kex.derive_keys(k, H, H)        -- session_id = first-KEX H
    io.recv_cipher = cipoly.new(keys.key_c2s)
    io.send_cipher = cipoly.new(keys.key_s2c)

    -- (11) service request -> accept
    local sr = wire.reader(recv())
    assert(sr:u8() == consts.msg.SERVICE_REQUEST, "expected SERVICE_REQUEST")
    local svc = sr:string()
    send(wire.buf():u8(consts.msg.SERVICE_ACCEPT):string(svc):tostring())
    log('service %q accepted', svc)

    -- (12) userauth (RFC 4252): publickey / ssh-ed25519.  We verify the
    -- signature (proves key possession) AND consult opts.authorize for policy.
    local session_id = H
    local authed, user
    for _ = 1, 20 do
        local payload = recv()
        if string.byte(payload, 1) ~= consts.msg.USERAUTH_REQUEST then
            log('userauth: unexpected msg=%d', string.byte(payload, 1)); break
        end
        local req = userauth.parse_request(payload)
        log('userauth user=%q method=%q have_sig=%s',
            req.user, req.method, tostring(req.have_sig))
        if req.method == "publickey" and req.pk_alg == "ssh-ed25519" then
            if not req.have_sig then
                send(userauth.build_pk_ok(req.pk_alg, req.pk_blob))
            elseif userauth.verify_ed25519(req, session_id)
                   and opts.authorize{ user = req.user, service = req.service,
                                       method = req.method, pk_alg = req.pk_alg,
                                       pk_blob = req.pk_blob } then
                send(userauth.build_success())
                authed, user = true, req.user
                log('userauth SUCCESS user=%q', req.user)
                break
            else
                send(userauth.build_failure({ "publickey" }, false))
            end
        else
            send(userauth.build_failure({ "publickey" }, false))
        end
    end
    if not authed then return end

    -- (13) the session channel: open, ack pty/env, start on shell or exec
    local co = wire.reader(recv())
    if co:u8() ~= consts.msg.CHANNEL_OPEN then log('expected CHANNEL_OPEN'); return end
    local ctype, peer_ch, peer_win, peer_maxpkt =
        co:string(), co:u32(), co:u32(), co:u32()
    if ctype ~= "session" then
        send(channel.open_failure(peer_ch)); log('rejected channel %q', ctype); return
    end
    send(channel.open_confirm(peer_ch, 0, OUR_WIN, OUR_MAXPKT))

    local exec_cmd, pty
    while true do
        local rq = wire.reader(recv())
        if rq:u8() ~= consts.msg.CHANNEL_REQUEST then log('expected CHANNEL_REQUEST'); return end
        rq:u32()
        local rtype, want_reply = rq:string(), rq:boolean()
        log('channel request %q', rtype)
        if rtype == "shell" then
            if want_reply then send(channel.req_success(peer_ch)) end
            break
        elseif rtype == "exec" then
            exec_cmd = rq:string()
            if want_reply then send(channel.req_success(peer_ch)) end
            break
        elseif rtype == "pty-req" then
            pty = true                       -- client put its terminal in raw mode
            if want_reply then send(channel.req_success(peer_ch)) end
        elseif rtype == "env" then
            if want_reply then send(channel.req_success(peer_ch)) end
        else
            if want_reply then send(channel.req_failure(peer_ch)) end
        end
    end

    -- Fan out: this task ends, the data-phase tasks carry the connection.
    data_phase(S, io, {
        peer_ch = peer_ch, peer_window = peer_win, peer_maxpkt = peer_maxpkt,
        exec = exec_cmd, user = user, pty = pty, log = log,
    }, opts.session, defer)
end

-- serve(sock, opts) — run one connection to completion on its own reactor.
--   opts.hostkey    { seed, pub }  ed25519 host key
--   opts.session    function(S, sess) — what runs on the channel
--   opts.authorize  function(ctx) -> bool  (default: allow any verified key)
--   opts.version_id server identification string (default SSH-2.0-MicroNT_0.1)
--   opts.log        function(fmt, ...)
-- serve owns the socket: it wraps it in a stream and closes that (which
-- closes the socket) on exit.  Returns nothing; raises nothing (errors are
-- logged) so an accept loop can pcall-free it.
function M.serve(sock, opts)
    local log = opts.log or function() end
    assert(opts.hostkey, "ssh.conn.serve: opts.hostkey required")
    assert(opts.session, "ssh.conn.serve: opts.session required")
    opts.authorize = opts.authorize or function() return true end

    local S  = sched.new()
    local sk = stream.wrap(sock, { offset = true })   -- AFD: ByteOffset required, ignored
    local io = new_io(xport.wrap(sk))
    local defers = {}
    local function defer(fn) defers[#defers + 1] = fn end

    S:spawn(function()
        local ok, e = pcall(handshake, S, io, opts, defer)
        if not ok then log('handshake: %s', tostring(e)); S:stop() end
    end)

    local rok, rerr = pcall(function() S:run() end)
    if not rok then log('reactor: %s', tostring(rerr)) end

    for i = #defers, 1, -1 do pcall(defers[i]) end
    sk:close()
end

return M
