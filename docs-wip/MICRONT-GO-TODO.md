# MicroNT — Go (windows/386) missing Win32 surface

Goal: run stock `GOOS=windows GOARCH=386` Go binaries on MicroNT. Surface measured
from three real apps in `stuff/gostuff/`:
- **caddy** `caddy_windows_386.exe` (web server, ~Go 1.17)
- **frp** `frpc.exe` / `frps.exe` 0.22.0 (reverse-proxy client+server, ~Go 1.11)
- **soft-serve** `soft.exe` 0.4.6 (git server + bubbletea TUI, ~Go 1.20)

Two surfaces matter for Go and they differ:
- **Static import table** (`pefile` / `i686-w64-mingw32-objdump -p`): the tiny
  bootstrap set the Go runtime links directly.
- **Dynamically-resolved** procs: Go's runtime + `net` + `crypto/x509` + `os/user`
  `LoadLibraryW`+`GetProcAddress` the bulk of their Win32 surface at startup. These
  do **not** show in the import table — they live as proc-name strings in `.rdata`
  (recovered by substring probe; CamelCase names are reliable, the short BSD
  lowercase names sit in the ws2_32 proc table next to `WSACleanup`/`WSAIoctl`).

This enumerates **only what MicroNT is missing today** (measured against current
`.def` exports — kernel32 608, ws2_32 36, advapi32 54).

Design bias (shared with `MICRONT-RUST-TODO.md`): prefer the lean, Unixy surface
modern Go/Rust/Nim/Zig actually use. Go is Unixy by nature but, unlike Rust,
**hard-requires sockets to even reach `main`** — `net` init runs at package-init
and `runtime` brings up the IOCP netpoller eagerly. There is effectively no
console-only Go milestone for these apps; networking is the gate, not a follow-on.

## Already covered — no work
- **kernel32.dll** — 41 of 49 Go-used symbols already exported.
- **advapi32.dll** — Go's RNG path is fully present: `CryptAcquireContextW`,
  `CryptGenRandom`, `CryptReleaseContext` (caddy/frp legacy path) **and**
  `SystemFunction036` (= `RtlGenRandom`, soft-serve's newer-Go path). All route to
  the kernel CSPRNG. See `project_rng_subsystem`.
- **ws2_32.dll** — the BSD core (22 of 32 Go-used) is present: `socket`, `bind`,
  `connect`, `listen`, `accept`, `shutdown`, `send`/`recv`/`recvfrom`/`sendto`,
  `get/setsockopt`, `getsockname`/`getpeername`, `select`, `__WSAFDIsSet`,
  `gethostbyname`, `getservbyname`, `getprotobyname`, `WSAStartup`/`WSACleanup`,
  `WSAGet/SetLastError`.

## DLLs MicroNT must add (or extend)
| DLL | status | why Go needs it |
|-----|--------|-----------------|
| `ws2_32.dll` | **extend** (+10) | overlapped WSA* core — the real gate, see below |
| `mswsock.dll` | **new** | `AcceptEx`/`ConnectEx` — Go has *no* sync-accept fallback on Windows |
| `iphlpapi.dll` | **new** | `net` interface enumeration at startup (`GetAdaptersAddresses`) |
| `dnsapi.dll` | **new** | `DnsQuery_W` resolver path |
| `crypt32.dll` | **new** | system root cert store for outbound TLS verify |
| `netapi32.dll` | **new** | `os/user` (`NetUserGetInfo`, domain-join probe) |
| `userenv.dll` | **new** | `GetUserProfileDirectoryW` (home dir) — shared with Rust TODO |
| `winmm.dll` | **new** | `timeBeginPeriod`/`timeEndPeriod` (frp + soft-serve) |
| `secur32.dll` | **new** | SSPI / `GetUserNameExW` (opportunistic) |
| `psapi.dll` | **new** | process memory queries (frp + soft-serve, opportunistic) |
| kernel32.dll | **extend** (+8) | see list below |

Packaging/redirection is identical to the Rust TODO: in-tree under
`NT/PRIVATE/WINDOWS/BASE/`, path-derived build targets, PE export forwarding for
aliases, literal forwarder DLLs for any apiset names. Build **on demand** as an app
actually imports each one — don't front-load the long tail.

---

## ws2_32.dll — +10 (THE gate)
MicroNT's ws2_32 today is the verbatim wsock32 BSD core (see
`project_net_protocol_scope`). Go drives sockets through the **overlapped WSA\***
family bound to an IOCP — none of which exist yet:
```
WSASocketW           ; all sockets created WSA_FLAG_OVERLAPPED, bound to IOCP
WSARecv  WSASend     ; hot-path I/O (NOT recv/send)
WSARecvFrom  WSASendTo
WSAIoctl             ; SIO_GET_EXTENSION_FUNCTION_POINTER -> AcceptEx/ConnectEx ptrs
WSAGetOverlappedResult
WSAEnumProtocolsW    ; net init enumerates the TCP/IP catalog entry
GetAddrInfoW  FreeAddrInfoW   ; modern resolver (Go prefers over gethostbyname)
```
This is the crux: Go is essentially a conformance test for the overlapped-AFD +
IOCP paths already being hardened (`project_iocp_test_suite`, `project_afd_cancel_invariant`,
the P9 `NtRemoveIoCompletion` fix). The BSD calls Go imports are mostly setup; the
data path is `WSARecv`/`WSASend` + `GetQueuedCompletionStatus(Ex)`.

**Deferred / gated on `MODERN-IPSTACK.md`.** Whether this is the cheap flat-ws2_32
route over the existing 3.50 AFD or the srv03 downport is the open call there.

## mswsock.dll — new DLL (mandatory for Go)
```
AcceptEx
ConnectEx
GetAcceptExSockaddrs
TransmitFile
```
Retrieved via `WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER)`, so the ioctl plumbing
in ws2_32/AFD must return real function pointers. No synchronous fallback exists in
the Go runtime — listeners and dialers both go through these.

## iphlpapi.dll — new DLL
```
GetAdaptersAddresses   ; called at net init; hard-failure can panic before main
GetAdaptersInfo
GetIfEntry
GetBestInterfaceEx     ; soft-serve (newer Go)
```
Needs a real (if minimal-but-honest) implementation, not a stub — `net` walks the
adapter list during package init. Aligns with `project_deployment_scope` (single NIC).

## dnsapi.dll — new DLL
```
DnsQuery_W
DnsRecordListFree
```
Go's resolver tries `DnsQuery_W` before falling back. A correct-but-thin shim over
the existing resolver path may satisfy it.

## crypt32.dll — new DLL
```
CertOpenStore  CertOpenSystemStoreW  CertCloseStore
CertEnumCertificatesInStore  CertFindCertificateInStore
CertGetCertificateChain  CertVerifyCertificateChainPolicy
CertFreeCertificateContext
CryptProtectData  CryptUnprotectData   ; soft-serve
```
Only needed for outbound TLS **verification**. A server-only deployment (frps) can
tolerate empty stores; caddy-as-client and soft-serve's git-over-https need a real
or bundled-CA store. Lowest priority of the net DLLs.

## netapi32.dll — new DLL
```
NetUserGetInfo
NetGetJoinInformation
NetApiBufferFree
```
`os/user.Current()`. Thin stubs returning a single local user are plausible given
the security model (`project_security_model_direction`) — but implement honestly,
don't blind-stub.

## userenv.dll — new DLL (shared with Rust TODO)
```
GetUserProfileDirectoryW
```

## winmm.dll — new DLL
```
timeBeginPeriod
timeEndPeriod
```
Go runtime bumps timer resolution. No-op-honest is acceptable (we have no <1ms
timer to tune), but the exports must resolve.

## secur32.dll / psapi.dll — new DLLs (opportunistic, low priority)
`secur32!GetUserNameExW`, `psapi` process-memory queries. soft-serve also pulls a
long x/sys/windows tail (`wtsapi32`, `setupapi`, `cfgmgr32`, `dwmapi`, `powrprof`,
`wintrust`, `sechost`, `ole32`, `version`) — almost all opportunistic lazy-DLL
loads that tolerate `LoadLibrary` failure. **Do not build these** until something
actually faults on a missing one.

## kernel32.dll — +8 (41 of 49 already exported)
```
AddVectoredExceptionHandler   ; Go runtime panic/signal machinery (also in Rust TODO)
SwitchToThread                ; scheduler yield (also in Rust TODO)
SetWaitableTimer              ; (also in Rust TODO)
CreateWaitableTimerA          ; caddy
CreateWaitableTimerExW        ; soft-serve (also in Rust TODO)
GetQueuedCompletionStatusEx   ; soft-serve (newer-Go batched IOCP dequeue)
PostQueuedCompletionStatus    ; soft-serve
SetProcessPriorityBoost
```
Overlaps the Rust TODO's kernel32 +27 (`AddVectoredExceptionHandler`, `SwitchToThread`,
`SetWaitableTimer`, `CreateWaitableTimerExW` are common to both) — do once, both
benefit. `GetQueuedCompletionStatusEx`/`PostQueuedCompletionStatus` are part of the
same IOCP work as the ws2_32 overlapped core.

## Per-app notes
- **frpc/frps** (oldest Go): leanest. `GetQueuedCompletionStatus` (not `...Ex`),
  `winmm` timers, no advapi32/crypt deps at all in the static table.
- **caddy**: uses the legacy CryptoAPI RNG (`advapi32!CryptGenRandom`, done) and
  `ntdll!NtWaitForSingleObject`. Client TLS → needs `crypt32` cert store.
- **soft-serve** (newest Go): widest surface — `...Ex` IOCP variants,
  `SystemFunction036` RNG, `Nt*` natives, `user32` (TUI terminal sizing), and the
  long opportunistic x/sys/windows tail. Treat as the "everything" target; tick the
  others off first.

## Milestones
- **frp (TCP)** — leanest realistic first Go target. Gated on: ws2_32 +10,
  `mswsock`, `iphlpapi`, `dnsapi`, `winmm`, kernel32 +8 (the IOCP four). NOT gated
  on crypt32/advapi32. → all of it sits behind `MODERN-IPSTACK.md`.
- **caddy / soft-serve** — add `crypt32` (client TLS), `netapi32`/`userenv`
  (`os/user`), and for soft-serve `user32` + the x/sys tail as it faults.

## Cross-refs
- `MICRONT-DLL-TODO.md` — authoritative DLL registry + acceptance-sample map (this delta feeds it)
- `MODERN-IPSTACK.md` — the networking gate (AFD/TDI/ws2_32 overlapped, srv03 downport)
- `MICRONT-RUST-TODO.md` — shared kernel32 +N and `userenv`; Rust has a console-only
  path, Go does not
- memory: `project_net_protocol_scope`, `project_iocp_test_suite`,
  `project_afd_cancel_invariant`, `project_rng_subsystem`, `project_deployment_scope`
