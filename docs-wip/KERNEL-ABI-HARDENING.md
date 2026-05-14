# KERNEL-ABI-HARDENING.md

Strategic catalog of bug *classes* in the NT 3.5 kernel ABI as inherited
by MicroNT. The point of this doc is to build the map before we start
fixing — identify the recurring failure modes, document a few examples
of each, then decide what's worth fixing, what's acceptable as
documented residual risk, and what blocks the "running workloads on the
internet" trajectory.

Not a fix plan. Not an audit report. A framework for one.

## Why this doc exists

The MicroNT security model (see `SECURITY-MODEL.md` planned, `SOCKET-SECURITY.md`)
is built on two prongs:

- **Authorization** — who can call what. Custom group SIDs, SDs on
  object-manager devices, process tokens minted by init.
- **Robustness** — given who's calling, what happens when the bytes
  are hostile.

The first prong assumes the second is sound. It isn't. NT's defensive
style against malformed syscall input is essentially "wrap it in
`__try` / `__except` and let the exception handler return
`STATUS_ACCESS_VIOLATION`". That handles user-passed-bad-pointer, which
is one bug class. It does not handle the rest of what an attacker can
construct from inside an authorized process — and a remote attacker
who pwns a worker can construct quite a lot.

The cage holds. The cage is not made of dynamite. This doc tracks
whether the cage is, in fact, dynamite.

## Foundations that color every bug class below

### SEH dispatcher

Kernel-mode `Zw*` go through `_KiKernelDispatch`
(`KE/I386/sysstubs.asm`), not INT 2Eh. For `NtContinue` and
`NtRaiseException` — the two services that read `[ebp+0]` as
`PKTRAP_FRAME` — `kkd_with_trap_frame` synthesizes a real
`KTRAP_FRAME` on the kernel stack: `TsExceptionList` from real
`fs:[0]`, `TsSegCs = KGDT_R0_CODE` with FRAME_EDITED bits set so
`EXIT_ALL`'s iret-emulation path resumes at `CONTEXT.Eip:CONTEXT.Esp`
with the saved chain head restored. The other ~190 services take
a fast path with no trap frame. `RtlUnwind`'s `ZwContinue` round
trip through this helper is what makes kernel-mode
`__try` / `__except` sound.

### What probe actually guarantees

`ProbeForRead(p, size, align)` checks `p + size <= MmUserProbeAddress`
and the alignment of `p`. That's it. It does *not* check:

- That `p` is mapped (probe is address-range only, not page-presence)
- That mapping persists past the probe (TOCTOU window)
- That the *contents* at `p` are well-formed for whatever struct the
  syscall expects (semantic validation)
- Anything about the relationship between input and output buffers in
  an IOCTL

Most bug classes below exploit one of these gaps.

## Bug classes

### Class 1 — Probe-then-deref TOCTOU

**What.** `ProbeForRead(p)` returns success. Caller then `p->field`
later in the syscall. Between probe and deref, another thread in the
same process unmaps the region (`NtFreeVirtualMemory`). Deref faults.
SEH catches it — if there *is* SEH on that line. If state was already
mutated before the fault, the kernel is in a torn state.

**Impact.** Torn kernel state. Specific to the syscall: privilege
edit half-applied, IRP queued but completion-routine fields invalid,
etc. Sometimes BSOD if the dispatcher itself is touched.

**Mitigation pattern.** Capture-on-entry: allocate kernel pool, copy
user data in under one `__try`, then work against the kernel copy
only. NT's `SeCaptureLuidAndAttributesArray` (`SE/TOKENADJ.C:243`) is
the textbook example done right.

**Examples in this tree.** Open audit. Grep target:
`grep -rn 'ProbeForRead' --include=*.c` then look for any deref of
the same pointer outside an immediate capture call.

---

### Class 2 — Direct user-pointer deref without capture

**What.** Syscall reads fields directly off the user pointer inside
`__try`, performs work, writes output back. No kernel-side copy.
Each field access is its own TOCTOU window; attacker can flip a
length field after it's been "validated" but before it's used.

**Impact.** Length-confusion. The "I told you it was 8 bytes when you
checked, now I'm telling you it's 800 MB" trick. Often escalates to
pool corruption or info-leak depending on how the now-bogus length
is used downstream.

**Mitigation pattern.** Same as Class 1 — capture the whole struct
into a kernel buffer once. Never touch the user pointer again.

**Examples in this tree.** Open audit.

---

### Class 3 — Missing `__try` wrap

**What.** Kernel routine dereferences a user pointer with no
exception handler on the path. User-mapped page goes bad (unmapped,
or just never was mapped, or guard page), kernel takes an access
violation it can't dispatch, system bug-checks.

**Impact.** Remote DoS primitive *if* the routine is reachable from
authenticated network input. Otherwise local-process DoS. Every
missing `__try` on the IOCTL paths is one IRP-of-garbage away from
kernel panic.

**Mitigation pattern.** `__try` discipline. Or capture-on-entry,
which dominates `__try` (captured buffer can't fault).

**Examples in this tree.** Open audit. Grep target on IOCTL handlers:
look for `Irp->UserBuffer` / `Irp->AssociatedIrp.SystemBuffer` derefs
outside `__try` blocks, particularly in TDI/AFD/NDIS upcall paths.

---

### Class 4 — Length-field trust

**What.** Syscall struct contains a length field (`Count`, `Length`,
`BufferLength`, etc.). Kernel reads the length, probes that many
bytes, then uses the length again later to bound iteration. The
*second* read of the length comes from user memory (still aliased)
or from a stale capture done before the relevant field. User flips
the length between the probe-time read and the use-time read; kernel
iterates further than was validated.

**Impact.** Out-of-bounds read or write of user memory under kernel
authority. Reads → info leak. Writes → arbitrary user-side corruption
masquerading as kernel-attributed access.

**Mitigation pattern.** Capture the length *once*, into a local
ULONG, before any probe. Use that local everywhere. Never re-read.

**Examples in this tree.** Open audit. Watch the IOCTL handlers
where IRP input length and a struct-internal length both exist
(`InputBufferLength` from IRP stack vs. `aiob->BufferCount` etc.);
the relationship between them is often unchecked.

---

### Class 5 — Integer overflow in size computation

**What.** Kernel computes `total = count * sizeof(entry) + header_size`
to bound an allocation. `count` is attacker-controlled. Multiplication
wraps. Allocation is tiny; iteration proceeds for the original `count`,
trampling past the end.

**Impact.** Pool corruption → kernel arbitrary-write primitive →
privesc.

**Mitigation pattern.** Range-check `count` against a sane upper
bound *before* the multiplication. Or use `RtlULongMult` /
`RtlULongAdd` style checked-arithmetic helpers (NT has them in later
versions; we'd have to backport).

**Examples in this tree.** Open audit. Particular concern: the TDI
info-query path, which iterates over a user-supplied entity list.

---

### Class 6 — Semantic validation gaps

**What.** Pointer is valid, struct is well-formed by C type rules,
but the *contents* are hostile. Embedded offsets point outside the
struct. Type tag mismatches the union member that gets used. A
nominally-unsigned field treated as signed wraps to negative.
Self-referential offsets create cycles that cause unbounded recursion
in walkers.

**Impact.** Wide. Depends entirely on what the kernel does with the
malformed data. Often leads back to Class 4 (length-field) or Class 5
(integer overflow) via a different door.

**Mitigation pattern.** No general fix. Per-struct validation rules.
This is the class that static analysis is worst at and human review
is best at.

**Examples in this tree.**

- The `IsDHCPZeroAddress` check at `TCP/NTDISP.C:3300`: reads the
  first ULONG of `sin_zero` looking for `0x12345678` as a DHCP marker.
  This is type confusion as a feature — `sin_zero` is documented as
  padding, user-mode can put anything there, and the kernel reads it
  as a flag. Not a vulnerability in itself (the marker just enables a
  DHCP code path that's also valid) but a worked example of how
  "trust the struct contents" patterns sneak in. We rely on this
  ourselves in `nt.net.dhcp`.

---

### Class 7 — IOCTL access-bit encoding wrong

**What.** Standard `CTL_CODE` macro encodes
`(Device << 16) | (Access << 14) | (Function << 2) | Method`. The IO
manager extracts the `Access` field and uses it to check the handle's
`GRANTED_ACCESS` before dispatching the IRP. A device driver that
defines its IOCTLs with a malformed macro — wrong shift, missing
access field — bypasses this entire check. Handle opened for read
can submit IOCTLs that, by their function code, would normally
require write access.

**Impact.** Authorization bypass at the device-IOCTL layer. Combines
with permissive device SDs to give effectively unfiltered access.

**Mitigation pattern.** Use the standard `CTL_CODE` macro. Audit
every driver's IOCTL-code header.

**Examples in this tree.**

- `AFD.H:202-203` —
  ```c
  #define _AFD_CONTROL_CODE(request,method) \
          ((FSCTL_AFD_BASE)<<12 | (request<<2) | method)
  ```
  Device base shifted by 12 instead of 16. No access-bits field at
  all. Every `IOCTL_AFD_*` ends up encoding as `FILE_ANY_ACCESS`,
  and the device-base bits collide with the function bits. The IO
  manager's access check on AFD IOCTLs is therefore a no-op. (Whether
  this is even noticeable depends on AFD's device SD — see SOCKET-
  SECURITY.md — but the macro itself is structurally broken.)

---

### Class 8 — Output buffer aliasing / METHOD mismatch

**What.** IOCTL handler assumes input/output buffers are separate;
they're aliased. Or the handler is wired for `METHOD_BUFFERED` and
treats `SystemBuffer` as both in and out, but the input data
overwrites itself before it's consumed. Or the handler is wired for
`METHOD_NEITHER` but derefs `UserBuffer` as if it were probed.

**Impact.** Logic confusion at minimum; can become a primitive for
controlled kernel-side memcpy if the alias is attacker-controlled.

**Mitigation pattern.** Explicit METHOD discipline. Capture input,
zero output buffer, never overlap.

**Examples in this tree.** AFD's fast/slow path layout for
`IOCTL_AFD_RECEIVE_DATAGRAM` (`FASTIO.C:1245` vs `RECVDG.C:137`) is
not a security bug — both paths agree on the user-mode contract via
the self-aliased buffer pattern — but it's a worked example of how
input/output buffer aliasing is load-bearing for *correctness* in
this driver, which means any change here that breaks the aliasing
assumption breaks behavior silently.

---

### Class 9 — Pool exhaustion via attacker-controlled allocation

**What.** Kernel allocation size derives from user input with no
upper bound or quota check. Attacker submits requests in a loop,
each pinning kernel pool. System runs out of nonpaged pool, hangs.

**Impact.** DoS. Whole-system, not just per-process.

**Mitigation pattern.** Hard upper bound per allocation; per-process
quota tracking (NT 3.5 has quota blocks attached to the token, but
many drivers don't use them).

**Examples in this tree.** Open audit. AFD's per-socket receive-buffer
allocation is a candidate — user controls `RecvBufferSize` via
`setsockopt`.

---

### Class 10 — Uninitialized output / pool-contents leak

**What.** Kernel allocates an output struct, fills in some fields,
leaves others uninitialized (padding bytes, optional fields, union
non-active members). Copies the whole struct to user. User reads the
uninitialized bytes — which contain whatever was previously in that
pool slot.

**Impact.** Kernel-pool info leak. Attacker farms pool contents for
addresses (KASLR defeat — though NT 3.5 has no KASLR), token values,
SID strings, file paths, etc.

**Mitigation pattern.** Zero the output buffer before fill. Or use
`RtlZeroMemory` on the captured struct. Or never copy structs with
padding; copy field-by-field.

**Examples in this tree.** Open audit. The TDI info-query handlers
that return `IPRouteEntry` / `IPAddrEntry` arrays are a candidate —
their structs contain padding for alignment.

---

### Class 11 — Reference-count discipline under error paths

**What.** Routine does `ObReferenceObjectByHandle`, succeeds, then
hits an error on the next statement and `return`s without calling
`ObDereferenceObject`. Object leaks a reference. Repeated invocation
exhausts handles or pins objects past their intended lifetime.

**Impact.** Slow-burn DoS via handle/object leak. Or UAF if another
path expects the refcount to drop and re-uses the object.

**Mitigation pattern.** Single exit point with cleanup labels, or
RAII-equivalent macros. NT idiom is `goto cleanup;` with the
deref at the cleanup label.

**Examples in this tree.** Open audit. The TDI request-allocation
paths are a candidate — multiple ref-taking calls in sequence with
returns scattered throughout.

---

### Class 12 — Kernel-address / kernel-pointer leak via info classes

**What.** `NtQuerySystemInformation` / `NtQueryInformationProcess` /
TDI info-query / etc. return structures that include kernel virtual
addresses (e.g. `EPROCESS` pointer, kernel-side handle table base,
PE image base for kernel modules). Unprivileged caller reads them.

**Impact.** Kernel ASLR defeat. NT 3.5 doesn't have ASLR per se, but
the same primitives let an attacker discover where their target
struct lives in kernel memory to aim a later corruption primitive.

**Mitigation pattern.** Zero or randomize kernel addresses in
returned info classes. Or gate the info class behind a privilege.

**Examples in this tree.** `SystemProcessInformation` is unprivileged
in NT 3.5 and returns process names, PIDs, thread counts. Doesn't
return pointers directly but is a fingerprinting primitive. Other
info classes need a survey.

---

### Class 13 — Cancel / completion-routine races

**What.** IRP cancellation paths in NT are notoriously hard. A cancel
routine fires concurrent with completion; both try to deref the IRP;
one of them is operating on freed memory.

**Impact.** UAF in kernel context → controlled-write primitive.

**Mitigation pattern.** Strict locking discipline around
`IoSetCancelRoutine` / `IoAcquireCancelSpinLock`. Or avoid cancel
routines entirely where possible.

**Examples in this tree.** Open audit. AFD has cancel routines on
the connect / accept / recv paths.

---

## Surfaces to audit, in attacker-reachability order

The classes above are universal. What matters for prioritization is
*which surfaces an attacker can poke*.

1. **Network-reachable** — kernel TCP/IP stack ingress (TCPRCV.C,
   IPRCV.C, UDPRCV.C, ARPRCV.C). Anyone on the same network. Highest
   priority. Partly captured in `IPSTACK-HARDENING.md`; cross-link
   findings here.
2. **Authenticated-network-reachable** — IOCTL handlers reachable from
   a compromised worker that holds a passed AFD handle (the SOCKET-
   SECURITY.md scenario). Once a worker is RCE'd, anything reachable
   from its token + handles is on the menu.
3. **Local-unauthenticated** — IOCTLs / syscalls callable by any
   process the system has, before the AppArmor profiles take effect
   (i.e. during the boot window before init has minted restrictive
   tokens). Smaller window but worth checking.
4. **Local-authenticated** — IOCTLs / syscalls only reachable from a
   process holding specific privileges or SIDs. Lower priority but
   still load-bearing for the "drop privileges then keep running"
   pattern.
5. **Kernel-mode-only** — IRP majors reachable only from another
   driver. Not an attacker surface unless we land a driver-loading
   primitive somewhere.

## Audit progress

Per-syscall checkbox matrix lives under
[`syscall-audit/`](syscall-audit/README.md) — one file per kernel
subsystem (KE, IO, MM, OB, PS, SE, EX, LPC, CONFIG), one section per
service in `_KiServiceTable` (182 total), with the 13 classes above as
checkboxes under each.  Findings, mitigations, and references go inline
under the relevant item as the audit advances.

Format for findings as we accumulate them:

```
- Class N — file:line — surface tier — short note
```

Seed entries (from prior work, not a complete audit):

- Class 7 — `AFD.H:202-203` — tier 2 — `_AFD_CONTROL_CODE` macro
  malformed (no access bits, wrong device-base shift). Authorization
  check at IO manager is a no-op for all AFD IOCTLs.
- Class 6 — `TCP/NTDISP.C:3300` — tier 2 — `IsDHCPZeroAddress` reads
  `sin_zero` as a typed flag. Type confusion as deliberate feature;
  documented here as a worked example.

## Related docs

- [`syscall-audit/`](syscall-audit/README.md) — per-syscall × bug-class
  checkbox matrix, split by subsystem; the working surface for the
  audit this doc maps.
- [`SOCKET-SECURITY.md`](SOCKET-SECURITY.md) — sockets-specific access
  control and the AFD-opens-TDI-as-SYSTEM trick.
- [`IPSTACK-HARDENING.md`](IPSTACK-HARDENING.md) — kernel TCP/IP stack
  hardening; the network ingress side of this doc's tier-1 surface.
- [`IOCP.md`](IOCP.md) — IOCP design notes.
- `SECURITY-MODEL.md` (planned) — broader AppArmor-style profile +
  init-as-trust-anchor architecture.

## What this doc deliberately is not

- A fix plan. Fixes come after the map is good enough to prioritize.
- A complete audit. Every "Open audit" marker above is real work, not
  a placeholder for findings we already have.
- A claim of severity. Class enumeration is independent of impact;
  most cells in the (class × surface) grid will turn out to be
  unreachable or low-impact when actually investigated, and that's
  fine — the doc captures the survey work, not just the hits.
