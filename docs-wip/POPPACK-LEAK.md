# POPPACK-LEAK.md

NT 3.5's `POPPACK.H` doesn't actually pop. It hard-sets `#pragma pack(2)`
on the way out. Every `pshpack4 / poppack` (or `pshpack8 / poppack`) pair
in an include chain therefore *leaves the compiler at pack(2)* for the
rest of the translation unit — silently changing the layout of every
struct declared afterwards.

This is a real upstream bug, not a quirk of our tree, and the NT source
already works around it in dozens of places with an explicit
`#pragma pack()` between header includes. We're inheriting both the
bug and the workarounds.

This note exists because we just hit it from the Lua / LuaJIT side
while writing SYSINFO coverage tests — and the same bite is waiting
anywhere else we declare an FFI `typedef struct` that mirrors an NT
kernel struct.

## The bug

`PUBLIC/SDK/INC/POPPACK.H` lines 25-33:

```c
#if ( _MSC_VER >= 800 )
#pragma warning(disable:4103)
#if !(defined( MIDL_PASS )) || defined( __midl )
#pragma pack(2)              // ← NOT a pop. Hardcoded.
#else
#pragma pack()
#endif
#else
#pragma pack()
#endif
```

`pshpack4.h` does `#pragma pack(4)` (no push). `poppack.h` does
`#pragma pack(2)` (no pop). Between them the compiler has no stack
of saved values to restore — the "pop" is fictional. After the pair,
struct alignment is **2**, regardless of what it was before.

## Why pack(2)?

Heritage. NT 3.x shared headers with:

- **16-bit MSC compilers** for the Win16 / OS/2 1.x subsystems. 16-bit
  MSC defaults to 2-byte packing because the 8086 has no fast 4-byte
  load instruction — packing to 2 gives you better density at the
  same access cost.
- **OS/2 1.x kernel structures**, which NT could load and inspect for
  16-bit subsystem compatibility. Those structs were laid out under
  pack(2) on OS/2 itself.

`POPPACK.H`'s author appears to have assumed "default packing for
headers that get included from 16-bit translation units is pack(2),
so popping means re-asserting pack(2)". Wrong for 32-bit kernel
compilation, but not visible if every TU happens to start the include
chain from a pack(2)-aware preamble.

The bug bites whenever a `pshpack? / poppack` pair appears *inside* a
TU and a struct is declared *after* it without an explicit reset.

## Visible symptoms

Any struct declared in code reached via `<ntddk.h>` → `<ntdef.h>` →
`<ntexapi.h>` (or any chain that goes through a pshpack/poppack pair)
ends up with **struct alignment = 2** instead of the ABI-natural value.
For 4-byte-aligned members the *member* layout is unchanged (consecutive
ULONGs naturally fall on 4-byte offsets), but **the trailing tail pad
is computed to the smaller alignment**. So:

| Struct | Members | Natural sizeof | Leaked pack(2) sizeof |
|---|---|---|---|
| `SYSTEM_BASIC_INFORMATION` | 10×ULONG + 1×CCHAR | 44 | **42** |
| `SYSTEM_QUERY_TIME_ADJUST_INFORMATION` | 2×ULONG + 1×BOOLEAN | 12 | **10** |
| `SYSTEM_SET_TIME_ADJUST_INFORMATION` | 1×ULONG + 1×BOOLEAN | 8 | **6** |

Structs that end on a natural alignment boundary (all ULONG, or
`SYSTEM_KERNEL_DEBUGGER_INFORMATION` = 2×BOOLEAN aligned to 1) are
unaffected — their tail pad is zero either way.

NT's `NtQuerySystemInformation` / `NtSetSystemInformation` check
`len != sizeof(T)` with strict equality and reject with
`STATUS_INFO_LENGTH_MISMATCH`. So caller-side cdef must match
*exactly* what the kernel was compiled with — including the leaked
pack(2) tail. A "correct" pack(4) cdef on the Lua side will be
rejected.

## Where the bug is already being worked around in NT

Search the NT tree for `#pragma pack()` between header includes; almost
every one is a reset for this same leak. Examples:

- Between `<ntifs.h>` and `<ntdddisk.h>` — DDK header pairs habitually
  go pshpack4 → poppack and leave pack(2) hanging for the disk DDK
  structs.
- Inside compound includes that bundle SDK + DDK headers.
- Recorded in our memory at `feedback_poppack_leaks`.

The NT 3.5 codebase carries these defensively — they're not commented
"this is for the poppack bug", they look like cargo-cult cleanups.
They're not.

## How this surfaces on the Lua side

LuaJIT's FFI parser implements `#pragma pack(push, n)` and `pack(pop)`
correctly. So if a caller's cdef block uses

```c
#pragma pack(push, 4)
typedef struct _SYSTEM_BASIC_INFORMATION { ... } SYSTEM_BASIC_INFORMATION;
#pragma pack(pop)
```

LuaJIT computes 44 bytes (correct under ISO C). But the kernel was
compiled with leaked pack(2), so it expects **42**. Length-mismatch.

## Diagnosis recipe

To confirm a sizeof skew is the pack(2) leak (vs. some other layout
issue):

1. Compute the LuaJIT sizeof: `print(ffi.sizeof('SYSTEM_FOO'))`.
2. Probe the kernel with the LuaJIT value, the pack(2) value
   (= unpadded-size rounded up to the next even number), and the
   unpadded size itself. Whichever the kernel accepts tells you which
   pack value it was compiled under.
3. If the accepted size matches the pack(2) prediction, this is the
   leak. The fix is to declare the affected struct on the Lua side
   under `#pragma pack(push, 2) / pack(pop)` and add an inline note
   pointing at this doc.

The diagnostic test in `test/sys.lua` does exactly steps 2–3 for
the two SYSTEM_* classes we've hit so far.

## Fix strategy

Two layers:

1. **Lua-side, short term** — declare each affected `nt.dll.*` struct
   under `pack(push, 2)`. Cost: an extra two-line block per affected
   struct. Each block gets a one-line comment pointing here so future
   readers know it's a workaround, not a quirk we like. **This is the
   current direction.**

2. **NT-side, eventually** — fix `POPPACK.H` to actually pop (`#pragma
   pack(pop)`), then audit and remove the explicit `#pragma pack()`
   resets throughout the NT tree. This is a wide surgery: every
   header pair that has been silently relying on the leak-becomes-pack(2)
   behaviour for ABI-compat with old structs will need a real
   `pshpack2 / poppack` instead. Touches a huge surface of the kernel
   and the userland headers — not a small change.

Until the NT-side fix happens, treat every kernel struct we expose via
FFI as suspect. The right test is the diagnostic recipe above: if its
sizeof divergence between LuaJIT and the kernel matches the pack(2)
prediction, wrap the cdef in pack(2) and link this doc.

## Cleanup checklist

When the NT-side fix lands:

- Audit every `#pragma pack()` reset inside NT source files. Each one
  was either fighting this leak (delete) or asserting a real layout
  intent (keep — needs to become `pack(push, N) / pack(pop)`).
- Audit every Lua-side `pack(push, 2)` block in `nt.dll.*` that cites
  this doc. Replace with the natural alignment.
- Re-run the full selftest suite, particularly any test that compares
  `sizeof(...)` against a literal — those literals need updating.
- Re-run coverage. Any binary that was being compiled against a
  leaked-pack-2 struct now has a different ABI; mixed-version mismatch
  is the obvious risk during the cutover.

## See also

- `feedback_poppack_leaks` memory entry — quick warning about the same
  bug in DDK header chains.
- `feedback_nt35_struct_packing` — related: PEB/TEB compiled with
  pack(2), naturally-aligned consumer code faults silently.
- `PUBLIC/SDK/INC/POPPACK.H` line 28 — the offending pragma.
