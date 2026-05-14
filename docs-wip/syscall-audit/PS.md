# Syscall audit — PS (Process structure)

22 syscalls.  See 
[`README.md`](README.md) for legend, class definitions, and the
rationale for the N/A pre-fills.

## NtAlertResumeThread

Source: [`PS/PSSPND.C`](../../src/NT/PRIVATE/NTOS/PS/PSSPND.C) · service #4

References the target thread for `THREAD_SUSPEND_RESUME`,
calls `KeAlertResumeThread` (kernel-side helper), optionally
writes back the previous suspend count.

- [x] C1 Probe-then-deref TOCTOU — `PreviousSuspendCount` ULONG
  probed + written inside `__try`.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output writes inside try.
- [x] C4 Length-field trust — no length-bearing parameter.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `THREAD_SUSPEND_RESUME` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — scalar
  `PreviousSuspendCount` writeback.
- [x] C11 Reference-count discipline under error paths — thread
  derefed on every branch.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtAlertThread

Source: [`PS/PSSPND.C`](../../src/NT/PRIVATE/NTOS/PS/PSSPND.C) · service #5

References the thread for `THREAD_SUSPEND_RESUME`, calls
`KeAlertThread`.

- [x] C1 Probe-then-deref TOCTOU — no user pointers in body.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — no user-memory access.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `THREAD_SUSPEND_RESUME` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtCreateProcess

Source: [`PS/CREATE.C`](../../src/NT/PRIVATE/NTOS/PS/CREATE.C) · service #26

Full process-creation syscall in `CREATE.C:671`.  Probes the
output `ProcessHandle`, captures `SectionHandle`/`DebugPort`/
`ExceptionPort`/`ParentProcess`, allocates `EPROCESS`, initializes
its VA space, attaches token, inserts handle.

- [x] C1 Probe-then-deref TOCTOU — output probed, optional handles
  by-value scalars (validated via ObReference downstream).
- [x] C2 Direct user-pointer deref without capture — none beyond
  output handle.
- [x] C3 Missing `__try` wrap — output writes inside try.
- [x] C4 Length-field trust — no length-bearing parameter.
- [x] C5 Integer overflow in size computation — `EPROCESS`-sized
  pool block; per-section quotas applied via section refs.
- [x] C6 Semantic validation gaps — `ParentProcess` validated as
  process; `SectionHandle` (optional) as a section.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Process body + VAD tree + page-directory non-paged
    allocations; bounded by per-process quotas inherited from
    the parent.
- [x] C10 Uninitialized output / pool-contents leak — `HANDLE` only;
  `EPROCESS` body initialised field-by-field.
- [x] C11 Reference-count discipline under error paths — **finding (minor)** *(closed: P1 handle-leak sweep)*
  - Same output-handle-leak shape: `*ProcessHandle = Handle`
    write fault leaves the process inserted but its handle name
    un-communicated.  Self-inflicted DoS — the orphan handle
    also keeps the new process pinned until the caller exits.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- C13 Cancel / completion-routine races — N/A

---

## NtCreateThread

Source: [`PS/CREATE.C`](../../src/NT/PRIVATE/NTOS/PS/CREATE.C) · service #31

Thin wrapper around `PspCreateThread` (`CREATE.C:60`).  Probes
output `ThreadHandle`, optional `ClientId`, mandatory
`ThreadContext` for read, `InitialTeb` for read.  Delegates.

- [x] C1 Probe-then-deref TOCTOU — probes inside try at `:114-128`.
- [x] C2 Direct user-pointer deref without capture — `ThreadContext`
  and `InitialTeb` captured by `PspCreateThread`.
- [x] C3 Missing `__try` wrap — probes inside try.
- [x] C4 Length-field trust — fixed-size structs.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `ProcessHandle` validated
  (`PROCESS_CREATE_THREAD`); `CONTEXT.ContextFlags` filtered
  by `KeContextToKframes` downstream.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - `ETHREAD` + kernel-stack pool block; size kernel-derived.
- [x] C10 Uninitialized output / pool-contents leak — `HANDLE` +
  optional `ClientId` writeback.
- [ ] C11 Reference-count discipline under error paths
  - Same output-handle-leak shape lives in `PspCreateThread`
    where the `*ThreadHandle = Handle` write happens.  Audit
    deferred to that helper.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` + `CLIENT_ID` (pid/tid pair, not pointers).
- C13 Cancel / completion-routine races — N/A

---

## NtGetContextThread

Source: [`PS/PSCTX.C`](../../src/NT/PRIVATE/NTOS/PS/PSCTX.C) · service #52

Asks a target thread (possibly running) for its current
`CONTEXT`.  References the thread for `THREAD_GET_CONTEXT`,
allocates a `GETSETCONTEXT` work-block from non-paged pool,
queues a kernel APC against the target thread to capture its
state, waits on `OperationComplete`, then copies the captured
context back to user.

- [x] C1 Probe-then-deref TOCTOU — `ThreadContext->ContextFlags`
  captured at `PSCTX.C:102` inside try.
- [x] C2 Direct user-pointer deref without capture — `ContextFlags`
  into local; full `CONTEXT` copied via `RtlMoveMemory` at
  `:175` inside its own try.
- [x] C3 Missing `__try` wrap — both accesses inside try blocks.
- [x] C4 Length-field trust — fixed `CONTEXT` size.
- [x] C5 Integer overflow in size computation — fixed size.
- [x] C6 Semantic validation gaps — `THREAD_GET_CONTEXT` access;
  system threads rejected at `:88`.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - `sizeof(GETSETCONTEXT)` non-paged pool per call — fixed
    size.  Quota debited.
- [ ] C10 Uninitialized output / pool-contents leak
  - `KeContextToKframes` (called inside the APC) writes only
    fields requested by `ContextFlags`.  Fields *not*
    requested are left untouched.  Since `Ctx->Context` lives
    in a fresh pool allocation that is **not zero-initialized
    by `ExAllocatePoolWithQuota`**, unrequested-field bytes
    leak whatever was in that pool slot to user.
  - Confirmed by inspection: the only zero-init at `:95` is
    `RtlZeroMemory(&Ctx, sizeof(Ctx))` which zeros the
    **pointer variable** (4 bytes), not the buffer.  Typo;
    intent was probably `RtlZeroMemory(Ctx, sizeof(*Ctx))`
    after the alloc.
  - Fix shape: zero the `Ctx->Context` block after allocation
    (or use `ExAllocatePoolWithQuotaTag`'s zero-init variant).
- [x] C11 Reference-count discipline under error paths — **finding (minor)** *(closed: P1 handle-leak sweep)*
  - The user-write fault path at `:174-180` returns
    `STATUS_SUCCESS` even when the write faulted.  Caller
    can't tell the data didn't reach the user buffer.  Same
    data-loss shape as `NtRemoveIoCompletion` but less
    consequential (the context state isn't consumed, just
    snapshotted).
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - C10 above also reaches C12 — leaked pool bytes can contain
    kernel pointers.  Tracked together.
- C13 Cancel / completion-routine races — N/A

---

## NtImpersonateThread

Source: [`PS/PSIMPERS.C`](../../src/NT/PRIVATE/NTOS/PS/PSIMPERS.C) · service #55

References two thread handles (server thread + target client
thread), captures the optional `SECURITY_QUALITY_OF_SERVICE`,
uses `PsImpersonateClient` to put the target's token onto the
server thread's impersonation slot.

- [x] C1 Probe-then-deref TOCTOU — `SecurityQos` captured inside
  try.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — captures inside try.
- [x] C4 Length-field trust — fixed SQOS struct.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `THREAD_DIRECT_IMPERSONATION`
  access on server; `THREAD_IMPERSONATE` on client.  SQOS
  impersonation level checked.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths — both
  threads dereffed.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtOpenProcess

Source: [`PS/PSOPEN.C`](../../src/NT/PRIVATE/NTOS/PS/PSOPEN.C) · service #73

Probes the output `ProcessHandle`, optional `ObjectAttributes`,
optional `ClientId`.  Calls `PsLookupProcessByProcessId` (when
`ClientId` provided) or `ObOpenObjectByName` (when name
provided).  Writes handle on success.

- [x] C1 Probe-then-deref TOCTOU — probes inside try at
  `PSOPEN.C:~50`.
- [x] C2 Direct user-pointer deref without capture — `ClientId`
  captured into local.
- [x] C3 Missing `__try` wrap — probes inside try.
- [x] C4 Length-field trust — fixed `CLIENT_ID`.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — must pass exactly one of
  `ClientId.UniqueProcess` or `ObjectAttributes->ObjectName`.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — `HANDLE` only.
- [x] C11 Reference-count discipline under error paths — **finding (minor)** *(closed: P1 handle-leak sweep)*
  - Same output-handle-leak shape as the other Open* siblings.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- C13 Cancel / completion-routine races — N/A

---

## NtOpenThread

Source: [`PS/PSOPEN.C`](../../src/NT/PRIVATE/NTOS/PS/PSOPEN.C) · service #78

Mirror of `NtOpenProcess` for threads.  Same pattern; same
output-handle-leak shape.

- [x] C1 Probe-then-deref TOCTOU — probes inside try.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — probes inside try.
- [x] C4 Length-field trust — fixed structs.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — must pass exactly one of
  `ClientId` or name.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — `HANDLE` only.
- [x] C11 Reference-count discipline under error paths — **finding (minor)** *(closed: P1 handle-leak sweep)*
  - Same output-handle-leak shape.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- C13 Cancel / completion-routine races — N/A

---

## NtQueryInformationProcess

Source: [`PS/PSQUERY.C`](../../src/NT/PRIVATE/NTOS/PS/PSQUERY.C) · service #93

Probes output buffer for per-class fixed size, references the
target process, fills the per-class struct.  ~12 info classes
including `ProcessBasicInformation`, `ProcessIoCounters`,
`ProcessVmCounters`, `ProcessSessionInformation`,
`ProcessDebugPort`, etc.

- [x] C1 Probe-then-deref TOCTOU — single probe at top.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output writes inside per-class try.
- [x] C4 Length-field trust — `ProcessInformationLength` checked
  against per-class minimum.
- [x] C5 Integer overflow in size computation — fixed per-class.
- [x] C6 Semantic validation gaps — `PROCESS_QUERY_INFORMATION`
  access for most classes; some require `PROCESS_QUERY_LIMITED_INFORMATION`-
  equivalent (NT 3.5 has only the broad mask).
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [ ] C10 Uninitialized output / pool-contents leak
  - Most arms populate struct fields explicitly; some classes
    (e.g. `ProcessVmCounters`) copy from `EPROCESS` counters
    that include padding bytes between counters.  Per-class
    audit needed.
- [x] C11 Reference-count discipline under error paths — process
  derefed on every branch.
- [ ] C12 Kernel-address / kernel-pointer leak via info classes — **finding**
  - `ProcessBasicInformation.PebBaseAddress` — user-space VA of
    PEB, legitimate.
  - `ProcessDebugPort` returns the debug port `HANDLE` —
    opaque token, OK.
  - **`ProcessHandleCount`-style counts** — fine.
  - `ProcessImageFileName` (if implemented) returns file-path
    metadata — user-space, OK.
  - Several internal info classes in NT 3.5 (`ProcessLdtInformation`,
    `ProcessWow64Information`) may return kernel-derived
    structure offsets that act as a fingerprinting primitive,
    though not direct pointers.
  - Defer per-class C12 sweep until pattern-first restructure;
    flag here.
- C13 Cancel / completion-routine races — N/A

---

## NtQueryInformationThread

Source: [`PS/PSQUERY.C`](../../src/NT/PRIVATE/NTOS/PS/PSQUERY.C) · service #94

Mirror of `NtQueryInformationProcess` for threads.  ~9 info
classes including `ThreadBasicInformation`, `ThreadTimes`,
`ThreadDescriptorTableEntry`.

- [x] C1 Probe-then-deref TOCTOU — single probe at top.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output writes inside try.
- [x] C4 Length-field trust — per-class size validated.
- [x] C5 Integer overflow in size computation — fixed per-class.
- [x] C6 Semantic validation gaps — `THREAD_QUERY_INFORMATION` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [ ] C10 Uninitialized output / pool-contents leak — same per-
  class padding concern as `NtQueryInformationProcess`.
- [x] C11 Reference-count discipline under error paths.
- [ ] C12 Kernel-address / kernel-pointer leak via info classes
  - `ThreadBasicInformation.TebBaseAddress` is a user VA.
  - `ThreadDescriptorTableEntry` returns a captured `LDT_ENTRY`
    — bounded but per-class audit warranted.
- C13 Cancel / completion-routine races — N/A

---

## NtRegisterThreadTerminatePort

Source: [`PS/PSDELETE.C`](../../src/NT/PRIVATE/NTOS/PS/PSDELETE.C) · service #118

References a port handle, attaches it to the current thread's
TLS so the kernel sends termination notifications via that port
when the thread exits.

- [x] C1 Probe-then-deref TOCTOU — no user pointers.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — no user-memory access.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — port handle validated.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Each registration is a small fixed allocation per thread;
    bounded by thread count.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths — port ref
  released on thread-exit; symmetric.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtReleaseProcessMutant

Source: [`PS/CREATE.C`](../../src/NT/PRIVATE/NTOS/PS/CREATE.C) · service #120

Internal mutant release (used by Win32 subsystem startup).
References the process by handle, releases its mutant.

- [x] C1 Probe-then-deref TOCTOU — no user pointers.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — no user-memory access.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — process handle validated.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtResumeThread

Source: [`PS/PSSPND.C`](../../src/NT/PRIVATE/NTOS/PS/PSSPND.C) · service #131

Mirror of `NtSuspendThread`.  Decrements suspend count, wakes
the thread if count hits zero.

- [x] C1 Probe-then-deref TOCTOU — optional `PreviousSuspendCount`
  ULONG probed + written inside try.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output inside try.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `THREAD_SUSPEND_RESUME` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — `ULONG` only.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtSetContextThread

Source: [`PS/PSCTX.C`](../../src/NT/PRIVATE/NTOS/PS/PSCTX.C) · service #133

Mirror of `NtGetContextThread`.  Reads user `CONTEXT`,
copies into a pool work-block, queues an APC against the target
thread to apply it.

- [x] C1 Probe-then-deref TOCTOU — probes inside try at `:252`.
- [x] C2 Direct user-pointer deref without capture — `CONTEXT`
  copied to pool block.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — fixed `CONTEXT` size.
- [x] C5 Integer overflow in size computation — fixed size.
- [x] C6 Semantic validation gaps — `THREAD_SET_CONTEXT` access;
  system threads rejected.  `ContextFlags` filtered by
  `KeContextFromKframes` (the inverse of the get path's
  filter); invalid bits ignored.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - `sizeof(GETSETCONTEXT)` per call; fixed.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths
  - Same `RtlZeroMemory(&Ctx, sizeof(Ctx))` "zeros the pointer
    variable, not the buffer" typo at `:246` — but here it
    doesn't matter because the immediately-following
    `RtlMoveMemory(&Ctx->Context, ThreadContext, sizeof(CONTEXT))`
    at `:255` overwrites every byte of the context block from
    user input.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtSetInformationProcess

Source: [`PS/PSQUERY.C`](../../src/NT/PRIVATE/NTOS/PS/PSQUERY.C) · service #144

Mirror of `NtQueryInformationProcess` for set operations.  Probes
input `ProcessInformation` for per-class size, references process,
applies the change.  Most classes require
`PROCESS_SET_INFORMATION`.

- [x] C1 Probe-then-deref TOCTOU — input copied to local per class.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — accesses inside per-class try.
- [x] C4 Length-field trust — per-class size validated.
- [x] C5 Integer overflow in size computation — fixed per-class.
- [x] C6 Semantic validation gaps — per-class privilege
  requirements (`SeTcbPrivilege` for some classes like
  `ProcessSessionInformation`).
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtSetInformationThread

Source: [`PS/PSQUERY.C`](../../src/NT/PRIVATE/NTOS/PS/PSQUERY.C) · service #145

Mirror of `NtQueryInformationThread` for set operations.

- [x] C1 Probe-then-deref TOCTOU — input copied to local per class.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — accesses inside per-class try.
- [x] C4 Length-field trust — per-class size validated.
- [x] C5 Integer overflow in size computation — fixed per-class.
- [x] C6 Semantic validation gaps — `THREAD_SET_INFORMATION` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtSetLdtEntries

Source: [`PS/I386/PSLDT.C`](../../src/NT/PRIVATE/NTOS/PS/I386/PSLDT.C) · service #148

Modifies LDT entries for the calling process.  Architecture-
specific (`PS/I386/PSLDT.C`).  Probes ULONG indices and
descriptor pairs.

- [x] C1 Probe-then-deref TOCTOU — descriptors captured into locals.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — entry counts are ULONG by-value.
- [x] C5 Integer overflow in size computation — entry slot
  indices range-checked.
- [x] C6 Semantic validation gaps — descriptors validated for
  ring-3-only (no privilege escalation via LDT entries).
  `Type` field's high bits checked.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - LDT allocation bounded by max LDT size (~64KB).
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtSuspendThread

Source: [`PS/PSSPND.C`](../../src/NT/PRIVATE/NTOS/PS/PSSPND.C) · service #163

Increments suspend count, halts the thread.

- [x] C1 Probe-then-deref TOCTOU — optional `PreviousSuspendCount`
  ULONG probed + written inside try.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output inside try.
- [x] C4 Length-field trust — none.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `THREAD_SUSPEND_RESUME` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — `ULONG` only.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtTerminateProcess

Source: [`PS/PSDELETE.C`](../../src/NT/PRIVATE/NTOS/PS/PSDELETE.C) · service #165

Terminates all threads of the target process with the given
status.  References the process for `PROCESS_TERMINATE`.

- [x] C1 Probe-then-deref TOCTOU — no user pointers.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — no user-memory access.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `PROCESS_TERMINATE` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtTerminateThread

Source: [`PS/PSDELETE.C`](../../src/NT/PRIVATE/NTOS/PS/PSDELETE.C) · service #166

Terminates the target thread.  References for
`THREAD_TERMINATE`.

- [x] C1 Probe-then-deref TOCTOU — no user pointers.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — no user-memory access.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `THREAD_TERMINATE` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtTestAlert

Source: [`PS/PSSPND.C`](../../src/NT/PRIVATE/NTOS/PS/PSSPND.C) · service #167

Checks the current thread's alert flag, raises
`STATUS_ALERTED` if set.  No arguments, no user-memory access.

- [x] C1 Probe-then-deref TOCTOU — no input.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — no access.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — none needed.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths — no refs.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtWaitForProcessMutant

Source: [`PS/CREATE.C`](../../src/NT/PRIVATE/NTOS/PS/CREATE.C) · service #176

Internal mutant wait (Win32 subsystem startup).  Waits on the
process's mutant object.

- [x] C1 Probe-then-deref TOCTOU — optional `Timeout` captured.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — inside try.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — process handle validated.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## Fix-scope summary across PS

### Root-cause groups

1. **Output-handle leak (5 syscalls)** — `NtCreateProcess`,
   `NtCreateThread` (via `PspCreateThread`), `NtOpenProcess`,
   `NtOpenThread`.  Same shape as OB/SE/IO/MM siblings.

2. **`NtGetContextThread` C10 + C12** — `GETSETCONTEXT` pool
   block is allocated without zeroing.  `KeContextToKframes`
   only writes fields requested by `ContextFlags`; unrequested
   fields leak pool-slot contents to user.  The `RtlZeroMemory(&Ctx,
   sizeof(Ctx))` at `PSCTX.C:95` zeros the **pointer variable**
   (4 bytes), not the buffer — typo; intent was `Ctx,
   sizeof(*Ctx)` after the alloc.
   - Triggering: open a thread for `THREAD_GET_CONTEXT`, call
     `NtGetContextThread` with `ContextFlags` cleared to skip
     most field categories.  The kernel skips writing those
     categories; user receives the uninitialized pool slot
     instead.  Per-CONTEXT-class kernel pool disclosure.

3. **`NtGetContextThread` user-write fault returns
   `STATUS_SUCCESS`** at `PSCTX.C:177-180` — when the final
   `RtlMoveMemory` to user faults, the function returns success
   with the user buffer unchanged.  Caller can't tell the data
   didn't arrive.  Data-loss shape similar to
   `NtRemoveIoCompletion` but less consequential (state wasn't
   consumed).

4. **`NtQueryInformationProcess` / `NtQueryInformationThread`
   per-class C10/C12 risk** — many info-class arms populate
   per-`EPROCESS` / per-`ETHREAD` counter structs that have
   padding between fields.  No defensive zero of the output
   struct before per-field population.  Same shape as
   `NtQueryVirtualMemory` (MM) C10 latent finding.

### Fix shape

1. **Output-handle leak** — same one-line `NtClose(Handle)`
   cleanup as elsewhere.  5 sites (delegating to
   `PspCreateThread` for the Create variants).

2. **`NtGetContextThread` C10 fix** — replace `:95-96` with:
   ```c
   Ctx = ExAllocatePoolWithQuota(NonPagedPool, sizeof(GETSETCONTEXT));
   if (Ctx) RtlZeroMemory(Ctx, sizeof(*Ctx));
   ```
   Closes the pool-disclosure side channel.  Same typo at
   `:246` in `NtSetContextThread` is benign (overwritten by
   the move) but the fix should be applied for hygiene.

3. **`NtGetContextThread` user-write fault** — the `except`
   at `:177-180` should set a status before falling through:
   ```c
   } except(...) {
       ExFreePool(Ctx);
       return GetExceptionCode();   // not STATUS_SUCCESS
   }
   ```
   Caller learns about the failed delivery and can re-query.

4. **Per-class info-class C10 sweep** — defensive
   `RtlZeroMemory(&info, sizeof(info))` at the top of each
   info-class arm in `NtQueryInformationProcess` /
   `NtQueryInformationThread`.  ~12 small edits.

### Clean classes

The rest of PS is clean.  Suspend/Resume/Alert/Terminate/Test
syscalls are minimal HANDLE-by-value bodies.  Refcount
discipline is consistent across the family.  No C5 wraps
introduced in PS.

### Cross-references

- `NtSetLdtEntries` — `SeTcbPrivilege` or similar gate on
  per-descriptor `Type` bits.  Worth confirming during the
  `KERNEL-ABI-HARDENING.md` Class 6 sweep.
- The `GETSETCONTEXT` typo (4-byte zero of pointer variable
  instead of buffer body) appears twice in `PSCTX.C`.  Worth
  a grep across the tree for the same `RtlZeroMemory(&ptr,
  sizeof(ptr))` shape elsewhere.
