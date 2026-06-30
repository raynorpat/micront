# Building MicroNT

MicroNT builds the NT 3.5 source tree with the original Microsoft host
toolchain (CL/LINK/NMAKE) run under **wibo**, a minimal Win32 PE runner.
Everything is driven by `src/build.sh` — there is no top-level Makefile.

The output is a bootable UEFI disk image (`build/<profile>/esp.img`) you
run under QEMU.

---

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| **wibo** | runs the Win32 host toolchain (CL/LINK/NMAKE) on your host | `src/wibo-macos` (macOS) or `wibo-x86_64` at the repo root (Linux) — download from the MicroNT-patched fork's releases and `chmod +x` |
| **python3** | `mkhive.py` / `mkdisk.py` / `gen_objects.py` build helpers | system package |
| **x86_64-elf-gcc + binutils** | cross-compiles the UEFI bootloader (gnu-efi) | `brew install x86_64-elf-binutils x86_64-elf-gcc` (macOS) |
| **qemu-system-x86_64** | runs the image | `brew install qemu` / distro package |
| **gdb** | optional — kernel source-level debugging | `brew install gdb` / distro package |

The MS host tools themselves (CL.EXE, LINK.EXE, NMAKE.EXE, …) ship in the
source tree under `PUBLIC/OAK/BIN/I386`. On first run `build.sh`
provisions `src/wibo-tools/` (symlinks to those tools) via
`setup-wibo-tools.sh`; the bootloader build provisions gnu-efi via
`boot-efi/setup-gnu-efi.sh`. Both are automatic.

---

## Quick start

```sh
cd src
./build.sh                 # build everything → build/gui/esp.img
./boot.sh                  # boot it under QEMU (serial console)
```

`./build.sh` with no arguments builds the full **gui** profile and
assembles the disk image. First build is slow (it builds the toolchain
host steps + the whole kernel); later builds are incremental.

---

## Build targets

`./build.sh [--syms] [target ...]`

### Profiles (compile a superset, then assemble the disk)

| Target | Contents |
|---|---|
| `all` (default) | same as `gui` |
| `gui` | kernel + drivers + Win32 base + USER/GDI + shell → `build/gui/esp.img` |
| `headless` | kernel + drivers + Win32 base subsystem (no USER/GDI) → `build/headless/esp.img` |

### Groups

| Target | Builds |
|---|---|
| `ntoskrnl` | the kernel: `ke rtl ex ob se ps mm cache config lpc dbgk io kd fsrtl raw vdm init hal` |
| `drivers` | core drivers: `atdisk null fastfat npfs msfs serial`, the virtio stack, SCSI/NVMe storage, and the NDIS/TCPIP/AFD network stack |
| `drivers-gui` | input + video: `i8042prt kbdclass mouclass vga_miniport bochsvga` |
| `userland` / `userland-gui` | the Win32 subsystem + shell |
| `disk` | assemble `build/<profile>/esp.img` from already-built binaries |
| `debugtools` | the gdb debug host tools (see below) |

### Individual components

Any `build_<name>` is reachable by name, e.g.:

```sh
./build.sh ke              # just the kernel core
./build.sh ntoskrnl        # the whole kernel + hal
./build.sh tcpip           # the TCP/UDP transport driver
./build.sh drivers         # all core drivers
```

Run `./build.sh <unknown>` to print the full target list.

---

## The disk image

`build_disk` writes `build/<profile>/esp.img` — a GPT disk with an EFI
System Partition holding `BOOTX64.EFI`, the kernel, drivers, the SYSTEM
hive (`mkhive.py`), and the rest of the system files (`mkdisk.py`).

```sh
./build.sh                 # → build/gui/esp.img
./build.sh headless        # → build/headless/esp.img
```

Boot it:

```sh
./boot.sh                          # nvme disk, q35 machine, serial console
./boot.sh --machine pc --disk ide  # legacy chipset + IDE
./boot.sh --vga                    # open a VGA window
./boot.sh --gdb                    # freeze CPU, wait for gdb on :1234
```

`boot.sh` auto-selects the image (`build/gui` then `build/headless`;
override with `MICRONT_ESP=/path/to/esp.img`).

---

## Debug builds (`--syms`)

A normal build is retail (no symbols). `--syms` builds the kernel and
drivers with CodeView (`/Z7` + `-debugtype:cv`, `DBG=0` so code size
stays retail) and emits gdb-loadable DWARF sidecars:

```sh
./build.sh --syms                  # whole tree with symbols
./build.sh --syms ntoskrnl         # just the kernel + hal
```

This produces, next to each image:

- `ntoskrnl.dwf` — `NT/PRIVATE/NTOS/INIT/UP/obj/i386/ntoskrnl.dwf`
- `hal.dwf` — `NT/PRIVATE/NTOS/NTHALS/HAL/obj/i386/hal.dwf`
- a `.dwf` per driver in `PUBLIC/SDK/LIB/I386`

Each `.dwf` is a real DWARF-2 ELF (`.debug_info` / `.debug_line` /
`.symtab`) gdb consumes via `symbol-file` / `add-symbol-file`.

**How it works:** `--syms` sets `NTDEBUG=ntsdnodbg` + `NTDEBUGTYPE=windbg`
for `PRIVATE/NTOS` builds (host tools and Win32 userland stay retail).
The host tools are built up front so LINK can auto-run `cvpack`; after
the build, `splitsym` extracts each PE's CodeView blob to a `.DBG`
sidecar and `dbg2dwf` converts it to `.dwf`. Toggling `--syms` on/off
wipes the NTOS object trees (`/Z7` and retail objects can't be linked
together).

Build only the debug host tools (imagehlp + splitsym, dbg2dwf, cvdump,
cvpack, mkmsg):

```sh
./build.sh debugtools
```

### gdb session

```sh
./build.sh --syms             # 1. build symbols (once)
./boot.sh --gdb               # 2. terminal A: qemu frozen on :1234
./build.sh gdb                # 3. terminal B: gdb attached, symbols loaded
```

`build.sh gdb` symbol-files `ntoskrnl.dwf` + `hal.dwf` (linked at
canonical bases, no slide), sources `tools/gdb.init` + `tools/gdb_nt.py`
(the `nt` command namespace), and connects to `:1234`.

For scripted/agentic debug loops use `tools/agent_run.sh` — see
[DEBUGGING.md](DEBUGGING.md).

---

## Cleaning

```sh
./build.sh clean        # if present; otherwise:
rm -rf build            # drop the disk-image output
# force a from-scratch toolchain reprovision:
./setup-wibo-tools.sh --force
```

To force a clean rebuild of a single component, remove its
`obj/i386` directory and rebuild that target.

---

## Troubleshooting

- **`x86_64-elf-gcc: command not found`** during the disk image step —
  install the cross toolchain: `brew install x86_64-elf-binutils
  x86_64-elf-gcc`. Only the UEFI bootloader needs it.
- **`wibo binary not found`** — download `wibo-macos` (macOS) /
  `wibo-x86_64` (Linux) from the patched fork's releases, place it as
  `src/wibo-macos` (or repo-root `wibo-x86_64`), and `chmod +x`.
- **`D2036 ... not allowed with multiple source files` / stale link
  errors** after switching branches or `--syms` — stale precompiled
  headers / objects. Remove the affected `obj/i386` dir and rebuild.
- **macOS case-insensitive filesystem** — the tree has a few files that
  differ only in case; the build normalizes them at runtime. If a
  component's `obj/i386` looks wrong, wipe it and rebuild.
