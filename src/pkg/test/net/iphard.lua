-- IP hardening tests.  Locks in the H-006 / H-009 / H-020 strip
-- decisions from IPSTACK-HARDENING.md so a future edit can't silently
-- re-enable IP forwarding or accept-source-routing without flunking
-- the selftest.
--
-- Tier 1 — passive MIB inspection through \Device\Tcp:
--   * ipsi_forwarding reads back as IP_NOT_FORWARDING (2).
--   * Setting ipsi_forwarding = IP_FORWARDING (1) is refused with
--     TDI_INVALID_PARAMETER (kernel aliases this to
--     STATUS_INVALID_PARAMETER per TDISTAT.H:78).
--   * Setting ipsi_forwarding = IP_NOT_FORWARDING (2) is accepted as
--     a no-op (kernel doesn't care, but the path is exercised).
--
-- Tier 2 — counter sentinels around live UDP traffic.  If a future
-- edit ever puts a forwarding stub back that just bumps the counter
-- without doing the work, this catches it:
--   * ipsi_forwdatagrams stays exactly 0 across a UDP loopback
--     round-trip — the function whose only job was to increment it
--     literally doesn't exist anymore.
--   * ipsi_outnoroutes does not grow for local UDP sends — confirms
--     nothing accidentally hits the gone forwarding "no-route" path.
--
-- We don't try to inject crafted packets here.  SOCK_RAW isn't
-- supported on this tree (no \Device\RawIp; AFD has no raw transport
-- mapping; SOCK_RAW / IPPROTO_RAW are cosmetic constants in
-- winsock.h with no kernel backing).  Active fragment / redirect /
-- LSRR probes need either a co-VM attacker or a kernel test harness
-- driver; both deferred.

local t    = require('test')
local info = require('nt.net.info')
local afd  = require('nt.net.afd')

t.suite("ip_hardening")

-- Shared session: one \Device\Tcp open across all tests.  The handle
-- stays alive via this upvalue; tests don't pay the open/close
-- round-trip on each query.
local tcp_h

local function ensure_open()
    if not tcp_h then
        tcp_h = info.open()
    end
    return tcp_h
end

-- ------------------------------------------------------------------
-- Tier 1 — passive MIB checks.
-- ------------------------------------------------------------------

t.test("ipsi_forwarding reads IP_NOT_FORWARDING", function()
    local h = ensure_open()
    local stats = info.ip_stats(h)
    t.eq(tonumber(stats.ipsi_forwarding), info.IP_NOT_FORWARDING,
        "ipsi_forwarding")
    -- Sanity: defaultttl should be a plausible non-zero value
    -- (default 128 on this tree).  Confirms we're actually reading
    -- IPSNMPInfo, not zeroed memory.
    local ttl = tonumber(stats.ipsi_defaultttl)
    t.ok(ttl > 0 and ttl <= 255,
        "defaultttl in (0,255] (got " .. tostring(ttl) .. ")")
end)

t.test("set ipsi_forwarding = IP_FORWARDING is refused", function()
    local h = ensure_open()
    local stats = info.ip_stats(h)
    stats.ipsi_forwarding = info.IP_FORWARDING
    local st = info.set_ip_stats(h, stats)
    t.eq(st, info.TDI_INVALID_PARAMETER,
        "set IP_FORWARDING returns TDI_INVALID_PARAMETER")
    -- And the value MUST still read back as NOT_FORWARDING after the
    -- failed set.  Belt-and-braces against a kernel bug where the
    -- field gets written then the error code returned.
    t.eq(tonumber(info.ip_stats(h).ipsi_forwarding),
         info.IP_NOT_FORWARDING,
        "ipsi_forwarding unchanged after refused set")
end)

t.test("set ipsi_forwarding = IP_NOT_FORWARDING is accepted", function()
    local h = ensure_open()
    local stats = info.ip_stats(h)
    stats.ipsi_forwarding = info.IP_NOT_FORWARDING
    local st = info.set_ip_stats(h, stats)
    t.eq(st, info.STATUS_SUCCESS,
        "set IP_NOT_FORWARDING returns success")
end)

-- ------------------------------------------------------------------
-- Tier 2 — counter sentinels around real traffic.
-- ------------------------------------------------------------------

t.test("ipsi_forwdatagrams stays 0 across UDP loopback", function()
    local h = ensure_open()
    local before = info.ip_stats(h)
    t.eq(tonumber(before.ipsi_forwdatagrams), 0,
        "forwdatagrams already 0 at test start")

    -- One UDP loopback round-trip.  Both sides bind to 127.0.0.1 so
    -- nothing leaves the host; if any of these packets ever touch
    -- the (deleted) forwarding path, forwdatagrams would bump.
    local server = afd.udp()
    afd.bind(server, "127.0.0.1", 0)
    local _, sport = afd.getsockname(server)

    local client = afd.udp()
    afd.bind(client, "127.0.0.1", 0)
    local _, cport = afd.getsockname(client)

    afd.connect(server, "127.0.0.1", cport)
    afd.connect(client, "127.0.0.1", sport)

    afd.send(client, "ping", 1.0)
    t.eq(afd.recv(server, 64, 1.0), "ping", "server got ping")
    afd.send(server, "pong", 1.0)
    t.eq(afd.recv(client, 64, 1.0), "pong", "client got pong")

    server:close()
    client:close()

    local after = info.ip_stats(h)
    t.eq(tonumber(after.ipsi_forwdatagrams), 0,
        "forwdatagrams still 0 after UDP round-trip")

    -- Sanity: indelivers should have grown.  If it didn't, the
    -- "0 forwdatagrams" assertion above is meaningless because no
    -- traffic actually flowed through the IP layer.
    t.ok(tonumber(after.ipsi_indelivers) > tonumber(before.ipsi_indelivers),
        string.format("indelivers grew (%d -> %d)",
                      tonumber(before.ipsi_indelivers),
                      tonumber(after.ipsi_indelivers)))
end)

t.test("ipsi_outnoroutes does not grow for local UDP", function()
    local h = ensure_open()
    local before = info.ip_stats(h)

    -- A burst of local UDP sends.  Loopback never routes, so
    -- outnoroutes must stay flat.  The forwarding path used to
    -- bump it for un-routeable forwarded packets; with the path
    -- gone, only outbound failures (no_route() in IPTransmit) can
    -- move it — and we don't generate any.
    local server = afd.udp()
    afd.bind(server, "127.0.0.1", 0)
    local _, sport = afd.getsockname(server)

    local client = afd.udp()
    afd.bind(client, "127.0.0.1", 0)
    afd.connect(client, "127.0.0.1", sport)

    for _ = 1, 8 do
        afd.send(client, "x", 1.0)
    end

    server:close()
    client:close()

    local after = info.ip_stats(h)
    t.eq(tonumber(after.ipsi_outnoroutes),
         tonumber(before.ipsi_outnoroutes),
         "outnoroutes unchanged")
end)

-- ------------------------------------------------------------------
-- Tier 3 — route-mutator wiring.  Exercises the new add_route /
-- del_route surface against the kernel's IPSetInfo validation path
-- (IP/INFO.C:391-496).  The validation rejects NULL / loopback /
-- classD / classE nexthops before any NTE lookup, so these tests
-- work on a selftest environment that has only a loopback NTE.
--
-- The "real" roundtrip (add a route, observe via routes(h), delete,
-- observe gone) requires a non-loopback NIC and is deferred to the
-- DHCP-plan tests where we have a virtual NIC to drive.
-- ------------------------------------------------------------------

t.test("add_route with NULL nexthop is refused", function()
    local h = ensure_open()
    local st = info.add_route(h, {
        dest     = 0x0A000000,   -- 10.0.0.0
        mask     = 0xFF000000,   -- /8
        nexthop  = 0,            -- NULL_IP_ADDR — kernel rejects
        if_index = 1,
        metric   = 1,
    })
    t.eq(st, info.TDI_INVALID_PARAMETER,
        "NULL nexthop returns TDI_INVALID_PARAMETER")
end)

t.test("add_route with loopback nexthop is refused", function()
    local h = ensure_open()
    local st = info.add_route(h, {
        dest     = 0x0A000000,
        mask     = 0xFF000000,
        nexthop  = 0x7F000001,   -- 127.0.0.1 — IP_LOOPBACK → refused
        if_index = 1,
        metric   = 1,
    })
    t.eq(st, info.TDI_INVALID_PARAMETER,
        "loopback nexthop returns TDI_INVALID_PARAMETER")
end)

t.test("del_route validation path matches add_route", function()
    -- del_route forces ire_type = IRE_TYPE_INVALID but goes through
    -- the SAME validation block (INFO.C:407-440 runs before the
    -- add/delete fork at line 478).  So a bad-nexthop delete is
    -- refused with the same status — confirms del_route's wire
    -- path is actually reaching IPSetInfo and isn't silently
    -- short-circuited somewhere.
    local h = ensure_open()
    local st = info.del_route(h, {
        dest     = 0x0A000000,
        mask     = 0xFF000000,
        nexthop  = 0,
        if_index = 1,
    })
    t.eq(st, info.TDI_INVALID_PARAMETER,
        "del_route with bad nexthop returns TDI_INVALID_PARAMETER")
end)

t.test("routes(h) returns a non-empty table", function()
    -- Sanity check on the walker — proves the test environment has
    -- at least a loopback route, so our route-table observations
    -- aren't reading from an uninitialised stack.
    local h = ensure_open()
    local rs = info.routes(h)
    t.ok(#rs > 0,
        string.format("routes(h) has %d entries", #rs))
end)
