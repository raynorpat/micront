-- MicroNT IP-stack hardening reproducer target.
--
-- A minimal, finding-agnostic network endpoint for the host-side packet
-- harness (src/tools/netharness/).  Boots via the `iprepro` ntosbe
-- profile:  make -C src iprepro NET_HARNESS=<port>
--
-- Unlike selftest.lua this runs NO test suites.  It brings the network
-- up (DHCP, served by the harness) and holds a TCP listener open, then
-- idles.  All per-finding logic lives host-side in the harness's
-- reproducers (repro/h012.py, ...) — this end is just a live stack for
-- them to drive.
--
-- See docs-wip/IPSTACK-HARDENING.md §5.

-- Phase A reorg: every package lives under \SystemRoot\lua\.  Set this
-- before any require() — same prelude as main.lua / selftest.lua.
package.path = "\\SystemRoot\\lua\\?.lua;\\SystemRoot\\lua\\?\\init.lua"
package.cpath = ""

local dhcp = require('nt.net.dhcp')
local afd  = require('nt.net.afd')

-- TCP port the harness reproducers aim at.  Must match the
-- --target-port default in src/tools/netharness/repro/*.
local LISTEN_PORT = 9       -- "discard"; nothing here consumes data
-- Deep backlog on purpose: H-012 wants half-open (SYN_RCVD) TCBs to
-- accumulate against the listener's AddrObj, so the listen backlog
-- must not be the thing that caps them first.
local BACKLOG     = 1024
local HEARTBEAT   = 10      -- seconds between idle heartbeat lines

print("IPREPRO: boot")

-- Boot prelude — publishes \NLS\ sections etc.  Idempotent.
require('nt.boot').run()

-- Bring the interface up.  The harness serves DHCP and may connect a
-- moment after we boot, so retry before giving up.
local lease
for attempt = 1, 12 do
    local ok, res = pcall(dhcp.acquire, { timeout = 5 })
    if ok then
        lease = res
        break
    end
    print(string.format("IPREPRO: dhcp attempt %d/12 failed: %s",
        attempt, tostring(res)))
end
if not lease then
    print("IPREPRO: FATAL — no DHCP lease (is the harness running?)")
    while true do end
end
print(string.format("IPREPRO: dhcp ok ip=%s mask=%s gw=%s",
    lease.address_str, lease.mask_str, lease.gateway_str))

-- Open the listener the reproducers target.
local s = afd.tcp()
afd.bind(s, "0.0.0.0", LISTEN_PORT)
afd.listen(s, BACKLOG)
print(string.format("IPREPRO: listening tcp/%d backlog=%d", LISTEN_PORT, BACKLOG))
print("IPREPRO: ready — harness has the floor")

-- Idle.  accept() with a timeout is the idle primitive: the accept IRP
-- pends in the kernel (the thread genuinely sleeps — no CPU spin), and
-- the timeout gives us a wakeup for the heartbeat.  The reproducers
-- drive half-open / out-of-order / idle scenarios, none of which
-- complete a handshake, so accept() normally just times out; if one
-- ever does complete we close it and carry on.
local beats = 0
while true do
    local ok, conn = pcall(afd.accept, s, HEARTBEAT)
    if ok then
        print("IPREPRO: accepted a connection — closing")
        pcall(function() conn:close() end)
    else
        -- Timeout (STATUS_CANCELLED) is the normal idle path.
        beats = beats + 1
        print(string.format("IPREPRO: heartbeat %d (idle, listening tcp/%d)",
            beats, LISTEN_PORT))
    end
end
