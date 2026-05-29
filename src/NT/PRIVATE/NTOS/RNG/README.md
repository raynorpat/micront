# RNG — in-kernel CSPRNG

A first-class kernel subsystem (peer to KE/EX/IO) that owns the system's
cryptographically-strong random number generator. It exists so randomness is
*always present* — no driver to load, usable before any driver starts.

## Crypto core

A [Xoodyak](https://keccak.team/xoodoo.html) Cyclist duplex over the Xoodoo[12]
permutation, used in unkeyed (hash) mode as a sponge PRNG:

- `RngAddEntropy(buf, len)` — absorb. The only way entropy enters the pool.
- `RngGenerateBytes(buf, len)` — squeeze, then ratchet (forget the rate) for
  forward secrecy.

The core is deliberately **deterministic**: no clocks, no hardware access, no
threads — just the permutation, a lock, and absorb/squeeze. That is what lets it
be pinned by known-answer tests.

| file | contents |
|------|----------|
| `xoodoo.c`  | the Xoodoo[12] permutation |
| `rngpool.c` | Cyclist duplex + the pool + the public `Rng*` API |
| `rngkat.c`  | power-on self-test |
| `rngsys.c`  | `RngInitSystem` (boot) |

## Self-test

`RngInitSystem` runs `RngpSelfTest` at Phase 0, before anything trusts the pool,
and **bugchecks on mismatch** (`PHASE0_INITIALIZATION_FAILED`, P1 `'RNG0'`,
P2 = failing stage) — a wrong permutation would be silently insecure. Two
vectors, both from authoritative sources:

1. Xoodoo[12] of the all-zero state.
2. Xoodyak-Hash of the empty message — matches Count 1 of the NIST LWC
   `LWC_HASH_KAT_256.txt`, exercising the full absorb+squeeze path.

## Where entropy comes from (the HAL's job)

The RNG core has no entropy of its own; the HAL is the messy real-world
*gatherer* and feeds the pool via `RngAddEntropy`. See
`NTHALS/HAL/I386/random.c`. Raw values are absorbed **verbatim** — no entropy
estimation, no conditioning; the duplex concentrates whatever is present.

- **Boot** (`HalpAbsorbBootEntropy`, called at a few points across HAL init):
  TSC, the PIT channel-0 counter, and the boot wall-clock seed — all cheap —
  plus a one-shot `RDRAND` batch when CPUID advertises it.
- **Wall-clock seed**: read once through a detected backend
  (`HalpDetectClockSource`: UEFI → *kvmclock, reserved* → CMOS-if-present). The
  presence check matters — an absent RTC reads `0xFF`, which would otherwise
  drive `HalpReadCmosTime`'s update-in-progress guard to its iteration limit
  (a million port-I/O VM-exits under KVM, stalling boot).
- **Hardware RNG is kept off the boot critical path.** `RDRAND` executes
  natively under KVM and is fast, but ongoing reseeding will move to a
  background thread so a slow/trapping draw can never block boot or a generator
  caller.
