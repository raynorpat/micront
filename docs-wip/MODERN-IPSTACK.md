# MicroNT — Modern sockets on the 3.50 AFD (overlapped + IOCP for Go & Rust)

**What we did** We hardened the 3.50 async core and integrated it tightly:
- AFD pends and completes correctly (receive/send/accept/connect/poll all async).
- The kernel IOCP completion-port delivery path works (`IopCompleteRequest` →
  `KeInsertQueue`, `NtRemoveIoCompletion` → `KeRemoveQueue`).
- A string of cancellation races are fixed: cancel-spinlock ordering (cancel-outer,
  endpoint-inner), the throttled-recv lock leak ("Fix A", `RECVVC.C:700`), the
  `AfdCleanup` cancel invariant (commit `0efcc1b`), and the `IopDisassociateThreadIrp`
  tombstone backstop (`INTERNAL.C:1191`).

## The realization that makes this cheap

ws2_32 today is a **synchronous wrapper over an already-async stack.** `recv()`
(`RECV.C:153`) issues the async IOCTL then *chooses* to block on a per-thread event:

```c
status = NtDeviceIoControlFile(Handle, SockThreadEvent, NULL, NULL,   // ApcCtx = NULL
                               &ioStatusBlock, IOCTL_TDI_RECEIVE, ...);
if (status == STATUS_PENDING) { SockWaitForSingleObject(SockThreadEvent, ...); }
```

The IRP genuinely pends in AFD and completes asynchronously; ws2_32 just waits. So
the overlapped surface is mostly a **userland change** to ws2_32, riding kernel/AFD
machinery that already exists.

### Traced end-to-end — what already works
| Layer | Mechanism | Evidence |
|-------|-----------|----------|
| AFD receive pend | `IoMarkIrpPending` + `STATUS_PENDING` | `RECVVC.C:445-482` |
| AFD receive complete (async) | indication handler `IoCompleteRequest` | `RECVVC.C:689` (fast), `:1397` (drain) |
| AFD send pend/complete | `IoMarkIrpPending` `SEND.C:260` / `IoCompleteRequest` `:745` | `SEND.C` |
| AFD poll **async-on-readiness** | `AfdPoll` pends `POLL.C:625/642`; `AfdIndicatePollEvent` completes `:1054` | `POLL.C` |
| IOCP association | `NtSetInformationFile(FileCompletionInformation)` → `FileObject->CompletionContext` | `QSINFO.C:1431` |
| IOCP delivery | `port && UserApcContext` → `KeInsertQueue(port, &irp->Tail.Overlay.ListEntry)` | `INTERNAL.C:998-1008` |
| IOCP dequeue (GQCS) | `NtRemoveIoCompletion` → `KeRemoveQueue` | `COMPLETE.C:524` |
| Cancel discipline | cancel-outer lock; unlink + `IoSetCancelRoutine(NULL)` before release | `RECVVC.C:600-641`, `AfdCancelReceive :1411` |

Note the delivery condition: `IopCompleteRequest` routes to the port only when
`UserApcContext` is non-NULL. Today `recv()` passes `ApcContext = NULL`, so the
overlapped wrappers **must** pass `lpOverlapped` there (it becomes the value GQCS
returns) and pass `(PIO_STATUS_BLOCK)lpOverlapped` as the IOSB (its
`Internal`/`InternalHigh` overlay the IOSB).

## The two (three) consumer models — they stress different paths

| Consumer | Mechanism | Status on 3.50 AFD |
|----------|-----------|--------------------|
| **Rust std (blocking)** | synchronous recv/send/accept/connect | **works today** (the `server` milestone) |
| **Go runtime** | overlapped `WSARecv`/`WSASend` + `AcceptEx`/`ConnectEx`, one IOCP, `GetQueuedCompletionStatus(Ex)`, `PostQueuedCompletionStatus` to wake | needs the gap list below |
| **Rust + Tokio (mio)** | AFD readiness poll (`IOCTL_AFD_POLL`) bound to an IOCP — the *wepoll* mechanism; readiness-based, **not** overlapped data ops, **not** AcceptEx | poll mechanism present; conformance + write re-arm to verify |

Key clarification the old doc conflated: **AcceptEx/ConnectEx are the Go track**;
the **AFD-poll-over-IOCP reactor is the Tokio track**. They share the IOCP delivery
path but use different AFD entry points.

## mio (Tokio) — grounded against `stuff/testrust/mio` v1.2.1

Tracing mio's `src/sys/windows/{afd,iocp,net,waker}.rs` against the in-tree
sources pins the Tokio delta exactly. mio creates sockets with `WSASocketW` +
`ioctlsocket(FIONBIO)` (both real), opens one AFD **helper handle**, and submits
`IOCTL_AFD_POLL` readiness requests on it bound to an IOCP. It does **not** use
overlapped `WSARecv`/`WSASend`, `AcceptEx`/`ConnectEx`, or `SIO_BASE_HANDLE` —
it polls the socket handle directly (the wepoll base-handle dance is gone in 1.x).
The actual reads/writes after readiness are ordinary non-blocking `recv`/`send`,
which already work.

| mio call | lowers to | status |
|----------|-----------|--------|
| `WSASocketW` + `ioctlsocket(FIONBIO)` | ws2_32 | ✅ real |
| `NtCreateFile("\Device\Afd\Mio", EaBuffer=NULL)` | AFD `CREATE.C` | ❌ rejects EA-less open (`CREATE.C:70 → STATUS_INVALID_PARAMETER`); needs a helper-endpoint path (no transport binding, poll-only) |
| `NtDeviceIoControlFile(IOCTL_AFD_POLL = 0x00012024)` | AFD `POLL.C` | ⚠️ function-number drift: ours is `0x00012010` (req 4); `0x12024` is req **9** = our `IOCTL_AFD_SET_INFORMATION`. Alias `0x12024` → `AfdPoll`. `AFD_POLL_INFO` is **byte-compatible** (28B, `Handles[]`@16; mio `exclusive`=0 lands on our `Unique` byte; event bits identical) |
| `CreateIoCompletionPort` | kernel32 | ✅ exists (`CLIENT/ERROR.C`) |
| `GetQueuedCompletionStatusEx` (mio dequeues via `get_many` only) | `NtRemoveIoCompletionEx` | ❌ both absent — only singular `GetQueuedCompletionStatus`/`NtRemoveIoCompletion` exist |
| `PostQueuedCompletionStatus` (the Waker — Tokio always builds one) | `NtSetIoCompletion` | ❌ both absent; needs the lookaside mini-packet format so `NtRemoveIoCompletion*` can tell posted packets from completed IRPs (gap 2) |
| `SetFileCompletionNotificationModes(FILE_SKIP_SET_EVENT_ON_HANDLE)` | kernel32 | ❌ absent; `Afd::new` returns `Err` if it fails, so **required** (the flag is `SKIP_SET_EVENT_ON_HANDLE`, *not* `SKIP_COMPLETION_PORT_ON_SUCCESS`) |
| `NtCancelIoFileEx` (poll cancel on deregister/drop) | ntdll | ❌ absent — we have 2-arg `NtCancelIoFile`; need the 3-arg per-IRP `Ex` |

**Tokio kernel/DLL delta = 6 items:** (1) AFD EA-less helper open, (2) AFD poll
IOCTL alias `0x12024`, (3) `NtSetIoCompletion` + kernel32 `PostQueuedCompletionStatus`,
(4) `NtRemoveIoCompletionEx` + kernel32 `GetQueuedCompletionStatusEx`, (5) kernel32
`SetFileCompletionNotificationModes`, (6) `NtCancelIoFileEx`. First step is the Lua
poll dry-run (Tier 2) reproducing items 1–2 with no Rust.

Corrections to the older gap list below, from this grounding: `SIO_BASE_HANDLE`
is **not** needed; the `SetFileCompletionNotificationModes` flag is
`SKIP_SET_EVENT_ON_HANDLE` (not `SKIP_COMPLETION_PORT_ON_SUCCESS`); and the
plural `NtRemoveIoCompletionEx`/`GetQueuedCompletionStatusEx` are required (mio
never uses the singular dequeue).

## Gap list (priority-ordered, tracked work-items)

1. **ws2_32 overlapped wrappers** — `WSARecv`/`WSASend`/`WSARecvFrom`/`WSASendTo`/
   `WSASocketW`/`WSAGetOverlappedResult`. Thread the app `OVERLAPPED` through as
   IOSB + `ApcContext`, marshal `WSABUF[]`→MDL, **don't wait**, return
   `WSA_IO_PENDING`. Lower layers ready. *Cheapest; unblocks Go data path + Rust overlapped.*
2. **`NtSetIoCompletion`** (`PostQueuedCompletionStatus` backend) — **absent**
   (grep-empty; only named in `io.md`). Go uses it to wake the netpoller. Design
   point: the port `KQUEUE` currently holds IRP `ListEntry`s and `NtRemoveIoCompletion`
   recovers results via `CONTAINING_RECORD(entry, IRP, ...)`; a posted packet has no
   IRP, so both ends need an agreed packet format (real NT uses a lookaside mini-packet).
3. **`AfdSuperAccept`** (`IOCTL_AFD_SUPER_ACCEPT`, AcceptEx backend) — **not in our
   tree**, only in `srv03rtm-anika/.../afdsys/accept.c` (`AfdSuperAccept ~:888`).
   Port it + `AfdCancelSuperAccept`. ⚠️ It cancels **lock-free** via
   `InterlockedCompareExchangePointer(&connection->AcceptIrp, ...)` — a different
   discipline than our endpoint-spinlock cancel paths; preserve the interlocked protocol.
4. **ConnectEx + connect-cancel audit** — `IOCTL_AFD_SUPER_CONNECT` (bind-first +
   optional send-data). Separately: `AfdConnect` (`CONNECT.C:114`) delegates
   cancellation entirely to TDI (no AFD cancel routine). Go cancels connects on every
   dial deadline — **verify a connecting IRP is actually cancellable at TDI**, or it
   hangs in exactly the way the pre-"Fix A" recv path did on `CLOSING` TCBs.
5. **Tokio write-readiness re-arm (`SEND_POSSIBLE`)** — `VcNonBlockingSendPossible`
   inits TRUE (`blkconn.c:374/784`) but goes FALSE on a non-blocking-send WOULDBLOCK
   (`send.c:1173`) with **no edge to re-arm it**. Blocking sends are fine; a Tokio
   write-interest poll can stick un-ready under sustained backpressure. Needs a
   send-possible re-arm wired into the poll path.
6. **mio `AFD_POLL` conformance + EA-less helper open** — CONFIRMED (see mio
   section above), no longer speculative. mio's `IOCTL_AFD_POLL` is `0x00012024`
   (function 9) vs our `0x00012010` (function 4); `0x12024` currently maps to our
   `IOCTL_AFD_SET_INFORMATION`, so alias `0x12024` → `AfdPoll`. `AFD_POLL_INFO` is
   byte-compatible. Plus: mio opens `\Device\Afd\Mio` with `EaBuffer=NULL`, which
   `CREATE.C:70` rejects — add a poll-only helper-endpoint open path.
7. **`SetFileCompletionNotificationModes`** — REQUIRED for mio with
   `FILE_SKIP_SET_EVENT_ON_HANDLE` (NOT `SKIP_COMPLETION_PORT_ON_SUCCESS` — earlier
   note was wrong); `Afd::new` returns `Err` if the export is missing. Newer Go
   additionally sets `SKIP_COMPLETION_PORT_ON_SUCCESS` — decide that one explicitly:
   ignore (always queue, safe) vs honor; silent mishandling → double-completion/hang.
9. **`NtRemoveIoCompletionEx` + `NtCancelIoFileEx`** — mio dequeues only via
   `GetQueuedCompletionStatusEx` (→ `NtRemoveIoCompletionEx`, plural) and cancels a
   pending poll via `NtCancelIoFileEx` (3-arg, per-IRP). We have only the singular
   `NtRemoveIoCompletion` and the 2-arg `NtCancelIoFile`. Both are part of the Tokio
   delta (gap 2 covers the `NtSetIoCompletion` post side).
8. **`WSAEventSelect`/`WSAEnumNetworkEvents`** — no `IOCTL_AFD_EVENT_SELECT` in 3.50.
   Emulate in userland over `IOCTL_AFD_POLL` (same poll primitive as the Tokio reactor —
   effort compounds).

## Conformance testing: real targets + upstream test suites

The point of these targets is that they **fail loudly** if the async/cancel edges are
wrong — they exercise paths our hand-written kernel tests can't easily reach.

- **frp (Go)** — overlapped + AcceptEx + IOCP, client *and* server. Primary Go target.
- **a Tokio echo/server (Rust)** — the AFD-poll reactor under load.
- **Rust std `server`** — blocking baseline; works now, regression canary.

Plan: once the ws2_32 + `mswsock` surface ships (`MICRONT-DLL-TODO.md`), pull in
**Go's `net` package tests** and **Rust's `std::net` + `mio`/`tokio` integration
tests** as conformance suites. They encode years of edge cases — concurrent
close+I/O, deadline cancellation, half-close, zero-byte recv, accept storms — i.e.
exactly the IOCP/cancel abuse we want to certify against, without hand-authoring it.
This is the `project_dll_acceptance_testing` model: the app and its own test suite
are the oracle.

## ws2_32 build plan — surface tiers
Per-symbol have/need detail now lives in **`MICRONT-DLL-TODO.md`** (measured against
the real Rust/Go binaries); this is the build *ordering*. Placement:
`NT/PRIVATE/WINDOWS/BASE/WS2_32`, target `windows_ws2_32`, links `ntdll` directly.
Full `ws2_32.src` `.def` preserved (ordinals intact, tail stubs to honest errors).

- **T1 BSD core** — present in 3.50 AFD today (the existing sync path). Rust std
  blocking rides this.
- **T2 name resolution** — `getaddrinfo`/`freeaddrinfo`/`GetAddrInfoW` + DNS resolver
  (port `dns.lua`) + static protocols/services tables. (+`GetHostNameW` → drops the
  Rust ≤1.91 pin, see `MICRONT-RUST-TODO.md`.)
- **T3 startup/error** — real `WSAStartup`/`Cleanup`/`Get|SetLastError` (TLS),
  `__WSAFDIsSet`. WS1.1 blocking hooks + `WSAAsync*` → `WSAEINVAL` (headless).
- **T4 overlapped/WS2 core** — `WSARecv`/`WSASend`/`...From`/`...To`, `WSASocketW`,
  `WSAGetOverlappedResult`, `WSAEnumProtocolsW` (fixed TCP/UDP catalog), `WSAIoctl`
  incl. `SIO_GET_EXTENSION_FUNCTION_POINTER` → AcceptEx/ConnectEx (gap items 1,3,4).
- **T5 stub-only** — RNR namespace, `WSC*` provider catalog, `WSAJoinLeaf` (no
  multicast, single-NIC cloud scope).

### Milestones
- **W1** Rust std `server` — blocking TCP (T1 + T3). *Closest to done.*
- **W2** name resolution (T2) + `GetHostNameW` (unpin Rust).
- **W3 (Go)** overlapped wrappers + `AfdSuperAccept` + `NtSetIoCompletion` → frp.
- **W4 (Tokio)** AFD-poll-over-IOCP conformance + `SEND_POSSIBLE` re-arm +
  `WSAEventSelect` emulation → Tokio echo/server.

## Subsystem tickets
1. **ws2_32 overlapped wrappers** (userland; gap 1) — W3 gate.
2. **`NtSetIoCompletion`** (kernel; gap 2) — isolated, packet-format design.
3. **`AfdSuperAccept` port** from srv03 afdsys (kernel/AFD; gap 3) — biggest piece,
   keep interlocked cancel.
4. **ConnectEx + connect-cancel audit** (gap 4) — feature + latent-hang fix.
5. **Tokio poll path (grounded — see mio section)** — the 6-item delta: AFD EA-less
   helper open + poll-IOCTL alias `0x12024` (gap 6), `NtSetIoCompletion` /
   `PostQueuedCompletionStatus` (gap 2), `NtRemoveIoCompletionEx` /
   `GetQueuedCompletionStatusEx` + `NtCancelIoFileEx` (gap 9),
   `SetFileCompletionNotificationModes` (gap 7), plus `SEND_POSSIBLE` write re-arm
   (gap 5). Start with the Tier-2 Lua poll dry-run (reproduces gaps 1–2, no Rust).
6. **`SetFileCompletionNotificationModes`** decision (gap 7).
7. **Conformance harness** — wire Go `net` + Rust `mio`/`tokio` test suites once the
   DLL surface ships.
