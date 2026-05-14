# Syscall audit — KE (Kernel)

2 syscalls.  See 
[`README.md`](README.md) for legend, class definitions, and the
rationale for the N/A pre-fills.

## NtContinue

Source: [`KE/I386/TRAP.ASM`](../../src/NT/PRIVATE/NTOS/KE/I386/TRAP.ASM) · service #14

Two-layer implementation: asm wrapper at `KE/I386/TRAP.ASM:4044`
runs after `_KiKernelDispatch`'s `kkd_with_trap_frame` builds the
synthetic `KTRAP_FRAME`; C-side helper `KiContinue`
(`RAISEXCP.C:29`) probes + captures the user `CONTEXT` record
and copies it into the trap + exception frames via
`KeContextToKframes`.  See
[`../KERNEL-ABI-HARDENING.md`](../KERNEL-ABI-HARDENING.md)
"SEH dispatcher" section for the trap-frame contract.

- [x] C1 Probe-then-deref TOCTOU — `CONTEXT` probed at
  `RAISEXCP.C:103` and *copied* into `ContextRecord2` local at
  `:104` before any further use.  Subsequent reads use the
  kernel copy.
- [x] C2 Direct user-pointer deref without capture — fully captured.
- [x] C3 Missing `__try` wrap — copy inside try at `:94-124`.
- [x] C4 Length-field trust — `sizeof(CONTEXT)` is a fixed
  compile-time constant.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `ContextFlags` filtered by
  `KeContextToKframes` per architecture rules; invalid bits are
  ignored rather than rejected.  No security impact —
  unrecognized flags simply don't transfer fields.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — no
  pool allocation; uses stack-resident `CONTEXT ContextRecord2`.
- [x] C10 Uninitialized output / pool-contents leak — does not
  return data to user; modifies trap frame.
- [x] C11 Reference-count discipline under error paths — no
  object refs.  `IrqlChanged` flag at `:68/126` makes the
  `KeLowerIrql` symmetric to the optional `KeRaiseIrql` at `:82`.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  no output.
- C13 Cancel / completion-routine races — N/A

---

## NtRaiseException

Source: [`KE/I386/TRAP.ASM`](../../src/NT/PRIVATE/NTOS/KE/I386/TRAP.ASM) · service #113

Same two-layer pattern: asm wrapper at `TRAP.ASM:4126` →
synthetic trap-frame via `kkd_with_trap_frame` → C helper
`KiRaiseException` (`RAISEXCP.C:133`) probes + captures both
`EXCEPTION_RECORD` and `CONTEXT` into kernel locals, then calls
`KiDispatchException`.

- [x] C1 Probe-then-deref TOCTOU
  - `ContextRecord` probed at `:200` then `RtlMoveMemory`'d
    into `ContextRecord2` at `:214`.
  - `ExceptionRecord` length captured from
    `ExceptionRecord->NumberParameters` at `:201` *inside* the
    probe try; the value is then validated against
    `EXCEPTION_MAXIMUM_PARAMETERS` at `:202` before being used
    to compute the bounded copy size.
- [x] C2 Direct user-pointer deref without capture — both records
  captured.
- [x] C3 Missing `__try` wrap — accesses inside try at `:190-228`.
- [x] C4 Length-field trust
  - `Length` declared as `LONG` (signed); the
    `(Length - EXCEPTION_MAXIMUM_PARAMETERS) * sizeof(ULONG)`
    arithmetic at `:206` therefore produces signed results,
    not the wrap that the same shape causes in
    `NtAdjustPrivilegesToken:191-193` (where the variable was
    `ULONG`).  Probe size at `:207` ends up at
    `sizeof(EXCEPTION_RECORD) - (15 - NumberParameters) * 4`
    bytes — the header size minus the unused-param tail.
    Correct shape.
- [x] C5 Integer overflow in size computation — see C4; signed
  arithmetic avoids the wrap.
- [x] C6 Semantic validation gaps
  - `NumberParameters > EXCEPTION_MAXIMUM_PARAMETERS` rejected
    at `:202`.  `ExceptionCode`'s reserved bit cleared at
    `:246` so kernel-internal status codes can't be forged by
    user.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — no
  pool; both captures are stack-resident.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths — no refs.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  no output.
- C13 Cancel / completion-routine races — N/A

---

## Fix-scope summary across KE

KE syscalls are clean.  The trap-frame contract that makes them
work is documented in
[`../KERNEL-ABI-HARDENING.md`](../KERNEL-ABI-HARDENING.md) "SEH
dispatcher" — `_KiKernelDispatch` builds a synthetic
`KTRAP_FRAME` for service numbers 14 and 113 so the
asm wrappers find the right shape at `[ebp+0]`.

No findings.  Both `KiContinue` and `KiRaiseException` follow
the textbook capture-on-entry pattern: probe the user record,
copy into a kernel-local, work against the copy from there on.

The signed-`LONG`-vs-unsigned-`ULONG` distinction at
`RAISEXCP.C:180`/`:201` is what saves `KiRaiseException` from
the same wrap that bites `NtAdjustPrivilegesToken` —
worth noting as a defensive-style pattern when restructuring
the audit doc pattern-first.
