# Syscall × bug-class audit

One file per kernel subsystem, one section per syscall.  Bug classes
are defined in
[`../KERNEL-ABI-HARDENING.md`](../KERNEL-ABI-HARDENING.md); each
syscall section lists the 13 of them as checkboxes, with findings
and notes added inline as the audit progresses.

## Index

- [`KE.md`](KE.md) — Kernel (2)
- [`IO.md`](IO.md) — I/O manager (28)
- [`MM.md`](MM.md) — Memory manager (18)
- [`OB.md`](OB.md) — Object manager (15)
- [`PS.md`](PS.md) — Process structure (22)
- [`SE.md`](SE.md) — Security (10)
- [`EX.md`](EX.md) — Executive (55)
- [`LPC.md`](LPC.md) — Local procedure call (14)
- [`CONFIG.md`](CONFIG.md) — Configuration manager (registry) (18)

**Total:** 182 syscalls across 9 subsystems.

For the **pattern-first map** of findings across all subsystems
(root patterns, reach lists, fix shapes, defense-in-depth
roadmap), see [`SUMMARY.md`](SUMMARY.md).

## Cell meaning

- `[ ]` — class applies here; not yet audited
- `[x]` — class applies here; audited clean *or* finding addressed (link the finding)
- `N/A` — class does not apply at this layer (see below)

Findings, mitigations, and follow-ups go as prose / nested bullets
directly under the relevant item.

## Why some classes are pre-marked N/A

**C7 (IOCTL access-bit encoding)** and **C8 (Output buffer aliasing /
METHOD mismatch)** describe driver-side bugs in how an IOCTL is
defined or how its input/output buffers are handled.  They manifest
*through* `NtDeviceIoControlFile` and `NtFsControlFile`, but the bug
class lives in the driver — each driver carries its own audit for
these.  Marked N/A on every syscall here.

**C13 (Cancel / completion-routine races)** is an IRP-cancellation
hazard; it only meaningfully applies to the I/O syscalls that issue
cancellable IRPs.  Marked N/A on every non-IO syscall.  (Alert/APC-
based cancellation, used by `NtWaitFor*` and `NtAlertThread`, is a
different mechanism and is not tracked under C13.)
