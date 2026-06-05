-- mio (Tokio) poll dry-run — reproduce Rust mio's exact \Device\Afd readiness
-- sequence in Lua, no Rust, to validate the two kernel/AFD gaps the Tokio
-- reactor depends on:
--
--   1. an EA-less poll-helper open of \Device\Afd\Mio (AFD CREATE.C's helper
--      endpoint path — modern reactors open a bare handle they bind to an IOCP),
--   2. IOCTL_AFD_POLL == 0x00012024 (the modern AFD ABI; renumbered from NT 3.5's
--      0x00012010) issued on that helper, referencing a *foreign* socket handle
--      in the AFD_POLL_INFO Handles array — the wepoll/mio readiness model.
--
-- The IOCP integration (GetQueuedCompletionStatusEx / NtSetIoCompletion /
-- SetFileCompletionNotificationModes / NtCancelIoFileEx) is a separate, later
-- gap set; this probe deliberately uses the event-based wait so it isolates the
-- poll path. See MODERN-IPSTACK.md ("mio (Tokio) — grounded ...").

local t   = require('test')
local bit = require('bit')
local afd = require('nt.net.afd')

t.suite("mio-poll")

local TIMEOUT = 2.0

-- A connected loopback TCP pair. connect() completes via the listen backlog,
-- so accept() can run after it without a second thread.
local function listen_on()
    local listener = afd.tcp()
    t.defer(function() listener:close() end)
    afd.bind(listener, "127.0.0.1", 0)
    afd.listen(listener, 1)
    local _, port = afd.getsockname(listener)
    return listener, port
end

local function connect_to(port)
    local client = afd.tcp()
    t.defer(function() client:close() end)
    afd.bind(client, "127.0.0.1", 0)
    afd.connect(client, "127.0.0.1", port, TIMEOUT)
    return client
end

-- ------------------------------------------------------------------

t.test("EA-less \\Device\\Afd\\Mio poll-helper opens (gap 1)", function()
    local helper = afd.open_poll_helper()
    t.ok(helper ~= nil, "helper handle returned")
    helper:close()
end)

t.test("IOCTL_AFD_POLL 0x12024 on helper reports ACCEPT (gaps 1+2)", function()
    local listener, port = listen_on()
    connect_to(port)                                  -- pending connection

    local helper = afd.open_poll_helper()
    t.defer(function() helper:close() end)

    local res = afd.poll_on(helper, { [listener] = afd.POLL_ACCEPT }, TIMEOUT)
    t.ok(bit.band(res[listener] or 0, afd.POLL_ACCEPT) ~= 0,
         "POLL_ACCEPT fired on the foreign listener handle (got 0x"
         .. bit.tohex(res[listener] or 0) .. ")")
end)

t.test("IOCTL_AFD_POLL 0x12024 on helper reports RECEIVE (gaps 1+2)", function()
    local listener, port = listen_on()
    local client = connect_to(port)

    local peer = afd.accept(listener, TIMEOUT)        -- dequeue the pending conn
    t.defer(function() peer:close() end)
    afd.send(client, "mio-poll", TIMEOUT)             -- make data readable on peer

    local helper = afd.open_poll_helper()
    t.defer(function() helper:close() end)

    local res = afd.poll_on(helper, { [peer] = afd.POLL_RECEIVE }, TIMEOUT)
    t.ok(bit.band(res[peer] or 0, afd.POLL_RECEIVE) ~= 0,
         "POLL_RECEIVE fired on the foreign socket handle (got 0x"
         .. bit.tohex(res[peer] or 0) .. ")")
end)
