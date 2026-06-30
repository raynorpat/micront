# MicroNT

NT 3.5 "Daytona", built from source on Linux/macOS, booting under UEFI on QEMU, with minimal cruft

## Status

Implemented:

- [x] Build the kernel + system services from source (wibo-hosted MS toolchain)
- [x] 64-bit UEFI bootloader (`BOOTX64.EFI`, OVMF on qemu)
- [x] macOS (Apple Silicon/Intel) + Linux build support
- [x] PCI-native HAL — bus-master DMA + BAR relocation above 4 GiB
- [x] Fast `SYSENTER`/`SYSEXIT` user dispatch + direct kernel-mode Zw* dispatch
- [x] VirtIO transport (modern PCI, shared `virtio.lib`)
  - [x] virtio-net (NDIS 3 miniport)
  - [x] virtio-input (keyboard, mouse → kbdclass + mouclass)
  - [x] virtio-console, virtio-rng
- [x] NDIS 3 + TDI + AFD + TCP / UDP / ICMP / IP
- [x] NVMe + SCSI port/disk class (`scsiport.sys` / `scsidisk.sys`)
- [x] TSC-derived HAL wall clock (seeded from UEFI `GetTime`)
- [x] Native gdb kernel debugging — CodeView → DWARF `.dwf` pipeline

Coming next:

- [ ] Ninja powered build system
- [ ] Modern Windows build support
- [ ] SATA (SCSI miniport on top of `scsiport.sys`)
- [ ] LAPIC + IOAPIC + HPET HAL (replace i8259 + i8254)
- [ ] SMP
- [ ] GPT partitions (currently MBR via `mkdisk.py`)
- [ ] NTFS (NT 3.5 + NT 4.0 backports exist on the Lua line; not merged here)
- [ ] Modern display path (Bochs VBE miniport works; need GOP-handoff loader path)
- [ ] OpenGL reimplementation
- [ ] Windows NT shell (Program Manager, Control Panel, Notepad, File Browser, etc)

See **[docs/BUILDING.md](docs/BUILDING.md)** for the full build reference
and **[docs/DEBUGGING.md](docs/DEBUGGING.md)** for kernel debugging.

## Repository layout

```
src/NT/PRIVATE/         original NT source (kernel, drivers, sdktools)
src/NT/PUBLIC/          shipped headers + import libs + bootstrap binaries
src/boot-efi/           UEFI loader (gnu-efi, x86_64; long-mode → 32-bit kernel)
src/cmd-stub/           minimal cmd.exe replacement for NMAKE
src/tools/              utility + debug scripts (gdb_nt, agent_run, decode_av, mkhive, mkdisk, …)
src/wibo-tools/         symlinks into PUBLIC/OAK/BIN/I386 for macOS/Linux building (built first-run)
```

## Build

On Linux:
```sh
sudo apt install gcc gcc-multilib libc6-dev-i386 make gnu-efi \
                 qemu-system-x86 ovmf

git clone --recursive
cd micront
curl -fL https://github.com/HarryR/wibo/releases/download/v1.1.0-micront.2/wibo-x86_64 -o wibo-x86_64 && chmod +x wibo-x86_64
cd src
./build.sh
```

On macOS (Apple Silicon or Intel):
```sh
brew install x86_64-elf-binutils x86_64-elf-gcc cmake ninja qemu

git clone --recursive
cd micront

# The stock wibo-macos release mishandles redirected stdout for tools that
# re-exec helpers (cl386->cl->c1, midl->cl), so build a patched wibo from
# source. See src/patches/wibo-macos-grandchild-stdio.patch for the fix.
git clone https://github.com/HarryR/wibo.git
git -C wibo checkout v1.1.0-micront.2
git -C wibo apply ../src/patches/wibo-macos-grandchild-stdio.patch
( cd wibo && cmake --preset release-macos && cmake --build --preset release-macos )
cp wibo/build/release/wibo src/wibo-macos

cd src
./build.sh   # first run auto-builds gnu-efi for the loader (setup-gnu-efi.sh)
```

The macOS build uses the Homebrew `x86_64-elf` cross toolchain for the UEFI
loader; `src/boot-efi/setup-gnu-efi.sh` fetches and builds gnu-efi into a
gitignored `.gnu-efi/` on first build.

Two toolchains coexist:

- **wibo** runs the original MS toolchain (CL 8.50, ML 6.11d, LINK 2.50, NMAKE) under a tiny PE loader. No Wine.
- **gcc + gnu-efi** for the UEFI loader.

Output lands in `build/<profile>/` — e.g. `build/gui/esp.img` + the `SYSTEM` hive. A plain `./build.sh` builds the `gui` profile.

## Run

`src/boot.sh` (next to `build.sh`) wraps QEMU directly — never invoke `qemu-system-*` by hand:

```sh
boot.sh                          # COM1+COM2 muxed to stdio
boot.sh --gdb                    # freeze CPU, listen on :1234 for gdb
boot.sh --trace                  # -d int,cpu_reset,in_asm → ./qemu.log
boot.sh --vga                    # add a VGA window
boot.sh --mem 256                # bump guest RAM (default 128 MiB)
boot.sh --disk nvme|ide|virtio-blk   # pick the boot disk controller
```

`boot.sh` auto-selects `build/gui/esp.img` (then `build/headless/`);
override with `MICRONT_ESP=/path/to/esp.img`.

## Debugging

Source-level kernel debugging under gdb, via a CodeView → DWARF pipeline:

```sh
src/build.sh --syms              # build kernel + drivers with /Z7; emit .dwf
src/boot.sh --gdb                # terminal A: qemu frozen on :1234
src/build.sh gdb                 # terminal B: gdb attached, symbols + `nt` helpers
```

`build.sh --syms` emits `ntoskrnl.dwf` / `hal.dwf` and a `.dwf` per
driver (real DWARF-2 ELF gdb loads directly). `build.sh gdb` symbol-files
them and sources the `nt` command namespace (`nt modules`, `nt bugcheck`,
`nt trapframe`, …). For scripted/agentic debug loops use
`tools/agent_run.sh`.

Full reference: **[docs/DEBUGGING.md](docs/DEBUGGING.md)**.
