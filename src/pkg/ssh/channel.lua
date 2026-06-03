-- ssh.channel — the connection layer (RFC 4254): session channel messages
-- plus a Channel that presents the CHANNEL_DATA stream as an nt.term
-- transport (blocking :read()/:write()), so the terminal stack (line editor,
-- a REPL, eventually a spawned program) rides straight on top of it.
--
-- Single-channel, single-reader: the data phase is one blocking loop, so no
-- scheduler is needed.  read() consumes CHANNEL_DATA (handling window
-- replenishment, WINDOW_ADJUST, EOF/CLOSE inline); write() emits CHANNEL_DATA
-- chunked to the peer's max packet.

local wire   = require('ssh.wire')
local consts = require('ssh.consts')

local M = {}

-- ---- message builders ---------------------------------------------
function M.open_confirm(peer_ch, our_ch, window, maxpkt)
    return wire.buf():u8(consts.msg.CHANNEL_OPEN_CONFIRMATION)
        :u32(peer_ch):u32(our_ch):u32(window):u32(maxpkt):tostring()
end
function M.open_failure(peer_ch, reason, desc)
    return wire.buf():u8(consts.msg.CHANNEL_OPEN_FAILURE)
        :u32(peer_ch):u32(reason or consts.open_failure.UNKNOWN_CHANNEL_TYPE)
        :string(desc or "unknown channel type"):string(""):tostring()
end
function M.req_success(peer_ch)
    return wire.buf():u8(consts.msg.CHANNEL_SUCCESS):u32(peer_ch):tostring()
end
function M.req_failure(peer_ch)
    return wire.buf():u8(consts.msg.CHANNEL_FAILURE):u32(peer_ch):tostring()
end
function M.data(peer_ch, bytes)
    return wire.buf():u8(consts.msg.CHANNEL_DATA):u32(peer_ch):string(bytes):tostring()
end
function M.window_adjust(peer_ch, n)
    return wire.buf():u8(consts.msg.CHANNEL_WINDOW_ADJUST):u32(peer_ch):u32(n):tostring()
end
function M.eof(peer_ch)
    return wire.buf():u8(consts.msg.CHANNEL_EOF):u32(peer_ch):tostring()
end
function M.close(peer_ch)
    return wire.buf():u8(consts.msg.CHANNEL_CLOSE):u32(peer_ch):tostring()
end
-- exit-status (RFC 4254 §6.10): a no-reply CHANNEL_REQUEST sent before
-- EOF/CLOSE so the client process exits with the program's status rather
-- than the 255 "no exit-status received" fallback.
function M.exit_status(peer_ch, code)
    return wire.buf():u8(consts.msg.CHANNEL_REQUEST)
        :u32(peer_ch):string("exit-status"):boolean(false)
        :u32(code or 0):tostring()
end

-- ---- Channel: the nt.term transport over CHANNEL_DATA -------------
local Ch = {}
Ch.__index = Ch

-- new{ peer_ch, our_ch, send, recv, our_window, peer_window, peer_maxpkt, log }
-- send(payload) / recv() -> payload are the connection's packet I/O.
function M.new(o)
    return setmetatable({
        peer_ch     = o.peer_ch,
        our_ch      = o.our_ch,
        send        = o.send,
        recv        = o.recv,
        our_window  = o.our_window,
        peer_window = o.peer_window,
        peer_maxpkt = o.peer_maxpkt or 32768,
        consumed    = 0,
        closed      = false,
        log         = o.log or function() end,
    }, Ch)
end

-- read() -> next terminal bytes, or nil at channel EOF/CLOSE.  Other
-- connection messages (window adjust, mid-session requests) are serviced
-- inline so the single reader keeps the channel live.
function Ch:read()
    while true do
        local r  = wire.reader(self.recv())
        local mt = r:u8()
        if mt == consts.msg.CHANNEL_DATA then
            r:u32()                                  -- our channel id
            local data = r:string()
            -- replenish our receive window when half-spent
            self.consumed = self.consumed + #data
            if self.consumed * 2 >= self.our_window then
                self.send(M.window_adjust(self.peer_ch, self.consumed))
                self.consumed = 0
            end
            return data
        elseif mt == consts.msg.CHANNEL_WINDOW_ADJUST then
            r:u32(); self.peer_window = self.peer_window + r:u32()
        elseif mt == consts.msg.CHANNEL_EOF then
            return nil
        elseif mt == consts.msg.CHANNEL_CLOSE then
            self.closed = true
            return nil
        elseif mt == consts.msg.CHANNEL_REQUEST then
            self.log("channel: ignoring mid-session CHANNEL_REQUEST")
        else
            self.log("channel: ignoring msg " .. mt)
        end
    end
end

-- write(bytes) — emit CHANNEL_DATA, chunked to the peer's max packet.
function Ch:write(bytes)
    local i = 1
    while i <= #bytes do
        local chunk = string.sub(bytes, i, i + self.peer_maxpkt - 1)
        self.send(M.data(self.peer_ch, chunk))
        self.peer_window = self.peer_window - #chunk
        i = i + #chunk
    end
end

return M
