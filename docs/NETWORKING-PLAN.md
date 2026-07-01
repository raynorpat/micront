# Plan: Import and build the networking stack

Goal: bring up real networking on MicroNT — **Winsock, TCP/IP utilities, SMB
(file sharing), and the UI for those services** — on top of the transport
stack that already builds.

Net source lives in **`SOURCE1A.782_disc1/PRIVATE/NET`** plus the kernel
network drivers under `SOURCE1A.../PRIVATE/NTOS` (`NBT`, `RDR`, `SRV`).

## What already works

`build.sh` already builds the entire kernel transport stack as drivers
(`DRIVER_TARGETS`):

- `ndis_wrapper` (`ndis.sys`) + `vionet` (virtio NIC miniport)
- `tdi_wrapper` (`tdi.sys`) — Transport Driver Interface
- `tdi_tcpip_ip` (`ip.lib`) + `tdi_tcpip_tcp` (`tcpip.sys`) — IP/TCP/UDP
- `afd` (`afd.sys`) — socket emulation layer above TDI

And `mkhive.py` configures the adapter with a static IP (10.0.2.15) for
QEMU's user NAT. **So packets already flow at the kernel level** — what's
missing is the user-mode API (Winsock), the SMB drivers/services, and the UI.

## Prerequisite: the Service Control Manager

The net **services** (workstation/server/browser) are started by
`services.exe` (the SCM host). Today we build the SCM *client* (`sclib`,
`svcctrl`) and the advapi32 SCM client, but **not the SCM server**. Drivers
(`rdr`/`srv`/`netbt`) and DLLs (`wsock32`) load without it, but the service
DLLs in Tier 3+ need it. Confirm/stand up `services.exe` (NT 3.5 SCM lives
in `WINDOWS/SCREG/SC` / `NET/SVCCTRL`) before Tier 3, or run the redirector
in driver-only mode initially.

## Tier 1 — Winsock + TCP/IP utilities (highest value, lowest risk)

User-mode sockets on the existing `afd.sys`. This validates the whole
transport stack from user mode and is self-contained.

| Component | Source dir | Output |
|-----------|-----------|--------|
| Winsock | `NET/SOCKETS/WINSOCK` | `wsock32.dll` |
| Winsock registry | `NET/SOCKETS/SOCKREG` | helper/registration |
| WSH helpers | `NET/SOCKETS/WSHNBF`, `WSHNETBS` | `wshnbf.dll`, etc. (transport-specific Winsock helpers) |
| TCP utilities | `NET/SOCKETS/TCPCMD` | `ping.exe`, `arp.exe`, `route.exe`, `ipconfig`/`ftp`/`telnet` etc. |

Wire `wsock32` into `USERLAND_TARGETS`; stage `wsock32.dll` + chosen
utilities. **Verify:** `ping 10.0.2.2` (QEMU gateway) from cmd.exe.

## Tier 2 — NetBIOS over TCP (SMB prerequisite)

| Component | Source dir | Output |
|-----------|-----------|--------|
| NetBT | `NTOS/NBT` | `netbt.sys` (NetBIOS datagram/session over TCP) |
| NetBIOS | `NET/NETBIOS` | `netbios.dll` + NetBIOS interface |

`netbt.sys` is a driver (→ `DRIVER_TARGETS`). Add its service entry +
bindings (NetBT over tcpip) to `mkhive.py`. SMB rides on this.

## Tier 3 — SMB file sharing

Client first (mount remote shares), then optionally the server.

**Client (redirector):**

| Component | Source dir | Output |
|-----------|-----------|--------|
| Redirector | `NTOS/RDR` | `rdr.sys` (SMB client / network FS) |
| Net API | `NET/API` | `netapi32.dll` |
| Net lib | `NET/NETLIB` | `netlib.lib` |
| Workstation svc | `NET/SVCDLLS/WKSSVC` | `wkssvc.dll` (drives the redirector) |
| net command | `NET/NETCMD` | `net.exe` (`net use`, `net view`) |

**Server (optional, to serve shares):**

| Component | Source dir | Output |
|-----------|-----------|--------|
| Server | `NTOS/SRV` | `srv.sys` (SMB server) |
| Server svc | `NET/SVCDLLS/SRVSVC` | `srvsvc.dll` |
| Browser | `NET/SVCDLLS/BROWSER` | `browser.dll` |

`rdr.sys`/`srv.sys`/`netbt.sys` → `DRIVER_TARGETS`; `netapi32`/`wkssvc`/
`srvsvc`/`net.exe` → `USERLAND_TARGETS`. Add service entries + start order +
bindings (LanmanWorkstation→rdr, LanmanServer→srv) to `mkhive.py`.
**Verify:** `net use Z: \\host\share` against a host SMB server.

## Tier 4 — Network UI

| Component | Source dir | Output | Notes |
|-----------|-----------|--------|-------|
| Network applet | `NET/UI/NCPA` | `ncpa.cpl` | the Control Panel "Network" applet — ties into `SHELL-APPS-PLAN.md` Tier 3 (`control.exe`) |
| Net UI libs | `NET/UI/NETUI`, `NET/UI/COMMON` | shared net dialogs | |
| Net shell UI | `NET/UI/SHELLUI`, `NET/UI/SHELL` | browse/connect dialogs | |

`NET/UI` is large (MFC-based admin tools under `RHINO`, `ADMIN`, `FTPMGR` —
skip those). Scope Tier 4 to `ncpa.cpl` + the minimal NETUI dialogs needed by
File Manager's "Connect Network Drive" and the Control Panel applet. Stage
`ncpa.cpl` into `System32` (auto-discovered by `control.exe`).

## Build-system wiring summary

- **Drivers** (`DRIVER_TARGETS`): `netbt`, `rdr`, `srv` — alongside the
  existing `tdi_*`/`afd`/`vionet`.
- **Userland** (`USERLAND_TARGETS`): `wsock32`, `netapi32`, `wkssvc`,
  `srvsvc`, `browser`, `net` (and TCP utilities).
- **`mkhive.py`**: service entries + `Linkage\Bind` chains for NetBT→tcpip,
  LanmanWorkstation→rdr, LanmanServer→srv; start-order groups (NDIS → TDI →
  PrimaryDisk... → NetBIOSGroup).
- **`mkdisk.py`**: stage the new `.sys`, `.dll`, `.exe`, and `ncpa.cpl`
  (gate behind the `gui`/`headless` profile as appropriate — Winsock +
  utilities are useful headless; `ncpa.cpl` is gui-only).

## Suggested order

1. Tier 1 — Winsock + `ping`. Proves user-mode networking end to end.
2. Tier 2 — NetBT.
3. SCM (`services.exe`) prerequisite, then Tier 3 client (`net use`).
4. Tier 3 server (optional).
5. Tier 4 — `ncpa.cpl` + minimal net UI.

See `DHCP-PLAN.md` to replace the static IP once Winsock (Tier 1) is up.

---

# Implementation status

**Tiers 1–3 are built and committed. Tier 4 was assessed and skipped.**

Everything below builds under the normal `./build.sh` flow, stages into the
disk image, and is registered in the hive. The whole user-mode service stack
(`services.exe` + wkssvc/srvsvc/browser) is registered **demand-start**, so it
is present but dormant — activating + boot-testing it is a separate step. None
of the runtime paths (`ping`, `net use`, `net view`) have been booted yet.

## Tier 1 — Winsock + TCP/IP utilities ✅

- `wsock32.dll` — imported `NET/SOCKETS/{WINSOCK,SOCKREG,SOCKUTIL,LIBUEMUL}`.
  Needed `$(BASEDIR)\private\inc` on the include path (BSD-style `sys/`,
  `sockets/` headers) and `PRIVATE/INC/{SOCKETS,SYS}` imported.
- **`wshtcpip.dll` — written from scratch.** The TCP/IP Winsock helper shipped
  only as a prebuilt `.lib` in the leak. NT4's is Winsock 2 (drags in
  `winsock2.h`/`ws2tcpip.h`), so this is a minimal 3.5-native reimplementation
  on the `WSHNETBS.C` skeleton (8-function `wsahelp.h` interface), TCP+UDP.
- **`icmp.dll` — written from scratch.** `IcmpCreateFile`/`IcmpSendEcho` over
  the IP driver's existing `IOCTL_ICMP_ECHO_REQUEST` on `\Device\Ip`.
- **`ping` / `tracert` — written** (minimal, use icmp.dll). **`arp` / `route`**
  imported from `NTOS/TDI/TCPIP/UTILS`.
- Registry: `Winsock\Parameters:Transports` + `Tcpip\Parameters\Winsock`
  (Mapping blob + `HelperDllName`).

## Tier 2 — NetBIOS over TCP/IP ✅

- `netbt.sys` (from `NTOS/NBT`) + `netbios.sys` (from `NTOS/NETBIOS`, the
  `\Device\Netbios` NCB interface — the plan's `NET/NETBIOS` is a static lib
  redundant with the prebuilt netapi32).
- **Key gotcha:** NT 3.5 netbt defaults to the old STREAMS stack
  (`\Device\Streams\Tcp`); our tcpip exposes `\Device\Tcp`/`\Device\Udp`, so
  `NetBT\Parameters\TransportBindName = "\Device\"` retargets it. It reads the
  adapter IP by groveling `Services\Vionet1\Parameters\Tcpip`.

## Tier 3 — SMB client + server ✅

- **Client:** `rdr.sys` (+ smbtrsup/bowser libs), the SCM server
  `services.exe` (from `SCREG/SC/SERVER`, which winlogon execs), `wkssvc.dll`,
  and `net.exe`.
- **`net.exe` unblock:** the netcmd/netlib tree pulls the DosPrint headers
  (`dosprint.h`/`rxprint.h`/`xsdef16.h`) via `port1632.h`; these are absent
  from both the NT 3.5 and NT4 leaks and were **recovered from the OpenNT
  tree** into `PRIVATE/INC`.
- **Server:** `srv.sys` + `srvsvc.dll`, and the Computer Browser `browser.dll`
  + its downlevel transaction server `xactsrv.dll` (with the RPCXLATE stack:
  dosprint/rxcommon/rxapi/netrap).
- **Circular DLL break:** `xactsrv` ↔ `browser` each link the other's import
  lib. Broken the samsrv↔lsasrv way — compile both, synthesize each import lib
  from its `.def`, then link. The browser server's `.mdl→.c` precomp rule
  shells out to cmd's `type` builtin (a no-op under wibo), so `bowser_s.c` is
  pre-wrapped in `build_browser_idl`.
- **MIDL `-oldnames`:** svcctl/wkssvc/srvsvc/bowser server stubs need it to
  emit `<iface>_ServerIfHandle` (vs `<iface>_v1_0_s_ifspec`).
- Registry: `Rdr`/`Srv` drivers + `LanmanWorkstation`/`LanmanServer`/`Browser`
  services (ServiceDll + Linkage to netbt), all demand-start.

## Tier 4 — Network UI ❌ skipped

`ncpa.cpl` itself uses the standard build, but it links **`netui0/1/2`** — the
BLT dialog framework, **~174,000 lines of C++** under `NET/UI/COMMON/SRC` built
with a **custom `RULES.MK` system for the `cfront` compiler** (not in our
toolchain, doesn't map to the SOURCES/cl386 build). Reconstructing enough of
that framework from the headers to make the original applet link and behave is
effectively writing a mini-MFC — too large and too speculative to be worth it,
since networking is fully functional via the registry without a GUI applet.
If revisited, the tractable path is a **fresh minimal Win32 `ncpa.cpl`** (no
BLT) that edits the adapter's IP config via the registry.
