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
