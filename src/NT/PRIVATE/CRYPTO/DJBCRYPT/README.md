# djbcrypt.dll

The DJB crypto primitive set for MicroNT's SSH stack — and any other
consumer, since it's a standalone native DLL.

| primitive | source |
|---|---|
| X25519, Ed25519, ChaCha20, Poly1305, SHA-512 | Monocypher 4.0.2 (`mono.cpp`, `monoed.cpp`) |
| SHA-256 | B-Con crypto-algorithms, public domain (`sha256.c`) |

`djbcrypt.c` is C-linkage glue (cdecl) over the vendored reference C, exporting
8 functions (`dc_sha256`, `dc_sha512`, `dc_x25519`, `dc_ed25519_pubkey`,
`dc_ed25519_sign`, `dc_ed25519_verify`, `dc_chacha20`, `dc_poly1305`). The
`ffi.cdef` in `pkg/ssh/crypto.lua` **is** this ABI — keep the two in lockstep.

The functions are **pure and stateless**: there is no `randombytes` here, so the
DLL has no OS coupling and every export is directly KAT-testable. Entropy is the
caller's job (Lua draws it from `NtGenerateSecureRandom` via `nt.dll.rng`). KATs
(RFC 8439/7748/8032 + FIPS vectors) live in `pkg/test/ssh/crypto.lua`.

## Building under the period toolchain

The MS C 8.x compiler (1994, C89 / pre-standard C++) can't build Monocypher
as-is. The hand-port is documented in the build notes; the load-bearing points:

- Compiled as **C++** (the `.cpp` extension selects the front-end that accepts
  Monocypher's C99-isms); headers keep `extern "C"` so exports stay C-linkage.
- Array parameters are pointerized (`fe p[N]` → `fe *p`) — this compiler won't
  decay them.
- `monoed.cpp` is wrapped in `#pragma optimize("", off)`: the optimizer both ICEs
  on, and silently **miscompiles**, the 64-bit SHA-512 (KAT caught wrong digests).
  `mono.cpp` stays optimized (`/Oxs`) and is KAT-clean.
- `stdint.h` (local shim) supplies the fixed-width names the front-end lacks.

Built by the `crypto_djbcrypt` target in `pkg/ntosbe/build.lua`; output goes to
`PUBLIC/SDK/LIB`, shipped to `System32` by the `core` layer.
