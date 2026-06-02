-- ssh.xport — SSH transport over an nt.net.afd TCP socket.
--
-- Two jobs the packet layer needs from the byte transport:
--   * read EXACTLY n bytes (afd.recv returns up to n, so we buffer and
--     loop) — packet parsing is framed and cannot tolerate short reads;
--   * the version-string exchange (RFC 4253 §4.2) that precedes the
--     binary packet protocol.
--
-- A Conn wraps one connected afd socket and owns the receive buffer, so
-- no transport state leaks into module globals.  It deliberately knows
-- nothing about packets, ciphers, or sequence numbers — that is the
-- packet/transport-discipline layer's concern, kept separate per the
-- pkg/nt pure-library split.

local afd = require('nt.net.afd')

local M = {}

-- RFC 4253 §4.2: an identification string (incl. CR LF) is at most 255
-- bytes.  Cap line reads so a peer can't make us buffer unboundedly
-- before the SSH banner appears.
local MAX_LINE      = 255
local RECV_CHUNK    = 4096
local DEFAULT_TIMEO = 30          -- seconds

local Conn = {}
Conn.__index = Conn

-- wrap(sock, opts?) — opts.timeout overrides the per-op timeout (seconds).
function M.wrap(sock, opts)
    opts = opts or {}
    return setmetatable({
        sock    = sock,
        rbuf    = "",
        timeout = opts.timeout or DEFAULT_TIMEO,
    }, Conn)
end

-- pull one more chunk into rbuf; raises on EOF/closed peer.
function Conn:_fill()
    local chunk = afd.recv(self.sock, RECV_CHUNK, self.timeout)
    if not chunk or chunk == "" then
        error("ssh.xport: connection closed by peer", 2)
    end
    self.rbuf = self.rbuf .. chunk
end

-- read exactly n bytes.  This is the callback the packet cipher's read()
-- consumes as `read_exact`.
function Conn:read(n)
    while #self.rbuf < n do
        self:_fill()
    end
    local out = string.sub(self.rbuf, 1, n)
    self.rbuf = string.sub(self.rbuf, n + 1)
    return out
end

-- write all of s.  afd.send is expected to deliver the whole buffer (it
-- rides the async bridge); if a partial-write path ever surfaces it
-- belongs here, not in callers.
function Conn:write(s)
    afd.send(self.sock, s, self.timeout)
end

-- read one CR/LF- or LF-terminated line, returned WITHOUT the terminator.
function Conn:read_line()
    while true do
        local nl = string.find(self.rbuf, "\n", 1, true)
        if nl then
            local line = string.sub(self.rbuf, 1, nl - 1)
            self.rbuf  = string.sub(self.rbuf, nl + 1)
            if string.sub(line, -1) == "\r" then
                line = string.sub(line, 1, -2)
            end
            return line
        end
        if #self.rbuf > MAX_LINE then
            error("ssh.xport: line exceeds " .. MAX_LINE .. " bytes", 2)
        end
        self:_fill()
    end
end

-- exchange_versions(local_id, is_server) — send our identification string
-- and read the peer's, skipping any pre-banner lines the peer is allowed
-- to send first (RFC 4253 §4.2).  Returns the peer's identification string
-- (no CR/LF).  Both the value passed in and the value returned are the
-- forms used verbatim in the exchange hash (V_C / V_S), so callers keep
-- them for KEX.
--
-- `is_server` is accepted for symmetry / future ordering tweaks; today we
-- send-then-read regardless, which is legal for both roles.
function Conn:exchange_versions(local_id, is_server)
    self:write(local_id .. "\r\n")
    while true do
        local line = self:read_line()
        if string.sub(line, 1, 4) == "SSH-" then
            return line
        end
        -- non-SSH line before the banner: ignore (server greeting, etc.)
    end
end

return M
