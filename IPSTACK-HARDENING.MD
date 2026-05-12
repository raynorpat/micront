# IP Stack Hardening

Working document. Tracks the scope, threat model, identified risks, analysis,
decisions, and test status for hardening the NT 3.50 IP/TCP/UDP stack as
shipped in MicroNT.

Nothing here is a patch plan. Findings are entered, analysed, decided on, and
tested before any code change lands. The document is the audit trail for that
process.

## 1. Scope

In scope:

- Single-NIC virtualised guest. One ethernet device, no IP forwarding, no
  multi-homing.
- Deployment targets: arbitrary x86 KVM/Proxmox/Xen-based VPS, EC2, GCE,
  Hetzner, OVH, low-end providers. Hypervisor anti-spoof and L2 isolation
  vary; assume hostile L2 for cheapest tier.
- Public-internet reachable IPv4. Any "appliance in front" (NAT, LB, WAF) is
  treated as bonus, not as a precondition. Correctness must hold without it.
- Stack components in this tree:
  - `src/NT/PRIVATE/NTOS/NDIS/WRAPPER` (and `NDIS/VIONET` driver)
  - `src/NT/PRIVATE/NTOS/TDI/TCPIP/{IP,TCP,H}`
  - `src/NT/PRIVATE/NTOS/AFD`

Out of scope (explicitly, recorded so we don't drift):

- IPv6. Not present in the source tree.
- IPSec, PPTP, RAS, NetBT-over-TCP. Not in this tree at this stage.
- IP forwarding / router behaviour. We assert non-forwarding host and will
  enforce that as an invariant.
- Anything above the transport layer (RPC, SMB, MSV1_0, etc.) — separate
  hardening track.
- Cloud-layer controls (security groups, firewall rules, LB terminators).
  Not a substitute for stack correctness; not analysed here.

## 2. Threat model

Adversaries we plan to defend against:

- T1. **Internet attacker, off-path.** Can send arbitrary IP packets to our
  public address. Cannot observe replies that do not return to its address.
- T2. **Internet attacker, semi-blind.** As T1, but can probe responses
  through reflection / side channels.
- T3. **L2 neighbour on the same hypervisor segment.** Can send raw frames
  with chosen source MAC, can ARP-spoof, can claim to be the gateway. Some
  hypervisors filter (EC2, GCE source/dest check); cheap VPS often do not.
- T4. **Resource-bounded attacker.** Limited but non-trivial pps and
  bandwidth from one or more sources; intent is denial of service against
  the host kernel, not a specific application.

Not in our threat model:

- Adversary with code execution on the host. Kernel/userland separation is a
  separate problem.
- Compromised hypervisor.
- Stateful, fully on-path adversary that can both observe and inject. (We
  note where this matters but do not attempt to defeat it.)

## 3. Methodology

Each finding follows the same lifecycle:

1. **Logged** — file, line, rough class, one-line summary.
2. **Analysed** — what the bad path does, what an attacker controls, what
   inputs reach it, what the failure mode is (BSOD / pool exhaustion / route
   hijack / info leak / wrap-around copy / etc.). Cite code; quote the lines
   that matter.
3. **Reproducer drafted** — concrete packet(s) that exercise the bad path,
   expected observable on the unpatched stack.
4. **Reproducer confirmed** — run against unpatched MicroNT, observe the
   predicted failure. A finding without a working reproducer stays
   "suspected" rather than "confirmed".
5. **Decision** — one of:
   - `FIX` (with sketched approach),
   - `ACCEPT` (with rationale: not reachable under §1/§2, or cost > benefit),
   - `DEFER` (with what would change to revisit),
   - `INVALID` (analysis showed the bug isn't actually present).
6. **Patch** — minimal, isolated, commented; references this document by
   finding ID. Patch lands only after the reproducer is in the regression
   harness.
7. **Verified** — reproducer no longer triggers; legitimate traffic
   regression suite still passes.

Conventions:

- Findings are numbered `H-NNN` and never renumbered. `INVALID` findings stay
  in the table with that status, not deleted.
- File:line citations are pinned to a commit hash when first written so they
  remain meaningful as the tree evolves. Re-pin on substantial code change.
- "Reachable" means: under §1 scope and §2 threat model, an unauthenticated
  remote can drive the input. "Reachable, post-bind" means a listening
  service is required.

## 4. Cross-cutting invariants

Properties we want to assert and keep asserted. Each is its own work item;
violations turn into findings.

- I1. **No IP forwarding, ever.** Registry, init path, and any runtime
  toggle must default off. To be enforced and verified by boot-time check.
- I2. **No source-routed packets accepted for local delivery.** LSRR/SSRR
  options on inbound packets cause drop, not processing. (Distinct from I1:
  a non-forwarding host can still honour source routing for itself.)
- I3. **No ICMP redirect acceptance.** Redirect arrivals are counted and
  dropped; routing table is not mutated by network input.
- I4. **Reassembly is bounded.** Total in-flight reassembly memory and
  per-source context count have explicit caps; oldest contexts evict on
  pressure; per-context timeout is enforced on a real timer, not opportunistic.
- I5. **Datagram size is bounded before allocation.** Any path that adds
  fragment data computes the resulting total length in a width that cannot
  alias 16-bit, and rejects > 65535 before touching reassembly state.
- I6. **TCB allocation is bounded per listener.** SYN-RCVD count per
  listening AddrObj has a cap; over-cap drops the oldest half-open or the
  new SYN, deterministically.
- I7. **Per-TCB out-of-order queue is bounded in bytes.** Past the cap,
  segments are dropped; no allocation chain grows unboundedly with
  attacker-chosen seq numbers.
- I8. **ARP cache changes are validated.** Replies to non-outstanding
  requests do not silently overwrite entries; cache size is capped.

The findings in §6 are the specific places where we today violate one or
more of these invariants.

## 5. Test infrastructure

To be filled in. Sketch:

- Send side: Linux host with scapy, generating one finding's worth of
  packets per script. Each script self-documents the finding ID and the
  expected target behaviour ("BSOD on unpatched", "drop+counter on patched").
- Receive side: MicroNT under QEMU/KVM with virtio-net, kernel debug serial
  captured, pool counters and IP stat counters exported.
- Oracle: per-finding observable. BSOD = guest dies. Pool DoS = nonpaged pool
  watermark crosses threshold. Route hijack = routing table changes. Reject =
  specific stat counter increments and packet does not reach upper layer.
- Regression: golden traffic suite (TCP echo, HTTP fetch, fragmented UDP at
  spec sizes, ICMP echo at 64/1472/8192 bytes) passes on patched build.

Open questions:

- Q1. Do we drive reproducers from the same Linux host or a second guest?
  (Same-host is faster to wire up; second-guest matches T3 better.)
- Q2. How do we observe nonpaged pool from outside the guest reliably?
- Q3. What's our acceptance criterion for "rate" when we cap things — chosen
  by measurement on the smallest target VPS, or fixed conservative number?

## 6. Findings

Status legend: `LOGGED` / `ANALYSED` / `REPRO` / `DECIDED` / `PATCHED` / `VERIFIED` / `ACCEPTED` / `DEFERRED` / `INVALID`.

Severity: `CRIT` (single-packet host kill or root-equivalent compromise),
`HIGH` (remote DoS or route/identity hijack), `MED` (resource exhaustion
needing volume, or partial info leak), `LOW` (defence-in-depth).

Reachability: `T1` (off-path internet), `T2` (semi-blind), `T3` (L2 neighbour),
`T4` (rate-bound DoS); `post-bind` if a listening service is required.

Each entry is a stub to be filled in during analysis. Code references are
pinned on first analysis.

---

### H-001 — Fragment overlap underflow (Teardrop / Bonk / NewTear class)

- **Where:** `src/NT/PRIVATE/NTOS/TDI/TCPIP/IP/IPRCV.C` ~441-496 (overlap-trim
  path). Pin commit on first analysis.
- **Class:** Single-packet kill / memory corruption.
- **Severity:** CRIT (suspected).
- **Reachable:** T1.
- **Summary:** Overlap-trim recomputes `DataLength = NewEnd - NewOffset + 1`
  in `ushort`; if trimming makes `NewEnd < NewOffset`, the value wraps and is
  used as a copy length / pointer adjustment. Classic 1997 Teardrop family.
- **Invariant violated:** I5 (and the implicit "subtractions don't go
  negative" invariant on the overlap path).
- **Analysis:** TBD. Walk every assignment to `NewOffset`, `NewEnd`,
  `DataLength`, `DataOffset` in the trim block; enumerate which combinations
  of (existing fragment, new fragment) inputs produce wrap, and what the
  resulting memory operation is.
- **Reproducer:** TBD. Likely two-fragment Teardrop pattern; record exact
  offsets/lengths used.
- **Decision:** 2026-05-11 — strip the reassembly path entirely. No legitimate
  workload in scope produces IP fragments: TCP runs with DF=1 + PMTUD/MSS-clamp,
  UDP large-payload apps fragment at L7 (EDNS0, NFS) or fall back to TCP,
  ICMP large payloads are not load-bearing. With reassembly absent, the
  Teardrop/Bonk/NewTear arithmetic in `ReassembleFragment` does not exist
  to be exploited.
- **Test:** see "Strip verification" entry in §7.
- **Status:** INVALID — code path removed.

### H-002 — Reassembled datagram > 65535 (Ping of Death class)

- **Where:** `IPRCV.C` ~396-418, last-fragment commit path setting
  `RH->rh_datasize`.
- **Class:** Single-packet kill.
- **Severity:** CRIT (suspected).
- **Reachable:** T1.
- **Summary:** `rh_datasize` is `ushort`; final-fragment path assigns
  `Offset + DataLength` with no `<= 65535` check, allowing wrap and
  premature/incorrect reassembly completion.
- **Invariant violated:** I5.
- **Analysis:** TBD.
- **Reproducer:** TBD. Final fragment at high offset, length pushing total
  past 65535.
- **Decision:** 2026-05-11 — covered by the same reassembly strip as H-001.
  The final-fragment commit at `IPRCV.C` ~417-418 no longer exists.
- **Test:** see "Strip verification" entry in §7.
- **Status:** INVALID — code path removed.

### H-003 — Reassembly context exhaustion

- **Where:** `IPRCV.C` ~367-402, `CTEAllocMem(sizeof(ReassemblyHeader))`.
- **Class:** Resource exhaustion / nonpaged pool DoS.
- **Severity:** HIGH.
- **Reachable:** T1, T4.
- **Summary:** No per-source cap, no global cap, no per-RH timer; only
  opportunistic reaping on NTE tick. Fragment-0-only floods with varying
  (src, id) tuples allocate unboundedly.
- **Invariant violated:** I4.
- **Analysis:** TBD. Confirm exact reaping cadence; measure per-RH cost
  including attached `IPRcvBuf`s; pick caps based on smallest target VPS
  nonpaged pool.
- **Reproducer:** TBD. Sustained fragment-0 stream at modest pps.
- **Decision:** 2026-05-11 — covered by the reassembly strip. `ReassemblyHeader`,
  `RABufDesc`, and the per-NTE `nte_ralist` are gone; there is no allocation
  to exhaust.
- **Test:** see "Strip verification" entry in §7.
- **Status:** INVALID — code path removed.

### H-004 — Tiny first fragment / firewall-bypass class

- **Where:** `IPRCV.C` ~529-547, ~635-639.
- **Class:** L4 header truncation across fragments.
- **Severity:** LOW (no firewall in scope at IP layer; mostly a defence-in-depth
  concern). Re-evaluate if we add a packet filter.
- **Reachable:** T1.
- **Summary:** First fragment is allocated to at least `MIN_FIRST_SIZE`, but
  the on-wire fragment can be smaller than the L4 header.
- **Invariant violated:** none directly (but adjacent to I5 hygiene).
- **Analysis:** TBD.
- **Reproducer:** TBD.
- **Decision:** 2026-05-11 — covered by the reassembly strip. Inbound fragments
  are dropped at the dispatch hook before any L4 header reconstruction.
- **Test:** see "Strip verification" entry in §7.
- **Status:** INVALID — code path removed.

### H-005 — Zero-length / zero-offset fragment edge cases

- **Where:** `IPRCV.C` ~408-442.
- **Class:** Edge-case arithmetic in fragment insert.
- **Severity:** MED (suspected; effect depends on combination with H-001).
- **Reachable:** T1.
- **Summary:** No `DataLength > 0` check; `NewEnd = Offset + DataLength - 1`
  underflows on zero-length fragments.
- **Invariant violated:** I5.
- **Analysis:** TBD.
- **Reproducer:** TBD.
- **Decision:** 2026-05-11 — covered by the reassembly strip. The arithmetic
  block does not exist in tree.
- **Test:** see "Strip verification" entry in §7.
- **Status:** INVALID — code path removed.

### H-006 — Source routing honoured (LSRR/SSRR)

- **Where:** `IPRCV.C` ~192-201; forwarding path `IPROUTE.C` ~3051-3083.
- **Class:** Spoofing / trust boundary bypass.
- **Severity:** HIGH on T3, MED on T1 (T1 cannot generally bounce off our
  host because we don't forward; T3 can use SSRR-on-receive to look like a
  trusted source on shared L2).
- **Reachable:** T1 (delivery-to-self), T3 (impersonation).
- **Summary:** LSRR/SSRR options are processed for inbound packets even
  with forwarding off.
- **Invariant violated:** I2.
- **Analysis:** TBD. Confirm whether forwarding=off short-circuits any of
  this. Determine whether any legitimate inbound traffic in our deployment
  would carry these options (expected: none).
- **Reproducer:** TBD.
- **Decision:** TBD.
- **Status:** LOGGED.

### H-007 — IP option-walk infinite loop on Length<2

- **Where:** `IPRCV.C` ~172-214.
- **Class:** Liveness / CPU DoS.
- **Severity:** MED (suspected; depends on whether any earlier validation
  rules out Length<2).
- **Reachable:** T1.
- **Invariant violated:** general parser hygiene.
- **Analysis:** TBD. Is there a higher-level header validator that rejects
  options before this loop sees them?
- **Reproducer:** TBD.
- **Decision:** TBD.
- **Status:** LOGGED.

### H-008 — Record-route / timestamp pointer bounds on update

- **Where:** `IPRCV.C` option parsing + IP transmit option-update path
  (location TBD).
- **Class:** Out-of-bounds write on transit/reply.
- **Severity:** MED (suspected).
- **Reachable:** T1 (via packets that elicit a reply or transit).
- **Analysis:** TBD. With forwarding off and source routing dropped (I1, I2)
  this surface mostly closes; remaining concern is reply-with-options paths.
- **Status:** LOGGED.

### H-009 — ICMP redirect accepted

- **Where:** `ICMP.C` ~789-807; `IPROUTE.C` `Redirect` ~2077-2138.
- **Class:** Route hijack.
- **Severity:** HIGH on T3, low on T1 (acceptance gated on src matching
  current gateway, but spoofing a single IPv4 source on shared L2 is cheap).
- **Reachable:** T3 primarily; T1 if the upstream provider does not filter
  inbound spoofed-source packets.
- **Invariant violated:** I3.
- **Analysis:** TBD. Confirm exact validation. We do not need redirects in
  our deployment.
- **Reproducer:** TBD.
- **Decision:** TBD.
- **Status:** LOGGED.

### H-010 — ICMP echo reply size uncapped

- **Where:** `ICMP.C` ~816-837 (echo handler), `SendEcho` ~312-400.
- **Class:** Amplification / interaction with H-001/H-002.
- **Severity:** HIGH (in combination with reassembly bugs); MED standalone.
- **Reachable:** T1.
- **Analysis:** TBD. Standalone, this is a reflection/amplification factor of
  ~1; severity is mostly inherited from reassembly bugs feeding it.
- **Reproducer:** TBD.
- **Decision:** TBD.
- **Status:** LOGGED.

### H-011 — Land (src == dst SYN)

- **Where:** `TCPRCV.C` ~1807-1810 (SYN handling).
- **Class:** Logic / loop on local TCB.
- **Severity:** MED (NT 3.50-era effect on this code path TBD; was BSOD on
  some Microsoft builds, may be silent loop here).
- **Reachable:** T1.
- **Analysis:** TBD. Trace what the SYN handler actually does when both
  endpoints alias the local addr/port. Effect may be benign loop, ack storm,
  or full hang.
- **Reproducer:** TBD.
- **Decision:** TBD.
- **Status:** LOGGED.

### H-012 — SYN flood / unbounded half-open

- **Where:** `TCPRCV.C` `FindListenConn` ~554-660; `AllocTCB` at ~652;
  `TCB.C` `MaxTCBs` ~47.
- **Class:** Resource exhaustion (TCB / nonpaged pool).
- **Severity:** HIGH.
- **Reachable:** T1, T4. Post-bind for actual exhaustion to land on a
  listener; pre-bind exhaustion of global TCB pool also possible.
- **Invariant violated:** I6.
- **Analysis:** TBD. Behaviour at MaxTCBs ceiling, per-listener accounting
  feasibility, drop-oldest vs drop-new policy.
- **Reproducer:** TBD.
- **Decision:** TBD.
- **Status:** LOGGED.

### H-013 — Per-TCB out-of-order reassembly unbounded

- **Where:** `TCPRCV.C` ~1411-1426 (`CreateTRH`/`PutOnRAQ`).
- **Class:** Per-connection memory exhaustion.
- **Severity:** HIGH on post-bind.
- **Reachable:** T1 post-bind.
- **Invariant violated:** I7.
- **Analysis:** TBD.
- **Reproducer:** TBD. Open one TCP connection, send high-seq segments only.
- **Decision:** TBD.
- **Status:** LOGGED.

### H-014 — Idle-ESTABLISHED reaper (Naptha)

- **Where:** TCB structure `TCP.H` ~136 (`tcb_alive`), accept queue
  handling.
- **Class:** Slow resource exhaustion.
- **Severity:** MED.
- **Reachable:** T1 post-bind.
- **Analysis:** TBD. Confirm whether `tcb_alive` is armed automatically on
  ESTABLISHED transition or only when `KEEPALIVE` socket option set.
- **Reproducer:** TBD.
- **Decision:** TBD.
- **Status:** LOGGED.

### H-015 — TCP RST acceptance window

- **Where:** `TCPRCV.C` RST handling around ~2071 (SYN-SENT) and ~2569
  (ESTABLISHED).
- **Class:** Blind connection reset.
- **Severity:** LOW (off-path RST injection across the open internet is
  hard at NT-3.50-era window sizes; documented but not a focus).
- **Reachable:** T1, T2.
- **Analysis:** TBD. Just record the policy; RFC 5961-grade tightening is
  probably out of scope.
- **Status:** LOGGED.

### H-016 — TCP options parsing

- **Where:** `TCPRCV.C` ~815-854 (`FindMSS`).
- **Class:** Parser correctness.
- **Severity:** LOW (SACK / wscale / TS not implemented, so attack surface
  is small).
- **Reachable:** T1.
- **Analysis:** TBD. Verify the unknown-option advance bound (`OptPtr[1]`)
  is checked against remaining size on every iteration, not just first.
- **Status:** LOGGED.

### H-017 — WinNuke / urgent-pointer

- **Where:** `TCPDELIV.C` `HandleUrgent` ~1600-1705.
- **Class:** Historical BSOD on urgent data; appears mitigated in this tree.
- **Severity:** suspected INVALID.
- **Reachable:** T1 post-bind.
- **Analysis:** TBD. Initial read: bounds checked at ~1622 and ~1638. Need
  to confirm path coverage including the BSD-style 1-byte case at lower
  protocol layers.
- **Status:** LOGGED.

### H-018 — UDP broadcast amplification (Fraggle)

- **Where:** `UDP.C` broadcast delivery path.
- **Class:** Amplification.
- **Severity:** LOW (no chargen/echo built; no broadcast on cloud single-NIC
  in normal operation).
- **Reachable:** T1 if a broadcastable UDP service exists; otherwise N/A.
- **Analysis:** TBD. Probably ACCEPT subject to "no UDP service binds to
  broadcast address" being an enforced invariant.
- **Status:** LOGGED.

### H-019 — ARP cache poisoning / unsolicited replies

- **Where:** `ARP.C` ~2538-2553.
- **Class:** L2 trust.
- **Severity:** HIGH on T3.
- **Reachable:** T3.
- **Invariant violated:** I8.
- **Analysis:** TBD. Hypervisor anti-spoof handles this on EC2/GCE; cheap
  VPS often does not. We cannot detect which we're on.
- **Reproducer:** TBD. Easier to demonstrate on a Linux host with the same
  driver path.
- **Decision:** TBD.
- **Status:** LOGGED.

### H-020 — IP forwarding default / runtime toggle

- **Where:** TCP/IP init (`IP/INIT.C`, registry binding) — pin TBD.
- **Class:** Configuration invariant.
- **Severity:** HIGH if violated (turns the box into an open relay for
  many of the above).
- **Invariant violated:** I1.
- **Analysis:** TBD. Confirm default in `INIT.C`; confirm there is no input
  channel that flips it without admin auth; consider compile-out of the
  forwarding code path entirely for our build.
- **Status:** LOGGED.

## 7. Decision log

Decisions made about scope, methodology, or whole-class triage. One line
per entry, dated. Append-only.

- 2026-05-05 — Document created. Scope §1 set: single-NIC, internet-exposed,
  no reliance on upstream filtering. Threat model §2 set: T1–T4. Methodology
  §3 fixed. No code changes pending decision.

- 2026-05-11 — **Decision: strip IP fragmentation and reassembly from this
  stack.** Both directions: inbound fragments dropped at the dispatch hook,
  outbound `IPFragment` removed (oversized payloads become a caller error,
  counted and dropped). Rationale: PMTUD + MSS clamping keep TCP off the
  fragment path entirely; UDP large-payload apps either chunk at L7 (EDNS0,
  NFS) or fall back to TCP; ICMP large payloads aren't load-bearing. With
  fragmentation absent, H-001 / H-002 / H-003 / H-004 / H-005 are not just
  fixed but unreachable. Invariant I5 retires.

  This strip is the cleanest defence against the 1997 Teardrop/Bonk/NewTear
  family and Ping of Death: there is no overlap-trim arithmetic, no
  `rh_datasize` accumulator, no per-NTE reassembly list, no `IPRcvBuf` to
  carry an attacker-controlled length. Attribution: `(MS LANMan, 1990-1992)`
  — file headers carry no individual author. PMTUD reception in `ICMP.C` is
  preserved; TCP needs it under DF=1 outbound.

- 2026-05-11 — **Decision: NDIS is Ethernet-only.** Removed AFILTER (ARCnet),
  FFILTER (FDDI), TFILTER (Token Ring) sources/headers/exports, and every
  `MediaType` arm in `MINIPORT.C` and `WRAPPER.C`. Added a registration gate
  in `WRAPPER.C` that rejects any miniport reporting `MediaType !=
  NdisMedium802_3` so non-Ethernet dispatch code cannot be reached. ARCnet
  in particular shipped its own 508-byte link-layer fragmentation; removing
  it is in scope for "no fragmentation". Token Ring + FDDI gone for the same
  reason — neither is realistic on any single-NIC virtualised target this
  decade, and their filter packages added attack surface (group/functional
  address rewriting, source-routing bridges) with zero deployment value.

  Build verification: 2026-05-11 — full tree builds clean with no unresolved
  externals; `ndis.sys` exports the reduced surface, gate path exercised at
  miniport registration only.

## 8. Open questions

Tracked separately from per-finding TBDs because they cut across findings.

- OQ-1. Do we want to compile the forwarding path out entirely, or leave it
  in and gate at runtime? Compile-out is harder to reason about wrt source
  drift; runtime-gate has a flip-the-bit risk.
- OQ-2. What is our policy when an attacker fills a bounded structure (frag
  table, half-open queue, ARP cache)? Drop-oldest, drop-new, randomized
  drop, or per-source quota? Same answer for all three?
- OQ-3. Are we willing to diverge from on-the-wire RFC behaviour where the
  RFC mandates we accept something we'd rather drop (e.g., source-routed
  packets, ICMP redirects)? Default: yes, document each divergence here.
- OQ-4. How do we observe pool / TCB / RH counters from outside the guest
  for automated regression?
- OQ-5. What is the smallest target VPS profile (RAM, nonpaged pool size)
  we calibrate caps against?

## 9. Changelog

- 2026-05-05 — Initial draft. §1–§5 written. §6 populated from prior audit
  with 20 stub findings (H-001 … H-020), all status LOGGED. No analysis,
  reproducers, decisions, or patches yet.
- 2026-05-11 — Strip landed: IP fragmentation/reassembly (~683 LOC across
  `IPRCV.C`, `IPXMIT.C`, `IPROUTE.C`, `INIT.C`, `IPDEF.H`, `IPXMIT.H`,
  `INFO.C`; PMTUD reception in `ICMP.C` retained). NDIS reduced to Ethernet:
  AFILTER/FFILTER/TFILTER deleted, MINIPORT/WRAPPER `MediaType` arms removed,
  registration gate added. Findings H-001 .. H-005 marked INVALID. Invariant
  I5 retires. Build verified clean.
