# MicroNT (aka *"NT 3.65 Cloud Edition"*)

NT 3.50 "Daytona", built from source on Linux, booting under UEFI on QEMU, with a native-NT Lua runtime as `init`. No Win32, no `smss.exe`, no shell. What if we built NT again from Cutler's vision, without Windows baggage...

## Status

Implemented:

- [x] 64-bit UEFI bootloader (`BOOTX64.EFI`, OVMF on qemu)
- [x] PCI-native HAL (BAR relocation above 4 GiB, no PC/AT assumptions)
- [x] Fast `SYSENTER`/`SYSEXIT` & Zw* kernel service dispatch
- [x] VirtIO transport (modern PCI, shared `virtio.lib`)
  - [x] virtio-net (NDIS 3 miniport)
  - [x] virtio-input (keyboard, mouse → kbdclass + mouclass)
  - [x] virtio-console, virtio-rng
- [x] NDIS 3 + TDI + AFD + TCP / UDP / ICMP / IP
- [x] NVMe (SCSI miniport on top of `scsiport.sys`)
- [x] Native-NT Lua userland (LuaJIT 2.1, FFI to `ntdll`)

Coming next:

- [ ] LAPIC + IOAPIC + HPET HAL (replace i8259 + i8254)
- [ ] SMP
- [ ] GPT partitions (currently MBR via `mkdisk.py`)
- [ ] Modern display path (Bochs VBE miniport works; need GOP-handoff loader path)

## Lua as init

The kernel spawns one user-mode process via `Control\Init\Exe` — the
Lua runtime (`src/cr/run.exe`, native NT subsystem, imports `ntdll`
only). This is the equivalent of Linux's `/sbin/init`. There is no
`smss.exe`, no `csrss.exe`, no `winlogon`, no GDI / USER. Everything
the system does post-kernel — driver loading, PnP, the test harness,
anything that would have lived in a service — is Lua under
`\SystemRoot\lua\`. FFI bindings to the NT syscall surface live under
`lua/nt/dll/`.

## Repository layout

```
src/NT/PRIVATE/         original NT source (kernel, drivers, sdktools)
src/NT/PUBLIC/          shipped headers + import libs + bootstrap binaries
src/boot-efi/           UEFI loader (gnu-efi, x86_64; long-mode → 32-bit kernel)
src/cr/                 native-NT LuaJIT runtime (run.exe + lua.dll + librt)
src/pkg/                Lua tree staged at \SystemRoot\lua\ on disk
src/pkg/ntosbe/         NT OS Build Environment (hive + disk + profiles)
src/cmd-stub/           minimal cmd.exe replacement for NMAKE
src/tools/              utility scripts (kdserial, pe2gdb, dumphive, …)
src/wibo-tools/         symlinks into PUBLIC/OAK/BIN/I386 (built first-run)
src/build.lua           top-level build driver (LuaJIT)
src/bootstrap.sh        builds the host LuaJIT used to run build.lua
src/ntosbe.lua          CLI entry into pkg/ntosbe (mkhive + mkdisk replacement)
```

`stuff/` and `wibo/` are reference trees. CI fetches a prebuilt
`wibo-x86_64` from the [wibo fork's release
page](https://github.com/HarryR/wibo/releases) — the in-tree `wibo/` is
for diffing.

## Build

```sh
sudo apt install gcc gcc-multilib libc6-dev-i386 make gnu-efi \
                 gcc-mingw-w64-i686 binutils-mingw-w64-i686 \
                 mingw-w64-i686-dev qemu-system-x86 ovmf

git clone --recursive 
cd nt365
curl -fL https://github.com/HarryR/wibo/releases/download/v1.1.0-micront.2/wibo-x86_64 -o wibo-x86_64 && chmod +x wibo-x86_64
cd src
./bootstrap.sh                                # builds the host LuaJIT
../build/host-tools/luajit ./build.lua        # builds everything
```

Three toolchains coexist:

- **wibo** runs the original MS toolchain (CL 8.50, ML 6.11d, LINK 2.50,
  NMAKE) under a tiny PE loader. No Wine.
- **gcc + gnu-efi** for the UEFI loader.
- **mingw-w64 i686** for the cr testbed (LuaJIT cross-compiled for
  native-NT subsystem).

Output lands in `build/disk/` (`esp.img`, `nvme.img`, `SYSTEM` hive).

## Run

```sh
make -C src/cr boot              # boot the disk under QEMU + OVMF
make -C src/cr selftest          # boot, run selftest.lua, shut down (CI signal)
```

`src/boot.sh` (next to `build.lua`) wraps QEMU directly — never invoke
`qemu-system-*` by hand:

```sh
boot.sh                          # COM1+COM2 muxed to stdio
boot.sh --gdb                    # freeze CPU, listen on :1234 for gdb
boot.sh --trace                  # -d int,cpu_reset,in_asm → ./qemu.log
boot.sh --vga                    # add a VGA window
boot.sh --mem 256                # bump guest RAM (default 128 MiB)
debug.sh                         # one-shot: paused QEMU + gdb.script + capture
```

## Iteration

- `luajit build.lua <component>` — single component, e.g. `ke`, `mm`,
  `virtio`, `ntdll`. Run with no args or unknown name to list targets.
- `luajit build.lua virtio_lib` rebuilds just `virtio.lib`; `virtio`
  rebuilds the lib + every consumer `.sys`.
- `luajit build.lua clean:<component>` drops just that component's
  `obj/`; `clean:<group>` (ntoskrnl / drivers / userland / tools)
  recurses; bare `clean` nukes everything.
- The build skips unchanged objects on `.c` mtime alone. Editing a `.h`
  doesn't trigger dependents — touch the `.c` or run `clean:<comp>`.

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

