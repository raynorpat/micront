# Syscall audit — SE (Security)

10 syscalls.  See 
[`README.md`](README.md) for legend, class definitions, and the
rationale for the N/A pre-fills.

## NtAccessCheck

Source: [`SE/ACCESSCK.C`](../../src/NT/PRIVATE/NTOS/SE/ACCESSCK.C) · service #1

Entry probes 5 user pointers in one `__try` at `ACCESSCK.C:852-888`
(`AccessStatus`, `GrantedAccess`, `PrivilegeSetLength`, `PrivilegeSet`,
`GenericMapping`).  `GenericMapping` is the only one *captured* into a
local (`LocalGenericMapping`); the rest are re-derefed later in the
body.  All later writes to user memory sit inside their own small
`__try`/`__except` blocks.  `SecurityDescriptor` is captured properly
via `SeCaptureSecurityDescriptor`.

- [x] C1 Probe-then-deref TOCTOU
  - `*PrivilegeSetLength` is re-read at `:970` and `:1009` after the
    initial probe.  The probe's "size" argument (`:874`) read the value
    once but didn't capture it; an attacker can flip the user-side
    `ULONG` between the probe and these checks.  Impact bounded —
    `SepPrivilegeSetSize(Privileges)` is kernel-computed, so the
    comparison can be made to pick the wrong branch but cannot induce
    OOB write — but the window is gratuitous and shares a root cause
    with C3.
- [x] C2 Direct user-pointer deref without capture
  - `*PrivilegeSetLength` is dereferenced three times (`:874`, `:970`,
    `:1009`) without being captured into a local.  The fix mirrors what
    `*GenericMapping` already does at `:884`: read once at probe time,
    work against the local thereafter.
- [x] C3 Missing `__try` wrap — **finding**
  - The deref of `*PrivilegeSetLength` at `:970` (inside the
    `Privileges != NULL` branch's bounds check) and at `:1009` (inside
    the empty-privset branch's bounds check) is **outside any `__try`
    block**.  If the user unmaps that page between entry and either
    check, the kernel takes an unhandled access violation.  Direct
    local-DoS primitive for any process that can call `NtAccessCheck`.
    Fix is C2 (capture once at probe time).
- [x] C4 Length-field trust
  - Same root cause as C1/C2 — `*PrivilegeSetLength` is the length
    field, never captured, re-read at use time.
- [x] C5 Integer overflow in size computation
  - No attacker-controlled multiplication in the syscall body;
    `*PrivilegeSetLength` is passed straight to `ProbeForWrite` which
    detects address-range wrap.  `SepPrivilegeSetSize(Privileges)` is
    kernel-computed from a bounded struct.
- [x] C6 Semantic validation gaps
  - `SecurityDescriptor` validated via `SeCaptureSecurityDescriptor` +
    explicit owner/group present check (`:1100-1108`).  `ClientToken`
    validated as `TokenImpersonation` at `>= SecurityIdentification`
    (`:919-928`).  `DesiredAccess` rejected if any unmapped generic
    bit set (`:890-894`).  `GenericMapping` field values not range-
    checked, but `SepAccessCheck` doesn't trust them structurally —
    soft, not a finding.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - `SeCaptureSecurityDescriptor` allocates from `PagedPool` sized by
    the captured SD's internal lengths — bounded by the SD's own
    sub-field counts (each a `USHORT`).  `SepPrivilegePolicyCheck`
    allocates `Privileges` sized by token-internal state.  No
    unbounded user-controlled allocation in the syscall body.
- [ ] C10 Uninitialized output / pool-contents leak
  - At `:989` the success path does `RtlMoveMemory(PrivilegeSet,
    Privileges, SepPrivilegeSetSize(Privileges))`.  If
    `SepPrivilegePolicyCheck` doesn't fully initialize padding/unused
    bytes of its allocated `Privileges` block, this leaks pool
    contents to user.  Audit deferred until `SE/PRIV.C` is reviewed.
- [x] C11 Reference-count discipline under error paths — **finding**
  - At `:1107` `return( STATUS_INVALID_SECURITY_DESCR );` leaks both
    references taken earlier in the body:
    - `Token` (referenced via `ObReferenceObjectByHandle` at `:900`)
      — no `ObDereferenceObject(Token)` call on this path.
    - `CapturedSecurityDescriptor` (allocated via
      `SeCaptureSecurityDescriptor` at `:1047`) — no
      `SeReleaseSecurityDescriptor` call on this path.
    - Every other error path in this body releases both correctly;
      this branch is the singular outlier.  Repeated invocation with
      a malformed SD (missing owner or group) leaks one token
      reference and one paged-pool SD allocation per call — slow-burn
      DoS for any caller that can reach `NtAccessCheck`.
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - Outputs are `NTSTATUS`, `ACCESS_MASK`, and a `PRIVILEGE_SET` whose
    contents are `LUID` + `ULONG` attributes — no kernel pointers
    returned.
- C13 Cancel / completion-routine races — N/A

---

## NtAdjustGroupsToken

Source: [`SE/TOKENADJ.C`](../../src/NT/PRIVATE/NTOS/SE/TOKENADJ.C) · service #2

Two-pass adjust: first pass counts changes + computes return length,
second pass applies them.  `NewState` (variable-length `TOKEN_GROUPS`)
is captured via `SeCaptureSidAndAttributesArray`; the token is locked
for write across both passes.  Capture is skipped entirely when
`ResetToDefault=TRUE`, leaving `CapturedGroups` at its declared NULL
initializer and `CapturedGroupCount`/`CapturedGroupsLength`
uninitialized — SepAdjustGroups is expected to ignore those params on
the reset path.

- [x] C1 Probe-then-deref TOCTOU
  - `NewState->GroupCount` read once at `:609` inside the capture try
    block; rest of the body uses `CapturedGroupCount`.  All later
    user-memory writes (`*ReturnLength` at `:694`,
    `PreviousState->GroupCount` at `:791`, `SepAdjustGroups`-side
    writes) sit inside their own `__try` blocks.
- [x] C2 Direct user-pointer deref without capture
  - `NewState` contents captured into kernel pool.  `BufferLength` is
    by-value (ULONG).  `PreviousState` only written, never read.
- [x] C3 Missing `__try` wrap
  - Every user-pointer access is inside a try.
- [x] C4 Length-field trust
  - `GroupCount` captured at `:609` and used everywhere after.
- [x] C5 Integer overflow in size computation — **finding (severe)**
  - The overflow is in the **helper**, not the syscall body.
    `SeCaptureSidAndAttributesArray` (`CAPTURE.C:1442`) at `:1615`
    computes `ArraySize = ArrayCount * sizeof(SID_AND_ATTRIBUTES)`
    with no overflow check; `ArrayCount` is `CapturedGroupCount`,
    straight from `NewState->GroupCount` at TOKENADJ.C:609.
  - `TempArray` is allocated for the **wrapped** (small) `ArraySize`
    at `:1625`, but the first-pass loop at `:1647-1665` iterates
    `NextIndex < ArrayCount` using the **unwrapped** (huge) count.
    Each iteration writes 8 bytes (`Sid` pointer + `SidLength`) to
    `TempArray[NextIndex]` — **kernel-pool OOB write** past the
    end of the small `TempArray` allocation, driven by an
    attacker-controlled iteration count.
  - The 4-byte `.Sid` value written each iteration is the user-
    memory read of `InputArray[NextIndex].Sid` (after 32-bit address
    wrap, lands in attacker-mapped low user space) — fully
    attacker-controlled.  The 4-byte `.SidLength` value is
    `RtlLengthRequiredSid(SubAuthorityCount)` ≤ ~1028, bounded but
    attacker-influenced.
  - **Net primitive:** controlled kernel paged-pool OOB write of
    `(attacker-pointer, bounded-int)` pairs at a stride and length
    set by `GroupCount`.  Practical exploitation requires shaping
    the wrap so each iteration's wrapped user-side read lands in a
    mapped page, but the bug itself is sustained pool corruption,
    not a one-shot AV.
  - **Compounding finding — `SepAdjustGroups` inner loop**
    (`TOKENADJ.C:1328`): for each token group (~30) the inner
    `while (NewIndex < GroupCount) && !Found` loop reads
    `NewState[NewIndex].Sid` from the wrapped capture allocation.
    Unlike the LUID variant (compared by-value via
    `RtlLargeIntegerEqualTo`), the SID comparison
    `RtlEqualSid(CurrentGroup.Sid, NewState[NewIndex].Sid)`
    **dereferences** the OOB-read pointer:
    - If the wrapped-pool follow-on bytes form a pointer that
      lands on a mapped kernel page → `RtlEqualSid` reads that
      kernel memory as a candidate SID header.  Kernel-content
      disclosure side channel (the match branch leaks one bit of
      information about each address tested).
    - If unmapped → unhandled kernel AV; first-pass
      `SepAdjustGroups` is called at `TOKENADJ.C:677` **without
      a `__try`**, so the AV escalates to
      `KMODE_EXCEPTION_NOT_HANDLED` → bug-check.  Local DoS.
    - If the OOB-read pointer happens to match a real token-group
      SID with flipped enable bits, the token's group enable
      state can be toggled (analogous to the privilege-toggle
      side channel in `NtAdjustPrivilegesToken`, but for groups).
  - Fix at the syscall layer: cap `CapturedGroupCount` against a
    sane upper bound (e.g. token's plausible group count) before
    calling the helper.  Fix at the helper layer: range-check
    `ArrayCount * sizeof(SID_AND_ATTRIBUTES)` for overflow before
    allocating.  Wrap the first-pass `SepAdjustGroups` call at
    `:677` in `__try` so OOB-read AVs return a status instead of
    bug-checking.  Backport `RtlULongMult`-style checked arithmetic.
  - Shared bug — same `SeCaptureSidAndAttributesArray` is reachable
    from `NtCreateToken` (see below); flag during further audits.
  - **Cap in place** — `SeCaptureSidAndAttributesArray` rejects
    `GroupCount > SEP_MAX_CAPTURE_COUNT (0x10000)` with
    `STATUS_INVALID_PARAMETER` before any allocation or first-pass
    loop runs.  The OOB-write primitive and the
    `SepAdjustGroups` inner-loop OOB-read side channel are no
    longer reachable.  Tests: `pkg/test/fuzz/se.lua`.
- [x] C6 Semantic validation gaps
  - `ResetToDefault=TRUE` short-circuits `NewState` use.  Token
    handle validated by `ObReferenceObjectByHandle`.  SID structural
    validation lives in `SeCaptureSidAndAttributesArray`.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - `SeCaptureSidAndAttributesArray` (`CAPTURE.C`) allocates from
    `PagedPool` sized by user-given group count × `sizeof(SID_AND_
    ATTRIBUTES)`, plus per-SID copies.  Implicit upper bound is
    `MmUserProbeAddress` (probe must fit in user space) — still
    ~2 GB worst case.  No per-token or per-process quota check.
- [x] C10 Uninitialized output / pool-contents leak
  - Output goes through `SepAdjustGroups` which writes per-entry
    fields explicitly.  No `RtlCopyMemory` of a kernel pool block
    with uninitialized padding.
- [x] C11 Reference-count discipline under error paths — **finding**
  - At `:799`, the second-pass exception handler calls
    `SeReleaseSidAndAttributesArray( CapturedGroups, PreviousMode, TRUE )`
    **unconditionally** — every other error path in the body (`:657`,
    `:701`, `:722`, `:745`, `:808`) guards the release with
    `if (ARGUMENT_PRESENT(CapturedGroups))`.
  - `CapturedGroups` is NULL when `ResetToDefault=TRUE` (capture
    block at `:605-632` is skipped, decl at `:536` is the only
    initializer).
  - `SeReleaseSidAndAttributesArray`
    (`CAPTURE.C:1862-1908`) calls `ExFreePool(CapturedArray)`
    when `RequestorMode==UserMode`, with no NULL check —
    `ExFreePool(NULL)` bug-checks `BAD_POOL_CALLER`.
  - **Trigger** (no privilege needed beyond TOKEN_ADJUST_GROUPS on
    own token): call with `ResetToDefault=TRUE`, valid `PreviousState`
    + `BufferLength`, then unmap the `PreviousState` page (or
    `PreviousState->GroupCount` at `:791`, or whatever
    `SepAdjustGroups` writes) before the second-pass try at `:774`
    completes.  Exception fires → `:799` calls release on NULL →
    bug-check.  Local DoS primitive.
  - **NULL guard in place** — `SeReleaseSidAndAttributesArray` now
    early-returns on NULL (`CAPTURE.C`), so the `:799` unconditional
    release no longer bug-checks.  The asymmetric guarding at the
    syscall layer (`ARGUMENT_PRESENT` at four sites, raw at one) is
    untouched — the helper-side guard makes both shapes safe.
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - Outputs are `NTSTATUS`, `ULONG`, and a `TOKEN_GROUPS` carrying
    `SID + attributes` — no kernel pointers.

---

## NtAdjustPrivilegesToken

Source: [`SE/TOKENADJ.C`](../../src/NT/PRIVATE/NTOS/SE/TOKENADJ.C) · service #3

Two-pass adjust with the same structure as `NtAdjustGroupsToken` but
for privileges.  `NewState` (variable-length `TOKEN_PRIVILEGES`) is
captured via `SeCaptureLuidAndAttributesArray`.  Capture is skipped
when `DisableAllPrivileges=TRUE`, leaving `CapturedPrivileges` at NULL.

- [x] C1 Probe-then-deref TOCTOU
  - `NewState->PrivilegeCount` captured into `CapturedPrivilegeCount`
    at `:190` inside the probe try.  All later code uses the local.
- [x] C2 Direct user-pointer deref without capture
  - `NewState->Privileges` array captured into kernel pool by
    `SeCaptureLuidAndAttributesArray`.  `BufferLength` by-value.
- [x] C3 Missing `__try` wrap
  - Every user-pointer access is inside a try.
- [x] C4 Length-field trust
  - `PrivilegeCount` captured once at `:190` and used everywhere.
- [x] C5 Integer overflow in size computation — **finding**
  - Two layered wraps in this path:
    1. **Syscall body** at `:191-193`:
       ```c
       ParameterLength = sizeof(TOKEN_PRIVILEGES) +
           ((CapturedPrivilegeCount - ANYSIZE_ARRAY) *
            sizeof(LUID_AND_ATTRIBUTES));
       ```
       `CapturedPrivilegeCount` is user-controlled.  For
       `CapturedPrivilegeCount=0`, `(0 - 1)` underflows to
       `0xFFFFFFFF`, multiply wraps, `ParameterLength` lands tiny.
       For `count >= 0x15555556`, `count * 12` overflows ULONG and
       again wraps to tiny.  The second probe at `:195` then probes
       a tiny range — effectively bypassed.
    2. **Helper** `SeCaptureLuidAndAttributesArray`
       (`CAPTURE.C:1325`) recomputes `ArraySize = ArrayCount *
       sizeof(LUID_AND_ATTRIBUTES)` with the same wrap.  Its probe
       at `:1333`, allocation at `:1362`, and copy at `:1376` all
       use the wrapped value — internally consistent, no OOB inside
       the helper itself.
  - **Downstream impact** in `SepAdjustPrivileges` (`:817`):
    - The capture allocation holds only `wrapped_ArraySize / 12`
      real entries, but `CapturedPrivilegeCount` (passed unchanged
      as `PrivilegeCount`) is the huge user value.
    - Inner loop at `:979` runs `while (NewIndex < PrivilegeCount)
      && !Found`.  For each of the ~30 token privileges that
      doesn't match early, the inner loop reads
      `NewState[NewIndex].Luid` and the attribute byte for
      `NewIndex` up to `PrivilegeCount` — **OOB read past the
      small wrapped pool allocation** into adjacent paged-pool
      slabs.
    - **First-pass** `SepAdjustPrivileges` is invoked at
      TOKENADJ.C:313 **outside any `__try`** (only the second-pass
      call at `:380` is wrapped).  An OOB read that hits an
      unmapped pool page is therefore an unhandled kernel AV →
      `KMODE_EXCEPTION_NOT_HANDLED` bug-check.  Local DoS
      primitive callable by any process with `TOKEN_ADJUST_
      PRIVILEGES` on its own token (i.e. any process).
    - **Privilege-toggle side channel:** when OOB reads happen to
      land in mapped pool slabs, an attacker who pool-sprays values
      whose low 8 bytes equal a real token-privilege LUID and whose
      next 4 bytes encode a flipped `SE_PRIVILEGE_ENABLED` bit will
      cause `SepAdjustPrivileges` to enable/disable that privilege
      on the caller's own token.  Limited to privileges the token
      already holds (the array is iterated against the token's
      existing entries), so this can at most toggle the *enabled*
      state of pre-assigned privileges — meaningful only when a
      held privilege is currently disabled (e.g. a freshly minted
      restricted token).  Not a wild escalation primitive, but
      still a non-trivial defeat of intended state machinery.
  - Fix at this layer: range-check `CapturedPrivilegeCount`
    against a sane upper bound (token's plausible privilege count,
    e.g. 64) before the multiply at `:191-193`, *and* wrap the
    first-pass `SepAdjustPrivileges` call at `:313` in a `__try`
    so an OOB-read AV becomes a status return rather than a
    bug-check.  Fix at the helper layer: range-check `ArrayCount *
    sizeof(LUID_AND_ATTRIBUTES)` for overflow before allocating
    in `SeCaptureLuidAndAttributesArray`.  Same fix surface as
    the `SeCaptureSidAndAttributesArray` finding in
    `NtAdjustGroupsToken` above — `RtlULongMult` backport covers
    both.
  - Shared bug — same `SeCaptureLuidAndAttributesArray` is
    reachable from `NtCreateToken`, `NtFilterToken`, and other SE
    callers; flag during those audits.
  - **Cap in place** — `SeCaptureLuidAndAttributesArray` rejects
    `PrivilegeCount > SEP_MAX_CAPTURE_COUNT (0x10000)` with
    `STATUS_INVALID_PARAMETER`.  Hostile counts may also be
    rejected earlier by the count-derived second probe at
    `:191-199` (probe length exceeds `MmUserProbeAddress` → AV);
    both are clean rejections.  The downstream OOB read in
    `SepAdjustPrivileges` and the privilege-toggle side channel
    are no longer reachable.  Tests: `pkg/test/fuzz/se.lua`.
- [x] C6 Semantic validation gaps
  - `DisableAllPrivileges=TRUE` short-circuits `NewState` use.
    Token handle validated.  `NewState` contents (each
    `LUID_AND_ATTRIBUTES`) validated by `SeCaptureLuidAnd-
    AttributesArray`.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - Same shape as `NtAdjustGroupsToken`: user-sized allocation
    bounded only by `MmUserProbeAddress`.  No quota check.  Wrap
    above (C5) actually *caps* the allocation, ironically.
- [x] C10 Uninitialized output / pool-contents leak
  - Output written by `SepAdjustPrivileges` per-entry; no block
    copy of kernel pool to user (modulo the C5 downstream concern).
- [x] C11 Reference-count discipline under error paths
  - All five `SeReleaseLuidAndAttributesArray` call sites (`:291`,
    `:336`, `:361`, `:404`, `:418`) guard with
    `if (CapturedPrivileges != NULL)`.  Token write-lock + token
    ref are released on every error path.  Symmetric and correct —
    contrast with the `NtAdjustGroupsToken` `:799` outlier.
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - Outputs are `NTSTATUS`, `ULONG`, and `TOKEN_PRIVILEGES` (LUIDs +
    attributes) — no kernel pointers.

---

## NtCreateToken

Source: [`SE/TOKEN.C`](../../src/NT/PRIVATE/NTOS/SE/TOKEN.C) · service #33

Documented as requiring `SeCreateTokenPrivilege` — that gate lives in
`SepCreateToken`, not in the syscall body.  The syscall body does
nine successive captures (User, Groups, Privileges, Owner,
PrimaryGroup, DefaultDacl, AuthenticationId, ExpirationTime,
TokenSource) via `SeCaptureSidAndAttributesArray`,
`SeCaptureLuidAndAttributesArray`, `SeCaptureSid`, `SeCaptureAcl`, and
direct struct copies.  All captures happen **before** the privilege
check inside `SepCreateToken`.

- [x] C1 Probe-then-deref TOCTOU
  - Header probes at `:1394-1432` cover the fixed-size headers of
    every input struct.  Variable-length array contents
    (`Groups->Groups[]`, `Privileges->Privileges[]`,
    `User->User.Sid`, `Owner->Owner`, `PrimaryGroup->PrimaryGroup`,
    `DefaultDacl->DefaultDacl`) are captured under the inner
    `__try` at `:1467-1638`, which catches re-read faults.
  - `Groups->GroupCount` (`:1506`) and `Privileges->PrivilegeCount`
    (`:1525`) are read once each into locals; rest of the body
    uses the locals.
- [x] C2 Direct user-pointer deref without capture
  - Every variable-length input goes through an `SeCapture*`
    helper before use.
- [x] C3 Missing `__try` wrap
  - All user-memory touches inside one of the two try blocks.
- [x] C4 Length-field trust
  - `CapturedGroupCount` / `CapturedPrivilegeCount` captured once
    each.
- [x] C5 Integer overflow in size computation — **finding (severe, shared)**
  - Reaches **both** of the helper-side overflows already flagged
    in this doc:
    - `SeCaptureSidAndAttributesArray` (Groups path at
      `:1507-1517`) — same kernel-pool **OOB write** primitive
      as `NtAdjustGroupsToken` C5.
    - `SeCaptureLuidAndAttributesArray` (Privileges path at
      `:1526-1536`) — same wrapped-allocation /
      downstream-OOB-read pattern as `NtAdjustPrivilegesToken`
      C5.
  - **Reachability without privilege**: the captures happen
    before `SepCreateToken` is called at `:1646`.  Worse,
    `SepCreateToken` (`TOKEN.C:1765`) puts its `SeSinglePrivilege-
    Check(SeCreateTokenPrivilege, ...)` at **`:2223`** — *after*
    `ObCreateObject` (`:2063`), all body initialization
    (`:2085-2158`), and the `DynamicPart` paged-pool allocation
    (`:2168`).  An unprivileged caller therefore drives the
    entire token construction before the privilege gate fires —
    only handle insertion is gated.
  - **Fresh OOB primitives inside `SepCreateToken`** beyond the
    capture-helper findings, all driven by the unwrapped user
    counts against the wrapped capture allocations:
    - `:1934-1938` attribute-fix loop iterates
      `GroupIndex < GroupCount` writing
      `Groups[GroupIndex].Attributes |= SE_GROUP_ENABLED…`.
      For wrapped capture + huge `GroupCount` → kernel-pool **OOB
      write** into adjacent slabs.
    - `:1946-1955` SeChangeNotifyPrivilege scan iterates
      `PrivilegeIndex < PrivilegeCount` reading
      `Privileges[PrivilegeIndex].Luid/Attributes`.  OOB read.
    - `:1982-2009` owner search iterates `GroupIndex < GroupCount`
      calling `RtlEqualSid(Owner, Groups[i].Sid)` — same OOB-read
      **plus PSID deref** shape as the `NtAdjustGroupsToken`
      compounding finding above.
    - `:2118` and `:2146` `RtlCopy*AndAttributesArray(count, ...)`
      copy `PrivilegeCount` / `GroupCount` entries from the
      wrapped capture into the newly allocated token body.  This
      simultaneously reads OOB from the capture *and* writes OOB
      into the token body (which was sized using the wrapped
      lengths from the capture helpers via
      `VariableLength = GroupsLength + PrivilegesLength` at
      `:2031` — i.e. the token body is allocated too small for
      what the loops will copy).
  - Fix locations same as already noted on the helpers, **plus**
    move `SeSinglePrivilegeCheck` to the top of `SepCreateToken`
    (before any allocation or iteration) — closes most of the
    unprivileged reachability on its own.
  - **Cap in place (capture layer only)** — both capture helpers
    now reject `count > SEP_MAX_CAPTURE_COUNT (0x10000)`.  The
    primary OOB primitives in the helpers themselves are no longer
    reachable.  **Still open:** the `SepCreateToken` privilege
    check at `TOKEN.C:2223` runs after `ObCreateObject` (P11), and
    the five token-body loops at `:1934 / :1946 / :1982 / :2118 /
    :2146` are now bounded by the cap but still operate on
    attacker-shaped data — those structural fixes are independent
    of P3.
- [x] C6 Semantic validation gaps
  - `TokenType` validity not checked at the syscall layer.
    `SepCreateToken` at `TOKEN.C:2090` stores `TokenType` into
    `Token->TokenType` without range-checking.  Invalid types
    are then treated as `Primary` by every later
    `if (type == TokenImpersonation) … else …` site (degenerate
    but not corrupting).  Soft finding.
  - `CapturedSecurityQos` is left uninitialized when
    `TokenType != TokenImpersonation` (the QOS capture at
    `:1442-1459` is gated on Impersonation); `:1652` then passes
    `CapturedSecurityQos.ImpersonationLevel` to `SepCreateToken`
    — uninitialized stack read.  `SepCreateToken` stores it at
    `TOKEN.C:2091` regardless of token type; readers gate on
    `TokenType == TokenImpersonation` before reading the field
    (per SE convention), so the UB read doesn't surface today.
    Soft hygiene issue.
  - **`GroupCount=0` is accepted** at `SepCreateToken` —
    produces a token with `UserAndGroupCount=1` (user only).
    Such tokens later trigger the wrap in
    `NtQueryInformationToken`'s `TokenGroups` arm (see that
    syscall's C5).
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - Multiple user-sized captures: `CapturedUser` (count=1,
    bounded), `CapturedGroups` (user count), `CapturedPrivileges`
    (user count), `CapturedOwner` / `CapturedPrimaryGroup`
    (bounded SIDs), `CapturedDefaultDacl` (bounded by 16-bit
    `AclSize`).  Groups and Privileges are the unbounded ones
    — same exhaustion shape as the `NtAdjust*` syscalls.
  - Also: `SeCaptureAcl` uses `NonPagedPool` (`:1583`) — the
    one syscall in this file pulling on the precious non-paged
    pool, again with attacker-controlled (though 16-bit
    bounded) size.
- [x] C10 Uninitialized output / pool-contents leak
  - Output is a single `HANDLE`.
- [x] C11 Reference-count discipline under error paths
  - The capture-try `__except` at `:1598-1637` walks all six
    captured-pool pointers with `if (Captured* != NULL)` guards
    — symmetric.  The success cleanup at `:1674-1695` mirrors
    it.  No source token is held (this is a *create*, not a
    duplicate).
  - Handle leak on the `*TokenHandle = LocalHandle` write fault
    at `:1703-1705` (same shape as Open*Token / DuplicateToken,
    same minor-self-DoS classification).
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - Returns a `HANDLE`.

---

## NtDuplicateToken

Source: [`SE/TOKENDUP.C`](../../src/NT/PRIVATE/NTOS/SE/TOKENDUP.C) · service #41

Probes only the `TokenHandle` output; `ObjectAttributes` SQOS goes
through `SeCaptureSecurityQos`; the source token is referenced and
`SepDuplicateToken` does the heavy lifting.  All user-memory writes
inside `__try`.

- [x] C1 Probe-then-deref TOCTOU
  - Only user-memory write is `*NewTokenHandle` at `:332` inside
    a `__try`.
- [x] C2 Direct user-pointer deref without capture
  - `ObjectAttributes` captured by `SeCaptureSecurityQos`.
- [x] C3 Missing `__try` wrap
  - All user-memory accesses inside try.
- [x] C4 Length-field trust
  - No length-bearing parameter.
- [x] C5 Integer overflow in size computation
  - No size arithmetic in the body.
- [ ] C6 Semantic validation gaps — **finding**
  - `:150-152` validates `TokenType` with the wrong logical
    operator:
    ```c
    if ( (TokenType < TokenPrimary) && (TokenType > TokenImpersonation) )
        return STATUS_INVALID_PARAMETER;
    ```
    With `TokenPrimary=1` and `TokenImpersonation=2` this is
    `TokenType < 1 && TokenType > 2` — **always false**.  No
    value of `TokenType` can satisfy both halves, so the check
    is dead code.  Should be `||`.
  - Vintage NT 3.5 typo.  Downstream `SepDuplicateToken` is
    fail-soft on unknown `TokenType` values, so the immediate
    consequence is "weird types pass through to the helper"
    rather than corruption — but the gate is doing nothing.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - `SepDuplicateToken` allocations are sized by the **source**
    token's structure (kernel-bounded), not by user input.
- [x] C10 Uninitialized output / pool-contents leak
  - Output is a single `HANDLE`.
- [ ] C11 Reference-count discipline under error paths — **finding (minor)**
  - Same handle-leak pattern as `NtOpenProcessToken` at
    `:332-333`: `*NewTokenHandle = LocalHandle` write fault
    leaves the new handle installed in the caller's table but
    un-communicated.  Self-inflicted DoS only.
  - Source-token deref at `:323` is unconditional and reached on
    every success-or-error post-insert path — no source leak.
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - Returns a `HANDLE`.

---

## NtOpenProcessToken

Source: [`SE/TOKENOPN.C`](../../src/NT/PRIVATE/NTOS/SE/TOKENOPN.C) · service #74

Resolves a process handle to its token and opens a handle on that
token in the caller's handle table.  Single user output (`TokenHandle`)
probed and written under `__try`; access-mask validation deferred to
`ObOpenObjectByPointer`.

- [x] C1 Probe-then-deref TOCTOU
  - Only user pointer is `TokenHandle`, written once at `:142`
    inside `__try`.  No earlier read.
- [x] C2 Direct user-pointer deref without capture
  - Same — single write, no read.
- [x] C3 Missing `__try` wrap
  - All user-memory touches inside try.
- [x] C4 Length-field trust
  - No length-bearing parameter.
- [x] C5 Integer overflow in size computation
  - No size arithmetic.
- [x] C6 Semantic validation gaps
  - `ProcessHandle` validated by `PsOpenTokenOfProcess`.
    `DesiredAccess` validated by `ObOpenObjectByPointer`.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - No user-sized allocation in the syscall body.
- [x] C10 Uninitialized output / pool-contents leak
  - Output is a single `HANDLE` value.
- [ ] C11 Reference-count discipline under error paths — **finding (minor)**
  - At `:140-149` the post-success `*TokenHandle = LocalHandle`
    write sits in its own `__try`; on a fault (user unmaps the
    output page between probe at `:90` and write here), the
    handle has *already been inserted* into the caller's handle
    table by `ObOpenObjectByPointer` at `:115`, but its value is
    never communicated to the user — the handle leaks into the
    caller's own handle table and holds the token ref until the
    process exits.
  - Self-inflicted: only the caller is harmed.  Repeated
    triggering (deliberately invalidating own output buffer
    mid-call) can exhaust the caller's handle table — slow-burn
    self-DoS.  Fix is `NtClose(LocalHandle)` before the `return
    GetExceptionCode()` at `:146`.
  - Same pattern appears in `NtOpenThreadToken` below.  Common NT
    3.5 vintage idiom.
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - Returns a `HANDLE` — opaque to user-mode by design.

---

## NtOpenThreadToken

Source: [`SE/TOKENOPN.C`](../../src/NT/PRIVATE/NTOS/SE/TOKENOPN.C) · service #79

Resolves a thread handle to its impersonation token and opens a handle
on that token (or a duplicate, when `CopyOnOpen` is set).  Adds the
`OpenAsSelf` impersonation-disable dance around the open.  Same
single-output (`TokenHandle`) probe/write pattern as
`NtOpenProcessToken`.

- [x] C1 Probe-then-deref TOCTOU
  - `TokenHandle` written once at `:362` inside `__try`.
- [x] C2 Direct user-pointer deref without capture
  - Single write, no read.
- [x] C3 Missing `__try` wrap
  - All user-memory touches inside try.
- [x] C4 Length-field trust
  - No length-bearing parameter.
- [x] C5 Integer overflow in size computation
  - No size arithmetic.
- [x] C6 Semantic validation gaps
  - `ThreadHandle` validated by `PsOpenTokenOfThread`.  Anonymous
    impersonation level is rejected by `PsOpenTokenOfThread`
    (`STATUS_CANT_OPEN_ANONYMOUS`).
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - `SepDuplicateToken` (`:296`) is taken only when the thread's
    impersonation token sets `CopyOnOpen`; allocation is sized
    by the *source* token (kernel-side), not user input.
- [x] C10 Uninitialized output / pool-contents leak
  - Output is a single `HANDLE` value.
- [ ] C11 Reference-count discipline under error paths — **finding (minor)**
  - Same handle-leak as `NtOpenProcessToken` above, at `:362-363`.
    `ObOpenObjectByPointer` (or `ObInsertObject` on the
    `CopyOnOpen` path at `:313`) has already installed the
    handle; the `*TokenHandle` write fault drops the handle name
    on the floor.  Fix is `NtClose(LocalHandle)` before
    `return GetExceptionCode()` at `:363`.
  - Impersonation-state restore at `:341-346` *is* correctly
    placed before the user-write try, so the impersonation
    cleanup is sound on this fault path.
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - Returns a `HANDLE`.

---

## NtPrivilegeCheck

Source: [`SE/PRIVILEG.C`](../../src/NT/PRIVATE/NTOS/SE/PRIVILEG.C) · service #81

Tests whether a client token holds a caller-supplied set of privileges
and writes per-entry attribute results back into the user's
`PRIVILEGE_SET` buffer.  Uses the same `SeCaptureLuidAndAttributesArray`
helper as `NtAdjustPrivilegesToken` and inherits the same C5 wrap.

- [x] C1 Probe-then-deref TOCTOU
  - `RequiredPrivileges->PrivilegeCount` and `->Control` captured
    into locals at `:352-353` inside the probe try.  All later
    code uses `CapturedPrivilegeCount` / `PrivilegeSetControl`.
- [x] C2 Direct user-pointer deref without capture
  - Variable-length `Privilege[]` array captured into kernel pool
    by `SeCaptureLuidAndAttributesArray` at `:362-371`.  Scalar
    fields captured into locals as above.
- [x] C3 Missing `__try` wrap
  - All user-memory touches inside try blocks.
- [x] C4 Length-field trust
  - `PrivilegeCount` captured once and used throughout.
- [x] C5 Integer overflow in size computation — **finding (shared)**
  - Same wrap as `NtAdjustPrivilegesToken` C5.  At `:339-341`:
    ```c
    ParameterLength = sizeof(PRIVILEGE_SET) +
        ((RequiredPrivileges->PrivilegeCount - ANYSIZE_ARRAY) *
         sizeof(LUID_AND_ATTRIBUTES));
    ```
    Same underflow at `count=0`, same overflow at large counts.
    Probe at `:343` then "validates" a wrapped tiny range.
  - Downstream is `SepPrivilegeCheck` (`PRIVILEG.C:~50`) rather
    than `SepAdjustPrivileges`, but the same shape applies — it
    iterates the small wrapped capture allocation using
    `CapturedPrivilegeCount` (huge) and reads OOB from paged
    pool.
  - `RtlMoveMemory` at `:398-402` writes back
    `CapturedPrivilegesLength` bytes — also computed from the
    wrapped count, so the *write* itself is bounded; user-side
    corruption shape is OOB read into pool, then truncated copy
    out.
  - Same fix surface: cap count at the syscall layer and/or
    overflow-check in the helper.
  - **Cap in place** — `SeCaptureLuidAndAttributesArray` rejects
    `PrivilegeCount > SEP_MAX_CAPTURE_COUNT (0x10000)` with
    `STATUS_INVALID_PARAMETER`.  Larger counts may surface as
    `STATUS_ACCESS_VIOLATION` from the count-derived second probe
    at `:343-347` (probe length exceeds `MmUserProbeAddress`);
    both are clean rejections.  The downstream OOB read in
    `SepPrivilegeCheck` is no longer reachable.  Tests:
    `pkg/test/fuzz/se.lua`.
- [x] C6 Semantic validation gaps
  - `ClientToken` validated by `ObReferenceObjectByHandle`.
    `:316-325` rejects impersonation tokens below
    `SecurityIdentification` with `STATUS_BAD_IMPERSONATION_LEVEL`.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [ ] C9 Pool exhaustion via attacker-controlled allocation
  - Same shape as the other capture-array syscalls: user-sized
    `PagedPool` allocation in the helper, no per-process quota.
- [x] C10 Uninitialized output / pool-contents leak
  - Output buffer is overwritten by `RtlMoveMemory` of the
    captured + attribute-stamped array; `SepPrivilegeCheck`
    writes each entry's attributes explicitly.
- [x] C11 Reference-count discipline under error paths — **finding**
  - At `:418` the success-path release calls
    `SeReleaseLuidAndAttributesArray(CapturedPrivileges, …)`
    unconditionally.  `SeCaptureLuidAndAttributesArray` at
    `CAPTURE.C:1297-1301` returns success with
    `*CapturedArray=NULL` when `ArrayCount==0`.  The
    `ASSERT(CapturedPrivileges != NULL)` at `:379` is non-checked
    in retail — a caller passing `PrivilegeCount=0` reaches
    `:418`, which feeds `NULL` to
    `SeReleaseLuidAndAttributesArray` →
    `ExFreePool(NULL)` → `BAD_POOL_CALLER` bug-check.
  - Same shape as `NtAdjustGroupsToken:799` (different trigger:
    here it's `count==0`, there it's `ResetToDefault=TRUE`).
    Two flavors of the same vintage NULL-release pattern in SE.
    Local DoS callable by any process with `TOKEN_QUERY` on the
    target client token (i.e. any process on its own token).
  - The write-back-fault `__except` at `:406-414` *also* calls
    release on the same pointer, but only on a fault from the
    `:392` try; same NULL-deref shape.
  - Fix: add `if (CapturedPrivileges != NULL)` around both
    release sites, *or* fix the helper to no-op on NULL.
  - **NULL guard in place** — `SeReleaseLuidAndAttributesArray`
    now early-returns on NULL (`CAPTURE.C`), so both the success-
    path release at `:418` and the write-back-fault path at
    `:406-414` are safe.  Test: `pkg/test/fuzz/se.lua`
    `NtPrivilegeCheck succeeds on PrivilegeCount=0`.
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - Outputs are LUID + attribute fields + a `BOOLEAN` — no
    kernel pointers.

---

## NtQueryInformationToken

Source: [`SE/TOKENQRY.C`](../../src/NT/PRIVATE/NTOS/SE/TOKENQRY.C) · service #95

Switch over 10 `TOKEN_INFORMATION_CLASS` values (`TokenUser`,
`TokenGroups`, `TokenPrivileges`, `TokenOwner`, `TokenPrimaryGroup`,
`TokenDefaultDacl`, `TokenSource`, `TokenType`, `TokenImpersonationLevel`,
`TokenStatistics`).  Each arm: reference token → acquire read lock →
compute `RequiredLength` from kernel-side token state → `*ReturnLength
= RequiredLength` in a `__try` → bounds check vs. `TokenInformationLength`
→ write the info struct in a `__try` → release lock + deref token.

- [x] C1 Probe-then-deref TOCTOU
  - Single `ProbeForWrite(TokenInformation, TokenInformationLength,
    …)` at `:159` covers the whole output buffer; `ReturnLength`
    probed at `:165`.  Per-arm writes inside `__try`.
- [x] C2 Direct user-pointer deref without capture
  - No user-input reads in the body beyond the probed scalars.
    Output struct contents come from kernel token state.
- [x] C3 Missing `__try` wrap
  - All user-memory writes inside try.
- [x] C4 Length-field trust
  - `TokenInformationLength` is by-value (ULONG); used in
    `RequiredLength` comparison only.
- [ ] C5 Integer overflow in size computation — **finding (minor)**
  - `TokenGroups` arm at `:295-298`:
    ```c
    RequiredLength = sizeof(TOKEN_GROUPS) +
                     ((Token->UserAndGroupCount - ANYSIZE_ARRAY - 1) *
                     sizeof(SID_AND_ATTRIBUTES));
    ```
    For a token with `UserAndGroupCount==1` (no groups, just
    user — possible for some restricted tokens),
    `(1 - 1 - 1) = (ULONG)-1` underflows, multiplies to wrap.
    `RequiredLength` ends up huge.  Write at `:315` reports the
    huge value to the user as `*ReturnLength`; bounds check at
    `:324` then almost always returns `STATUS_BUFFER_TOO_SMALL`.
  - Consequence is a *bogus* `ReturnLength` value, not OOB
    corruption — but user-mode code that re-allocates based on
    `ReturnLength` could end up requesting absurd sizes.  Soft
    finding.
  - Sibling arms (`TokenPrivileges` at `:368`, etc.) compute
    `RequiredLength` from kernel-side counts and don't have the
    same off-by-one shape.
- [x] C6 Semantic validation gaps
  - Each arm validates per its `TOKEN_QUERY` /
    `TOKEN_QUERY_SOURCE` access requirement via
    `ObReferenceObjectByHandle`.  Unknown `TokenInformationClass`
    falls through the switch to a default which returns
    `STATUS_INVALID_INFO_CLASS`.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - No kernel allocations in the syscall body — output written
    directly to user buffer.
- [x] C10 Uninitialized output / pool-contents leak
  - `SepCreateToken` (`TOKEN.C:1765`) does *not* `RtlZeroMemory`
    the token body or the separately-allocated `DynamicPart` —
    body fields are written one-by-one at `:2085-2102` and the
    `DynamicPart` (`:2168`) is filled only with `PrimaryGroup`
    (`:2185`) and optional `DefaultDacl` (`:2191-2194`), leaving
    a `DynamicAvailable`-sized **gap** of uninitialized paged
    pool inside the token.
  - None of the current query arms reach the gap: `TokenDefaultDacl`
    copies bounded by `AclSize`, `TokenPrimaryGroup` bounded by
    `RtlLengthRequiredSid`.  The token-body field copies in
    other arms read scalar fields that *are* initialized.
  - **No leak through `NtQueryInformationToken` today**, but the
    gap is real and any future audit code that queries a wider
    region (audit log dumps, kernel-mode diagnostic dumps) could
    expose it.  Fix shape: `RtlZeroMemory(DynamicPart, DynamicLength)`
    immediately after `ExAllocatePoolWithTag` at `TOKEN.C:2168`.
- [x] C11 Reference-count discipline under error paths
  - Each arm derefs the token before every `return`; symmetric
    pattern.  No write-lock taken (read lock only) — release
    is consistent.
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - Output structs contain `PSID` / `PACL` fields, but each arm
    rewrites these to point *inside the user's output buffer*
    (e.g. `:239` `PSid = LocalUser + sizeof(TOKEN_USER)`) so
    only user-space addresses are leaked.  No kernel pointers
    in any arm's output.

---

## NtSetInformationToken

Source: [`SE/TOKENSET.C`](../../src/NT/PRIVATE/NTOS/SE/TOKENSET.C) · service #146

Three valid `TOKEN_INFORMATION_CLASS` arms only: `TokenOwner`,
`TokenPrimaryGroup`, `TokenDefaultDacl`.  Other values rejected at
`:174-180` before token reference.  Each arm captures the input via
`SeCaptureSid` / `SeCaptureAcl`, validates, writes the token's
default field, releases the capture.

- [x] C1 Probe-then-deref TOCTOU
  - Initial `ProbeForRead(TokenInformation, TokenInformationLength,
    …)` at `:160` covers the header.  Per-arm code reads scalar
    fields (e.g. `((PTOKEN_OWNER)TokenInformation)->Owner` at
    `:228`) inside an arm-local `__try`.  Capture into kernel
    pool isolates the rest from TOCTOU.
- [x] C2 Direct user-pointer deref without capture
  - Each variable input goes through an SE capture helper.
- [x] C3 Missing `__try` wrap
  - All variable user-pointer accesses inside the arm's `__try`.
- [x] C4 Length-field trust
  - `TokenInformationLength` checked against
    `sizeof(TOKEN_OWNER)` / `sizeof(TOKEN_PRIMARY_GROUP)` /
    `sizeof(TOKEN_DEFAULT_DACL)` at arm entry.
- [x] C5 Integer overflow in size computation
  - `SeCaptureSid` is bounded by SID format (`SubAuthorityCount`
    is a `UCHAR`, max SID ≈ 1028 bytes).  `SeCaptureAcl` is
    bounded by 16-bit `AclSize` (max 65535).  Neither helper
    multiplies a user count by a fixed entry size — no wrap
    surface here.
- [x] C6 Semantic validation gaps
  - Invalid info classes rejected at `:174-180`.
  - `TokenOwner` arm validates that the proposed owner SID
    appears in the token's user-or-groups list with the
    `SE_GROUP_OWNER` attribute — caller can't promote arbitrary
    SIDs to default owner.
  - `TokenPrimaryGroup` similarly validates membership.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - SID captures bounded ≤ 1028 bytes; ACL captures bounded
    ≤ 65535 bytes.  `TokenDefaultDacl` uses `NonPagedPool` for
    the ACL capture (mirrors `NtCreateToken`'s helper choice) —
    bounded but uses precious non-paged pool.
- [x] C10 Uninitialized output / pool-contents leak
  - No output buffer; this syscall is set-only.
- [x] C11 Reference-count discipline under error paths
  - Token reference released on every arm exit.  Capture
    releases inside `if (Captured* != NULL)` style guards.
    Each arm symmetric.
- [x] C12 Kernel-address / kernel-pointer leak via info classes
  - No output.

---

## Shared helpers (TOKENADJ.C, TOKEN.C, TOKENDUP.C, CAPTURE.C)

Helpers don't have their own syscall row; findings are attributed back
to the syscalls that reach them.  This section catalogs the
helper-side defects so a fix lands in one place and clears multiple
syscall checkboxes at once.

### `SeCaptureLuidAndAttributesArray` (CAPTURE.C:1211)

- Both entry points (`SeCaptureLuidAndAttributesArray:1325` and
  `SeCaptureSidAndAttributesArray:1615` below) reject
  `ArrayCount > SEP_MAX_CAPTURE_COUNT (0x10000)` with
  `STATUS_INVALID_PARAMETER` before any multiply or allocation.
  The cap is sized to (a) prevent `ArrayCount * sizeof(...)` from
  wrapping a `ULONG`, and (b) cap single-call pool footprint at
  ~768 KB (LUID path) / ~5.5 MB (SID path).  No legitimate caller
  approaches the cap — realistic token group/privilege counts
  are O(10s).
- The C5 wrap is therefore no longer reachable through either
  helper; downstream OOB reads in `SepAdjustPrivileges` /
  `SepAdjustGroups` and the C5-driven OOB primitives in
  `SepCreateToken` are bounded.
- The `*CapturedArray=NULL` on `ArrayCount=0` behaviour
  (`:1297-1301`) remains — combined with the unguarded
  `SeReleaseLuidAndAttributesArray` (`:1862`) it still gives
  `ExFreePool(NULL)` → `BAD_POOL_CALLER` for any caller that
  releases unconditionally.  See **P4** (open).
- Reached from: `NtAdjustPrivilegesToken`, `NtPrivilegeCheck`,
  `NtCreateToken`.

### `SeCaptureSidAndAttributesArray` (CAPTURE.C:1442)

- Capped via `SEP_MAX_CAPTURE_COUNT` (see above).  The previously-
  noted kernel-pool **OOB write** primitive — first-pass loop at
  `:1647-1665` iterating an unwrapped count against the wrapped
  `TempArray` allocation — is no longer reachable: the cap rejects
  hostile counts before the allocation runs.
- Same `*CapturedArray=NULL` on `ArrayCount=0` + unguarded
  `SeReleaseSidAndAttributesArray` pattern remains (P4, open).
- Reached from: `NtAdjustGroupsToken`, `NtCreateToken`.

### `SeCaptureSid` (CAPTURE.C:749) — clean

- Bounded by `UCHAR SubAuthorityCount × 4 + header` ≤ 1028 bytes.
- Probes, allocates, copies, validates with `RtlValidSid`.
- `SeReleaseSid` (`:925`) has the same unconditional `ExFreePool`
  shape, but normal call sites only reach it on success →
  non-NULL.

### `SeCaptureAcl` (CAPTURE.C:975) — clean

- Bounded by `USHORT AclSize` ≤ 65535.
- Probes, allocates, copies, validates with `SepCheckAcl`.
- Uses `NonPagedPool` when caller requests (NtCreateToken,
  NtSetInformationToken `TokenDefaultDacl` arm) — precious pool,
  but bounded.
- `SeReleaseAcl` shares the unconditional-`ExFreePool` shape; same
  practical-safety argument as `SeReleaseSid`.

### `SepAdjustPrivileges` (TOKENADJ.C:817)

- Outer loop bounded by `Token->PrivilegeCount` (kernel, ~30 max).
- Inner loop iterates `NewIndex < PrivilegeCount` against the
  wrapped LUID capture — OOB read on the LUID values, by-value
  comparison via `RtlLargeIntegerEqualTo`, no pointer deref.
- Reaches kernel AV if the wrapped-capture follow-on slab is
  unmapped → bug-check (first-pass caller has no `__try`).

### `SepAdjustGroups` (TOKENADJ.C:1101)

- Same shape as `SepAdjustPrivileges` but **worse**: inner loop's
  `RtlEqualSid(token-side, NewState[NewIndex].Sid)` dereferences
  the OOB-read PSID.  Kernel pointer disclosure / arbitrary-kernel-
  page-read side channel on match; bug-check on unmapped.
- First-pass caller (`NtAdjustGroupsToken:677`) has no `__try`.

### `SepCreateToken` (TOKEN.C:1765)

- **Privilege check at `:2223`** — runs *after* `ObCreateObject`,
  body initialization, and `DynamicPart` allocation.  Unprivileged
  callers reach all earlier work.
- `:1934`, `:1946`, `:1982`, `:2118`, `:2146` — five loops driven
  by the *unwrapped* user `GroupCount` / `PrivilegeCount`; against
  the wrapped capture allocations these are kernel-pool
  OOB read/write primitives.
- `DynamicPart` (`:2168`) is allocated without zero-init; gap
  between PrimaryGroup and DefaultDacl carries uninitialized pool
  bytes.  Not reachable through current `NtQueryInformationToken`
  arms but should be zeroed defensively.
- Accepts `GroupCount=0` → token with `UserAndGroupCount=1` which
  later wraps in `NtQueryInformationToken`'s `TokenGroups` arm.

### `SepDuplicateToken` (TOKENDUP.C:340)

- Wholesale `RtlMoveMemory` of `ExistingToken->VariablePart` at
  `:536-539` — propagates any uninitialized padding from source
  to duplicate.
- `:642` casts `PACL` where `PSID` was meant — type-confused but
  the pointer math is correct, no runtime consequence.
- Reachable only through validated syscalls; no direct
  attacker-controlled inputs.

### Release functions (`SeRelease*And…Array`, `SeReleaseSid`, `SeReleaseAcl`, `SeReleaseSecurityDescriptor`)

- All five release helpers in `CAPTURE.C` early-return on NULL
  before reaching `ExFreePool`.  `BAD_POOL_CALLER` bug-check on
  NULL-release is no longer reachable at either outlier site
  (`NtAdjustGroupsToken:799`, `NtPrivilegeCheck:418`).  Other
  callers that already gated with `if (Captured* != NULL)` are
  unaffected by the change.

## Fix-scope summary across SE

Fixing **four** helper-side issues closes the bulk of the SE findings:

1. ~~**Overflow-check `ArrayCount * sizeof(…)`** in both capture-array
   helpers~~ — **done**.  `SEP_MAX_CAPTURE_COUNT = 0x10000` cap in
   `CAPTURE.C` rejects hostile counts at both
   `SeCaptureLuidAndAttributesArray:1325` and
   `SeCaptureSidAndAttributesArray:1615` before any multiply or
   allocation.  Closes the C5 findings on `NtAdjustGroupsToken`,
   `NtAdjustPrivilegesToken`, `NtPrivilegeCheck`, and (capture-layer
   portion of) `NtCreateToken`.  Tests: `pkg/test/fuzz/se.lua`.
2. ~~**NULL-check in release helpers**~~ — **done**.  All five
   release helpers in `CAPTURE.C` (`SeReleaseSecurityDescriptor`,
   `SeReleaseSid`, `SeReleaseAcl`,
   `SeReleaseLuidAndAttributesArray`,
   `SeReleaseSidAndAttributesArray`) early-return on NULL.  Closes
   the C11 findings on `NtAdjustGroupsToken:799` and
   `NtPrivilegeCheck:418`.  Test:
   `pkg/test/fuzz/se.lua` `NtPrivilegeCheck succeeds on
   PrivilegeCount=0`.
3. **Wrap first-pass `SepAdjust*` calls in `__try`** at
   `TOKENADJ.C:313` and `:677`.  Turns OOB-read AVs into status
   returns instead of bug-checks; defense-in-depth even with the
   C5 fix.
4. **Move `SeSinglePrivilegeCheck` to the top of `SepCreateToken`**
   (before `ObCreateObject`).  Closes the unprivileged-reachability
   on `NtCreateToken` for the new SepCreateToken-side primitives.

Remaining syscall-local issues (handle leaks, dead `TokenType`
check, `*PrivilegeSetLength` outside `__try`, refcount leak at
`ACCESSCK.C:1107`) are independent and need per-syscall fixes.
