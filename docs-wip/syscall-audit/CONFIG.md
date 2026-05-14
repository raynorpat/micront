# Syscall audit — CONFIG (Configuration manager (registry))

18 syscalls.  See 
[`README.md`](README.md) for legend, class definitions, and the
rationale for the N/A pre-fills.

## NtCreateKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #20

Probes the optional `Class` `UNICODE_STRING` buffer and the
output `KeyHandle`/`Disposition`.  Takes
`CmpLockRegistryExclusive`, dispatches to the parse routine via
`ObOpenObjectByName` with a `CM_PARSE_CONTEXT` containing
`Class` info.  All body work inside one big try with
`CmpExceptionFilter`.

- [x] C1 Probe-then-deref TOCTOU — `Class` captured via
  `ProbeAndReadUnicodeString`.
- [x] C2 Direct user-pointer deref without capture — `Class`
  captured; outputs written inside try.
- [x] C3 Missing `__try` wrap — entire body inside try.
- [x] C4 Length-field trust — `Class.Length` captured.
- [x] C5 Integer overflow in size computation — `USHORT`-bounded
  via `UNICODE_STRING`.
- [x] C6 Semantic validation gaps
  - `CreateOptions` masked against `REG_LEGAL_OPTION` at `:233`.
  - When `REG_OPTION_BACKUP_RESTORE` is set, the parse routine
    consults `SeBackupPrivilege` / `SeRestorePrivilege` for the
    effective access mask.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Class name capture bounded by `USHORT MaximumLength`.
- [x] C10 Uninitialized output / pool-contents leak — `HANDLE`
  and optional `Disposition` ULONG only.
- [ ] C11 Reference-count discipline under error paths — **finding (minor)**
  - Same handle-leak shape: `*KeyHandle = Handle` at `:269`
    inside the outer try; on fault, `CmpExceptionFilter` sets
    status to AV but the handle is already inserted.
  - `STATUS_PREDEFINED_HANDLE` path at `:254-266` is more
    careful: it `NtClose`s the temporary handle.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- C13 Cancel / completion-routine races — N/A

---

## NtDeleteKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #36

Single big try; references the key for `DELETE`, marks for
delete (entry removed when last handle closed).

- [x] C1 Probe-then-deref TOCTOU — no user pointers.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — body inside try.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `DELETE` access required.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtDeleteValueKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #37

References the key, captures the value-name string, calls
`CmDeleteValueKey`.

- [x] C1 Probe-then-deref TOCTOU — `ValueName` captured.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — inside try.
- [x] C4 Length-field trust — `USHORT`-bounded.
- [x] C5 Integer overflow in size computation — `USHORT`-bounded.
- [x] C6 Semantic validation gaps — `KEY_SET_VALUE` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — name
  capture bounded.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtEnumerateKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #42

Probes output `KeyInformation` for `Length`, references the
parent key, calls `CmEnumerateKey` to populate per-class struct
(`KeyBasicInformation`, `KeyNodeInformation`, `KeyFullInformation`)
with the subkey at `Index`.

- [x] C1 Probe-then-deref TOCTOU — output probed.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output writes inside try.
- [x] C4 Length-field trust — `Length` captured.
- [x] C5 Integer overflow in size computation — per-class size
  + variable name; bounded by hive cell size.
- [x] C6 Semantic validation gaps — `KEY_ENUMERATE_SUB_KEYS` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [ ] C10 Uninitialized output / pool-contents leak
  - Per-class struct populated field-by-field from
    `CM_KEY_NODE` state.  Padding between fields not zeroed;
    `KeyNodeInformation` has a `ClassOffset` followed by
    `ClassLength` packed in a way that historically had a 2-byte
    padding hole.  Verify per-class struct layout.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - Output structs contain no kernel pointers — names + offsets
    relative to the user buffer.
- C13 Cancel / completion-routine races — N/A

---

## NtEnumerateValueKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #43

Mirror of `NtEnumerateKey` for values.  Per-class structs:
`KeyValueBasicInformation`, `KeyValueFullInformation`,
`KeyValuePartialInformation`.  `KeyValueFullInformation` is the
big one — embeds the value's raw data inline.

- [x] C1 Probe-then-deref TOCTOU — output probed.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output writes inside try.
- [x] C4 Length-field trust — `Length` captured.
- [x] C5 Integer overflow in size computation — per-class size +
  variable name + variable value data; bounded by hive cell size.
- [x] C6 Semantic validation gaps — `KEY_QUERY_VALUE` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [ ] C10 Uninitialized output / pool-contents leak — per-class
  padding concern; same shape as `NtEnumerateKey`.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  output uses user-buffer-relative offsets.
- C13 Cancel / completion-routine races — N/A

---

## NtFlushKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #47

References the key, flushes its hive synchronously.

- [x] C1 Probe-then-deref TOCTOU — no user pointers.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — no user-memory access.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `KEY_NOTIFY` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtInitializeRegistry

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #56

Kernel-only API used during smss boot to seal the registry
volatile state.  Single boolean parameter; takes the registry
lock exclusively.

- [x] C1 Probe-then-deref TOCTOU — no user pointers.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — no user-memory access.
- [x] C4 Length-field trust — none.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — must be called exactly once
  during boot; idempotent if hit again.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtLoadKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #59

**Privileged** — requires `SeRestorePrivilege` at `:2041`.
Loads a hive file into the registry namespace at the specified
target key.  Probes + captures `TargetKey` and `SourceFile`
`OBJECT_ATTRIBUTES`.

- [x] C1 Probe-then-deref TOCTOU — captured via `Ob`.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — inside try.
- [x] C4 Length-field trust — `USHORT`-bounded.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — privilege gate.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Hive load reads a file; size bounded by file size.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtNotifyChangeKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #65

Registers asynchronous change-notification on a key.  Probes
optional `IoStatusBlock`, references the key + optional event,
allocates a notify block in non-paged pool.  Long-poll IRP-like
shape.

- [x] C1 Probe-then-deref TOCTOU — `IoStatusBlock` probed.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output inside try.
- [x] C4 Length-field trust — `BufferSize` is by-value.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `KEY_NOTIFY` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - Notify block per registration; concurrent registrations
    accumulate non-paged pool.  Same long-poll shape as
    `NtNotifyChangeDirectoryFile` in IO.
- [x] C10 Uninitialized output / pool-contents leak — buffer
  written by notification machinery.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- [ ] C13 Cancel / completion-routine races
  - Notification IRPs are long-lived; cancel race exists when
    the watched key is deleted.

---

## NtOpenKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #71

Probes output `KeyHandle`, calls `ObOpenObjectByName` with
`CmpKeyObjectType`.  Same big-try shape as `NtCreateKey`.

- [x] C1 Probe-then-deref TOCTOU — output probed.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — body inside try.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `ObOpenObjectByName` validates
  via parse routine; `REG_OPTION_BACKUP_RESTORE` honoured.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — `HANDLE` only.
- [ ] C11 Reference-count discipline under error paths — **finding (minor)**
  - Same handle-leak shape as `NtCreateKey`.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- C13 Cancel / completion-routine races — N/A

---

## NtQueryKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #97

Probes output `KeyInformation` for `Length`, references the
key, fills per-class struct (`KeyBasicInformation`,
`KeyNodeInformation`, `KeyFullInformation`).

- [x] C1 Probe-then-deref TOCTOU — output probed.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output inside try.
- [x] C4 Length-field trust — `Length` captured.
- [x] C5 Integer overflow in size computation — bounded.
- [x] C6 Semantic validation gaps — `KEY_QUERY_VALUE` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [ ] C10 Uninitialized output / pool-contents leak — per-class
  padding concern; same shape as `NtEnumerateKey`.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtQueryValueKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #110

Probes output `KeyValueInformation` for `Length`, references
the key, looks up value by name, copies value data into output
in per-class shape.

- [x] C1 Probe-then-deref TOCTOU — output probed.
- [x] C2 Direct user-pointer deref without capture — value name
  captured.
- [x] C3 Missing `__try` wrap — output inside try.
- [x] C4 Length-field trust — `Length` captured.
- [x] C5 Integer overflow in size computation — bounded by hive
  value-cell size (≤ `CM_MAX_VALUE_SIZE`, typically 1 MB in
  NT 3.5).
- [x] C6 Semantic validation gaps — `KEY_QUERY_VALUE` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Big values (up to ~1 MB) are read into temporary kernel
    pool before copy to user.  Bounded.
- [ ] C10 Uninitialized output / pool-contents leak — per-class
  padding concern.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtReplaceKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #123

**Privileged** — requires `SeRestorePrivilege` at `:2241`.
Replaces a key's hive with a new file's contents atomically.
Probes + captures the new/old file `OBJECT_ATTRIBUTES`.

- [x] C1 Probe-then-deref TOCTOU — captured via Ob.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — inside try.
- [x] C4 Length-field trust — `USHORT`-bounded.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — privilege gate.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation —
  bounded by hive file size.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtRestoreKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #130

**Privileged** — requires `SeRestorePrivilege` at `:1560`.
Restores a key from a saved-hive file.

- [x] C1 Probe-then-deref TOCTOU — captured via Ob.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — inside try.
- [x] C4 Length-field trust — no user-length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — privilege gate.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation —
  bounded by file size.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtSaveKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #132

**Privileged** — requires `SeBackupPrivilege` at `:1649`.
Writes a key's hive to a file.

- [x] C1 Probe-then-deref TOCTOU — no user pointers.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — inside try.
- [x] C4 Length-field trust — no length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — privilege gate.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtSetInformationKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #142

Probes input `KeyInformation` for `Length`, references the
key, applies per-class change.  Only one info class today
(`KeyWriteTimeInformation`).

- [x] C1 Probe-then-deref TOCTOU — input captured.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — inside try.
- [x] C4 Length-field trust — `Length` checked against class size.
- [x] C5 Integer overflow in size computation — fixed.
- [x] C6 Semantic validation gaps — `KEY_SET_INFORMATION` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtSetValueKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #158

Probes input `Data` for `DataSize`, references the key,
captures value name, writes new value into the hive.

- [x] C1 Probe-then-deref TOCTOU — input copied into hive cell.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — inside try.
- [x] C4 Length-field trust — `DataSize` captured.
- [x] C5 Integer overflow in size computation
  - Total value cell = `DataSize` + value-name-length + hdr.
    Bounded by `CM_MAX_VALUE_SIZE` (1 MB).
- [x] C6 Semantic validation gaps — `KEY_SET_VALUE` access.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Value cell allocation bounded by 1 MB per value.
    Aggregate per hive bounded by hive file quota.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## NtUnloadKey

Source: [`CONFIG/NTAPI.C`](../../src/NT/PRIVATE/NTOS/CONFIG/NTAPI.C) · service #169

**Privileged** — requires `SeRestorePrivilege` at `:1876`.
Unloads a hive previously loaded with `NtLoadKey`.

- [x] C1 Probe-then-deref TOCTOU — no user pointers.
- [x] C2 Direct user-pointer deref without capture — captured via Ob.
- [x] C3 Missing `__try` wrap — inside try.
- [x] C4 Length-field trust — no user-length.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — privilege gate.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## Fix-scope summary across CONFIG

### Root-cause groups

1. **Output-handle leak (2 syscalls)** — `NtCreateKey`,
   `NtOpenKey`.  Same shape; both wrapped in the big `try` /
   `CmpExceptionFilter` block.  The `STATUS_PREDEFINED_HANDLE`
   path in `NtCreateKey:254-266` shows the correct cleanup
   (`NtClose(Handle)` after consuming the predefined value),
   so the fix template exists in the same function.

2. **Per-class info-struct padding** — `NtEnumerateKey`,
   `NtEnumerateValueKey`, `NtQueryKey`, `NtQueryValueKey`.
   Same shape as `NtQueryInformationProcess` /
   `NtQueryInformationThread` — per-class structs populated
   field-by-field with no defensive zero-init of padding bytes
   between fields.  Latent C10 if the structs gain padding.

3. **Notification IRP cancel race** — `NtNotifyChangeKey`
   queues long-poll IRPs against the watched key.  Cancel
   semantics when the key is deleted are non-trivial.  Same
   shape as `NtNotifyChangeDirectoryFile` in IO.

### Fix shape

1. **`NtCreateKey` / `NtOpenKey` handle-leak** — explicit
   `NtClose(Handle)` on the AV branch of the outer try.  Two
   sites.

2. **Per-class struct zero-init** — `RtlZeroMemory(buffer,
   class_size)` at the top of each per-class arm before
   field-by-field population.  ~4 syscalls × per-class arms.

3. **`NtNotifyChangeKey` cancel race** — same fix shape as the
   IO equivalent; coordinate.

### Clean classes

The registry has consistent discipline: every syscall wraps its
body in a single big `try` with `CmpExceptionFilter` as the
filter function (centralizes AV handling).  Probe + capture
patterns are uniform.  All "back up / restore" operations are
properly gated by `SeBackupPrivilege` / `SeRestorePrivilege`.

The hive-cell maximum value size (`CM_MAX_VALUE_SIZE`, ~1 MB
in NT 3.5) provides a hard cap on per-value pool allocation
that the IO subsystem doesn't have on its IRP buffers.  Good
design.

### Cross-references

- `CmpExceptionFilter` (`CONFIG/`) — the centralized
  filter every CONFIG syscall uses.  Worth confirming it
  doesn't swallow status codes that should propagate.
- `REG_LEGAL_OPTION` mask — defines which `CreateOptions`
  flags are accepted.  Worth a `KERNEL-ABI-HARDENING.md`
  Class 6 cross-ref.
