# IOCP-driven Lua coroutine reactor for MicroNT

Status: **draft / deferred**. Captures the intended shape so we can pick
this up cleanly in a future session. Nothing in this document is
implemented yet — the AFD socket layer (`nt.afd`) currently exposes
*synchronous* primitives that block on a per-IRP `Event` handle. This
spec describes how to layer real NT I/O Completion Ports on top so a
Lua coroutine scheduler can multiplex many concurrent sockets in one
OS thread.

## Why this exists

Today, every `nt.afd.recv(sock, n, timeout)` call:

1. Allocates a fresh `Event` handle via `ke.NtCreateEvent`.
2. Issues `NtReadFile` with that Event as the synchronisation handle.
3. If the IRP returns `STATUS_PENDING`, blocks the caller's OS thread
   on `NtWaitForSingleObject(Event, timeout)`.
4. Returns when the IRP completes — or, on timeout, calls
   `NtCancelIoFile`, drains via an infinite wait, and raises
   `STATUS_CANCELLED`.

This is fine for serial code, but it pins one OS thread per pending
operation. A Lua program that wants to handle several connections
concurrently is forced into `nt.thread`, which is heavyweight, has its
own VM-per-thread isolation cost, and doesn't share state ergonomically.

The proposed reactor lets a single OS thread service N coroutines, each
doing its own `recv` / `send` / `connect`. The coroutine doing I/O
yields; the scheduler resumes it when the corresponding IRP completes.

## Kernel surface — what we're building on

The relevant primitives are already in the MicroNT kernel
(`src/NT/PRIVATE/NTOS/IO/COMPLETE.C` and `QSINFO.C`):

| Syscall | Purpose |
|---|---|
| `NtCreateIoCompletion(out Handle, access, oa, count)` | Create an IoCompletion object. `count` is the maximum concurrent threads the kernel should allow to dequeue at once (irrelevant for our single-threaded design — pass 1). |
| `NtRemoveIoCompletion(Handle, out Key, out ApcContext, out Iosb, Timeout)` | Block (or with `Timeout=0`, poll) for the next completion. Returns the `(key, apc_context, iosb)` tuple the I/O manager queued. |
| `NtSetIoCompletion(Handle, Key, ApcContext, Status, Information)` | Manually post a completion. Lets the scheduler wake itself for non-IO events (timers expiring, cross-coroutine signals, `loop:stop()`). |
| `NtSetInformationFile(File, &Iosb, &info, sizeof(info), FileCompletionInformation)` | Associate a file/device handle with an IoCompletion port. After this, every async IRP completion on that file auto-queues to the port. |

`FILE_COMPLETION_INFORMATION` carries the IoCompletion handle and a
`Key` (`ULONG_PTR`). The `Key` arrives on every completion from this
file; we use it to identify the socket. The per-IRP `ApcContext` is
the value the caller passed as `ApcContext` to `NtReadFile` /
`NtWriteFile` / `NtDeviceIoControlFile` — perfect for identifying *which
operation* on the socket completed.

Once a socket is attached to an IoCompletion port, do **not** pass an
`Event` handle on subsequent IRPs — completions go to the port instead.
Cancellation still works via `NtCancelIoFile`; a cancelled IRP arrives
on the port with `iosb.Status = STATUS_CANCELLED`.

## Architecture

### Layering (bottom-up)

```
+-----------------------------------------------------------+
|  Application coroutines: loop:spawn(fn)                    |
|    fn() does loop:recv(sock, n) / loop:send / loop:sleep   |
+-----------------------------------------------------------+
|  nt.loop  — coroutine scheduler                            |
|    .spawn / .run / .stop / .sleep                          |
|    .recv / .send / .connect / .accept (yielding wrappers)  |
|    Per-IRP state: { coroutine, iosb, buf, deadline }       |
|    Internal: timer wheel + IoCompletion drain loop         |
+-----------------------------------------------------------+
|  nt.iocp  — thin wrapper over IoCompletion + attach        |
|    .create() -> NT_HANDLE                                  |
|    .attach(sock, key)                                      |
|    .dequeue(timeout) -> (key, apc_context, iosb)           |
|    .post(key, apc_context, status, info)                   |
+-----------------------------------------------------------+
|  nt.afd  — sockets (existing, unchanged blocking API)      |
|    plus: io_wait_iocp() variant that omits the Event       |
+-----------------------------------------------------------+
|  nt.dll.io  — IoCompletion bridge                          |
|    NtCreateIoCompletion / NtRemoveIoCompletion             |
|    NtSetIoCompletion / NtSetInformationFile                |
|    (FileCompletionInformation flavour)                     |
+-----------------------------------------------------------+
```

### Concurrency model

**Single-threaded.** One OS thread, one IoCompletion port, many Lua
coroutines. Each coroutine that issues an I/O op yields; the scheduler
resumes exactly the coroutine whose IRP completed. There is no shared
state across threads, so no locking, no MT-safety concerns.

If parallelism is needed later, a thread pool variant can be layered
on the same `nt.iocp` module — the kernel's IoCompletion already
serialises completions across threads via the `count` parameter — but
for now the assumption is *one Lua VM, one OS thread*.

### Key scheme

- **CompletionKey (ULONG_PTR per file)**: identifies the socket. We
  set it at `iocp.attach(sock, key)` time. Since x86 is 32-bit, key
  is `ULONG`. We use the `lightuserdata`-ish trick: each socket gets a
  small dense integer index (1, 2, 3...) into the loop's socket table.
  The integer is stable for the socket's lifetime.

- **ApcContext (PVOID per IRP)**: identifies the operation. We pass
  the address of a per-call `OPERATION` cdata that holds the
  `IO_STATUS_BLOCK`, the user's buffer, and a back-pointer to the
  waiting coroutine. The scheduler casts the `ApcContext` it gets from
  `NtRemoveIoCompletion` back to that `OPERATION*`, picks up the
  coroutine, resumes it with whatever `iosb` says.

  GC concern: the `OPERATION` cdata MUST stay alive across the syscall
  boundary. We pin it in a Lua-side table keyed by its raw address
  until the completion is dequeued. `loop:_pending[op_addr] = op`,
  cleared in the dequeue handler.

### Yielding wrappers

`loop:recv(sock, n, [timeout])` shape:

```lua
function Loop:recv(sock, n, timeout)
    local op = self:_alloc_op(coroutine.running(), n)
    fs.NtReadFile_async(sock, op.buf, n, op)        -- no Event
    if timeout then
        self:_arm_timeout(op, timeout)
    end
    -- Coroutine yields here. The scheduler resumes it from the
    -- IoCompletion drain loop, having filled in op.iosb.
    coroutine.yield()
    self:_free_op(op)
    if op.iosb.Status == STATUS_CANCELLED then
        error{ fn = 'NtReadFile (timeout)', status = 0xC0000120 }
    end
    return ffi.string(op.buf, op.iosb.Information)
end
```

Mirrors of `send`, `connect` (IOCTL_TDI_CONNECT), `accept`, and a
non-IO `sleep(secs)` that posts a self-completion via
`NtSetIoCompletion` after the timer wheel fires.

### Driver loop

```lua
function Loop:run()
    while next(self._coroutines) do        -- spawned but not finished
        local timeout = self:_next_timer()  -- nil = infinite
        local key, apc, iosb = iocp.dequeue(self._port, timeout)
        if key == nil then
            -- Timeout: a scheduled timer is due; pop expired ones.
            self:_fire_due_timers()
        else
            local op = self._pending[apc]
            self._pending[apc] = nil
            op.iosb = iosb
            self:_resume(op.co)
        end
    end
end
```

`run` shape: **runs until all spawned coroutines finish.** A
`loop:run_forever()` variant can be added if needed; it differs only
in the loop predicate. (Asyncio-vs-tornado question; defaults to
"run-until-done" for ergonomics.)

### Timeout / cancellation

Per-op timeouts use a min-heap timer wheel. `_arm_timeout(op, secs)`
inserts `(deadline, op)`. The dequeue loop computes `_next_timer()`
to bound `iocp.dequeue`'s wait. When a timer fires before its IRP
completes, the scheduler:

1. Calls `NtCancelIoFile(op.sock, ...)`.
2. Lets the cancelled IRP arrive on the port (it WILL — that's the
   semantics; cancellation just hurries it along with
   `iosb.Status = STATUS_CANCELLED`).
3. Resumes the coroutine, which raises the same structured timeout
   error our blocking API does today.

This avoids the synchronous "drain via infinite wait" we do in the
blocking path — the scheduler's already in a loop draining the port.

### Coexistence with existing nt.afd

The blocking primitives (`afd.recv` / `afd.send` / `afd.connect` etc.)
stay as-is. They keep the per-IRP `Event` model and remain the right
choice for code that wants linear, non-coroutine semantics (tests,
quick scripts, init code). The reactor is **additive**.

A socket is "in IOCP mode" once `loop:attach(sock)` has been called.
After that, blocking calls on it would deadlock (the IRP completion
goes to the port, never the Event); the reactor APIs (`loop:recv`)
are mandatory. We can make this explicit by having `loop:attach`
flip a flag on the `NT_HANDLE` userdata, and have `afd.recv` raise
if the flag is set — saves a debugging session for the 47-th person
who mixes them up.

## Implementation plan (when we pick this up)

1. **`nt.dll.io`** (~80 lines):
   - cdef `NtCreateIoCompletion` / `NtRemoveIoCompletion` /
     `NtSetIoCompletion` / `FILE_COMPLETION_INFORMATION` /
     extra `IO_COMPLETION_INFORMATION_CLASS`.
   - Wrappers raise via `nt.errors` per the existing pattern.
   - Generic `NtSetInformationFile_completion(handle, port, key)`
     helper — keeps `nt.dll.fs.NtSetInformationFile` un-bloated.

2. **`nt.iocp`** (~50 lines):
   - `iocp.create([max_concurrent])` returns `NT_HANDLE`.
   - `iocp.attach(file_handle, key)` — wraps the
     `FileCompletionInformation` set.
   - `iocp.dequeue(port, timeout_secs)` returns
     `(key, apc_context_lightud, iosb_cdata)` or `nil` on timeout.
   - `iocp.post(port, key, apc_context, status, information)` for
     scheduler self-wakeups.

3. **`nt.afd` async-aware tweak** (~30 lines):
   - Internal `read_io` / `write_io` / `ioctl` already accept a
     `timeout_secs`; add an `op` parameter that, when non-nil,
     means "use this `op` cdata as `ApcContext` and skip the Event".
   - Add `afd.attach_iocp(sock, port, key)` thin convenience wrapper.

4. **`nt.loop`** (~250 lines):
   - `Loop` metatable with `spawn`, `run`, `stop`, `sleep`, `recv`,
     `send`, `connect`, `accept`, `attach`.
   - Per-op cdata struct: `{ IO_STATUS_BLOCK iosb; void *buf; void *_pad; }`
     plus a Lua-side wrapper table holding the coroutine and deadline.
   - Timer heap (binary min-heap suffices; <100 LoC).
   - `_resume` handles coroutine errors → propagates to `_uncaught`
     (default: `print(traceback)`; user-overridable).

5. **Tests** in `src/cr/lua/test/loop.lua`:
   - **Concurrent UDP loopback**: spawn 4 coroutines, each does a
     ping/pong on its own socket pair; verify all 4 finish.
   - **Concurrent DNS**: spawn 8 DNS queries against 8.8.8.8; verify
     all return + their IDs match.
   - **Timeout**: connect to a black-hole port with 1s timeout;
     scheduler must continue serving other coroutines unimpeded
     during the wait.
   - **Sleep**: spawn coroutine that sleeps 100ms then resolves; pump
     scheduler; assert the wake-up time is within ~10ms of expected.

## Open questions

- **Should `afd.tcp()` / `afd.udp()` open files with
  `FILE_SYNCHRONOUS_IO_NONALERT` removed by default already?** They
  do today (the async timeout work flipped this). So sockets are
  ready for IOCP attachment without re-opening — good.

- **`NtSetIoCompletion` for cross-coroutine signalling.** The
  scheduler can use a fixed sentinel key (e.g. `0`) for
  manually-posted wakeups (timer-fire, `loop:stop()`); reserve
  socket keys to start at 1. Cleaner than mixing.

- **Per-op cdata lifetime.** Pinning by raw address in a Lua table
  is the cleanest pattern. We need to make sure `ffi.cast('PVOID', op)`
  produces a stable address — true for `ffi.new(struct)` allocations,
  not for VLAs. Use a fixed-size struct.

- **Does cancellation always produce a completion on the port?**
  Per the spec yes. Worth a focused test early on so the scheduler
  doesn't hang waiting for a cancelled IRP that never arrives.

- **Win32 socket compat layer**. Out of scope for v1; this is a
  Lua-native API. If LuaSocket portability is ever wanted, build it
  on top.
