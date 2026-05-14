# Syscall audit — LPC (Local procedure call)

14 syscalls.  See 
[`README.md`](README.md) for legend, class definitions, and the
rationale for the N/A pre-fills.

## NtAcceptConnectPort

Source: [`LPC/LPCCOMPL.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCCOMPL.C) · service #0

Server-side accept: probes output `PortHandle` (always),
`ServerView` / `ClientView` (optional, with `Probe…Write` each),
captures `ConnectionRequest` `PORT_MESSAGE` header.  Wraps the
listening port + the client-side server-port pair, inserts a
new port handle into the server's table.

- [x] C1 Probe-then-deref TOCTOU — probes inside `__try` at
  `:234-265`.
- [x] C2 Direct user-pointer deref without capture — `ConnectionRequest`
  header captured into local.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — message lengths captured.
- [x] C5 Integer overflow in size computation — `ConnectionInformation`
  length bounded by per-port `MaxConnectionInfoLength`.
- [x] C6 Semantic validation gaps — port handle validated for
  `PORT_ALL_ACCESS`; client-port pair matched against listening
  port state.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — port
  zone allocation bounded by per-port `MaxPoolUsage`.
- [x] C10 Uninitialized output / pool-contents leak — output port
  fields populated explicitly.
- [ ] C11 Reference-count discipline under error paths
  - Same handle-leak pattern at output-write; some sites use
    `NtClose` cleanup, others fall through.  Mixed
    discipline — flag during fix sweep.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- [ ] C13 Cancel / completion-routine races — long-poll listen
  is cancellable; cancel semantics in LPC layer.

---

## NtCompleteConnectPort

Source: [`LPC/LPCCOMPL.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCCOMPL.C) · service #12

Server-side connect completion: references the port created by
`NtAcceptConnectPort`, signals the connect message on the
client's reply queue.  No user-memory probes (just handles).

- [x] C1 Probe-then-deref TOCTOU — no user pointers.
- [x] C2 Direct user-pointer deref without capture — none.
- [x] C3 Missing `__try` wrap — no user-memory access.
- [x] C4 Length-field trust — no length parameter.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — port state checked
  (must be a server-side communication port awaiting completion).
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no output.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  no output.
- C13 Cancel / completion-routine races — N/A

---

## NtConnectPort

Source: [`LPC/LPCCONN.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCCONN.C) · service #13

Client-side connect.  Probes output `PortHandle`, optional
`ClientView` / `ServerView` `PORT_VIEW` structs, optional
`MaxMessageLength` ULONG, optional `ConnectionInformation` +
`ConnectionInformationLength`, optional `SecurityQos`.  Allocates
client-side port object, builds connection-request message,
sends it to the server's listen queue, waits for accept/reject.

- [x] C1 Probe-then-deref TOCTOU — probes inside `__try` at
  `:228-280`.
- [x] C2 Direct user-pointer deref without capture — `*PortView`
  captured, `ConnectionInformation` captured (copied into the
  request message).
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — `ConnectionInformationLength`
  captured and bounded against per-server `MaxConnectionInfoLength`.
- [x] C5 Integer overflow in size computation — message size
  bounded by zone block.
- [x] C6 Semantic validation gaps — server name resolved by
  `ObOpenObjectByName`; `SecurityQos` validates impersonation
  level.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Connection message sized by `ConnectionInformationLength`
    bounded above by per-server `MaxConnectionInfoLength` (set
    at server-side `NtCreatePort`).
- [x] C10 Uninitialized output / pool-contents leak — output port
  fields filled explicitly.
- [ ] C11 Reference-count discipline under error paths
  - Handle-leak pattern: same as the rest of the LPC family
    — some sites use `NtClose` on output-write fault, some
    don't.  Mixed.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- [ ] C13 Cancel / completion-routine races — connect is a
  blocking wait; alertable.

---

## NtCreatePort

Source: [`LPC/LPCCREAT.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCCREAT.C) · service #25

Server-side port creation.  Probes output `PortHandle`,
dereferences `ObjectAttributes->ObjectName` chain to decide
named/unnamed.  Allocates port object, zero-initializes,
initializes message queue, inserts handle.

- [ ] C1 Probe-then-deref TOCTOU — **finding (minor)**
  - The named/unnamed branch decision at `:120-125` reads
    `ObjectAttributes->ObjectName != NULL`, then
    `->ObjectName->Length`, then `->ObjectName->Buffer` — three
    derefs of the same chain.  Inside `__try` so faults are
    caught, but a deliberate concurrent attacker could flip the
    `ObjectName` pointer between reads to switch branches.
    Both branches lead to legitimate behaviour (unnamed vs
    named port creation), so no security impact — but the
    pattern is C1-like.
  - Capture the `ObjectName` pointer (and its `Length`) into
    locals once, then test the locals.
- [x] C2 Direct user-pointer deref without capture — same C1
  issue; recommend single-read capture.
- [x] C3 Missing `__try` wrap — user-memory access inside try.
- [x] C4 Length-field trust — `MaxConnectionInfoLength` /
  `MaxMessageLength` / `MaxPoolUsage` are by-value; the helper
  clamps them against zone block size.
- [x] C5 Integer overflow in size computation — none at this
  layer.
- [x] C6 Semantic validation gaps — `ObCreateObject` validates
  `ObjectAttributes`.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - `MaxPoolUsage` advertised by server — per-port quota,
    bounded by server policy.
- [x] C10 Uninitialized output / pool-contents leak
  - `RtlZeroMemory(ConnectionPort, sizeof(LPCP_PORT_OBJECT))`
    at `:161` zeros the whole object before per-field
    population.
- [x] C11 Reference-count discipline under error paths — **clean (positive)**
  - `:240-247` is the **template fix** for the handle-leak
    pattern: `try { *PortHandle = Handle } except {
    NtClose(Handle); Status = GetExceptionCode() }`.  This is
    the shape every Open*/Create* syscall in OB/SE/IO/MM
    should be rewritten to match.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `HANDLE` only.
- C13 Cancel / completion-routine races — N/A

---

## NtImpersonateClientOfPort

Source: [`LPC/LPCPRIV.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCPRIV.C) · service #54

Probes the `PORT_MESSAGE`-typed `ClientMessage`, captures its
header (including `ClientId`), references the port, looks up the
client thread by `ClientId`, calls `SeImpersonateClient` to copy
the client's token onto the current thread's impersonation slot.

- [x] C1 Probe-then-deref TOCTOU — message captured inside try.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — fixed-size header.
- [x] C5 Integer overflow in size computation — none.
- [x] C6 Semantic validation gaps — `ClientId` must reference a
  thread that sent the matching message (chain-walk validation).
  `SeImpersonateClient` validates the source token's
  impersonation level.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — no buffer
  output.
- [x] C11 Reference-count discipline under error paths — port
  derefed on each branch.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  no output.
- C13 Cancel / completion-routine races — N/A

---

## NtListenPort

Source: [`LPC/LPCLISTN.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCLISTN.C) · service #57

Server-side listen for a connection request.  Probes the
`PORT_MESSAGE`-typed output buffer, references the listening
port, blocks until a connection-request message arrives, copies
the request into the user buffer.

- [x] C1 Probe-then-deref TOCTOU — probe + write inside try.
- [x] C2 Direct user-pointer deref without capture — output write.
- [x] C3 Missing `__try` wrap — output inside try.
- [x] C4 Length-field trust — fixed-size `PORT_MESSAGE` header +
  connection-info body bounded by per-port
  `MaxConnectionInfoLength`.
- [x] C5 Integer overflow in size computation — bounded.
- [x] C6 Semantic validation gaps — port must be a server
  connection port; alertable wait.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation —
  message stays in the zone (no per-call allocation).
- [x] C10 Uninitialized output / pool-contents leak — port message
  populated from the connection request; copy is sized-correct.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  `ClientId` in `PORT_MESSAGE` is a `CLIENT_ID` (pid/tid pair),
  not a pointer.
- [ ] C13 Cancel / completion-routine races — long-poll wait;
  alertable.

---

## NtQueryInformationPort

Source: [`LPC/LPCQUERY.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCQUERY.C) · service #92

Probes the per-class output buffer, references the port, fills
`PORT_BASIC_INFORMATION` (`MaxMessageLength`, `MaxConnectionInfoLength`).

- [x] C1 Probe-then-deref TOCTOU — probe + write inside try.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output inside try.
- [x] C4 Length-field trust — per-class size validated.
- [x] C5 Integer overflow in size computation — fixed struct.
- [x] C6 Semantic validation gaps — only `PortBasicInformation`
  class accepted.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — none.
- [x] C10 Uninitialized output / pool-contents leak — struct
  fields written explicitly.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  scalar fields only.
- C13 Cancel / completion-routine races — N/A

---

## NtReadRequestData

Source: [`LPC/LPCREPLY.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCREPLY.C) · service #116

Server-side read of out-of-band message data referenced by an
incoming request.  Probes the output `Buffer` for `BufferSize`,
probes optional `NumberOfBytesRead`, references the port, walks
to the matching client thread's pending message data, copies
out of the source thread's address space.

- [x] C1 Probe-then-deref TOCTOU — probes inside try.
- [x] C2 Direct user-pointer deref without capture — output only.
- [x] C3 Missing `__try` wrap — output inside try.
- [x] C4 Length-field trust — `BufferSize` is by-value.
- [x] C5 Integer overflow in size computation — bounded by
  `DataInfo.BufferSize` in the source message (USHORT).
- [x] C6 Semantic validation gaps — `Message.MessageId` /
  `DataInfoOffset` validated against the in-flight message
  list.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Uses `MmProbeAndLockPages` (no separate pool buffer).
- [x] C10 Uninitialized output / pool-contents leak — source data
  copied; bounds bounded by source-side `DataInfo.BufferSize`.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  source-process bytes only.
- C13 Cancel / completion-routine races — N/A

---

## NtReplyPort

Source: [`LPC/LPCREPLY.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCREPLY.C) · service #124

Server-side reply.  Probes `ReplyMessage` header, captures it,
references the port, allocates reply slot from zone, copies
reply data, hands off to the waiting client thread.

- [x] C1 Probe-then-deref TOCTOU — captured inside try at `:48`.
- [x] C2 Direct user-pointer deref without capture — header
  captured.
- [x] C3 Missing `__try` wrap — accesses inside try; `LpcpMoveMessage`
  has its own try for the body copy.
- [x] C4 Length-field trust — `TotalLength` captured and bounded
  by zone block size.
- [x] C5 Integer overflow in size computation — bounded.
- [x] C6 Semantic validation gaps — `MessageId` must match a
  pending request; `Type` validated.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Zone-bounded message slot; one per outstanding request.
- [x] C10 Uninitialized output / pool-contents leak — server's
  reply data copied into kernel zone, then delivered to client.
- [x] C11 Reference-count discipline under error paths
  - Message returned to zone on fault; port derefed.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  no output buffer to caller.
- C13 Cancel / completion-routine races — N/A

---

## NtReplyWaitReceivePort

Source: [`LPC/LPCRECV.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCRECV.C) · service #125

The big one — server's main message-receive loop.  Probes input
`ReplyMessage` (optional, when sending a reply alongside the
wait), captures its header, probes output `ReceiveMessage`,
probes optional `PortContext` output, references the port,
delivers the pending reply (if any), waits on the port's
message queue, copies received message to user buffer.

- [x] C1 Probe-then-deref TOCTOU — probes + captures inside try.
- [x] C2 Direct user-pointer deref without capture — `ReplyMessage`
  header captured.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — message lengths captured; bounded.
- [x] C5 Integer overflow in size computation — bounded by zone.
- [x] C6 Semantic validation gaps — port handle access required;
  message-id matching for replies.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Each pending message occupies one zone block; per-port
    `MaxPoolUsage` bounds aggregate.
- [x] C10 Uninitialized output / pool-contents leak — received
  message data copied from sender's zone block.  Sender controls
  the contents; kernel adds no padding.
- [ ] C11 Reference-count discipline under error paths
  - Multiple cleanup paths; verify that any partially-delivered
    reply is returned to the message queue (rather than dropped)
    on receive-side failure.  Soft concern, deferred.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  source-process bytes only.
- [ ] C13 Cancel / completion-routine races — alertable wait;
  cancel during partial receive is the main race.

---

## NtReplyWaitReplyPort

Source: [`LPC/LPCREPLY.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCREPLY.C) · service #126

Send a reply and then wait for another reply on the same port.
Less common than `NtReplyWaitReceivePort`; same probe + capture
pattern.

- [x] C1 Probe-then-deref TOCTOU — captured inside try.
- [x] C2 Direct user-pointer deref without capture — captured.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — captured.
- [x] C5 Integer overflow in size computation — bounded.
- [x] C6 Semantic validation gaps — message-id matching for
  reply chain.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation —
  zone-bounded.
- [x] C10 Uninitialized output / pool-contents leak — sender's
  data only.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- [ ] C13 Cancel / completion-routine races — alertable wait.

---

## NtRequestPort

Source: [`LPC/LPCSEND.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCSEND.C) · service #127

Client → server one-way request (no reply expected).  Probes
`RequestMessage` header, captures it, validates `Type=0` and
`DataInfoOffset=0`, references port, allocates message from
zone (sized by `CapturedRequestMessage.u1.s1.TotalLength`),
copies into zone via `LpcpMoveMessage` inside its own try,
queues to receiver, signals receive semaphore.

- [x] C1 Probe-then-deref TOCTOU — captured at `:190` inside try.
- [x] C2 Direct user-pointer deref without capture — header
  captured; body copied via `LpcpMoveMessage`.
- [x] C3 Missing `__try` wrap — body copy at `:242-252` inside try.
- [x] C4 Length-field trust — `TotalLength` from captured header.
- [x] C5 Integer overflow in size computation
  - Zone block size bounds `TotalLength` (via
    `LpcpAllocateFromPortZone`); per-port `MaxMessageLength`
    derived from zone.
- [x] C6 Semantic validation gaps — `Type=0` and `DataInfoOffset=0`
  enforced at `:200-206`.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation
  - Per-message zone block; aggregate bounded by per-port
    `MaxPoolUsage` (server's `NtCreatePort` setting).
- [x] C10 Uninitialized output / pool-contents leak — sender's
  data only.
- [x] C11 Reference-count discipline under error paths
  - On `LpcpMoveMessage` fault, `LpcpFreeToPortZone(Msg, FALSE)`
    at `:254` returns the block.  Port derefed on every branch.
- [x] C12 Kernel-address / kernel-pointer leak via info classes —
  none.
- C13 Cancel / completion-routine races — N/A (datagram is
  not cancellable; non-blocking).

---

## NtRequestWaitReplyPort

Source: [`LPC/LPCSEND.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCSEND.C) · service #128

Synchronous client → server → reply.  Probes both `RequestMessage`
input and `ReplyMessage` output, captures the request header,
queues request, waits (alertable) for reply, copies reply into
user buffer.

- [x] C1 Probe-then-deref TOCTOU — probes inside try at `:652-657`.
- [x] C2 Direct user-pointer deref without capture — header
  captured; reply body written via `LpcpMoveMessage` inside try.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — captured.
- [x] C5 Integer overflow in size computation — zone-bounded.
- [x] C6 Semantic validation gaps — same as `NtRequestPort` plus
  reply-message-id matching.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation —
  zone-bounded.
- [x] C10 Uninitialized output / pool-contents leak — server-
  controlled reply data only.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- [ ] C13 Cancel / completion-routine races — alertable wait.

---

## NtWriteRequestData

Source: [`LPC/LPCREPLY.C`](../../src/NT/PRIVATE/NTOS/LPC/LPCREPLY.C) · service #180

Server-side write of out-of-band message data into a client
thread's address space (the inverse of `NtReadRequestData`).
Probes input `Buffer` for `BufferSize`, captures `Message`
header to find the target client, copies into the client's
mapped region.

- [x] C1 Probe-then-deref TOCTOU — probes inside try at `:601-613`.
- [x] C2 Direct user-pointer deref without capture — input copied
  through MDL.
- [x] C3 Missing `__try` wrap — accesses inside try.
- [x] C4 Length-field trust — `BufferSize` is by-value.
- [x] C5 Integer overflow in size computation — bounded by source
  message's `DataInfo.BufferSize`.
- [x] C6 Semantic validation gaps — message-id and data-info-offset
  validated.
- C7 IOCTL access-bit encoding — N/A
- C8 Output buffer aliasing / METHOD mismatch — N/A
- [x] C9 Pool exhaustion via attacker-controlled allocation — uses
  MDL.
- [x] C10 Uninitialized output / pool-contents leak — input syscall;
  `NumberOfBytesCopied` writeback only.
- [x] C11 Reference-count discipline under error paths.
- [x] C12 Kernel-address / kernel-pointer leak via info classes — none.
- C13 Cancel / completion-routine races — N/A

---

## Fix-scope summary across LPC

### Root-cause groups

1. **Handle-write fault discipline — mixed across LPC**
   - `NtCreatePort` (`LPCCREAT.C:240-247`) gets it **right**:
     `try { *PortHandle = Handle } except { NtClose(Handle);
     Status = GetExceptionCode() }`.  Worth treating as the
     template for fixing the same pattern elsewhere in
     OB/SE/IO/MM.
   - `NtAcceptConnectPort` and `NtConnectPort` may have the
     same template — flag during the fix sweep to confirm
     every output-handle write uses the `NtClose` cleanup.

2. **`NtCreatePort` C1-like chained user-deref** —
   `ObjectAttributes->ObjectName != NULL` → `->Length` →
   `->Buffer` at `:120-125` and `:132-134` are three reads of
   the same user pointer chain inside one try.  A racing
   attacker can flip `ObjectName` between reads, but both
   branches (named/unnamed port) are legitimate behaviour, so
   no security impact.  Code-quality fix: capture once.

3. **Per-port quota policy** — `MaxConnectionInfoLength` and
   `MaxPoolUsage` are advertised by the server at
   `NtCreatePort`.  A buggy / hostile server could advertise
   huge values and force the kernel to bound them only by the
   zone block size (typically 256 bytes per message).
   Defensible — zone is already the hard cap — but documented
   here for the `KERNEL-ABI-HARDENING.md` Class 9 audit.

### Fix shape

1. **Output-handle leak audit** — sweep the four LPC syscalls
   that write a `PortHandle` (`NtCreatePort`,
   `NtAcceptConnectPort`, `NtConnectPort`, `NtRequestPort` /
   reply variants don't have one) and verify the
   `NtCreatePort`-style cleanup is present at each
   `*Handle = Handle` site.  Anywhere it isn't, apply the
   same template.

2. **`NtCreatePort` named/unnamed capture** — three-line edit
   to capture `ObjectName` into a local before the branch
   test:
   ```c
   PUNICODE_STRING capturedName = ObjectAttributes->ObjectName;
   if (capturedName == NULL || capturedName->Length == 0 ||
       capturedName->Buffer == NULL) { UnNamedPort = TRUE; }
   ```

### Clean classes

LPC's probe-then-capture discipline is consistently rigorous.
Message bodies travel via `LpcpMoveMessage`, which has its own
`__try` for the body copy.  Zone-based allocation caps every
per-message kernel allocation.

### Deferred items

- **`NtReplyWaitReceivePort` partial-receive cleanup** (C11
  soft concern) — when the receive copy faults partway, does
  the kernel re-queue the message or drop it?  Verify the
  cleanup path in `LPCRECV.C`.
- **`LpcpMoveMessage`** — body-copy helper.  Worth confirming
  the bound matches the captured `TotalLength`.
- **`LpcpDetermineQueuePort` length validation** — called
  inside the request path with the captured request message;
  confirm it bounds against per-port max.

### Cross-references

- LPC is the underpinning for the security subsystem's
  client/server model.  `NtImpersonateClientOfPort` couples
  with the SE token impersonation rules — flagged during the
  SE audit.
- The window-manager / CSRSS interactions live entirely on
  LPC; CSR's IDLE-style state machines aren't subject to this
  syscall-level audit (they're userspace).
