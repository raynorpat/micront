# MicroNT — minimal SSH (feasibility / learning)

Goal: a minimal SSH-2 implementation running native on MicroNT, interoperable with
stock OpenSSH. Scope is deliberately a single cipher suite around **ed25519**.
First target is **feasibility/learning** — prove the crypto + protocol run under
MicroNT at all — server-side single-channel shell wired to `nt.term`.

## Framing: reference, not port

wolfSSH (`stuff/wolfssh`) is **reference code, not a port target**. The protocol
state machine, once stripped of breadth we don't want, is small enough to write
directly in Lua next to the AFD net stack. wolfSSH's value is the message
choreography; its crypto is delegated wholesale to wolfCrypt (not checked out)
and its cipher table is AES-only — see below.

Architecture:
- **Crypto** — DJB reference C (32-bit-clean, constant-time by design), built as a
  small primitive DLL and FFI'd from Lua. No AES, no wolfssl megabuild.
- **Protocol** — Lua, in `pkg/nt/`, over `nt.net.afd` for transport and
  `nt.dll.rng` (`NtGenerateSecureRandom`) for entropy.
- **Oracle** — a real `ssh`/`sshd` for differential testing at every layer.

## Cipher suite: chacha20-poly1305@openssh.com

Modern OpenSSH has exactly two AEAD families that collapse MAC negotiation to
implicit: `aes*-gcm@openssh.com` and `chacha20-poly1305@openssh.com`. We pick
**chacha20-poly1305**:

- OpenSSH's default-preferred cipher → guaranteed interop with stock `ssh`/`sshd`.
- Pure ARX. No S-box, no lookup tables → naturally constant-time. Software AES
  needs S-box tables (cache-timing leak) or bitslicing, and nothing exposes
  AES-NI to us; on a real multi-user target (see security-model direction) that
  side channel matters.
- Poly1305 replaces GHASH (GF(2^128) carryless multiply, whose fast forms are
  table-based and timing-leaky).
- Drops AES and GHASH entirely. The whole primitive set becomes one uniform
  flavour: 32-bit-word ARX + small-prime limb math.

Cost: wolfSSH has **no** chacha20-poly1305, so the cipher/packet-framing oracle is
OpenSSH, not wolfSSH (see oracle map).

Negotiated suite:

| Layer    | Name                    | Primitives             |
|----------|-------------------------|------------------------|
| KEX      | `curve25519-sha256`     | X25519, SHA-256        |
| Host key | `ssh-ed25519`           | Ed25519 (→ SHA-512)    |
| Cipher   | `chacha20-poly1305@openssh.com` | ChaCha20, Poly1305 |
| MAC      | *(implicit — AEAD)*     | —                      |

X25519 and Ed25519 **share one field core** (both over 2^255−19). Everything else
is 32-bit ARX or small-prime limbs. No binary-field math anywhere.

## Crypto primitive DLL

Small native DLL of imported DJB/PD reference C, FFI'd from a `pkg/nt/crypto`
Lua module. Packages like the existing `bcryptprimitives` forwarder and follows
the **INT64.LIB-from-source** precedent (import reference C, archive as a PUB_LIB,
path-derived build target).

| Primitive   | Source                                         | Notes |
|-------------|------------------------------------------------|-------|
| X25519      | `ref10` (SUPERCOP) or curve25519-donna (32-bit)| shares field with Ed25519 |
| Ed25519     | `ref10` or ed25519-donna (`ED25519_32BIT`)     | pulls in SHA-512 |
| ChaCha20    | DJB `chacha` ref / libsodium `ref`             | pure ARX |
| Poly1305    | poly1305-donna (`poly1305-donna-32.h`)         | explicit 32-bit limb path |
| SHA-512     | SUPERCOP `crypto_hash/sha512` (or any small PD)| Ed25519 |
| SHA-256     | SUPERCOP `crypto_hash/sha256` (or any small PD)| KEX hash + key derivation |

**`randombytes` wiring (don't miss):** ref10/NaCl keygen calls `randombytes()`,
which defaults to `/dev/urandom`. Shim it to `NtGenerateSecureRandom` (the
`nt.dll.rng` path) so the DLL carries no host-OS assumption.

## Oracle map (which reference for which layer)

- **KEX, key derivation, userauth, channels** → wolfSSH `src/internal.c`
  (curve25519-sha256 KEX-ECDH init/reply, exchange-hash + key-gen, userauth
  publickey, channel open/data).
- **Cipher + packet encryption framing** → OpenSSH `cipher-chachapoly.c` +
  `packet.c`. This is where the two-key construction lives:
  - 64-byte key = two ChaCha20 keys. **K1** encrypts *only* the 4-byte
    packet-length word (receiver must decrypt length before reading the rest).
  - **K2**: counter=0 → Poly1305 key; counter=1 → payload.
  - SSH sequence number is the nonce.
  - Poly1305 tag covers `enc_length ‖ enc_payload`.
  - (Contrast AES-GCM: length sent cleartext as AAD — a different framing path.)
- **Spec backstop** → RFCs 4251–4254, RFC 5656 (curve25519 KEX / 8731),
  RFC 8709 (ed25519 keys), OpenSSH `PROTOCOL.chacha20poly1305`.

## Minimal protocol surface

Single-channel server-side shell. Realistically ~1–1.5k lines of Lua; transport +
KEX is the only conceptually dense part, auth and channels are mostly
serialization.

- **Transport (4253):** version-string exchange (`SSH-2.0-…\r\n`) → `KEXINIT`(20)
  name-list negotiation → `KEX_ECDH_INIT`(30)/`KEX_ECDH_REPLY`(31) with
  `H = SHA256(V_C ‖ V_S ‖ I_C ‖ I_S ‖ K_S ‖ Q_C ‖ Q_S ‖ K)` and the ed25519 sig
  over `H` → `NEWKEYS`(21) → key derivation
  (`HASH(K ‖ H ‖ "A".."F" ‖ session_id)`, extended by `HASH(K ‖ H ‖ K1…)`).
- **Auth (4252):** `SERVICE_REQUEST` "ssh-userauth" → `USERAUTH_REQUEST`
  publickey(50), sig over the session-scoped blob → `USERAUTH_SUCCESS`(52) /
  `FAILURE`(51).
- **Connection (4254):** `CHANNEL_OPEN` "session"(90)/`CONFIRMATION`(91) →
  `pty-req`/`shell`/`exec`(98) → `CHANNEL_DATA`(94) + `WINDOW_ADJUST`(93) +
  `EOF`(96)/`CLOSE`(97); data side wired into `nt.term`.

## Build order

Bottom-up, with stock `ssh`/`sshd` as the differential oracle at each layer:

1. **Crypto DLL + Lua FFI binding**, validated by KATs:
   - ChaCha20-Poly1305 — RFC 8439 §2.8.2 vectors.
   - X25519 — RFC 7748 §5.2 vectors.
   - Ed25519 — RFC 8032 §7.1 vectors.
   - SHA-256 / SHA-512 — NIST/FIPS vectors.
2. **Packet codec + chacha-poly framing** — tested against a captured OpenSSH
   transcript (decrypt a recorded `ssh` session given the negotiated keys).
3. **KEX → NEWKEYS** — complete a real handshake with `ssh -v`; verify the
   exchange hash and key derivation against the live peer.
4. **Userauth (publickey)**.
5. **One session channel → `nt.term`** — interactive shell.

## Open / deferred

- Client direction (outbound) — same transport/KEX core, different auth + channel
  glue. Deferred; first target is server-side.
- Password auth, multiple channels, port forwarding, SFTP/SCP, agent — out of
  scope.
- Rekeying (`KEXINIT` mid-session) — deferred; document the limit rather than
  silently omit.
- Perf of the C primitives under MicroNT — measure before considering ASM paths.

## References (in-tree + spec)

- `stuff/wolfssh/src/internal.c` — protocol choreography reference.
- OpenSSH `cipher-chachapoly.c`, `packet.c`, `PROTOCOL.chacha20poly1305`.
- RFC 4251–4254 (SSH arch/transport/auth/connection), 4253 §7–8 (KEX/keys),
  5656 / 8731 (curve25519-sha256), 8709 (ssh-ed25519), 8439 (chacha-poly),
  7748 (X25519), 8032 (Ed25519).
- MicroNT: `src/pkg/nt/net/afd.lua` (transport), `src/pkg/nt/dll/rng.lua`
  (`NtGenerateSecureRandom`).

## Complexity of the deferred features

These are *not* four equal items. They share one root cause and then diverge
sharply. Ranking + shape, so the deferral is an informed one.

### The common thread: they break the synchronous read-loop

The single-channel shell can be near-synchronous — one connection, one transport,
one channel, `read packet → dispatch → write packet`, with a giant receive window
so flow control can be ignored. **Every feature below forces a real I/O
multiplexing reactor** — simultaneously waiting on the SSH socket *and* N channel
data sources/sinks (shells, files, forwarded sockets), none allowed to block the
others. On MicroNT that means committing to overlapped/IOCP-driven async over AFD
(or coroutines/threads) with a completion pump, and (per the `pkg/nt` no
module-local-mutable-state rule) holding all per-channel/per-session state
explicitly in connection objects. **That architectural shift is the real cost;**
the features are state machines layered on top.

### Multi-channel (RFC 4254) — the gateway

Foundation for everything else. Architecture + bookkeeping, no crypto:
- **Per-channel windowing** — independent receive window per channel; can't send
  more `CHANNEL_DATA` than advertised, grow own window via `WINDOW_ADJUST` as
  consumed. The subtle correctness trap: get it wrong → deadlock or overflow under
  load. (Single channel cheats with a huge window.)
- **Channel ID mapping + half-close** — each side assigns its own numbers; track
  `sentEof/recvdEof/sentClose/recvdClose` to know when to free.
- Per-channel `CHANNEL_REQUEST` (pty-req/env/signal/exit-status/subsystem) +
  `EXTENDED_DATA` (stderr).

Verdict: **medium — the real fork.** Converts the project from a linear loop to an
async reactor. Once paid, the rest is comparatively mechanical.

### SFTP — breadth, not depth

A *subsystem*: `CHANNEL_REQUEST "subsystem" "sftp"`, then a binary RPC protocol
runs inside one channel's byte stream.
- ~20 packet types (OPEN/READ/WRITE/OPENDIR/READDIR/STAT/SETSTAT/REALPATH/
  RENAME/MKDIR/…), each request-id matched.
- Opaque file/dir handles to mint+track; `ATTRS` (perms/size/uid/gid/times).
- **Real work = NT FS-semantics mapping:** `/`-paths → NT `\??\`, POSIX perms → NT,
  `NtCreateFile`/`NtQueryDirectoryFile`, realpath canonicalization.
- Pipelining (overlapping READ/WRITE) for throughput → wants async file I/O.

Verdict: **large but shallow.** wolfSSH *does* implement it (`src/wolfsftp.c`,
9.4k lines = the honest size estimate, and a direct reference). Subtle bits are
attribute/permission/path mapping, not the protocol.

### "Persistent sessions" — three different things

- **(a) Connection multiplexing** (OpenSSH `ControlMaster`/`-M`) — client-side;
  **server-side it's just multi-channel.** Free once multi-channel exists.
- **(b) Keepalives / idle** (`keepalive@openssh.com`, idle timeout) — easy.
- **(c) Rekeying** (RFC 4253 §9; mandatory ~1 GB / ~1 hr) — the genuinely hard
  transport item: a fresh KEXINIT→NEWKEYS interleaved with live channel traffic
  (no non-KEX packets between KEXINIT and NEWKEYS → queue/buffer channel data
  mid-rekey). Complicates the transport state machine the demo treats as one-shot.
- **(d) Reattachable sessions** (tmux/mosh-style) — **SSH does not provide this.**
  Decouple shell+PTY lifetime from the *connection*: a long-lived server-side
  session registry owns the process + `nt.term` endpoint, buffers output (ring)
  while detached, re-syncs on reattach. A separate subsystem, not a protocol item.

Verdict: (a)/(b) trivial-easy; **(c) is the real protocol complexity**; (d) is its
own subsystem.

### SOCKS forwarding — mostly a client feature

The SOCKS protocol (`ssh -D`) lives **entirely in the client**: it runs a local
SOCKS4/5 proxy, learns the target, then opens a `direct-tcpip` channel. **The
server never sees SOCKS** — identical to local forward (`-L`). So for MicroNT *as
server* it reduces to a `direct-tcpip` handler:
- Parse target host/port → **AFD outbound connect** (have it) → **bidirectional
  byte splice** channel↔socket.
- Fiddly part: **two-way copy with backpressure + half-close** — respect channel
  window one way, TCP backpressure the other, propagate FIN↔`CHANNEL_EOF`, avoid
  half-open deadlocks.
- **Policy:** an unrestricted `direct-tcpip` handler = open proxy. On an
  L2-hostile cloud host (deployment-scope), gate allowed targets rather than ship
  open.

Client `-D` would add a SOCKS5 listener (method negotiation + CONNECT) — modest,
but client-direction (deferred).

Verdict: **small given multi-channel** — dominated by splice-with-flow-control +
proxy policy. The SOCKS code itself is client-only.

### Ranking

| Feature | Depends on | Dominant cost | Difficulty |
|---------|------------|---------------|------------|
| Multi-channel | reactor I/O model | per-channel windowing + reactor | **Medium — gateway** |
| SFTP | multi-channel | NT FS-semantics mapping; broad serialization | Large, shallow (wolfSSH ref) |
| Persistent (a/b) | multi-channel | — | Trivial |
| Persistent (c) rekey | transport SM | interleave KEX w/ live traffic | Hard (subtle) |
| Persistent (d) reattach | session registry | lifetime decoupling + output buffering | Separate subsystem |
| SOCKS (server `direct-tcpip`) | multi-channel | splice w/ backpressure + policy | Small |

One-liner: **multi-channel is the real fork** — it converts the linear loop into
an async reactor. After that, SFTP is volume, server-side forwarding is small,
persistence is mostly easy except rekeying, and true reattach is its own thing.
