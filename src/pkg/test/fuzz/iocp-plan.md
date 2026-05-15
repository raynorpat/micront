# IOCP test suite — plan

Verifies the **P9** fix in `src/NT/PRIVATE/NTOS/IO/COMPLETE.C`
(`NtRemoveIoCompletion` data-loss on user-write fault). See
`docs-wip/syscall-audit/{IO,SUMMARY}.md` for the finding; the IOCP
*implementation* roadmap is tracked separately.

## The constraint that shapes everything

NT 3.5 has **no `NtSetIoCompletion`** — you cannot push a synthetic entry
onto a port. The only way an entry arrives is real async I/O on a handle
associated with the port (`NtSetInformationFile` +
`FileCompletionInformation`). So the success path, the FIFO round-trip, and
the P9 re-queue arm are unreachable until a real completion *source* exists;
only the error/timeout paths can be tested without one.

## Two API surfaces

- `test/*.lua` drives the Lua-idiomatic wrappers — `ex.iocompletion`
  (`nt/dll/ex.lua`) with `:depth()` / `:remove()`. This is the happy-path
  surface real callers use.
- `test/fuzz/*.lua` drops to raw `ntdll.Nt*` calls so it can hand the kernel
  deliberately malformed pointers, handles and timeouts the idiomatic wrapper
  would never construct. Mirrors `test/fuzz/se.lua`.

## `NtRemoveIoCompletion` codepaths and how to reach each

| Path | Trigger | Phase |
|------|---------|-------|
| Outer probe fault | bad `Key`/`Apc`/`IoStatusBlock` pointer | 1 |
| `ObReferenceObjectByHandle` fail | bad / wrong-type / under-privileged handle | 1 |
| `KeRemoveQueue` → `STATUS_TIMEOUT` | empty port + timeout | 1 (anchor) |
| `KeRemoveQueue` → `STATUS_USER_APC` | APC to a blocked thread | deferred (2nd thread) |
| Success: capture + write + `IoFreeIrp` | real completion on the port | 2 |
| **P9** `except` arm: re-queue + `GetExceptionCode` | completion present + output write faults (TOCTOU) | 3b |

## Roadmap — 4 phases

Each phase ends by isolating its suites in `selftest.lua` so the operator can
run `make selftest`, confirm green, and give feedback **before** the next
phase begins.

### Phase 1 — no completion source *(done — verified)*

`test/fuzz/iocp.lua`: raw-`ntdll` fuzz of the paths reachable with an empty
port — outer probe fault on each `NtRemoveIoCompletion` OUT pointer,
handle-reference failure (NULL / stale / wrong-type / missing
`IO_COMPLETION_MODIFY_STATE`), the empty-port `STATUS_TIMEOUT` anchor, and the
same probe-fault sweep on `NtQueryIoCompletion`. Invariant: every malformed
call returns a clean NTSTATUS and never bugchecks.

### Phase 2 — async file read as the completion source

The completion source: create a scratch file, write a known payload, re-open
it *without* `FILE_SYNCHRONOUS_IO`, associate it with the port
(`NtSetInformationFile` + `FILE_COMPLETION_INFORMATION`), and issue an
`NtReadFile` with an explicit `ByteOffset` **and a non-NULL `ApcContext`** —
the kernel only queues a port packet when `ApcContext` is non-NULL
(`INTERNAL.C:998`). Lives in `test/iosrc.lua`; the association wrapper is
`fs.set_completion_port` in `nt/dll/fs.lua`.

**Phase 2a — success path + FIFO round-trip** *(done — verified)*.
`test/sync.lua`, idiomatic surface: remove an entry, assert `KeyContext` =
association key, `ApcContext` = the read's cookie, `IoStatusBlock` = the read
result; queue several, assert FIFO drain order; `depth()` returns to 0.
Surfaced the P13 kernel bug (`IopSetOperationAccess` off-by-one — see SUMMARY).

**Phase 2b — P9 re-queue arm: no standalone test.** The P9 inner `except`
arm re-queues the IRP when a user-buffer write faults. That arm is **not
reachable single-threaded**: on i386 `ProbeForWriteLong` /
`ProbeForWriteIoStatus` (`COMPLETE.C:487-490`) touch *exactly* the bytes the
inner write touches, so a static bad page is caught by the probe itself — the
arm fires only under a TOCTOU race (a concurrent thread re-protecting the
output buffer between probe and write). A precisely-timed racy test would be
flaky and usually inconclusive. **Resolution:** the deterministic 2a tests
already guard the reorder (writes-before-`IoFreeIrp` — the regression-prone
half of the fix); the re-queue arm itself is exercised as a byproduct of
Phase 3's load test, whose bad-buffer injector produces genuine faulted
removes under real concurrency.

### Phase 3 — multi-threaded concurrency

`cr_thread` (exposed as `nt.thread`) gives each spawned consumer its own
`lua_State` on its own OS thread; NT handles are per-process, so the port
HANDLE is shared by value through the thread `PAYLOAD`. This unlocks the real
test of an IOCP port — the crux of the subsystem.

**Phase 3a — N×K drain race** *(done — implemented)*. `test/iocp.lua`:
produce N completions with distinct cookies (file source), spawn K consumer
threads each looping `:remove()`, join them, and assert the drained cookies
form an exact partition of 1..N — every completion consumed exactly once, no
loss, no duplication. The `KeRemoveQueue` concurrency invariant.

**Phase 3b — concurrent production + fault injection** *(implemented)*.
`test/iocp.lua`: the producer (main thread) feeds N completions while K
consumer threads drain, and the even-indexed consumers issue a faulting
remove (kernel-range `IoStatusBlock`) before each real drain attempt. A faulting remove is caught by
`COMPLETE.C`'s outer probe before `KeRemoveQueue` dequeues anything, so it
consumes no entry — the test asserts the invariant holds regardless: every
produced completion consumed exactly once (no loss, no duplication), plus a
check that the injector actually faulted some removes. This is the security
property P9 is about; it does **not** single out the P9 inner re-queue arm
(TOCTOU-only and userspace-indistinguishable — see Phase 2b). Producers are
not separate threads: a producer thread would have to keep its async-read
buffers alive until completion, so the main thread owns the one source.

The afd-socket second source from the original plan is dropped — a second
single-threaded source adds little once real concurrency is covered here.

### Phase 4 — named pipe (npfs)

Bind `NtCreateNamedPipeFile` (currently unbound — see the TODO list at the
foot of `nt/dll/fs.lua`) and build a Lua-idiomatic named-pipe interface over
npfs. Fully self-contained completion source (own both ends, write-then-read).
The named-pipe API is a deliverable in its own right, useful beyond IOCP.

## Deferred

`STATUS_USER_APC` path — block a thread in `:remove()`, `NtQueueApcThread` a
user APC to it, assert the status. Needs a second thread; low priority.
