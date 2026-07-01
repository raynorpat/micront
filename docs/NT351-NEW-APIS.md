# Windows NT 3.51 SP5 — New Win32 APIs (Deep Dive)

Unusually for a service pack, **NT 3.51 Service Pack 5** (build 3.51.1057.6,
September 1996) did not just fix bugs — it *extended the Win32 API surface*. Three
new families of functions appeared, plus one networking tool tweak:

1. **Fibers** — user-mode cooperative scheduling primitives.
2. **`AcceptEx` / `GetAcceptExSockaddrs`** — high-performance overlapped socket accept.
3. **`ReadDirectoryChangesW`** — rich, named directory-change notification.
4. **`ROUTE.EXE METRIC`** — per-route cost/hop-count argument.

These all became permanent parts of Win32 and survive in modern Windows essentially
unchanged. This document records what each does, the exact contract, and why it was
added — at the point in history when NT 3.51 SP5 introduced it.

> **Documentation-baseline caveat.** Today's MSDN pages list the "minimum supported
> client" as **Windows XP** (fibers, `ReadDirectoryChangesW`) or **Windows Vista /
> 8.1** (`AcceptEx`). That reflects when Microsoft *re-based* its reference docs onto
> then-supported OSes — **not** when the functions first shipped. The NT 3.51 SP5
> README (Microsoft KB Q128531) documents all of them as *new in SP5*, which is
> their true debut. The fiber headers gate on `_WIN32_WINNT >= 0x0400`
> (the NT 4.0 value) because that define did not yet have a 3.51-specific constant;
> the entry points themselves were live in 3.51 SP5's KERNEL32.

---

## 1. Fibers

### What the SP5 README says

> "A fiber is a lightweight thread that is manually scheduled. Fibers do not provide
> advantages over a well-designed multithreaded application. However, fibers can make
> it easier to port applications that were designed to schedule their own threads."

### Concept

A **fiber** is a unit of execution that lives *inside* a thread and is scheduled
**cooperatively by the application**, not preemptively by the kernel. A thread can
host many fibers, but only one runs at a time, and a fiber runs until it explicitly
yields by calling `SwitchToFiber`. The kernel knows nothing about fibers — to the
scheduler there is still just the one thread.

This is the classic trade-off:

- **No kernel involvement** in a fiber switch → very cheap context switches, no
  ring transition.
- **Cooperative** → one fiber that never yields starves all the others in that
  thread, and a blocking syscall blocks *every* fiber on the thread.
- **No parallelism** → fibers on one thread never run on two CPUs at once; for
  parallelism you still need real threads.

The stated motivation was **porting**: applications (notably large UNIX server
codebases) that already implemented their own user-space schedulers could map their
"tasks" onto fibers instead of fighting the Win32 thread model. The best-known real
consumer is **Microsoft SQL Server's "lightweight pooling" / fiber mode**, where the
engine schedules its own workers to minimize kernel context-switch overhead.

### The API (6 functions)

| Function | Role |
| --- | --- |
| `ConvertThreadToFiber(lpParameter)` | Turn the current thread into a fiber so it can participate in fiber switching. **Must be called first**, before any `SwitchToFiber`. Returns the fiber address for the thread. |
| `CreateFiber(dwStackSize, lpStartAddress, lpParameter)` | Allocate a new fiber with its own stack and a start routine. **Does not run it** — only `SwitchToFiber` does. Returns the fiber address. |
| `SwitchToFiber(lpFiber)` | Save the current fiber's state and begin/resume execution of `lpFiber`. This is the cooperative yield — *the* scheduling operation. |
| `DeleteFiber(lpFiber)` | Free a fiber and its stack. Deleting the currently running fiber exits the thread. |
| `GetCurrentFiber()` | Return the address of the running fiber (a macro). |
| `GetFiberData()` | Return the `lpParameter` value associated with the running fiber (a macro). |

### `CreateFiber` — exact contract

```c
LPVOID CreateFiber(
  SIZE_T                dwStackSize,    // initial committed stack; 0 = exe default
  LPFIBER_START_ROUTINE lpStartAddress, // fiber entry point (FiberProc)
  LPVOID                lpParameter     // passed to the fiber; read via GetFiberData()
);
```

- Returns the fiber's address on success, `NULL` on failure (`GetLastError`).
- Execution of the new fiber **does not begin** until *another* fiber calls
  `SwitchToFiber` with this address.
- The fiber count is bounded by virtual memory: at the default ~1 MB reserved stack
  each, a process tops out around ~2028 fibers. Reduce the stack (`.def` `STACKSIZE`
  / later `CreateFiberEx`) for more — but Microsoft's own guidance is that needing
  thousands of fibers means you want a different design.

### Minimal usage pattern

```c
// Thread side:
LPVOID mainFiber  = ConvertThreadToFiber(NULL);          // become a fiber
LPVOID workFiber  = CreateFiber(0, FiberProc, pContext); // create a worker
SwitchToFiber(workFiber);                                // run it (cooperative)
// ... control returns here only when the worker SwitchToFibers back ...
DeleteFiber(workFiber);

// Worker side:
VOID CALLBACK FiberProc(LPVOID lpParameter) {
    MyContext *ctx = (MyContext*)GetFiberData();  // == lpParameter
    // ... do work, periodically yield: ...
    SwitchToFiber(ctx->mainFiber);
}
```

**Gotcha that still bites people:** Fiber Local Storage did not exist yet (FLS came
much later), and **TLS is per-*thread*, not per-fiber** — fibers sharing a thread
share its TLS slots. Code ported onto fibers that assumed thread-local state needs
care here.

---

## 2. `AcceptEx` / `GetAcceptExSockaddrs`

### What the SP5 README says

> "Two new APIs, `AcceptEx()` and `GetAcceptExSockaddrs()`, have been added to the
> Windows Sockets family. `AcceptEx()` provides a way to asynchronously accept a
> connection, obtain the local and remote addresses for the connection, and receive
> the first block of data, all within a single call."

### Why it matters

The classic Berkeley `accept()` is **synchronous and blocking** — one accepted
connection per call, and you then need extra round-trips to learn the peer address
and to read the first bytes. `AcceptEx` collapses **three operations into one
overlapped (asynchronous) call**:

1. Accept a new connection.
2. Return both the local (server) and remote (client) addresses.
3. Receive the first block of data the client sends.

Because it is overlapped, it pairs naturally with **I/O completion ports**: a server
can keep a pool of pre-created accept sockets outstanding and service thousands of
clients with a handful of threads. This is the foundation of the scalable Winsock
server model that NT became known for — and SP5 is where the primitive first
appeared.

### `AcceptEx` — exact contract

```c
BOOL AcceptEx(
  SOCKET       sListenSocket,         // already listen()ing
  SOCKET       sAcceptSocket,         // pre-created, NOT bound or connected
  PVOID        lpOutputBuffer,        // holds: first data, then local addr, then remote addr
  DWORD        dwReceiveDataLength,   // bytes of the buffer for received data (may be 0)
  DWORD        dwLocalAddressLength,  // >= max sockaddr + 16
  DWORD        dwRemoteAddressLength, // >= max sockaddr + 16, cannot be 0
  LPDWORD      lpdwBytesReceived,     // set only on synchronous completion
  LPOVERLAPPED lpOverlapped           // required; this is overlapped I/O
);
```

Key rules (each one is a real-world footgun):

- **You must create the accept socket yourself in advance** — unbound and
  unconnected. `AcceptEx` does not create it for you (unlike `accept`). This is what
  lets you pre-post accepts.
- **The address buffers must be 16 bytes larger than the protocol's `sockaddr`.**
  For TCP/IP, `sockaddr_in` is 16 bytes, so reserve **at least 32 bytes** each for
  local and remote. The addresses are stored in an internal format that needs the
  slack.
- **`dwReceiveDataLength == 0`** makes `AcceptEx` complete as soon as the connection
  arrives, *without* waiting for data — often what you want, to avoid a slow/idle
  client tying up the accept.
- After completion you **must call `setsockopt(SO_UPDATE_ACCEPT_CONTEXT)`** on the
  accepted socket (passing the listen socket as the value) before it inherits the
  listener's properties or before `getsockname`/`getpeername` work on it.
- The single buffer mixes data + two addresses, so you **must call
  `GetAcceptExSockaddrs`** to split it back into (data, local sockaddr, remote
  sockaddr).
- In modern SDKs the function pointer is obtained at runtime via
  `WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER, WSAID_ACCEPTEX, …)` and lives in
  `MSWSOCK`. (The runtime-pointer pattern was formalized later; the SP5-era entry
  point shipped with the Winsock stack.)

### `GetAcceptExSockaddrs`

The mandatory companion. Given the `AcceptEx` output buffer and the same length
parameters, it returns pointers to the parsed **local** and **remote** `sockaddr`
structures (and implicitly delimits where the received data ends). Without it you
cannot safely interpret the addresses `AcceptEx` packed into the buffer.

### Idle-connection detection

A documented idiom that came with this API: use
`getsockopt(SO_CONNECT_TIME)` on the accepted socket to find how long it has been
connected (or `0xFFFFFFFF` if not yet connected). Combined with "accepted but no data
received," a server can reap clients that connect and then go silent — a basic but
important DoS mitigation for an accept-pooling server.

---

## 3. `ReadDirectoryChangesW`

### What the SP5 README says

> "One new API, `ReadDirectoryChangesW()`, has been added to enhance an application's
> ability to monitor directories. … Unlike `FindFirstChangeNotification()`, this API
> will return the **full name of the affected file**."

### Why it matters

Before SP5, the only directory-watching mechanism was
`FindFirstChangeNotification` / `FindNextChangeNotification`. That tells you only
that *something* under a directory changed — you then have to **rescan the whole
directory** to discover *what*. `ReadDirectoryChangesW` instead hands back a buffer
of **per-change records, each naming the specific file** and the kind of change
(added / removed / modified / renamed-from / renamed-to). This is the primitive that
made efficient file-system watchers, replication agents, and "auto-reload" tooling
possible on NT.

### Exact contract

```c
BOOL ReadDirectoryChangesW(
  HANDLE                          hDirectory,          // opened with FILE_LIST_DIRECTORY
  LPVOID                          lpBuffer,            // DWORD-aligned; FILE_NOTIFY_INFORMATION records
  DWORD                           nBufferLength,
  BOOL                            bWatchSubtree,       // TRUE = whole tree, FALSE = this dir only
  DWORD                           dwNotifyFilter,      // FILE_NOTIFY_CHANGE_* bitmask
  LPDWORD                         lpBytesReturned,     // synchronous calls only
  LPOVERLAPPED                    lpOverlapped,         // NULL = sync, else async
  LPOVERLAPPED_COMPLETION_ROUTINE lpCompletionRoutine  // optional APC-style completion
);
```

**The directory handle** must be opened via `CreateFile` with
`FILE_FLAG_BACKUP_SEMANTICS` (and `FILE_FLAG_OVERLAPPED` too, if you want
asynchronous completion).

**`dwNotifyFilter`** — combine one or more:

| Flag | Value | Fires on |
| --- | --- | --- |
| `FILE_NOTIFY_CHANGE_FILE_NAME`   | 0x001 | file create / delete / rename |
| `FILE_NOTIFY_CHANGE_DIR_NAME`    | 0x002 | subdirectory create / delete |
| `FILE_NOTIFY_CHANGE_ATTRIBUTES`  | 0x004 | attribute change |
| `FILE_NOTIFY_CHANGE_SIZE`        | 0x008 | size change (on flush to disk) |
| `FILE_NOTIFY_CHANGE_LAST_WRITE`  | 0x010 | last-write time change (on flush) |
| `FILE_NOTIFY_CHANGE_LAST_ACCESS` | 0x020 | last-access time change |
| `FILE_NOTIFY_CHANGE_CREATION`    | 0x040 | creation time change |
| `FILE_NOTIFY_CHANGE_SECURITY`    | 0x100 | security-descriptor change |

**Result format** — `lpBuffer` is filled with a chain of `FILE_NOTIFY_INFORMATION`
records, each carrying a `NextEntryOffset` (0 = last), an `Action`
(`FILE_ACTION_ADDED`, `_REMOVED`, `_MODIFIED`, `_RENAMED_OLD_NAME`,
`_RENAMED_NEW_NAME`), and the affected file's name as a counted UTF-16 string —
which is exactly the "full name" advantage over `FindFirstChangeNotification`.

### Three async-completion models (all supported)

1. **`GetOverlappedResult`** — no completion routine; signal via the `OVERLAPPED`
   event.
2. **Completion port** — associate `hDirectory` with an IOCP and drain via
   `GetQueuedCompletionStatus`. (Pairs perfectly with the same IOCP-based server
   design that `AcceptEx` enables.)
3. **Completion routine (APC)** — supply `lpCompletionRoutine`; it fires when the
   thread is in an alertable wait.

### Edge cases worth recording

- **Buffer overflow:** if more changes occur than fit, the call still "succeeds" but
  the whole buffer is discarded and `lpBytesReturned == 0` — your signal to fall
  back to a full directory enumeration.
- **Over the network, the buffer must be ≤ 64 KB** or the call fails with
  `ERROR_INVALID_PARAMETER` (a limit of the underlying file-sharing protocol).
- **`ERROR_NOACCESS`** if `lpBuffer` is not `DWORD`-aligned.
- If the target file system / redirector can't support it, you get
  `ERROR_INVALID_FUNCTION`.

---

## 4. `ROUTE.EXE METRIC` argument

Small but real: SP5 added a `METRIC` parameter to the `ROUTE` command.

```
ROUTE [-f] [command [destination] [MASK netmask] [gateway] [METRIC metric]]
```

> "The metric option is used to associate a cost/hop count for the destination
> specified by the route entry. Generally this specifies the distance in number of
> hops from the destination. If not specified, the metric is set to 1 by default."

This let administrators express route preference (lower metric = preferred path)
when adding static routes, bringing `ROUTE` closer to the routing-table control
expected on a multihomed NT server.

---

## Relevance to a from-source rebuild

- These entry points must exist in the SP5-level **KERNEL32** (fibers,
  `ReadDirectoryChangesW`), **WS2_32/MSWSOCK/WSOCK32** (`AcceptEx`,
  `GetAcceptExSockaddrs`), and the **TCPIP/route** tooling. On an RTM-through-SP4
  base they are absent — any component or test that links them will fail to resolve.
- Fibers touch the lowest level of the runtime: each fiber needs its own saved
  CPU context and stack, and `SwitchToFiber` is essentially a user-mode context
  switch. On the non-x86 targets this project also builds (**MIPS, Alpha, PowerPC**),
  the fiber switch is per-architecture assembly — worth flagging against
  `docs/MIPS-PPC-PORT.md` if fibers are ever in scope.
- `ReadDirectoryChangesW` and `AcceptEx` are both fundamentally **overlapped-I/O +
  completion-port** consumers; they exercise the same IRP/IOCP plumbing, so getting
  one working de-risks the other.

See also: `docs/NT351-SERVICE-PACKS.md` for the full service-pack timeline.

---

## Implementation status in micront

All four families are now implemented from the NT4 reference source. The entry
points are exported unconditionally (matching their SP5 debut); the public
header declarations are **not** gated on `_WIN32_WINNT >= 0x0400`, because
micront's headers do not use that versioning scheme.

| API | Where it lives | Commit |
| --- | --- | --- |
| Fibers (6 functions) | `KERNEL32`: `windows/base/client/thread.c` (`CreateFiber` / `DeleteFiber` / `ConvertThreadToFiber`), `i386/thunk.asm` (`SwitchToFiber`), `i386/context.c` (`BaseFiberStart`). `FIBER` struct + `GetCurrentFiber` / `GetFiberData` macros in `ntpsapi.h`; `NT_TIB.FiberData` union; `Fb*` / `Tb*` offsets in `ks386.inc` + `geni386.c` | `ed9d66f7` |
| `ReadDirectoryChangesW` | `KERNEL32`: `windows/base/client/filefind.c`, over the pre-existing `NtNotifyChangeDirectoryFile`. `FILE_ACTION_*` and the two missing `FILE_NOTIFY_CHANGE_*` filters added to `winnt.h` | `ed9d66f7` |
| `AcceptEx` / `GetAcceptExSockaddrs` | `WSOCK32`: `net/sockets/winsock/acceptex.c`, exported at ordinals 1141 / 1142; new public `mswsock.h`. Backed by a new `IOCTL_AFD_SUPER_ACCEPT` in `ntos/afd` | `40fbdb64`, `55ee4966` |
| `ROUTE METRIC` | `ntos/tdi/tcpip/utils/ip/route/newroute.c`: optional `METRIC` keyword before the metric value | `a581ae0b` |

### Notes on the AcceptEx / AFD super-accept path

- `IOCTL_AFD_SUPER_ACCEPT` (request 32, `METHOD_OUT_DIRECT`) pipelines
  wait-for-listen → accept → local/remote address capture → first-data receive
  in a single overlapped IRP, which is what AcceptEx needs.
- **Worker-thread deferral (micront-specific).** micront's 3.51 AFD completes
  the wait-for-listen at `DISPATCH_LEVEL`, but its accept core opens a TDI
  address handle (`ObOpenObjectByPointer` / `KeAttachProcess`) that requires
  `PASSIVE_LEVEL`. The completion routine therefore hands the remaining work to
  a passive worker (`AfdSuperAcceptWorker`). NT 4.0 avoids this because its
  later, factored `AfdAcceptCore` is dispatch-safe.
- The local address is obtained with a real `TDI_QUERY_ADDRESS_INFO` query on
  the accepted connection, so it matches `getsockname` even for wildcard binds.
- micront's `AFD_CONNECTION` has no `DeviceObject` field (NT 4.0's does), so the
  transport device is reached via `connection->FileObject->DeviceObject`.
- **Not yet build- or run-verified.** The AFD and wsock32 changes are kernel and
  service-provider code that has not been compiled or exercised; they need a
  checked build and a VM test (start with `dwReceiveDataLength == 0`, then with
  first-data receive).

---

## Sources

- [Q128531 — README.TXT: Windows NT 3.51 U.S. Service Pack (KB archive)](https://jeffpar.github.io/kbarchive/kb/128/Q128531/)
- [Windows NT 3.51 U.S. Service Pack 5 README — zx.net.nz](https://ftp.zx.net.nz/pub/Patches/Microsoft/WinNT-patches/3.51/fixes/ussp5/README.HTM)
- [CreateFiber function — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createfiber)
- [Fibers / Using Fibers — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/procthread/fibers)
- [AcceptEx function — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/winsock/nf-winsock-acceptex)
- [ReadDirectoryChangesW function — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-readdirectorychangesw)
