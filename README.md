# MicroNT

NT 3.5 "Daytona", built from source on Linux/macOS, booting under UEFI on QEMU, with minimal cruft

## Status

Implemented:

- [x] Build basic kernel and system services
- [x] 64-bit UEFI bootloader (`BOOTX64.EFI`, OVMF on qemu)

Coming next:

- [ ] Ninja powered build system
- [ ] Modern Windows build support
- [ ] PCI-native HAL (BAR relocation above 4 GiB, no PC/AT assumptions)
- [ ] Fast `SYSENTER`/`SYSEXIT` & Zw* kernel service dispatch
- [ ] VirtIO transport (modern PCI, shared `virtio.lib`)
  - [ ] virtio-net (NDIS 3 miniport)
  - [ ] virtio-input (keyboard, mouse → kbdclass + mouclass)
  - [ ] virtio-console, virtio-rng
- [ ] NDIS 3 + TDI + AFD + TCP / UDP / ICMP / IP
- [ ] NVMe (SCSI miniport on top of `scsiport.sys`)
- [ ] SATA (SCSI miniport on top of `scsiport.sys`)
- [ ] LAPIC + IOAPIC + HPET HAL (replace i8259 + i8254)
- [ ] SMP
- [ ] GPT partitions (currently MBR via `mkdisk.py`)
- [ ] Modern display path (Bochs VBE miniport works; need GOP-handoff loader path)
- [ ] OpenGL reimplementation
- [ ] Windows NT shell (Program Manager, Control Panel, Notepad, File Browser, etc)

## Repository layout

```
src/NT/PRIVATE/         original NT source (kernel, drivers, sdktools)
src/NT/PUBLIC/          shipped headers + import libs + bootstrap binaries
src/boot-efi/           UEFI loader (gnu-efi, x86_64; long-mode → 32-bit kernel)
src/cmd-stub/           minimal cmd.exe replacement for NMAKE
src/tools/              utility scripts (kdserial, pe2gdb, dumphive, …)
src/wibo-tools/         symlinks into PUBLIC/OAK/BIN/I386 for macOS/Linux building (built first-run)
```

## Build

On Linux:
```sh
sudo apt install gcc gcc-multilib libc6-dev-i386 make gnu-efi \
                 qemu-system-x86 ovmf

git clone --recursive
cd nt365
curl -fL https://github.com/HarryR/wibo/releases/download/v1.1.0-micront.2/wibo-x86_64 -o wibo-x86_64 && chmod +x wibo-x86_64
cd src
./build.sh
```

On macOS (Apple Silicon or Intel):
```sh
brew install x86_64-elf-binutils x86_64-elf-gcc cmake ninja qemu

git clone --recursive
cd nt365

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

Output lands in `build/disk/` (`esp.img`, `nvme.img`, `SYSTEM` hive).

## Run

`src/boot.sh` (next to `build.sh`) wraps QEMU directly — never invoke `qemu-system-*` by hand:

```sh
boot.sh                          # COM1+COM2 muxed to stdio
boot.sh --gdb                    # freeze CPU, listen on :1234 for gdb
boot.sh --trace                  # -d int,cpu_reset,in_asm → ./qemu.log
boot.sh --vga                    # add a VGA window
boot.sh --mem 256                # bump guest RAM (default 128 MiB)
debug.sh                         # one-shot: paused QEMU + gdb.script + capture
```

## Iteration

- TODO

## Symbol lookup under gdb

`pe2gdb.py` emits `ntoskrnl.gdb` and `hal.gdb` from each PE's export
table. Internal statics (`KiTrap*`, `MiReserveSystemPtes`, MM helpers)
aren't exported — disassemble and identify by call shape:

- `mov eax, fs:0x0` / `mov fs:0x0, esp` prologue → SEH-guarded routine.
- `cmp WORD [x], 0x5a4d` + `cmp DWORD [x+e_lfanew], 0x4550` →
  `RtlImageNtHeader`.
- `mov edi, ds:0xXXXXXXXX` where the constant is a list head → walking
  `PsLoadedModuleList` or similar.

Break at `KeBugCheckEx` (from `ntoskrnl.gdb`) to catch every bugcheck;
inspect `[esp+0..20]` for the call site and five parameters.
