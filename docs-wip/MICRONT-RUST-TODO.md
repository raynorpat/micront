# MicroNT — Rust (i686-pc-windows-gnu) missing Win32 surface

Goal: run stock `i686-pc-windows-gnu` Rust binaries on MicroNT. Surface measured
from a Rust **1.91.1** std `hello` (console only) + `server` (blocking TCP) —
scratch project at `stuff/testrust/`, imports via `i686-w64-mingw32-objdump -p`.
This enumerates **only what MicroNT is missing today**.

Toolchain pin: **Rust ≤ 1.91** (`stuff/testrust/rust-toolchain.toml`). 1.92 std
added `std::net::hostname` → `GetHostNameW` (a Win8.1 ws2_32 export the jammy
mingw import lib lacks). Drop the pin once ws2_32 provides `GetHostNameW`.

Design bias: prefer the lean, Unixy surface modern Rust/Go/Nim/Zig actually use
(console, files, basic sockets) — these languages are natively Unixy and sit well
on MicroNT. Heavy native-Windows machinery is antithetical to the design and goes
long-term (e.g. the srv03 net stack → `MODERN-IPSTACK.md`).

## Already covered — no work
- **ntdll.dll** — all 5 needed already exported: `NtOpenFile`, `NtReadFile`,
  `NtWriteFile`, `NtCreateNamedPipeFile`, `RtlNtStatusToDosError`.

## DLLs MicroNT must add
| DLL | why |
|-----|-----|
| `msvcrt.dll` | MinGW C runtime (mostly forwardable to existing `CRTDLL.DLL`) |
| ~~`bcryptprimitives.dll`~~ | **DONE** (commit 4e5d491) — RNG (`ProcessPrng`) |
| `userenv.dll` | home dir (`GetUserProfileDirectoryW`) |
| `api-ms-win-core-synch-l1-2-0.dll` | futex (`WaitOnAddress`/`WakeByAddress*`) — apiset name, needs a real DLL by this name |
| `ws2_32.dll` | sockets — **deferred**, see `MODERN-IPSTACK.md` (networking / `server`) |

## Packaging & redirection (decided)
- All new Win32 DLLs live **in-tree under `NT/PRIVATE/WINDOWS/`** and ship as
  MicroNT's Win32 subsystem package (alongside `BASE` = kernel32). Build targets
  are path-derived (e.g. `windows_ws2_32`), mirror `windows_base_client`
  (nmake `makedll=1` → `PUBLIC/SDK/LIB/i386/{x.lib,x.dll}`), and join
  `USERLAND_TARGETS`; the `core` layer copies `System32/x.dll`.
- DLL aliasing = **PE export forwarding** (native to the 3.50 Ldr): split a real
  DLL only when something imports it, forwarding to the underlying impl (e.g.
  `bcrypt`→`bcryptprimitives`, `msvcrt`→`CRTDLL`). Built as-needed (Path A).
- Apiset names (`api-ms-win-core-*`): ship a **literal forwarder DLL** by that
  name (LFN on FAT16 now works). Real ApiSetMap deferred until the apiset-name
  count grows — it's faithful NT loader behavior, not the rejected ad-hoc
  redirection, so it stays on the table as a graduate-to.

---

## kernel32.dll — 27 missing (93 of 120 already exported)
```
AddVectoredExceptionHandler
CancelIo
CompareStringOrdinal
CopyFileExW
CreateHardLinkW
CreateSymbolicLinkW
CreateToolhelp32Snapshot
CreateWaitableTimerExW
DeleteProcThreadAttributeList
FindFirstFileExW
GetFileInformationByHandleEx
GetFileSizeEx
GetFinalPathNameByHandleW
GetProcessId
GetSystemTimePreciseAsFileTime
InitOnceBeginInitialize
InitOnceComplete
InitializeProcThreadAttributeList
Module32FirstW
Module32NextW
RtlCaptureContext
SetFileInformationByHandle
SetFilePointerEx
SetThreadStackGuarantee
SetWaitableTimer
SwitchToThread
UpdateProcThreadAttribute
```

## msvcrt.dll — new DLL
Needs 10 funcs not in `CRTDLL.DLL` (the other 22 — `malloc`/`free`/`calloc`/
`memcpy`/`memmove`/`memset`/`memcmp`/`strlen`/`strncmp`/`fprintf`/`vfprintf`/
`fwrite`/`abort`/`exit`/`signal`/`_iob`/`_initterm`/`_onexit`/`_cexit`/
`_amsg_exit`/`_fpreset` — forward to `CRTDLL.DLL`):
```
__getmainargs
__initenv
__lconv_init
__p__acmdln
__p__commode
__p__fmode
__set_app_type
__setusermatherr
_commode
_fmode
```

## bcryptprimitives.dll — DONE (commit 4e5d491)
```
ProcessPrng          ; -> NtGenerateSecureRandom (kernel Xoodyak pool)
SystemPrng           ; sibling, same forwarder (also exported)
```
Shipped: WINDOWS/BASE/BCRYPTP, ntdll-only, forwards to the kernel CSPRNG (which
the HAL + virtio-rng feed) rather than poking viorng directly.

## userenv.dll — new DLL
```
GetUserProfileDirectoryW   ; stub a path
```

## api-ms-win-core-synch-l1-2-0.dll — new DLL
```
WaitOnAddress
WakeByAddressAll
WakeByAddressSingle
```
Rust imports ONLY these 3 from this apiset (no condvar re-exports needed).

Reference impl (Win7 backport, Cristian Adam):
https://github.com/cristianadam/api-ms-win-core-synch-Win7/blob/43cef8c1a108cbb85719cadc3eb9d6d5d479af81/api-ms-win-core-synch-l1-2-0.c

Primitive stack (real Windows): WaitOnAddress (Win8) -> CONDITION_VARIABLE
(Vista) -> keyed events (XP). Cristian's backport sits on **Vista condition
variables** (CONDITION_VARIABLE + SleepConditionVariableCS), NOT keyed events.
srv03 (5.2) has keyed events but NOT condvars (grep: SleepConditionVariable = 0
files) — so his code is a generation above srv03 and is not a drop-in.

Second reference (cleaner template, win32ss/VxKex kernel33/woa.c):
https://github.com/win32ss/VxKex/blob/ef5a07791c109cc9f734e2819a551fb5d46a4e75/kernel33/woa.c
Also condvar-based (NOT keyed events) — same generation gap vs srv03 — but a
better data structure: 256 hash buckets (addr/8 % 256) with LIST_ENTRY separate
chaining, per-address {addr, CVar, dwWaiters} HeapAlloc'd and freed at 0 waiters.

Plan: copy **VxKex's structure** (bucket hash + chaining + per-address entry),
swap the blocking primitive down from CONDITION_VARIABLE to a classic NT 3.1
**semaphore** (NtCreateSemaphore — present in MicroNT):
  - WakeByAddressSingle -> ReleaseSemaphore(sem, 1)
  - WakeByAddressAll    -> ReleaseSemaphore(sem, dwWaiters)
  - waiter: under bucket lock { value-check; dwWaiters++ }; drop lock;
    WaitForSingleObject(sem); re-lock; dwWaiters--; re-check value in a loop.
A counting semaphore => no lost wakeups; spurious wakeups are fine (WaitOnAddress
is contractually allowed to wake spuriously; caller re-checks). No condvars, no
keyed events, no new kernel surface.

Third reference (BEST for reuse — MIT, vintage-aligned): nxdk lib/winapi/sync.c
https://github.com/dracc/nxdk/blob/aeea6cb9337b9e60da6be77a9663586864cf40ce/lib/winapi/sync.c
Targets the original-Xbox kernel (NT 5.0-ish, also no keyed events) and
implements the whole Vista sync family over **classic Nt primitives MicroNT has**
(NtCreateEvent/NtWaitForMultipleObjectsEx/NtSetEvent/NtClearEvent/NtCreateSemaphore/
NtReleaseSemaphore). MIT-licensed (Stefan Schmidt et al.) => directly liftable
with attribution. Implements CRITICAL_SECTION, SRWLOCK, **InitOnce**,
CONDITION_VARIABLE, semaphores/mutexes — but NOT WaitOnAddress.

Decisions from this:
- **InitOnceBeginInitialize/InitOnceComplete** (2 of the 27 kernel32 below): LIFT
  from nxdk (MIT), adapt to MicroNT Nt* signatures. Port, not write.
- WaitOnAddress: keep the semaphore-direct route above; nxdk's condvar (the
  subtle two-event broadcast) is NOT a simplification to build WoA on.
- CONDITION_VARIABLE / SRWLOCK: nxdk on tap if/when an app imports them (Rust
  1.91 std does not).

## Networking (ws2_32 / sockets) → `MODERN-IPSTACK.md`
Moved to **`MODERN-IPSTACK.md`** — the srv03 modern net-stack downport (AFD / TDI /
ws2_32) + the ntoskrnl shim-delta analysis. **Longer-term / deferred**: a big,
native-Windows-heavy footprint (~67 ntoskrnl shims + the kernel test coverage these
subsystems must carry). The `server` (TCP) milestone is gated on it; `hello`
(console) is not and comes first. A cheap near-term option (flat ws2_32 over the
*existing* 3.50 AFD, no kernel work) is also described there if Rust/Go sockets are
wanted sooner.

## Future kernel subsystems (separate analysis + tickets)
As more NT surface is needed, do a per-subsystem analysis pass and cut individual,
easy-to-tick-off tickets rather than one mega-effort. Keep each focused.
Wishlist:
- **NT Job objects** (`NtCreateJobObject` + limits/accounting) — process
  containment / resource control; flagged as important as networking.
- **Networking** — see `MODERN-IPSTACK.md`.

## Milestones
- **`hello`** (console-only, near-term): kernel32 +27, `msvcrt.dll`,
  ~~`bcryptprimitives.dll`~~ (done), `userenv.dll`,
  `api-ms-win-core-synch-l1-2-0.dll`. Hardest piece: `WaitOnAddress`.
- **`server`** (networking): gated on `MODERN-IPSTACK.md` (deferred).

## Cross-refs
- `MICRONT-DLL-TODO.md` — authoritative DLL registry + acceptance-sample map (this delta feeds it)
- `MODERN-IPSTACK.md` — the networking gate
