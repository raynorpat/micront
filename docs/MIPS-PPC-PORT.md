# MIPS / PowerPC base-kernel back-port

This tree is x86-only. The multi-architecture **headers** were always present
in `PRIVATE/NTOS/INC` (`MIPS.H`, `PPC.H`, `PPCDEF.H`, `HALMIPS.H`, the Jazz/Duo
platform headers, …) and in `PUBLIC/SDK/INC` (`NTMIPS.H`, `NTPPC.H`, `KSMIPS.H`,
`KXPPC.H`, `MIPSINST.H`, `PPCINST.H`, …), but the architecture-specific
*implementation* directories had been stripped out.

This document records what was brought back, and — more importantly — what is
still missing before a MIPS or PowerPC build could actually link.

## Source

The MIPS/PPC source was lifted from the Windows NT 4.0 tree
(`windows_nt_4_source_code_IK/nt4/private/ntos/...`). File contents are
byte-for-byte from NT 4.0; only the directory and file **names** were
upper-cased to match the existing `I386` sibling convention. `SOURCES` build
descriptors still reference files in lower case, exactly as the existing
`I386/SOURCES` does (NT builds are case-insensitive).

> **Version caveat.** This is NT 4.0 source dropped into an NT 3.5 ("Daytona")
> tree. The arch-neutral kernel headers here (`KE.H`, `MI.H`, `PS.H`, …) are
> 3.5-era and will differ from what this code expects in places (PnP/Power
> additions, struct field changes, new exports). Treat the back-port as
> *reference source*, not as drop-in buildable code — see "Open work" below.

## What was ported

All base-kernel architecture subdirectories that NT 4.0 carries for `mips` and
`ppc` (168 files):

| Module                  | MIPS            | PPC             |
|-------------------------|-----------------|-----------------|
| `NTOS/KE`  (kernel)     | `KE/MIPS` (37)  | `KE/PPC` (31)   |
| `NTOS/MM`  (memory mgr) | `MM/MIPS` (8)   | `MM/PPC` (7)    |
| `NTOS/RTL` (runtime lib)| `RTL/MIPS` (15) | `RTL/PPC` (14)  |
| `NTOS/EX`  (executive)  | `EX/MIPS` (9)   | `EX/PPC` (9)    |
| `NTOS/PS`  (process)    | `PS/MIPS` (4)   | `PS/PPC` (5)    |
| `NTOS/KD`  (kernel dbg) | `KD/MIPS` (6)   | `KD/PPC` (6)    |
| `NTOS/LPC` (local proc) | `LPC/MIPS` (2)  | `LPC/PPC` (2)   |
| `NTOS/CONFIG`           | `CONFIG/MIPS`(2)| `CONFIG/PPC`(2) |
| `NTOS/DLL` (ntdll stubs)| `DLL/MIPS` (4)  | `DLL/PPC` (4)   |
| `NTOS/INIT`             | `INIT/MIPS` (1) | — (none in NT4) |

Plus the one missing arch header: `PRIVATE/NTOS/INC/HALPPC.H` (the MIPS and
Alpha equivalents were already present).

This is the CPU-port layer: context switch, trap/exception dispatch, IRQL,
spinlocks, IPIs, cache/TB flush, alignment/FP emulation, page-table setup,
exception unwinders, `RtlCaptureContext`/`RtlUnwind`, fast block copies, etc.

## Still missing — needed before MIPS/PPC can build or boot

### HALs (`NTOS/NTHALS` — not ported)

`NTHALS/` here contains only the custom x86 PCI `HAL`. The platform HALs these
ports were written against were not brought over:

- **MIPS** (R4000/R4400 Jazz & friends): `halacr`, `haldti`, `halduomp`,
  `halflex`, `halfxs`, `halfxspc`, `halnecmp`, `halntp`, `halr94a`, `halr96b`,
  `halr98b`, `halr98mp`, `halsgi`, `halsni4x`, `halsnip`, `haltyne`.
- **PowerPC** (PReP): `halppc`, `halcaro`, `haleagle`, `halfire`, `halps`,
  `halvict`, `halwood`.

Shared HAL support (`bushnd.c`, `drivesup.c`, `rangesup.c`, `nthals/inc`) is
also absent.

### Firmware / ARC boot loader (`NTOS/FW`, `NTOS/BLDR` — not ported)

MIPS and PPC do not boot via the UEFI loader in `src/boot-efi/`; they boot
through ARC firmware + `osloader`.

- `fw/mips` — full ARC firmware (Jazz/Duo board bring-up, video, SCSI, EISA,
  ~80 files). Not present.
- `fw/ppc` — NT 4.0 ships **headers only** here; no PPC firmware
  implementation exists in that tree either.
- `bldr` (osloader) — only `i386` exists in this tree; the MIPS/PPC osloader
  back ends are missing.
- `arcinst/mips` (ARC disk installer) — not ported.

### Build tools / toolchain (the hard blocker)

`PUBLIC/OAK/BIN/MIPS` and `PUBLIC/OAK/BIN/PPC` are **empty** — there is no
cross toolchain to build either target:

- MIPS C compiler back end + MIPS assembler (`.s` files).
- PowerPC C compiler back end + PPC assembler.
- Matching `LINK`/`CVPACK` arch awareness and the arch import libraries under
  `PUBLIC/SDK/LIB/MIPS` and `PUBLIC/SDK/LIB/PPC`.

`build.sh` / `boot.sh` are wired exclusively for I386 + the wibo-hosted MS
x86 toolchain and would need a parallel arch path even if a compiler existed.

### Arch-specific drivers, win32k, etc. (out of scope here)

Display/video miniports, the win32 kernel (`w32`), and bus/storage drivers
each carry their own MIPS/PPC bring-up that was not part of this base-kernel
port.

## Open work to make it real

1. Reconcile the NT 4.0 arch source against this tree's NT 3.5 headers
   (struct/field/export deltas), or back-port the matching 3.5 arch source if
   it surfaces.
2. Obtain or rebuild a MIPS and/or PowerPC cross toolchain and the arch import
   libs.
3. Port a HAL for at least one concrete board per arch.
4. Add an ARC/osloader boot path (the UEFI loader is x86-only).
5. Teach `build.sh`/`boot.sh` about a non-I386 target.
