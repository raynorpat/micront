# Syscall audit — consolidated map

The per-subsystem `*.md` files in this directory hold the
finding-by-finding detail.  This document is the **pattern-first
map**: each defect pattern, its reach across subsystems, and the
fix shape that closes every instance at once.

The audit covered **all 182 syscalls** in MicroNT's
`_KiServiceTable`.  Roughly 40 findings spread across the tree;
those 40 findings collapse to **~12 root patterns**.  Most
patterns recur because they're 1990–1992 NT house-style choices
applied uniformly, not localised mistakes by individual authors.

## Pattern catalog

Each pattern below lists: (a) the defect, (b) every syscall it
bites, (c) the fix shape.  Patterns are ordered by how many
syscalls they touch — the most-bites-most patterns close the
biggest fraction of findings per edit.

---

### P1 — Output-handle leak on `*Handle` write fault

**Shape.**  After `ObInsertObject` (or `ExCreateHandle`,
`ObOpenObjectByName` with handle output, etc.) succeeds, the
syscall writes the handle value to a user-mode `OUT PHANDLE`
parameter inside a `__try`.  On AV (user unmapped the output
page between probe and write), the `except` "falls through"
without `NtClose`.  The handle remains installed in the caller's
(or target process's) handle table; the value is never
communicated.

**Reach (~22 sites):**

| Subsystem | Syscalls |
| --- | --- |
| SE | `NtOpenProcessToken`, `NtOpenThreadToken`, `NtDuplicateToken`, `NtCreateToken` |
| OB | `NtCreateSymbolicLinkObject`, `NtOpenSymbolicLinkObject`, `NtCreateDirectoryObject`, `NtOpenDirectoryObject`, `NtDuplicateObject` |
| IO | `NtCreateIoCompletion`, `NtOpenIoCompletion` (+ thin wrappers `NtCreateFile`/`NtOpenFile`/`NtCreateMailslotFile`/`NtCreateNamedPipeFile` via `IoCreateFile`) |
| MM | `NtOpenSection` |
| PS | `NtCreateProcess`, `NtCreateThread`, `NtOpenProcess`, `NtOpenThread` |
| EX | `NtCreate{Event,EventPair,Mutant,Semaphore,Timer,Profile}`, `NtOpen{Event,EventPair,Mutant,Semaphore,Timer}` |
| CONFIG | `NtCreateKey`, `NtOpenKey` |
| LPC | `NtAcceptConnectPort`, `NtConnectPort` (verify); `NtCreatePort` already has the right shape — **template** |

**Severity.**  Self-inflicted DoS only.  Caller leaks one
handle slot in their own table per triggering call.
Cross-process variants (`NtDuplicateObject`) leak in the
**target** process; mildly worse but limited by who can hold
`PROCESS_DUP_HANDLE` on both source and target.

**Fix shape (template at `LPC/LPCCREAT.C:240-247`):**

```c
try {
    *Handle = LocalHandle;
} except (EXCEPTION_EXECUTE_HANDLER) {
    NtClose(LocalHandle);
    Status = GetExceptionCode();
}
```

For cross-process variants (`NtDuplicateObject`, etc.), wrap
the `NtClose` in `KeAttachProcess(&TargetProcess->Pcb)` /
`KeDetachProcess()` so the close happens in the target's
context.

---

### P2 — User-controlled `NonPagedPool` length

**Shape.**  IRP-issuing syscalls in IO allocate a system buffer
sized by the user's `Length` parameter via
`ExAllocatePoolWithQuota(NonPagedPool, Length)`.  Length is
bounded only by `MmUserProbeAddress` (~2 GB).  Quota tracking
debits the caller process, but a single huge allocation can
exhaust non-paged pool before quota throttles it — affecting
every other process on the system.

**Reach (13 sites):**

| Syscall | Source |
| --- | --- |
| `NtDeviceIoControlFile` / `NtFsControlFile` | `INTERNAL.C:5166` (`IopXxxControlFile`) |
| `NtReadFile`, `NtWriteFile` | `READ.C` / `WRITE.C` system-buffer paths |
| `NtQueryEaFile`, `NtSetEaFile` | `QSEA.C:469`, `QSEA.C:857` |
| `NtQueryInformationFile`, `NtSetInformationFile` | `QSINFO.C:448`, `QSINFO.C:1120` |
| `NtQueryVolumeInformationFile`, `NtSetVolumeInformationFile` | `QSFS.C:401`, `QSFS.C:715` |
| `NtQueryDirectoryFile`, `NtNotifyChangeDirectoryFile` | `DIR.C:457`, `DIR.C:874` |

**Severity.**  System-wide DoS via non-paged pool exhaustion.
Any process with a file/device handle (i.e. nearly all
processes) can trigger.

**Fix shape.**  Per-device `MAX_TRANSFER_SIZE` advertisement.
The `DRIVER_OBJECT` gains a `DriverMaxIoSize` field; the I/O
manager rejects calls that exceed it.  Default to a sane
upper bound (e.g. 32 MB) for legacy drivers that don't set
the field.  Splits large transfers across multiple IRPs in
the I/O manager.

Alternative: a tighter per-process aggregate non-paged-pool
reservation throttle.  More invasive (touches quota
machinery); less surgical.

---

### P3 — Capture-helper overflow (`SeCapture*AndAttributesArray`)

**Cap in place.**  `CAPTURE.C` defines
`SEP_MAX_CAPTURE_COUNT = 0x10000`; both
`SeCaptureLuidAndAttributesArray` (`:1325`) and
`SeCaptureSidAndAttributesArray` (`:1615`) reject
`ArrayCount > SEP_MAX_CAPTURE_COUNT` with
`STATUS_INVALID_PARAMETER` before any multiply, allocation, or
per-element loop runs.  The kernel-pool OOB write primitive in
`SeCaptureSidAndAttributesArray`'s first-pass loop is no longer
reachable; the downstream OOB reads in `SepAdjustPrivileges` /
`SepAdjustGroups` (P5) are bounded by the same cap.  Max
single-call pool footprint: ~768 KB (LUID path) / ~5.5 MB (SID
path).  Tests: `pkg/test/fuzz/se.lua` cover hostile counts
(`cap+1`, two wrap-shapes, `MAXULONG`) across all four
reachable syscalls.  P4 (release-helper NULL feed-through) and
P5 (first-pass `__try`) remain open.

**Original shape.**  Two SE helpers computed
`ArrayCount * sizeof(...)` to size capture allocations without
overflow checking:

- `SeCaptureLuidAndAttributesArray` (`CAPTURE.C:1325`) —
  consistent wrap (probe, alloc, copy all use the wrapped
  value); downstream code reads OOB.
- `SeCaptureSidAndAttributesArray` (`CAPTURE.C:1615`) —
  **inconsistent wrap**; loop iterates the unwrapped count
  against the wrapped allocation.  Kernel-pool OOB **write**
  of attacker-influenced data.  Sustained corruption
  primitive.

**Reach (6+ sites):**

| Helper | Syscall |
| --- | --- |
| `SeCaptureLuidAndAttributesArray` | `NtAdjustPrivilegesToken`, `NtPrivilegeCheck`, `NtCreateToken` |
| `SeCaptureSidAndAttributesArray` | `NtAdjustGroupsToken`, `NtCreateToken` |

Plus reach into `SepAdjustPrivileges` / `SepAdjustGroups`
(`TOKENADJ.C`) which iterate the wrapped capture during
processing — same OOB reads, with `SepAdjustGroups`
additionally dereferencing OOB-read PSIDs via `RtlEqualSid`.

**Severity.**  `SeCaptureSidAndAttributesArray` variant is a
**kernel-pool write primitive** with attacker-controlled
content (the `Sid` field of each entry).  Reachable from
unprivileged callers via `NtAdjustGroupsToken`.

**Fix shape.**  Two ~20-line edits in `CAPTURE.C`:

```c
ArraySize = ArrayCount * sizeof(SID_AND_ATTRIBUTES);
if (ArrayCount > MAX_SAFE_ARRAY_COUNT ||
    ArraySize / sizeof(SID_AND_ATTRIBUTES) != ArrayCount) {
    return STATUS_INVALID_PARAMETER;
}
```

Or backport `RtlULongMult` from NT 4 / 2000 and use it
throughout SE.

Combined with **P5 below**, wraps the first-pass `SepAdjust*`
calls in `__try` so an OOB-read AV becomes a status return,
not a bug-check.

---

### P4 — Release-helper NULL-pointer feed-through

**Closed.**  All five SE release helpers in `CAPTURE.C`
(`SeReleaseSecurityDescriptor`, `SeReleaseSid`,
`SeReleaseAcl`, `SeReleaseLuidAndAttributesArray`,
`SeReleaseSidAndAttributesArray`) now early-return on NULL
before reaching `ExFreePool`.  The two reach sites
(`NtPrivilegeCheck:418` on `PrivilegeCount==0` and
`NtAdjustGroupsToken:799` on `ResetToDefault=TRUE` + faulted
second-pass write) no longer bug-check `BAD_POOL_CALLER`.
Test: `pkg/test/fuzz/se.lua` `NtPrivilegeCheck succeeds on
PrivilegeCount=0` exercises the success-path NULL release; the
fault-path NULL release in `NtAdjustGroupsToken` is harder to
trigger from userspace (needs a read-only `PreviousState`
mapping) and is left untested.

**Original shape.**  `SeReleaseLuidAndAttributesArray`,
`SeReleaseSidAndAttributesArray`, `SeReleaseSid`,
`SeReleaseAcl` all called `ExFreePool(CapturedArray)` without
checking for NULL.  Modern Windows's `ExFreePool` handles NULL;
NT 3.5's bug-checks `BAD_POOL_CALLER`.

Most callers gate releases with
`if (Captured != NULL)`, so the NULL never reaches the helper
in practice.  Two outlier sites don't:

**Reach (2 sites):**

- `NtAdjustGroupsToken:799` — `ResetToDefault=TRUE` path with
  a second-pass user-write fault.
- `NtPrivilegeCheck:418` — `PrivilegeCount=0` reaches the
  success cleanup.

**Severity.**  Local DoS via `BAD_POOL_CALLER` bug-check.
Trivially triggerable.

**Fix shape.**  Add NULL guard at the top of each release
helper.  Two single-line edits in `CAPTURE.C`.

Alternative: backport modern `ExFreePool` NULL-tolerance (one
helper-side edit; benefits the whole kernel).

---

### P5 — First-pass helpers called without `__try`

**Closed.**  Both first-pass `SepAdjust*` calls in
`TOKENADJ.C` are now wrapped in `__try / __except`:

- `NtAdjustPrivilegesToken` first pass at `:313` matches the
  existing second-pass cleanup at `:380-411` — release lock
  with `FALSE`, dereference token, release captured array
  (NULL-safe via P4), return `GetExceptionCode()`.
- `NtAdjustGroupsToken` first pass at `:677` matches the
  existing second-pass cleanup at `:774-801`.

A future bug in `SepAdjust*` or any helper they call that
takes a fault is now a clean error return rather than a
system bug-check.  Combined with P3 (no current OOB-read
primitive from hostile input) and P4 (no NULL-release DoS),
the SE capture/adjust pipeline is structurally clean.
Existing happy-path tests in `pkg/test/se.lua`
(`adjust_privileges save_previous returns prior state`,
`adjust_privileges with mixed enable/disable`, `adjust_groups:
disable a group...`) cover the no-regression case.

**Original shape.**  `SepAdjustPrivileges` (`TOKENADJ.C:313`)
and `SepAdjustGroups` (`TOKENADJ.C:677`) were called for the
"counting" first pass before any user-side writes, both
**outside any `__try` block**.  An OOB-read AV (from **P3**)
inside the first-pass walk would escalate to
`KMODE_EXCEPTION_NOT_HANDLED` and bug-check the system.

---

### P6 — Per-class info-struct padding (latent C10)

**Shape.**  `Nt*Query*Information*` family populates per-class
output structs field-by-field with no `RtlZeroMemory` of the
output buffer before population.  On 32-bit NT 3.5 most of
these structs happen to have no padding; on 64-bit or after
adding fields they'll quietly leak pool bytes from the
kernel's local-variable stack onto user memory.

**Reach (5+ syscalls, latent):**

- `NtQueryVirtualMemory` — `MEMORY_BASIC_INFORMATION`
- `NtQueryInformationProcess` — multiple info classes
- `NtQueryInformationThread` — multiple info classes
- `NtQuerySystemInformation` — most info-class arms
- `NtQueryKey`, `NtEnumerateKey`, `NtEnumerateValueKey`,
  `NtQueryValueKey` — per-class registry info structs

**Severity.**  Latent today (no padding); fragile against
future change.  Modern Windows added defensive zero-init
across these paths.

**Fix shape.**  One-line `RtlZeroMemory(output_struct, size)`
at the top of each per-class arm.  ~20 total small edits.

---

### P7 — `NtQuerySystemInformation` kernel-pointer disclosure

**Shape.**  Two info classes in `NtQuerySystemInformation`
return raw kernel addresses to unprivileged callers:

- **`SystemHandleInformation`** — calls
  `ObGetHandleInformation` (`OBHANDLE.C:1619`) →
  `ObpCaptureHandleInformation` (`:1584`) which copies
  `NonPagedObjectHeader->Object` (raw kernel object pointer)
  into the `SYSTEM_HANDLE_TABLE_ENTRY_INFO.Object` field.
- **`SystemModuleInformation`** — returns the loaded-module
  list with `ImageBase` kernel addresses.

**Severity.**  Severe — defeats kernel-ASLR-equivalent
assumptions.  Any unprivileged process can map out every
kernel object and module address in the system.  Vintage
NT 3.5 (gated behind `SeDebugPrivilege` in modern Windows).

**Fix shape.**  Add `SeDebugPrivilege` check at the top of
the two info-class arms.  Either fail with
`STATUS_PRIVILEGE_NOT_HELD` or zero the `Object`/`ImageBase`
field per entry.  Two small edits in `SYSINFO.C`.

---

### P8 — `NtQueryDirectoryObject` phase-1 kernel-pointer write

**Shape.**  `NtQueryDirectoryObject` (`OBDIR.C:1000-1066`)
uses a two-phase write pattern: phase 1 writes
`DirInfo->Name.Buffer = ObjectName.Buffer` (kernel pointer)
directly into the user output buffer; phase 2 (`querydone:`)
rewrites the field to a user-buffer-relative address.

If phase 1 faults mid-enumeration (e.g. guard-page after the
first page), phase 2 is skipped and kernel pointers remain
in the user buffer.  Function returns
`STATUS_ACCESS_VIOLATION` but the mapped page already
contains the disclosure.

**Reach (1 site):** `NtQueryDirectoryObject`.

**Severity.**  Kernel-pointer disclosure of named-object
region.  Triggerable by any process with `DIRECTORY_QUERY`
access on any directory.

**Fix shape.**  Restructure phase 1 to write user-buffer
offsets directly (computed against the known destination
address), or stage the entire layout in a kernel-pool buffer
and copy with a single `__try`.

---

### P9 — `NtRemoveIoCompletion` data-loss on user-write fault

**Shape.**  At `COMPLETE.C:534-549`, the inner `try` writes
`*KeyContext` / `*ApcContext` / `*IoStatusBlock` **after**
`IoFreeIrp(Irp)` has returned the IRP to the pool.  On
user-write fault, the completion event is consumed and gone;
caller receives `STATUS_SUCCESS` (set unconditionally at
`:533`) with uninitialized output pointers.

**Reach (1 site):** `NtRemoveIoCompletion`.

**Severity.**  Classic IOCP-server data-loss primitive.
Triggerable via guard-page-after-first-page on any of the
three output pointers.  Server thinks it processed the
completion; the actual data is lost.

**Fix shape.**  Write the three user outputs *before*
`IoFreeIrp`.  On except, re-queue the entry to the completion
or leave the IRP allocated and return a retryable error
status.  ~10-line reorder in `COMPLETE.C`.

---

### P10 — `NtGetContextThread` pool-block zero typo

**Shape.**  `PSCTX.C:95-96`:

```c
RtlZeroMemory(&Ctx, sizeof(Ctx));   // zeros pointer variable (4 bytes!)
Ctx = ExAllocatePoolWithQuota(NonPagedPool, sizeof(GETSETCONTEXT));
```

Intent was clearly to zero the allocated buffer after the
alloc; actual effect is zeroing the local pointer variable
before assignment (harmless but useless).  Combined with
`KeContextToKframes` only writing fields requested by
`ContextFlags`, unrequested-category bytes in the
`Ctx->Context` block leak kernel pool slot contents to user.

**Reach (1 site):** `NtGetContextThread`.

**Severity.**  Per-`CONTEXT`-class kernel-pool disclosure.
Reachable by any process with `THREAD_GET_CONTEXT` on a
target thread.

**Fix shape.**  Swap the order and fix the target:

```c
Ctx = ExAllocatePoolWithQuota(NonPagedPool, sizeof(GETSETCONTEXT));
if (Ctx) RtlZeroMemory(Ctx, sizeof(*Ctx));
```

One-line fix in `PSCTX.C`.  The same typo exists at
`PSCTX.C:246` in `NtSetContextThread` but is benign there
(overwritten by the move).

---

### P11 — `NonPagedPoolMustSucceed` fallback under pressure

**Shape.**  `MM/READWRT.C:819` (in
`NtReadVirtualMemory`/`NtWriteVirtualMemory` large-transfer
staging) falls back to `NonPagedPoolMustSucceed` when the
regular `NonPagedPool` allocation fails.  Under pool pressure
this can recurse until the system bug-checks.

**Reach (1 site):** the read/write helper in `READWRT.C`.

**Severity.**  System DoS under pressure.  Requires
`PROCESS_VM_READ` or `PROCESS_VM_WRITE`, so privileged-ish.

**Fix shape.**  Drop the fallback.  Return
`STATUS_INSUFFICIENT_RESOURCES`; caller can split the transfer.

---

### P12 — `NtAccessCheck` ad-hoc bugs (not part of a pattern)

`SE/ACCESSCK.C` has two unique findings that don't fit the
patterns above:

- **C3 missing `__try`** at `:970` and `:1009` — `*PrivilegeSetLength`
  deref outside try.  Local DoS.
- **C11 refcount leak** at `:1107` — `STATUS_INVALID_SECURITY_DESCR`
  early return forgets to release Token + SD.

Plus the `NtDuplicateToken:150` operator typo (`&&` where `||`
was meant — dead validation).

Three one-off edits.  Listed separately because they're
non-pattern.

---

## Defense-in-depth roadmap

Beyond the per-pattern fixes, the audit suggests a set of
**defense-in-depth primitives** that the NT 3.5 kernel
predates.  Backporting them creates a stronger floor for the
fixes above and for whatever comes next.

### Primitive 1 — checked arithmetic helpers

Backport from NT 4 / 2000:

- `RtlULongMult(a, b, &result) → NTSTATUS`
- `RtlULongAdd(a, b, &result) → NTSTATUS`
- `RtlSIZETMult`, `RtlSIZETAdd` (when SIZE_T arrives)

Routes every `ArrayCount * sizeof(...)` style multiply
through overflow detection.  Closes **P3** structurally and
prevents future variants.

### Primitive 2 — `ExFreePool` NULL tolerance

Make `ExFreePool(NULL)` a no-op (modern Windows behavior).
Closes **P4** structurally; every helper that releases
optional pool blocks becomes safer.

### Primitive 3 — `RtlZeroMemoryUlong` / capture-after-alloc pattern

Pair every `ExAllocatePoolWithQuota` (and friends) with
`RtlZeroMemory` of the allocation.  Modern Windows ships
`ExAllocatePoolZero` for this; backport.  Closes **P6** and
**P10** structurally.

### Primitive 4 — `NtCloseSafe` / `ObCloseHandleSafe`

A handle-close that tolerates being called on a fault path
without re-entering kernel-side cleanup loops.  Makes **P1**
fixes safer.

### Primitive 5 — Per-driver `MaxIoSize`

A new `DRIVER_OBJECT` field (or device-extension flag) that
the I/O manager respects when sizing system buffers in
`IopXxxControlFile` / `NtReadFile` / etc.  Default a system-
wide cap (e.g. 32 MB).  Closes **P2** structurally.

### Primitive 6 — `SeDebugPrivilege` gate for kernel-pointer info classes

Modern Windows requires `SeDebugPrivilege` for:

- `NtQuerySystemInformation(SystemHandleInformation)`
- `NtQuerySystemInformation(SystemModuleInformation)`
- `NtQueryInformationProcess(ProcessHandleInformation)`
- A handful of others

Add the gate in MicroNT.  Closes **P7** structurally and
prevents future kernel-pointer-disclosure regressions.

### Primitive 7 — Two-pass staged-write pattern

Standardize "build full layout in kernel pool, single
`__try` `RtlMoveMemory` to user" as the way enumerators
return composite structures with embedded pointers.  Closes
**P8** structurally and prevents similar partial-write
disclosures elsewhere.

---

## Fix-effort summary

| Pattern | Edits | Effort |
| --- | --- | --- |
| P1 — Handle leak | ~22 sites, ~5 lines each | ~110 lines |
| P2 — NonPaged length cap | 1 helper + 6 syscall edits | ~80 lines (with new field) |
| ~~P3 — Capture overflow~~ (closed: cap in `CAPTURE.C`) | 2 helpers | done |
| ~~P4 — Release NULL~~ (closed: NULL guards in `CAPTURE.C`) | 5 helpers | done |
| ~~P5 — First-pass `__try`~~ (closed: both wrapped in `TOKENADJ.C`) | 2 sites | done |
| P6 — Padding zero | ~20 arms, 1 line each | ~20 lines |
| P7 — Kernel-pointer info | 2 sites, ~5 lines each | ~10 lines |
| P8 — Phase-1 disclosure | 1 site, restructure | ~50 lines |
| P9 — IOCP data-loss | 1 site, reorder | ~10 lines |
| P10 — Pool zero typo | 1 site, 2 lines | ~2 lines |
| P11 — Must-succeed fallback | 1 site, drop fallback | ~5 lines |
| P12 — `NtAccessCheck` adhoc | 3 sites | ~30 lines |
| **Subtotal — direct fixes** | **~60 edits** | **~400 lines** |
| Primitives backport | 7 primitives | ~200-300 lines per primitive |

**Estimate**: 1-2 weeks for the direct fixes, 3-4 weeks for the
primitives + their conversions.  Total ~5-6 weeks for a
hardening pass that closes 40+ findings and shifts the
defensive-coding floor up by ~25 years.

---

## Cross-references

- [`../KERNEL-ABI-HARDENING.md`](../KERNEL-ABI-HARDENING.md) —
  bug-class catalog this audit is organised against.
- AFD `_AFD_CONTROL_CODE` macro (Class 7) — driver-side bug,
  not covered by the syscall audit but flagged here for the
  hardening doc.
- `IsDHCPZeroAddress` `sin_zero` flag (Class 6) — deliberate
  type confusion, not a vulnerability; documented as an
  example.
