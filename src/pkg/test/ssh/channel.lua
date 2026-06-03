-- test.ssh.channel — connection-layer message builders + the Channel
-- transport (the data phase rides nt.term over this).  Pure; no DLL.

local t       = require('test')
local channel = require('ssh.channel')
local wire    = require('ssh.wire')
local consts  = require('ssh.consts')

t.suite("ssh.channel")

t.test("CHANNEL_OPEN_CONFIRMATION builder", function()
    local r = wire.reader(channel.open_confirm(7, 0, 1024, 32768))
    t.eq(r:u8(), consts.msg.CHANNEL_OPEN_CONFIRMATION)
    t.eq(r:u32(), 7); t.eq(r:u32(), 0); t.eq(r:u32(), 1024); t.eq(r:u32(), 32768)
end)

t.test("CHANNEL_DATA / WINDOW_ADJUST / EOF / CLOSE builders", function()
    local r = wire.reader(channel.data(3, "hello"))
    t.eq(r:u8(), consts.msg.CHANNEL_DATA); t.eq(r:u32(), 3); t.eq(r:string(), "hello")
    local w = wire.reader(channel.window_adjust(1, 4096))
    t.eq(w:u8(), consts.msg.CHANNEL_WINDOW_ADJUST); t.eq(w:u32(), 1); t.eq(w:u32(), 4096)
    t.eq(wire.reader(channel.eof(2)):u8(),   consts.msg.CHANNEL_EOF)
    t.eq(wire.reader(channel.close(2)):u8(), consts.msg.CHANNEL_CLOSE)
end)

t.test("Channel transport read (data + EOF) and chunked write", function()
    local sent, inbox, i = {}, { channel.data(0, "ab"), channel.eof(0) }, 0
    local ch = channel.new{
        peer_ch = 5, our_ch = 0,
        send = function(p) sent[#sent + 1] = p end,
        recv = function() i = i + 1; return inbox[i] end,
        our_window = 1024, peer_window = 1024, peer_maxpkt = 8,
    }
    t.eq(ch:read(), "ab")        -- first CHANNEL_DATA payload
    t.eq(ch:read(), nil)         -- CHANNEL_EOF -> end of stream

    ch:write("hello world!!")    -- 13 bytes > maxpkt 8 -> two CHANNEL_DATA
    t.eq(#sent, 2, "write chunked to peer_maxpkt")
    local r = wire.reader(sent[1])
    t.eq(r:u8(), consts.msg.CHANNEL_DATA); t.eq(r:u32(), 5)
    t.eq(r:string(), "hello wo")
end)
