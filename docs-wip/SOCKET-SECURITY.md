# Socket-layer security in MicroNT

A reference for the future security-layer work.  Captures what
the NT 3.5 TCP/IP + AFD code does today (effectively nothing),
why, and the shape of what should go on top.

**Status:** unimplemented.  Everything runs as `SYSTEM` in MicroNT
right now so the lack of gating is academic — the moment we land
non-`SYSTEM` user-mode processes the picture below becomes the
attack surface.

---

## The three layers, and why none of them gate

There are three places in the NT I/O architecture where socket
access could in principle be checked.  All three are wide open in
the NT 3.5 source we ship.

### Layer 1 — IOCTL access bits in `CTL_CODE`

The standard NT `CTL_CODE(device, function, method, access)` macro
threads a required-access field into the IOCTL number.  The I/O
manager compares `IRP_MJ_DEVICE_CONTROL` requests against the file
handle's `GrantedAccess` before dispatching.  A handle opened
`FILE_GENERIC_READ`-only can't issue an IOCTL whose code says
`FILE_WRITE_ACCESS`.

**TCP/IP IOCTLs (`\Device\Ip`, `\Device\Tcp`)** do thread access
through:

```
src/NT/PRIVATE/INC/NTDDIP.H:64
  #define _IP_CTL_CODE(function, method, access) \
              CTL_CODE(FSCTL_IP_BASE, function, method, access)

  IOCTL_ICMP_ECHO_REQUEST     _IP_CTL_CODE(0, METHOD_BUFFERED, FILE_ANY_ACCESS)
  IOCTL_IP_SET_ADDRESS        _IP_CTL_CODE(1, METHOD_BUFFERED, FILE_WRITE_ACCESS)
```

`IOCTL_TCP_SET_INFORMATION_EX` is hand-encoded with
`FILE_WRITE_ACCESS` too; `IOCTL_TCP_QUERY_INFORMATION_EX` is
`FILE_ANY_ACCESS`.  So far so consistent.

**TDI IOCTLs (`NTDDTDI.H`)** punt entirely:

```
src/NT/PUBLIC/SDK/INC/NTDDTDI.H:47
  #define _TDI_CONTROL_CODE(request, method) \
              CTL_CODE(FILE_DEVICE_TRANSPORT, request, method, FILE_ANY_ACCESS)
```

Every TDI IOCTL is `FILE_ANY_ACCESS`.  Connect, send, receive,
set-event-handler, set-information — all of them.

**AFD IOCTLs** are worse — the macro doesn't reach for the access
field at all:

```
src/NT/PRIVATE/INC/AFD.H:202
  #define _AFD_CONTROL_CODE(request, method) \
              ((FSCTL_AFD_BASE)<<12 | (request<<2) | method)
```

Note: there's no fourth argument and the device bits land at
`<<12` rather than `<<16` (`CTL_CODE` uses `<<16`).  The access
field (bits 14-15) is just left as zero, which is `FILE_ANY_ACCESS`.
All 26 AFD operations (`IOCTL_AFD_BIND` … `IOCTL_AFD_POLL` …) end
up requiring nothing.

So at layer 1: TCP/IP-set requires write access on the handle,
everything else requires nothing.

### Layer 2 — device security descriptor

Whether you can *get* a handle with `FILE_WRITE_ACCESS` on
`\Device\Tcp` / `\Device\Ip` / `\Device\Afd` depends on the SD
attached to the device object.  Looking at every `IoCreateDevice`
call in the network stack:

```
src/NT/PRIVATE/NTOS/TDI/TCPIP/IP/NTIP.C:338    \Device\Ip
src/NT/PRIVATE/NTOS/TDI/TCPIP/TCP/NTINIT.C:209  \Device\Tcp
src/NT/PRIVATE/NTOS/TDI/TCPIP/TCP/NTINIT.C:239  \Device\Udp
src/NT/PRIVATE/NTOS/AFD/INIT.C:127             \Device\Afd
```

All four use the form:

```c
IoCreateDevice(
    DriverObject, 0, &deviceName,
    FILE_DEVICE_NETWORK, // or FILE_DEVICE_NAMED_PIPE for AFD
    0,                   // DeviceCharacteristics — no FILE_DEVICE_SECURE_OPEN
    FALSE,               // Exclusive
    &DeviceObject);
```

No security descriptor argument, no follow-up `ZwSetSecurityObject`
call anywhere in the source tree, no `FILE_DEVICE_SECURE_OPEN` in
DeviceCharacteristics.  The AFD init source even flags it as a
TODO at `INIT.C:122`:

```c
// !!! Apply an ACL to the device object.
```

Without `FILE_DEVICE_SECURE_OPEN`, the I/O manager doesn't consult
the device's SD at open time — access falls through to whatever
the Object Manager permits on the namespace path leading to the
device.  The default SD on `\Device\` is world-traverse,
world-open, which means any caller capable of doing `NtCreateFile`
on any device path under `\Device\` can ask for and get the access
they want.

### Layer 3 — in-driver access checks

The drivers themselves could call `SeAccessCheck` (or the access-
state inherited via the IRP) at boundary operations.  Spot-check:

```bash
$ grep -rn 'SeAccessCheck\|SePrivilegeCheck' src/NT/PRIVATE/NTOS/AFD/ \
      src/NT/PRIVATE/NTOS/TDI/TCPIP/
```

No hits.  Neither AFD nor TCP/IP does any explicit access checking
of its own.  The kernel-side validation that *does* exist
(`IPSetInfo`'s nexthop / dest sanity checks, `ARPSetInfo`'s
`physaddrlen` check, `IPSetNTEAddr`'s context-matches-an-NTE
check) is purely correctness — it stops malformed inputs from
crashing the kernel, it doesn't separate "may install a default
route" from "may not."

### The AFD-opens-TDI-as-SYSTEM trick

Even if we fixed layer 2 by tightening the SD on `\Device\Tcp` and
`\Device\Udp`, **AFD's bind path would still get through**.  AFD
opens the underlying TDI transport from a dedicated kernel system
process:

```c
// src/NT/PRIVATE/NTOS/AFD/BIND.C:255
KeAttachProcess( AfdSystemProcess );

status = ZwCreateFile(
             &endpoint->AddressHandle,
             GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE,
             &objectAttributes,
             ...);
```

`KeAttachProcess` swaps the requestor's process context for
`AfdSystemProcess` (an `EPROCESS` AFD created at init time with a
SYSTEM token).  `ZwCreateFile` runs in that context, the I/O
manager sees a kernel-mode SYSTEM caller, and the open succeeds
regardless of the SD on `\Device\Tcp`.  The caller's identity is
structurally absent from the underlying transport open.

This means tightening the TDI device SD is *meaningless* if AFD
itself is reachable — AFD will pass anyone through.  The only
effective gate on socket use is at `\Device\Afd`, and that's
currently ungated.

---

## What "anyone with `\Device\Afd` access" can do today

The attack model: a non-SYSTEM process that successfully opens
`\Device\Afd` (which under the default SD is any process at all).
It can then:

- **Pick any transport** — TCP or UDP — by name string in the EA
  buffer at create time.  No filtering on which transport types
  are "allowed" for which callers.
- **Bind to any local port**, including the BSD-privileged range
  (0–1023).  NT has never enforced the BSD ≤1023-is-root model.
  An unprivileged process can bind 53 / 67 / 80 / 443 and serve
  whatever it wants from those ports.
- **Bind to any local IP**, including ones the calling process
  doesn't "own" in any meaningful sense.  Wildcard `0.0.0.0` is
  trivial.
- **Connect outbound to any IP:port.**  No outbound firewall.  No
  per-process destination filter.
- **Send UDP broadcast** without `SO_BROADCAST` — AFD just hands
  the destination address to TDI which sends it.  (Our DHCP code
  relies on this.)
- **Listen + accept** on any bound TCP port.
- **Influence routing through the TCP/IP IOCTLs** — open
  `\Device\Tcp` directly (not via AFD), get `FILE_WRITE_ACCESS`,
  and call `IOCTL_TCP_SET_INFORMATION_EX` with
  `IP_MIB_RTTABLE_ENTRY_ID` to install or delete routes; or
  `AT_MIB_ADDRXLAT_ENTRY_ID` to poison the ARP cache; or open
  `\Device\Ip` and use `IOCTL_IP_SET_ADDRESS` to overwrite an
  NTE's IP.  Our `nt.net.info` module does exactly this from
  Lua.

What's *not* reachable, by accident of architecture rather than
by gate:

- **Raw sockets / SOCK_RAW.**  AFD doesn't expose them, the IP
  driver has no `\Device\RawIp`, and the only raw-IP egress is
  `IOCTL_ICMP_ECHO_REQUEST` (FILE_ANY_ACCESS — anyone can ping).
  Custom protocol numbers, IP header injection, etc. are not
  reachable from user mode at all.
- **Promiscuous-mode capture.**  Requires NDIS packet filter
  changes which only the IP / ARP layer can issue.

---

## Design goals (from the project owner)

The forward plan: bring up non-SYSTEM user-mode processes as part
of a real startup sequence, with Object-Manager-namespace ACLs
applied during startup.  Specifically for sockets, the granularity
we want to support:

1. **All-or-nothing socket access per process** — a process that
   shouldn't network at all (a renderer, a sandboxed parser,
   anything CPU-only) gets denied `\Device\Afd` open and that's
   the end of the story.
2. **Bind/listen vs outbound as separate permissions** — a
   process that should be able to make outbound connections (a
   web client) shouldn't necessarily be able to listen for
   inbound, and vice versa.
3. **Optionally: port range gating** — restore the BSD-style
   privileged-port convention so unprivileged callers can't bind
   53 / 80 / 443 / etc. directly.  (Less critical than 1+2 — the
   admin can simply not run an unprivileged process that wants
   port 80 if the policy says only privileged services bind low
   ports.)
4. **TCP/IP routing/ARP/address IOCTLs become SYSTEM-only** — a
   non-privileged process should never be able to install a route
   or poison ARP.  Today these are reachable by anyone.

A nice-to-have eventually, but explicitly out of v1: outbound
destination filtering (a la firewall rules).  Process-level "you
can talk to 10.0.0.0/8 but not the internet" requires a packet
inspection point that NT 3.5 doesn't have a natural place for —
it's a separate component from the access-check layer and a
bigger project.

---

## Implementation sketch

Three pieces, in dependency order.

### A. Make AFD IOCTLs encode their required access

Fix the macro:

```c
// src/NT/PRIVATE/INC/AFD.H
#define _AFD_CONTROL_CODE(request, method, access) \
            CTL_CODE(FSCTL_AFD_BASE, request, method, access)
```

Note: this also moves the device bits from `<<12` to `<<16` (the
real `CTL_CODE`), which changes every existing IOCTL number.  AFD
clients are in-tree only (winsock, our nt.net.afd) so we can
re-table cleanly.

Then classify each IOCTL.  A reasonable split:

| Operation             | Access required                              |
|-----------------------|----------------------------------------------|
| `BIND`, `START_LISTEN`, `WAIT_FOR_LISTEN`, `ACCEPT` | `FILE_WRITE_ACCESS` (inbound capability) |
| (TDI) `CONNECT`, `SEND`, `SEND_DATAGRAM` | `FILE_WRITE_ACCESS` (outbound capability) |
| `POLL`, `GET_ADDRESS`, `QUERY_RECEIVE_INFO`, all `GET_*` | `FILE_READ_ACCESS` |
| `SET_INFORMATION`, all `SET_*` | `FILE_WRITE_ACCESS` |

This alone doesn't separate bind/listen from connect/send — both
demand `FILE_WRITE_ACCESS` on the file handle.  But it sets up
the next piece.

### B. Synthesize two AFD access masks at open time

Introduce dedicated access bits in the AFD-specific mask range
(bits 0-15 of the access mask are device-specific per the NT
spec):

```c
#define AFD_ACCESS_BIND_LISTEN  0x00000001
#define AFD_ACCESS_CONNECT_SEND 0x00000002
```

`AfdCreate` (the `IRP_MJ_CREATE` dispatch) extracts the requested
mask from the `IO_STACK_LOCATION` and checks per-op:

- `IOCTL_AFD_BIND`, `_START_LISTEN`, `_WAIT_FOR_LISTEN`, `_ACCEPT`
  require `AFD_ACCESS_BIND_LISTEN` in `FileObject->GrantedAccess`.
- `IOCTL_TDI_CONNECT`, `IOCTL_TDI_SEND_DATAGRAM`, `IRP_MJ_WRITE`
  on a connected socket require `AFD_ACCESS_CONNECT_SEND`.

The Lua-side socket helpers ask for whichever subset they need.
A pure-outbound HTTP client opens with only `AFD_ACCESS_CONNECT_
SEND` and is then mechanically incapable of binding-then-listening
even if its code is compromised.

### C. Apply real SDs at boot

During whatever new init code runs the user-mode startup (smss
analog, or our own bootstrap), set explicit security descriptors
on `\Device\Afd`, `\Device\Tcp`, `\Device\Ip`, `\Device\Udp` via
`ZwSetSecurityObject`.  Sketch SD:

```
\Device\Afd:
    SYSTEM, network-config-group:   GENERIC_ALL
    network-client-group:           AFD_ACCESS_CONNECT_SEND | READ
    network-server-group:           AFD_ACCESS_BIND_LISTEN  | READ
    everyone:                       (nothing)

\Device\Tcp, \Device\Udp, \Device\Ip:
    SYSTEM, network-config-group:   GENERIC_ALL
    everyone:                       FILE_READ_ACCESS   ; MIB queries OK
```

The set-IOCTLs on the TCP/IP devices remain `FILE_WRITE_ACCESS`-
required at the IOCTL layer (already true), so combined with the
SD that only grants write access to the privileged group, route
mutation, ARP mutation, and address assignment become
SYSTEM/admin-only.  Our DHCP client either keeps running in the
privileged context (preferred — it's a system service) or gets a
dedicated network-config service token at startup.

Note: this does **not** require touching the AFD-opens-TDI-as-
SYSTEM path.  AFD bypassing the TDI device SD is fine because:

1. Sockets you can already create via AFD don't need a second SD
   check at the TDI layer — AFD has already gated them.
2. The TDI-direct path (used by our `nt.net.info` for MIB ops and
   route/ARP/address mutation) is the actual surface we're
   protecting, and it goes through the normal open path which
   *does* honour the TDI device SD.

If at some point we want to remove the AFD-as-SYSTEM trick
entirely (because it's an architectural wart), that's a separate
much-larger refactor — AFD would have to pass the caller's
access state through to the TDI provider, which means changing
the TDI binding interface.

---

## Open questions for the design pass

- **Where does the "network-client-group" / "network-server-group"
  membership come from?**  We don't have a real SAM/LSA.  Probably
  baked into the process token at process creation time based on a
  manifest or registry policy, similar to how process integrity
  levels work on later Windows.
- **What's the unit of "process" in MicroNT today?**  Lua scripts
  share a process.  Will scripts within a single process need
  finer-grained gating, or is it acceptable that a Lua-based
  process is one trust unit?
- **Does the all-or-nothing case (#1) need to be a SD denial of
  AFD open, or a separate "no network" token attribute?**  SD
  denial is simpler; token attribute composes better if we ever
  want per-thread or per-impersonation policy.
- **Privileged ports (#3) — worth doing in v1, or defer?**  It's
  a single check in `AfdBind` (or `TdiOpenAddress` if we want it
  to cover the direct-TDI path too) but it adds a privilege
  concept we don't have yet.  Lean: defer until we have a real
  SCM-style privileged-service runtime.

---

## References

- `src/NT/PRIVATE/INC/AFD.H` — AFD IOCTL definitions, with the
  malformed `_AFD_CONTROL_CODE` macro.
- `src/NT/PRIVATE/NTOS/AFD/INIT.C:122` — the `// !!! Apply an ACL`
  TODO from the original Microsoft authors.
- `src/NT/PRIVATE/NTOS/AFD/BIND.C:255` — `KeAttachProcess(
  AfdSystemProcess)`, the SYSTEM-context TDI open.
- `src/NT/PRIVATE/NTOS/TDI/TCPIP/IP/NTIP.C:338` /
  `src/NT/PRIVATE/NTOS/TDI/TCPIP/TCP/NTINIT.C:209,239` — bare
  `IoCreateDevice` for the three TDI devices.
- `src/pkg/nt/net/info.lua` — current Lua user-mode TCP/IP
  config surface (set_address, add_route, etc.) that this work
  would gate behind the network-config group.
- `src/pkg/nt/net/afd.lua` — the AFD wrapper that would gain
  separate bind/listen vs connect/send access requests.
