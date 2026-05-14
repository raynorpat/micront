# Syscall audit — IO (I/O manager)

28 syscalls.  See 
[`README.md`](README.md) for legend, class definitions, and the
rationale for the N/A pre-fills.

## NtCancelIoFile

Source: [`IO/MISC.C`](../../src/NT/PRIVATE/NTOS/IO/MISC.C) · service #8

Probes the output `IoStatusBlock`, references the file handle,
acquires the file-object lock if `FO_SYNCHRONOUS_IO`, walks the
current thread's `IrpList` at `APC_LEVEL` cancelling IRPs whose
`OriginalFileObject` matches.  Polls (10ms delay) until matched
IRPs have completed.

- [x] C1 Probe-then-deref TOCTOU — `IoStatusBlock` probed once at
  `:104`, written at `:291-292` inside `__try`.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — all user writes inside try.
- [x] C4 Length-field trust — no length-bearing parameter.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — file handle validated by
  `ObReferenceObjectByHandle` (no specific access required).
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — no
  user-sized allocation in body.
- [x] C10 Uninitialized output / pool-contents leak — output is a
  fixed `IO_STATUS_BLOCK` with both fields explicitly written.
- [x] C11 Reference-count discipline under error paths
  - `ObDereferenceObject(fileObject)` on every exit
    (`:151`, `:325`).  File object lock released at `:318` when
    sync.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — no
  kernel pointers in output.
- [ ] C13 Cancel / completion-routine races
  - This syscall *is* the cancel entry point.  Polls the IRP
    list at `APC_LEVEL` and re-checks every 10ms; the cancel
    completion is the responsibility of the per-driver cancel
    routine (`IoCancelIrp` → driver's `CancelRoutine`).  Race
    safety of those routines belongs to each driver's own
    audit.

---

## NtCreateFile

Source: [`IO/CREATE.C`](../../src/NT/PRIVATE/NTOS/IO/CREATE.C) · service #18

Thin wrapper around `IoCreateFile` with
`CreateFileTypeNone` / no extra parameters.  All probe + capture
discipline lives in `IoCreateFile` (`IOSUBS.C` / `IOINIT.C`).
Audit deferred to that helper.

- [ ] C1 Probe-then-deref TOCTOU — see `IoCreateFile`.
- [ ] C2 Direct user-pointer deref without capture — see helper.
- [ ] C3 Missing `__try` wrap — see helper.
- [ ] C4 Length-field trust — `EaLength` capped against
  `MAXIMUM_EA_SIZE` inside the helper (verify).
- [ ] C5 Integer overflow in size computation — see helper.
- [ ] C6 Semantic validation gaps — see helper.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation —
  `EaLength` user-controlled.  See helper for upper bound.
- [ ] C10 Uninitialized output / pool-contents leak — see helper.
- [ ] C11 Reference-count discipline under error paths — see helper.
- [ ] C12 Kernel-address / kernel-pointer leak via info classes —
  output is a `HANDLE`.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtCreateIoCompletion

Source: [`IO/COMPLETE.C`](../../src/NT/PRIVATE/NTOS/IO/COMPLETE.C) · service #19

Single big `try` block wrapping the probe + `ObCreateObject` +
`KeInitializeQueue` + `ObInsertObject` + `*Handle` write.  The
nested `try` at `:140-145` writes the handle with `NOTHING` in
its `except`.

- [x] C1 Probe-then-deref TOCTOU — only output write.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output inside try.
- [x] C4 Length-field trust — no length-bearing parameter.
- [x] C5 Integer overflow in size computation — fixed-size
  `KQUEUE` object.
- [x] C6 Semantic validation gaps — `Count` parameter clamped
  inside `KeInitializeQueue` (defaults to processor count when 0).
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation —
  fixed-size object.
- [x] C10 Uninitialized output / pool-contents leak — `HANDLE` only.
- [x] C11 Reference-count discipline under error paths — **finding (minor)** *(closed: P1 handle-leak sweep)*
  - Same handle-leak shape as the SE / OB Open*/Create* siblings:
    `*IoCompletionHandle = Handle` write fault at `:140-145`
    drops the handle name; the handle was already installed by
    `ObInsertObject` at `:124`.  Self-inflicted DoS.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- C13 Cancel / completion-routine races — N/A

---

## NtCreateMailslotFile

Source: [`IO/CREATE.C`](../../src/NT/PRIVATE/NTOS/IO/CREATE.C) · service #21

Thin wrapper around `IoCreateFile` with
`CreateFileTypeMailslot` and a `MAILSLOT_CREATE_PARAMETERS` blob.
The `ReadTimeout` `PLARGE_INTEGER` is captured via
`ProbeAndReadLargeInteger` inside a local `__try` before the
delegation.  Other user-pointer handling lives in `IoCreateFile`.

- [x] C1 Probe-then-deref TOCTOU — `ReadTimeout` captured under
  try.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — `ReadTimeout` access inside try.
- [ ] C4 Length-field trust — see `IoCreateFile`.
- [ ] C5 Integer overflow in size computation — see helper.
- [ ] C6 Semantic validation gaps — see helper.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation — see helper.
- [ ] C10 Uninitialized output / pool-contents leak — see helper.
- [ ] C11 Reference-count discipline under error paths — see helper.
- [ ] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtCreateNamedPipeFile

Source: [`IO/CREATE.C`](../../src/NT/PRIVATE/NTOS/IO/CREATE.C) · service #23

Thin wrapper around `IoCreateFile` with
`CreateFileTypeNamedPipe` and a `NAMED_PIPE_CREATE_PARAMETERS`
blob.  `DefaultTimeout` captured via `ProbeAndReadLargeInteger`
inside a local `__try`.  Other user-pointer handling lives in
`IoCreateFile`.

- [x] C1 Probe-then-deref TOCTOU — `DefaultTimeout` captured.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — capture inside try.
- [ ] C4 Length-field trust — `MaximumInstances` / `InboundQuota`
  / `OutboundQuota` are by-value ULONGs validated downstream.
- [ ] C5 Integer overflow in size computation — see helper.
- [ ] C6 Semantic validation gaps — `NamedPipeType` /
  `ReadMode` / `CompletionMode` enum values validated downstream.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - `InboundQuota` / `OutboundQuota` reserve pool for pipe
    instances.  See helper (NPFS driver) for upper bound.
- [ ] C10 Uninitialized output / pool-contents leak — see helper.
- [ ] C11 Reference-count discipline under error paths — see helper.
- [ ] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtDeleteFile

Source: [`IO/MISC.C`](../../src/NT/PRIVATE/NTOS/IO/MISC.C) · service #35

Builds an `OPEN_PACKET` with
`FILE_DELETE_ON_CLOSE` and `DeleteOnly=TRUE`, calls
`ObOpenObjectByName`.  The parse routine opens, recognises the
flag, immediately dereferences (triggering FS cleanup +
delete), and never returns a handle.

- [x] C1 Probe-then-deref TOCTOU — no user-memory access in
  this body; `ObjectAttributes` captured by `ObOpenObjectByName`.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — no user-memory deref.
- [x] C4 Length-field trust — no length parameter.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `DELETE` access required;
  validation in `ObOpenObjectByName` + parse routine.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output buffer.
- [x] C11 Reference-count discipline under error paths
  - Single helper call; no manual reference management at this
    layer.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  no output.
- C13 Cancel / completion-routine races — N/A (delete is
  synchronous within the syscall).

---

## NtDeviceIoControlFile

Source: [`IO/DEVCTRL.C`](../../src/NT/PRIVATE/NTOS/IO/DEVCTRL.C) · service #38

Thin wrapper around `IopXxxControlFile`
(`INTERNAL.C:4712`) with `DeviceIoControl=TRUE`.  The actual
probing, IRP construction, fast-IO dispatch, and buffer-method
handling all live in the helper.

- [x] C1 Probe-then-deref TOCTOU — `IoStatusBlock`,
  `InputBuffer`, `OutputBuffer` probed in one try at
  `INTERNAL.C:4817-4872`.
- [x] C2 Direct user-pointer deref without capture
  - Method 0: input copied into kernel system buffer
    (`RtlCopyMemory` at `INTERNAL.C:5170`).
  - Method 1/2: `IoAllocateMdl` + `MmProbeAndLockPages` pin
    the output buffer.
  - Method 3 (`METHOD_NEITHER`): driver-side responsibility —
    flagged in `KERNEL-ABI-HARDENING.md` Class 8.
- [x] C3 Missing `__try` wrap — all probes + copies inside try
  blocks; buffer pin paths handled with their own try at
  `INTERNAL.C:5220-5264`.
- [x] C4 Length-field trust — `InputBufferLength` /
  `OutputBufferLength` are by-value ULONGs captured at entry.
- [x] C5 Integer overflow in size computation
  - Method-0 alloc: `max(InputBufferLength, OutputBufferLength)`
    at `INTERNAL.C:5166-5167` — straight ternary, no multiply.
    Bounded by `MmUserProbeAddress` (≈ 2 GB).
- [x] C6 Semantic validation gaps
  - `IoControlCode`'s access-mask bits (`>> 14 & 3`) checked
    against the handle's `GrantedAccess` at
    `INTERNAL.C:4909-4926`.  **This check assumes the driver
    encoded the IOCTL with `CTL_CODE`** — see
    `KERNEL-ABI-HARDENING.md` Class 7 for the AFD
    `_AFD_CONTROL_CODE` macro that bypasses this gate by
    encoding `FILE_ANY_ACCESS` for everything.
  - `Event` handle (when present) validated for
    `EVENT_MODIFY_STATE` at `INTERNAL.C:4936-4948`.
  - `CompletionContext` and `ApcRoutine` mutual-exclusion check
    at `INTERNAL.C:4898-4901`.
- C7 IOCTL access-bit encoding — N/A *at the syscall layer*; the
  finding lives in the per-driver IOCTL macros (cross-ref
  `KERNEL-ABI-HARDENING.md`).
- C8 Output buffer aliasing / METHOD mismatch — N/A at this
  layer; per-driver.
- [ ] C9 Pool exhaustion via attacker-controlled allocation — **finding**
  - `INTERNAL.C:5166` allocates `max(InputBufferLength,
    OutputBufferLength)` from **NonPagedPoolCacheAligned** (the
    `poolType` at `:5141` for `DeviceIoControl=TRUE`).  Non-paged
    pool is the most precious pool type; lengths are
    user-controlled up to MmUserProbeAddress (~2 GB).
  - Quota tracking via `ExAllocatePoolWithQuota` debits the
    calling process — but a single 2 GB allocation in a worker
    process can drain non-paged pool before quota throttles it,
    affecting every other process on the system.
  - `INTERNAL.C:5083-5087` also has a `Long-term request` path
    that allocates the IRP itself from non-paged pool sized by
    `sizeof(IRP) + StackSize × sizeof(IO_STACK_LOCATION)` —
    bounded by driver-stack depth (small).
  - Fix shape: cap `InputBufferLength` / `OutputBufferLength` at
    a sane upper bound per device (the device object could
    advertise it via a new `DriverObject->Driver{Max,Pool}IoSize`
    field), or split very large transfers across multiple
    IRPs in the I/O manager.
- [x] C10 Uninitialized output / pool-contents leak
  - `ExAllocatePoolWithQuota` does not zero the allocation, but
    method 0 writes either `InputBufferLength` bytes (from user)
    or nothing — output write to user happens in I/O completion
    path from the driver, copying from the same system buffer.
    The driver is responsible for writing every byte it returns
    to user (modern Windows uses `ExAllocatePoolWithQuotaZeroTag`
    here; NT 3.5 doesn't).  Per-driver concern; flag during
    individual driver audits.
- [x] C11 Reference-count discipline under error paths — **finding (minor)** *(closed: P1 handle-leak sweep)*
  - **Fast-IO path inconsistency** at `INTERNAL.C:5025-5030`:
    after `FastIoDeviceControl` succeeds, `*IoStatusBlock =
    localIoStatus` writes inside a `__try`; the except records
    the AV into `localIoStatus.Status` but the IRP work
    already completed and the event was already signalled at
    `:5037`.  Caller receives `STATUS_ACCESS_VIOLATION` despite
    the operation having succeeded — soft inconsistency, not a
    leak.
  - Otherwise refcount discipline is meticulous: every error
    path goes through `IopAllocateIrpCleanup` /
    `IopExceptionCleanup` which release `eventObject` (if
    referenced) and `fileObject` and free the IRP / SystemBuffer.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  not at this layer; per-driver.
- [ ] C13 Cancel / completion-routine races
  - This syscall queues IRPs that can be cancelled by
    `NtCancelIoFile`.  Cancel-routine correctness is per-driver.

---

## NtFlushBuffersFile

Source: [`IO/MISC.C`](../../src/NT/PRIVATE/NTOS/IO/MISC.C) · service #45

Probes `IoStatusBlock`, references the file, requires
`FILE_APPEND_DATA` or `FILE_WRITE_DATA` access (or
`FILE_WRITE_DATA` only for named pipes), acquires the file lock
if sync, allocates IRP + optional sync event, dispatches
`IRP_MJ_FLUSH_BUFFERS`.

- [x] C1 Probe-then-deref TOCTOU — `IoStatusBlock` probed at
  `:473`, written by driver via the IRP.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — probe + write inside try.
- [x] C4 Length-field trust — no length parameter.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps
  - `FILE_APPEND_DATA | FILE_WRITE_DATA` access check at
    `:514-520` (named pipe gets only `FILE_WRITE_DATA`).
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Allocates `KEVENT` and IRP from non-paged pool when async —
    fixed-size, not user-controlled.
- [x] C10 Uninitialized output / pool-contents leak — `IO_STATUS_BLOCK`
  written by completion routine.
- [x] C11 Reference-count discipline under error paths
  - Every error path goes through `IopAllocateIrpCleanup` or
    explicit deref + free.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  no output buffer.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path;
  per-driver flush cancel semantics.

---

## NtFsControlFile

Source: [`IO/FSCTRL.C`](../../src/NT/PRIVATE/NTOS/IO/FSCTRL.C) · service #51

Thin wrapper around `IopXxxControlFile`
(`INTERNAL.C:4712`) with `DeviceIoControl=FALSE`.  Same findings
as `NtDeviceIoControlFile` *except*:

- `poolType` at `INTERNAL.C:5141` is **`NonPagedPool`** (not
  cache-aligned) — same precious-pool concern.
- `IRP_DEFER_IO_COMPLETION` flag is set at `INTERNAL.C:5285-5287`
  for FSCTL so file systems' pending-completion handling works
  correctly.
- The fast-IO dispatch path is not exercised (only
  `DeviceIoControl=TRUE` reaches the `FastIoDeviceControl`
  branch).

- [x] C1 Probe-then-deref TOCTOU — see `NtDeviceIoControlFile`.
- [x] C2 Direct user-pointer deref without capture — see sibling.
- [x] C3 Missing `__try` wrap — see sibling.
- [x] C4 Length-field trust — see sibling.
- [x] C5 Integer overflow in size computation — see sibling.
- [x] C6 Semantic validation gaps — see sibling (same
  `CTL_CODE`-driven access-mask check).
- C7 IOCTL access-bit encoding — N/A at this layer.
- C8 Output buffer aliasing / METHOD mismatch — N/A at this layer.
- [ ] C9 Pool exhaustion via attacker-controlled allocation — **finding**
  - Same non-paged pool exhaustion shape as
    `NtDeviceIoControlFile`.  FSCTL is reachable on any file
    handle (including `\Device\NamedPipe\…` and
    `\Device\Mailslot\…`).
- [x] C10 Uninitialized output / pool-contents leak — see sibling.
- [x] C11 Reference-count discipline under error paths — see sibling.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  not at this layer.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtLoadDriver

Source: [`IO/LOADUNLD.C`](../../src/NT/PRIVATE/NTOS/IO/LOADUNLD.C) · service #58

**Privileged** — requires `SeLoadDriverPrivilege` at `:81`.
Probes the `DriverServiceName` `UNICODE_STRING`, captures it,
allocates a kernel copy of the service-name buffer from paged
pool, calls `IopLoadUnloadDriver`.

- [x] C1 Probe-then-deref TOCTOU
  - `DriverServiceName.Buffer` captured into kernel pool at
    `:99-103`.
- [x] C2 Direct user-pointer deref without capture — name buffer
  captured.
- [x] C3 Missing `__try` wrap — all user accesses inside try.
- [x] C4 Length-field trust — `MaximumLength` bounded by `USHORT`.
- [x] C5 Integer overflow in size computation — `USHORT`-bounded.
- [x] C6 Semantic validation gaps — privilege check at `:81`
  is the primary gate.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Name buffer allocation bounded by `USHORT MaximumLength` ≤
    65535.  Privileged-only, so attacker surface is narrow.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths — name
  buffer freed on exit.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  no output.
- C13 Cancel / completion-routine races — N/A

---

## NtLockFile

Source: [`IO/LOCK.C`](../../src/NT/PRIVATE/NTOS/IO/LOCK.C) · service #60

Probes `IoStatusBlock`, captures `ByteOffset` and `Length`
(both `LARGE_INTEGER`), references the file with no specific
access (lock semantics validated by FS), builds IRP for
`IRP_MJ_LOCK_CONTROL`.

- [x] C1 Probe-then-deref TOCTOU — all probes + captures inside
  one try.
- [x] C2 Direct user-pointer deref without capture — `LARGE_INTEGER`s
  captured via `ProbeAndReadLargeInteger`.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — `Length` is a 64-bit captured value.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — file system enforces lock
  semantics.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - IRP + optional sync `KEVENT` from non-paged pool — fixed.
- [x] C10 Uninitialized output / pool-contents leak — only
  `IO_STATUS_BLOCK` written by completion routine.
- [x] C11 Reference-count discipline under error paths — file
  object derefed on each cleanup branch.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path;
  alertable lock waits can be cancelled.

---

## NtNotifyChangeDirectoryFile

Source: [`IO/DIR.C`](../../src/NT/PRIVATE/NTOS/IO/DIR.C) · service #64

Probes `IoStatusBlock` and `Buffer` for `Length` bytes,
references the file with `FILE_LIST_DIRECTORY`, allocates IRP,
dispatches `IRP_MJ_DIRECTORY_CONTROL` /
`IRP_MN_NOTIFY_CHANGE_DIRECTORY`.  Long-poll: the IRP stays
pending in the FS until a change is detected or the wait is
cancelled.

- [x] C1 Probe-then-deref TOCTOU — `IoStatusBlock` + `Buffer`
  probed; per-driver writes happen later via the IRP.
- [x] C2 Direct user-pointer deref without capture — buffer
  pinned by MDL (see `IopDirectoryControl`).
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — `Length` captured.
- [x] C5 Integer overflow in size computation — none at this
  layer.
- [x] C6 Semantic validation gaps — `FILE_LIST_DIRECTORY`
  access required.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation — **finding**
  - `IRP_MJ_DIRECTORY_CONTROL` IRPs are long-lived (pending until
    a notification fires).  Each open + notify request consumes
    non-paged pool for an IRP + MDL + per-driver buffer state.
    A process can issue many concurrent notify requests; with
    user-controlled `Length`, the per-call buffer pin is also
    user-sized.  See `DIR.C:874` allocation pattern.
- [x] C10 Uninitialized output / pool-contents leak — per-driver
  writes only the change records it has data for.
- [x] C11 Reference-count discipline under error paths — file ref
  released on cleanup branches.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  per-driver.
- [ ] C13 Cancel / completion-routine races — long-poll IRP;
  cancellation is per-FS.

---

## NtOpenFile

Source: [`IO/OPEN.C`](../../src/NT/PRIVATE/NTOS/IO/OPEN.C) · service #69

Thin wrapper around `IoCreateFile` with `FILE_OPEN` disposition
and no EA/AllocationSize.  Audit deferred to `IoCreateFile`.

- [ ] C1 Probe-then-deref TOCTOU — see `IoCreateFile`.
- [ ] C2 Direct user-pointer deref without capture — see helper.
- [ ] C3 Missing `__try` wrap — see helper.
- [x] C4 Length-field trust — no length-bearing parameter.
- [x] C5 Integer overflow in size computation — none.
- [ ] C6 Semantic validation gaps — see helper.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation — see helper.
- [ ] C10 Uninitialized output / pool-contents leak — see helper.
- [ ] C11 Reference-count discipline under error paths — see helper.
- [ ] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- C13 Cancel / completion-routine races — N/A (synchronous open).

---

## NtOpenIoCompletion

Source: [`IO/COMPLETE.C`](../../src/NT/PRIVATE/NTOS/IO/COMPLETE.C) · service #70

Same shape as `NtCreateIoCompletion` — single big `try`,
nested handle-write try with `NOTHING` on except.

- [x] C1 Probe-then-deref TOCTOU — only output write.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output inside try.
- [x] C4 Length-field trust — none.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `ObOpenObjectByName` validates.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — `HANDLE` only.
- [x] C11 Reference-count discipline under error paths — **finding (minor)** *(closed: P1 handle-leak sweep)*
  - Same handle-leak as `NtCreateIoCompletion` at `:243-248`.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- C13 Cancel / completion-routine races — N/A

---

## NtQueryAttributesFile

Source: [`IO/MISC.C`](../../src/NT/PRIVATE/NTOS/IO/MISC.C) · service #84

Probes the fixed-size `FILE_BASIC_INFORMATION` output buffer,
builds an `OPEN_PACKET` with `QueryOnly=TRUE` and a pointer to
the buffer, dispatches via `ObOpenObjectByName`.  The parse
routine opens the file, runs the query, writes the result to
the user buffer via the FS's information procedure, and closes.

- [x] C1 Probe-then-deref TOCTOU — buffer probed at `:702-704`.
- [x] C2 Direct user-pointer deref without capture — buffer
  pointer passed through `OpenPacket.BasicInformation`; FS
  driver writes it.
- [ ] C3 Missing `__try` wrap — **the FS-side write of
  `BasicInformation` happens inside the FS's
  `FsdQueryInformation` handler.  Each FS driver is responsible
  for wrapping its writes in `__try`.**  Soft concern: relies
  on every FS getting this right; cross-ref C3 audit per-FS.
- [x] C4 Length-field trust — fixed-size struct.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `FILE_READ_ATTRIBUTES`
  access required.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — fixed struct;
  FS responsible for full initialization.
- [x] C11 Reference-count discipline under error paths — open packet
  handles cleanup.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  fixed scalar fields only.
- C13 Cancel / completion-routine races — N/A (synchronous).

---

## NtQueryDirectoryFile

Source: [`IO/DIR.C`](../../src/NT/PRIVATE/NTOS/IO/DIR.C) · service #86

Probes `IoStatusBlock` and `FileInformation` for `Length` bytes,
optionally probes + captures `FileName` `UNICODE_STRING` into
non-paged pool, references the file with `FILE_LIST_DIRECTORY`,
allocates IRP, allocates **non-paged system buffer of `Length`
bytes**, dispatches `IRP_MJ_DIRECTORY_CONTROL` /
`IRP_MN_QUERY_DIRECTORY`.

- [x] C1 Probe-then-deref TOCTOU — all probes + captures inside try.
- [x] C2 Direct user-pointer deref without capture — `FileName`
  captured at `:226-245`; output writes via FS.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — `Length` captured at entry.
- [x] C5 Integer overflow in size computation — none at this
  layer.
- [x] C6 Semantic validation gaps — `FILE_LIST_DIRECTORY` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation — **finding**
  - `DIR.C:457` `ExAllocatePoolWithQuota(NonPagedPool, Length)`
    — user-controlled length, non-paged pool.  Bounded by
    `MmUserProbeAddress` from the probe.  Same pattern as the
    other Query*File syscalls.
- [x] C10 Uninitialized output / pool-contents leak — per-FS.
- [x] C11 Reference-count discipline under error paths — IRP /
  buffer / file ref cleaned up on all branches.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  per-FS.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtQueryEaFile

Source: [`IO/QSEA.C`](../../src/NT/PRIVATE/NTOS/IO/QSEA.C) · service #88

Probes `IoStatusBlock`, output `Buffer` for `Length`, optional
`EaList` for `EaListLength`, captures `EaList` into kernel pool
when present.  References the file, allocates IRP +
system-buffer `Length`-byte non-paged pool, dispatches
`IRP_MJ_QUERY_EA`.

- [x] C1 Probe-then-deref TOCTOU — `EaList` captured.
- [x] C2 Direct user-pointer deref without capture — `EaList`
  copied to kernel pool at `:162-163`.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — `EaListLength` validated against
  `MaximumLength`-style bound inside the FS.
- [x] C5 Integer overflow in size computation — none at this
  layer.
- [x] C6 Semantic validation gaps — `FILE_READ_EA` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - Same non-paged pool allocation pattern (`Length`-sized) +
    `EaList` capture allocation (`EaListLength`-sized).  Two
    user-controlled allocations per call.
- [x] C10 Uninitialized output / pool-contents leak — per-FS.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — per-FS.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtQueryInformationFile

Source: [`IO/QSINFO.C`](../../src/NT/PRIVATE/NTOS/IO/QSINFO.C) · service #90

Probes `IoStatusBlock` and `FileInformation` for `Length`,
references the file (access depends on `FileInformationClass`),
allocates IRP, allocates system buffer (`Length`-sized non-paged),
dispatches `IRP_MJ_QUERY_INFORMATION`.

- [x] C1 Probe-then-deref TOCTOU — probes inside try at `:118-124`.
- [x] C2 Direct user-pointer deref without capture — output via FS.
- [x] C3 Missing `__try` wrap — probes inside try.
- [x] C4 Length-field trust — `Length` captured.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — per-class access requirement
  table (`IoQueryAccessRights[]`) selects the access mask.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - `QSINFO.C:448` `ExAllocatePoolWithQuota(NonPagedPool, Length)`.
- [x] C10 Uninitialized output / pool-contents leak — per-FS.
- [x] C11 Reference-count discipline under error paths.
- [ ] C12 Kernel-address / kernel-pointer leak via info classes
  - Several `FILE_INFORMATION_CLASS` values return file/object
    metadata that *may* include kernel-derived state (file ID,
    object IDs).  Per-class audit warranted; deferred to
    individual FS reviews.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtQueryIoCompletion

Source: [`IO/COMPLETE.C`](../../src/NT/PRIVATE/NTOS/IO/COMPLETE.C) · service #91

Probes `IoCompletionInformation` for fixed-size
`IO_COMPLETION_BASIC_INFORMATION` and optional `ReturnLength`,
references the I/O completion object, reads `KeReadStateQueue`
(`Depth`), writes back.  Single big `try` wraps everything.

- [x] C1 Probe-then-deref TOCTOU — output probed once.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output writes inside nested try.
- [x] C4 Length-field trust — `IoCompletionInformationLength`
  checked at `:348`.
- [x] C5 Integer overflow in size computation — fixed struct.
- [x] C6 Semantic validation gaps — `IO_COMPLETION_QUERY_STATE`
  access; only `IoCompletionBasicInformation` class accepted.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — single
  `LONG Depth` field.
- [x] C11 Reference-count discipline under error paths
  - `ObDereferenceObject(IoCompletion)` at `:375` reached on
    every success path; the write-fault except at `:382-384`
    `NOTHING`s after the deref already happened.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `LONG` only.
- C13 Cancel / completion-routine races — N/A

---

## NtQueryVolumeInformationFile

Source: [`IO/QSFS.C`](../../src/NT/PRIVATE/NTOS/IO/QSFS.C) · service #112

Probes `IoStatusBlock` and `FsInformation` for `Length`,
references the file (access varies by class), allocates IRP +
system buffer of `Length`-byte non-paged pool, dispatches
`IRP_MJ_QUERY_VOLUME_INFORMATION`.

- [x] C1 Probe-then-deref TOCTOU — probes inside try.
- [x] C2 Direct user-pointer deref without capture — output via FS.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — `Length` captured.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — per-class access lookup.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - `QSFS.C:401` `ExAllocatePoolWithQuota(NonPagedPool, Length)`.
- [x] C10 Uninitialized output / pool-contents leak — per-FS.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — per-FS.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtReadFile

Source: [`IO/READ.C`](../../src/NT/PRIVATE/NTOS/IO/READ.C) · service #115

References the file with `FILE_READ_DATA`, probes
`IoStatusBlock`, output `Buffer` for `Length` bytes, optional
`ByteOffset` and `Key`.  For `FO_NO_INTERMEDIATE_BUFFERING`
files, validates buffer alignment and length against
`deviceObject->SectorSize` + `AlignmentRequirement`.  Optionally
references `Event`.  Builds and dispatches `IRP_MJ_READ`.

- [x] C1 Probe-then-deref TOCTOU — probes + captures inside try
  at `:149-256`.  Custom exception filter
  `IopExceptionFilter` handles AVs specifically.
- [x] C2 Direct user-pointer deref without capture — `ByteOffset`
  and `Key` captured via `ProbeAndReadX`.
- [x] C3 Missing `__try` wrap — all user accesses inside try.
- [x] C4 Length-field trust — `Length` is by-value.
- [x] C5 Integer overflow in size computation — alignment math at
  `:206-220` uses bitmask checks (no multiply).
- [x] C6 Semantic validation gaps
  - `FILE_READ_DATA` access required.
  - `FO_NO_INTERMEDIATE_BUFFERING` length-alignment validated
    against sector size.
  - `CompletionContext`-vs-`ApcRoutine` mutual exclusion check.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - Buffered I/O path allocates a `Length`-sized non-paged pool
    system buffer; cached path uses the user buffer directly via
    MDL.  Same pattern as the other read/write syscalls.
- [x] C10 Uninitialized output / pool-contents leak — driver +
  FS responsibility.
- [x] C11 Reference-count discipline under error paths —
  meticulous; `IopExceptionFilter` handles cleanup.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  driver-side.
- [ ] C13 Cancel / completion-routine races — primary read path;
  cancel routine is per-driver.

---

## NtRemoveIoCompletion

Source: [`IO/COMPLETE.C`](../../src/NT/PRIVATE/NTOS/IO/COMPLETE.C) · service #122

Probes the three output pointers (`KeyContext`, `ApcContext`,
`IoStatusBlock`) and captures optional `Timeout`, references
the I/O completion object, calls `KeRemoveQueue` (which blocks
until an entry arrives or `Timeout` expires), frees the IRP, and
writes the captured completion data to user.

- [x] C1 Probe-then-deref TOCTOU — all four user pointers probed
  at `:476-482`.
- [x] C2 Direct user-pointer deref without capture — `Timeout`
  captured; outputs written under inner try.
- [x] C3 Missing `__try` wrap — accesses inside outer try.
- [x] C4 Length-field trust — none.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `IO_COMPLETION_MODIFY_STATE`
  access required.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [ ] C11 Reference-count discipline under error paths — **finding (data-loss)**
  - At `:534-549` the inner `try` writes
    `LocalApcContext` / `LocalKeyContext` / `LocalIoStatusBlock`
    to user **after** `IoFreeIrp(Irp)` has already returned the
    IRP to the pool.  On `except NOTHING`, the completion
    record is gone, `Status` remains `STATUS_SUCCESS` from
    `:533`, and the caller receives success status with
    uninitialized output pointers.
  - The completion event is **consumed and lost** — the IRP
    cannot be re-completed; the caller doesn't know the data
    is gone.  Triggerable by guard-page-after-first-page on
    any of the three output pointers; classic data-loss
    primitive against IOCP-using servers.
  - Fix shape: write the three outputs *before* `IoFreeIrp` (so
    a fault leaves the IRP intact for re-completion), or
    capture the IRP back into the queue under cancel.  Or set
    `Status = STATUS_ACCESS_VIOLATION` in the except (and
    re-queue or log the lost completion).
- [x] C10 Uninitialized output / pool-contents leak — outputs
  written from `LocalX` locals (initialized from the IRP).
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - `KeyContext` and `ApcContext` are user-supplied pointer
    values stored at I/O submission time — returned to user as
    opaque tokens, not kernel pointers.

---

## NtSetEaFile

Source: [`IO/QSEA.C`](../../src/NT/PRIVATE/NTOS/IO/QSEA.C) · service #136

Probes `IoStatusBlock` and input `Buffer` for `Length` bytes,
references the file with `FILE_WRITE_EA`, allocates system
buffer (non-paged, `Length`), copies user EA blob, dispatches
`IRP_MJ_SET_EA`.

- [x] C1 Probe-then-deref TOCTOU — probes + capture inside try.
- [x] C2 Direct user-pointer deref without capture — EA blob
  copied into system buffer at `:857`.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — `Length` captured.
- [x] C5 Integer overflow in size computation — EA-list structural
  validation in FS; bounded by `Length` ULONG.
- [x] C6 Semantic validation gaps — `FILE_WRITE_EA` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - `QSEA.C:857` `ExAllocatePoolWithQuota(NonPagedPool, Length)`.
- [x] C10 Uninitialized output / pool-contents leak — input copy only.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtSetInformationFile

Source: [`IO/QSINFO.C`](../../src/NT/PRIVATE/NTOS/IO/QSINFO.C) · service #141

Probes `IoStatusBlock` and input `FileInformation` for `Length`
bytes, references the file (per-class access), allocates system
buffer, copies user data, dispatches `IRP_MJ_SET_INFORMATION`.

- [x] C1 Probe-then-deref TOCTOU — probes + capture inside try.
- [x] C2 Direct user-pointer deref without capture — copied to
  system buffer at `:1120`.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — `Length` captured; per-class
  minimum size check.
- [x] C5 Integer overflow in size computation — none at this
  layer.
- [x] C6 Semantic validation gaps — per-class access lookup
  (`IoSetAccessRights[]`).  Rename/link operations capture
  target paths under separate guards.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - `QSINFO.C:1120` `ExAllocatePoolWithQuota(NonPagedPool, Length)`.
- [x] C10 Uninitialized output / pool-contents leak — no output
  beyond `IO_STATUS_BLOCK`.
- [x] C11 Reference-count discipline under error paths — `context`
  pool block at `:1398` released on completion.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtSetVolumeInformationFile

Source: [`IO/QSFS.C`](../../src/NT/PRIVATE/NTOS/IO/QSFS.C) · service #159

Probes `IoStatusBlock` and input `FsInformation` for `Length`
bytes, references the file (per-class access), allocates system
buffer, dispatches `IRP_MJ_SET_VOLUME_INFORMATION`.

- [x] C1 Probe-then-deref TOCTOU — probes + capture inside try.
- [x] C2 Direct user-pointer deref without capture — copied to
  system buffer at `:715`.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — `Length` captured.
- [x] C5 Integer overflow in size computation — none at this layer.
- [x] C6 Semantic validation gaps — per-class access lookup.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - `QSFS.C:715` `ExAllocatePoolWithQuota(NonPagedPool, Length)`.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtUnloadDriver

Source: [`IO/LOADUNLD.C`](../../src/NT/PRIVATE/NTOS/IO/LOADUNLD.C) · service #168

**Privileged** — requires `SeLoadDriverPrivilege` at `:283`.
Same name-capture pattern as `NtLoadDriver`.  Calls
`IopLoadUnloadDriver` to stop and unload the named driver.

- [x] C1 Probe-then-deref TOCTOU — `DriverServiceName` captured.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — inside try.
- [x] C4 Length-field trust — `USHORT`-bounded.
- [x] C5 Integer overflow in size computation — `USHORT`-bounded.
- [x] C6 Semantic validation gaps — privilege check at `:283`.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation —
  bounded `USHORT` name buffer.  Privileged-only.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths — name
  buffer freed on exit.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  no output.
- C13 Cancel / completion-routine races — N/A

---

## NtUnlockFile

Source: [`IO/LOCK.C`](../../src/NT/PRIVATE/NTOS/IO/LOCK.C) · service #170

Probes `IoStatusBlock`, captures `ByteOffset`, `Length`, and
optional `Key`, references the file, builds IRP for
`IRP_MJ_LOCK_CONTROL` with `IRP_MN_UNLOCK_SINGLE`.

- [x] C1 Probe-then-deref TOCTOU — captures inside try.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — inside try.
- [x] C4 Length-field trust — `Length` `LARGE_INTEGER` captured.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — file system enforces lock
  semantics.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — IRP
  + optional `KEVENT` fixed-size.
- [x] C10 Uninitialized output / pool-contents leak — `IO_STATUS_BLOCK`
  only.
- [x] C11 Reference-count discipline under error paths — file
  derefed on each branch.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- [ ] C13 Cancel / completion-routine races — IRP-issuing path.

---

## NtWriteFile

Source: [`IO/WRITE.C`](../../src/NT/PRIVATE/NTOS/IO/WRITE.C) · service #179

Mirror of `NtReadFile` with `FILE_WRITE_DATA` (or
`FILE_APPEND_DATA` for the file-pointer-relative writes).  Same
probe + IRP dispatch shape.

- [x] C1 Probe-then-deref TOCTOU — see `NtReadFile`.
- [x] C2 Direct user-pointer deref without capture — see sibling.
- [x] C3 Missing `__try` wrap — see sibling.
- [x] C4 Length-field trust — `Length` by-value.
- [x] C5 Integer overflow in size computation — see sibling.
- [x] C6 Semantic validation gaps — `FILE_WRITE_DATA` /
  `FILE_APPEND_DATA` access selected based on `ByteOffset`
  value (the magic `FILE_WRITE_TO_END_OF_FILE` /
  `FILE_USE_FILE_POINTER_POSITION` constants).
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - Buffered I/O path allocates a `Length`-sized system buffer.
- [x] C10 Uninitialized output / pool-contents leak — input
  syscall; no output buffer beyond `IO_STATUS_BLOCK`.
- [x] C11 Reference-count discipline under error paths — see sibling.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  driver-side.
- [ ] C13 Cancel / completion-routine races — primary write path.

---

## Fix-scope summary across IO

### Root-cause groups

1. **NonPagedPool exhaustion via user-controlled allocation length**
   — every Query/Set syscall that builds an IRP allocates a
   `Length`-sized system buffer from non-paged pool
   (`ExAllocatePoolWithQuota(NonPagedPool, Length)`).  Lengths are
   user-controlled, bounded only by `MmUserProbeAddress` (~2 GB).
   Quota tracking debits the caller but a single huge allocation
   can drain pool before the throttle fires.  Affected: 13
   syscalls (`NtDeviceIoControlFile`, `NtFsControlFile`,
   `NtReadFile`, `NtWriteFile`, `NtQueryEaFile`, `NtSetEaFile`,
   `NtQueryInformationFile`, `NtSetInformationFile`,
   `NtQueryVolumeInformationFile`, `NtSetVolumeInformationFile`,
   `NtQueryDirectoryFile`, `NtNotifyChangeDirectoryFile`,
   plus the helper `IopXxxControlFile`).

2. **Output-handle leak on output-write fault** — same
   `try { *Handle = value } except { NOTHING }` pattern as in
   SE / OB.  Affected: `NtCreateIoCompletion`, `NtOpenIoCompletion`.
   `NtCreateFile`/`NtOpenFile` inherit the same shape through
   `IoCreateFile` (to be confirmed when that helper is audited).

3. **`NtRemoveIoCompletion` completion-data-loss on write fault**
   — the inner `try { *KeyContext = ...; *ApcContext = ...;
   *IoStatusBlock = ...; } except { NOTHING }` at
   `COMPLETE.C:534-549` writes the three outputs **after**
   `IoFreeIrp(Irp)` has already freed the IRP.  On fault, the
   completion event is consumed and lost (IRP gone), caller
   receives `STATUS_SUCCESS` from `:533` with uninitialized
   output pointers.  Triggerable by guard-page-after-first-page
   on any of the three output pointers — classic data-loss
   primitive against IOCP-using servers.

4. **Fast-IO path status-reporting inconsistency** in
   `IopXxxControlFile:5025-5030` — after `FastIoDeviceControl`
   succeeds, the `*IoStatusBlock = localIoStatus` write fault
   only records the AV into `localIoStatus.Status`; the IRP
   work already completed and the user-event was signalled.
   Caller sees `STATUS_ACCESS_VIOLATION` despite success.

### Fix shape

1. **Pool-exhaustion (13 syscalls + helper)** — add a sane upper
   bound for the per-call `Length`.  Two options:
   - Per-device cap: each `DEVICE_OBJECT` advertises a
     `DriverObject->Driver{Max,Pool}IoSize` and the I/O manager
     fails calls that exceed it.
   - Process-relative cap: throttle the per-process aggregate of
     pending non-paged pool reservations to a fraction of the
     installed RAM (NT 3.5's quota system tracks this in
     principle; the threshold is what's missing).

   The per-device cap is the cleaner change and only needs one
   helper-level edit in `IopXxxControlFile` plus a few similar
   spots in `READ.C`, `WRITE.C`, `DIR.C`, `QSEA.C`, `QSINFO.C`,
   `QSFS.C`.

2. **Output-handle leak (2 syscalls)** — replace the
   `NOTHING` excepts with `NtClose(Handle); Status = …` so
   the handle is reaped on output-write fault.  Same fix as in
   SE / OB.

3. **`NtRemoveIoCompletion` data-loss** — swap the order so
   the user-side writes happen *before* `IoFreeIrp`, and on
   except status from those writes, re-queue the entry back to
   `IoCompletion` (or leave the IRP allocated and return an
   error status so the caller can retry).  Two ~10-line edits
   in `COMPLETE.C:534-549`.

4. **Fast-IO status inconsistency** — in
   `IopXxxControlFile:5025-5030`, on except, set the user-status
   return to `STATUS_ACCESS_VIOLATION` *and* avoid signalling
   the event, so the caller sees the failure consistently.
   Modest edit; preserves fast-IO performance.

### Deferred helper audits

- **`IoCreateFile`** (`IOSUBS.C`?) — reached from
  `NtCreateFile`, `NtCreateMailslotFile`, `NtCreateNamedPipeFile`,
  `NtOpenFile` (4 syscalls' user-pointer audit is deferred to
  this helper).
- **`IopLoadUnloadDriver`** — driver loading machinery; reached
  from privileged `NtLoadDriver` / `NtUnloadDriver` only.
- **Per-FS information procedures** — `IRP_MJ_QUERY_INFORMATION`,
  `IRP_MJ_SET_INFORMATION`, `IRP_MJ_QUERY_VOLUME_INFORMATION`,
  `IRP_MJ_DIRECTORY_CONTROL`, `IRP_MJ_QUERY_EA`, `IRP_MJ_SET_EA`
  handlers in NTFS, FAT, etc. own C3/C10/C12 correctness for
  each information class.

### Cross-references

- AFD's `_AFD_CONTROL_CODE` macro (cross-ref
  `KERNEL-ABI-HARDENING.md` Class 7) bypasses the
  `IopXxxControlFile:4909-4926` access-mask gate.  Already
  flagged as a tier-2 audit-progress entry; no IO-layer fix
  available — the driver itself must use proper `CTL_CODE`.
