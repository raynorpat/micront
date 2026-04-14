#!/bin/sh
#
# Boot MicroNT UEFI loader under OVMF32 in QEMU.
# Expects BOOTIA32.EFI + esp.img built by `make`.
#
# OVMF needs `-machine q35` — the secboot variant's SMM/PI code targets
# the ICH9 chipset. Default i440fx machine hangs silently before firmware
# ever initializes.
#
# Keep a per-checkout copy of NVRAM vars so /usr/share stays pristine.

if [ ! -f OVMF32_VARS_4M.fd ]; then
    cp /usr/share/OVMF/OVMF32_VARS_4M.fd OVMF32_VARS_4M.fd
fi

# GDB=1 enables QEMU's gdb-stub on :1234 and freezes CPU until gdb attaches.
# Connect with `gdb -x gdb.init` from a second shell.
GDB_FLAGS=""
if [ "${GDB:-0}" = "1" ]; then
    GDB_FLAGS="-s -S"
    echo "[boot.sh] gdb-stub on :1234, CPU frozen — attach with: gdb -x gdb.init"
fi

#
# Serial: COM1 (loader) + COM2 (kernel debug) both multiplexed to stdio.
# QEMU chardev mux-on merges both streams to the same terminal — output
# is interleaved but lets us watch everything live.
exec qemu-system-i386 -machine q35 \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF32_CODE_4M.secboot.fd \
    -drive if=pflash,format=raw,file=./OVMF32_VARS_4M.fd \
    -drive format=raw,file=esp.img \
    -chardev stdio,id=serialmux,mux=on \
    -serial chardev:serialmux \
    -serial chardev:serialmux \
    -d int,cpu_reset,in_asm -D qemu.log \
    -no-reboot \
    -display none $GDB_FLAGS