# Plan: Replace the hardcoded static IP with DHCP

Goal: stop hardcoding the guest's IP in the registry and instead lease it from
QEMU's built-in DHCP server (QEMU user-mode NAT runs a DHCP server at
`10.0.2.2` that hands out `10.0.2.15`+).

**Depends on** `NETWORKING-PLAN.md` Tier 1 (Winsock/afd): the DHCP client
service uses sockets to do its DISCOVER/OFFER/REQUEST/ACK exchange.

## What's hardcoded today

`mkhive.py` (≈ lines 764–768) writes static config into the adapter:

```python
services["Vionet1"]["Parameters"]["Tcpip"] \
    .set_dword("EnableDHCP",     0) \
    .set_multi_sz("IPAddress",      ["10.0.2.15"]) \
    .set_multi_sz("SubnetMask",     ["255.255.255.0"]) \
    .set_multi_sz("DefaultGateway", ["10.0.2.2"])
```

`tcpip.sys` reads this per-adapter block at init and configures the interface
statically. To switch to DHCP we flip `EnableDHCP` and add a client service.

## DHCP client source

Headers are present: `PRIVATE/INC/DHCPAPI.H`, `DHCPCAPI.H`. The client
service implementation candidate is **`NET/SOCKETS/TCPCMD/DHCP`** (confirm
this is the client service `dhcp`/`dhcpcsvc` and not just a CLI helper —
verify its `SOURCES` `TARGETNAME`/`TARGETTYPE` before wiring). The
`NET/UI/RHINO/DHCP` tree is the **DHCP Manager admin UI for the DHCP
*server*** — not needed for a client.

How the NT 3.5 DHCP client works: with `EnableDHCP=1`, `tcpip.sys` brings the
interface up in DHCP-pending state; the user-mode DHCP service performs the
lease handshake over UDP (client :68 → server :67) and writes the granted
address/mask/gateway/lease back into `tcpip` via private DHCP IOCTLs, which
also land under `...\Parameters\Tcpip` as `DhcpIPAddress`, `DhcpSubnetMask`,
`DhcpDefaultGateway`, `DhcpServer`, `LeaseObtainedTime`, etc.

## Steps

1. **Build the DHCP client service** (`NET/SOCKETS/TCPCMD/DHCP`): copy into
   the tree, add `build_dhcp()`, wire into `USERLAND_TARGETS` after `wsock32`.
   Stage `dhcp.dll`/`dhcpcsvc.dll` (whatever it produces) into `System32`.
2. **Register the service** in `mkhive.py`: add a `DHCP` service entry
   (`Type` = service DLL hosted by `services.exe`, autostart, depends on
   `Tcpip`/`Afd`). This needs the SCM (`services.exe`) prerequisite noted in
   the networking plan.
3. **Flip the adapter config** in `mkhive.py`:
   ```python
   services["Vionet1"]["Parameters"]["Tcpip"] \
       .set_dword("EnableDHCP", 1)
   # drop the static IPAddress / SubnetMask / DefaultGateway multi-sz values
   # (leave them as "0.0.0.0" or omit; the DHCP client fills DhcpIPAddress etc.)
   ```
4. **Verify**: boot the `gui`/`headless` disk; `ipconfig` shows a DHCP-leased
   `10.0.2.15` with server `10.0.2.2`; `ping 10.0.2.2` succeeds. Check
   `...\Parameters\Tcpip\DhcpIPAddress` is populated in the live hive.

## Risks / things to confirm

- **Exact client service module.** Confirm `TCPCMD/DHCP` is the lease client
  (not just a status tool). If the real client service isn't in this drop, the
  fallback is a tiny purpose-built DHCP client that does the 4-packet exchange
  over Winsock and writes the IOCTLs — small, but a port either way.
- **SCM dependency.** Auto-starting `DHCP` needs `services.exe`. Until that's
  up, the client can be launched manually for testing.
- **QEMU DHCP quirks.** QEMU's server is minimal (fixed lease, no renew
  niceties); make sure the client accepts a single OFFER and doesn't require
  options QEMU won't send.
- **Keep a static escape hatch.** Make DHCP-vs-static a `mkhive.py` toggle
  (e.g. a `--dhcp` flag or profile var) so we can fall back to the known-good
  static config if the lease path regresses.

## Suggested order

1. Land networking Tier 1 (Winsock) first.
2. Build + manually run the DHCP client against the static-IP hive to prove
   the handshake.
3. Add the `DHCP` service entry + flip `EnableDHCP=1`; verify autostart lease.
4. Make static/DHCP a build-time toggle.
