#!/bin/sh
#
# Boot MicroNT UEFI loader under OVMF in QEMU.
#
# Usage: boot.sh [--vga] [--gdb] [--trace] [--mem MB]
#   --vga       Open a VGA window (stdvga) in addition to serial.
#               Default: serial-console-only (-display none).
#   --gdb       Pause CPU at boot and listen for gdb on :1234.
#               Connect with `gdb -x boot-efi/gdb.init` from another shell.
#   --trace     Log int / cpu_reset / in_asm to ./qemu.log.
#               Produces a large file; opt-in for exception debugging.
#   --mem MB    Guest RAM in megabytes. Default 128.
#
# Runs under the default -machine pc (i440fx + PIIX3); OVMF works on
# both i440fx and q35, and our NT 3.5 atdisk.sys only speaks legacy IDE
# anyway, so staying on PIIX3 saves us the q35-→-AHCI impedance mismatch.
#
# Keep a per-checkout copy of NVRAM vars so /usr/share stays pristine.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ESP_IMG="$REPO_ROOT/build/disk/esp.img"

# --- Argument parsing --------------------------------------------------------

DISPLAY_FLAGS="-display none"
GDB_FLAGS=""
TRACE_FLAGS=""
MEM=128

while [ $# -gt 0 ]; do
    case "$1" in
        --vga)
            DISPLAY_FLAGS="-display gtk -vga std"
            shift
            ;;
        --gdb)
            GDB_FLAGS="-s -S"
            echo "[boot.sh] gdb-stub on :1234, CPU frozen — attach with:"
            echo "          gdb -x $SCRIPT_DIR/boot-efi/gdb.init"
            shift
            ;;
        --trace)
            TRACE_FLAGS="-d int,cpu_reset,in_asm -D qemu.log"
            echo "[boot.sh] tracing int,cpu_reset,in_asm to ./qemu.log"
            shift
            ;;
        --mem)
            shift
            MEM="$1"
            shift
            ;;
        -h|--help)
            sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# //; s/^#//'
            exit 0
            ;;
        *)
            echo "boot.sh: unknown flag '$1'" >&2
            echo "         try: $0 --help" >&2
            exit 1
            ;;
    esac
done

# --- Sanity --------------------------------------------------------

if [ ! -f "$ESP_IMG" ]; then
    echo "ERROR: $ESP_IMG not found. Run: build.sh" >&2
    exit 1
fi

cp /usr/share/OVMF/OVMF_VARS_4M.fd OVMF_VARS_4M.fd

# --- QEMU --------------------------------------------------------------------
#
# Serial: COM1 (loader) + COM2 (kernel debug) both multiplexed to stdio.
# Single COM1 channel to stdio — everything (loader, HAL, kernel) writes
# here. COM2 was used historically for HAL debug while COM1 served the
# KD (WinDbg) protocol; we don't use KD, so HAL now writes to COM1 too.
#
# Storage: legacy IDE is the default on -machine pc — no explicit
# -device piix3-ide needed. NT 3.5's atdisk.sys speaks IDE/ATA and
# OVMF's IdeBusDxe handles the firmware-side enumeration fine.
#
# Virtio devices: NT 3.5's HAL doesn't speak MMCONFIG / MSI-X, so we
# force transitional mode (legacy I/O config + INTx interrupts) on
# every virtio device with disable-modern=on,disable-legacy=off. The
# PCI vendor:device IDs land in our drivers' PCI scan range.
#
#   virtio-rng-pci      →  1AF4:1005  →  viorng.sys
#   virtio-serial-pci   →  1AF4:1003  →  vioser.sys
#
# virtio-serial: the PCI device hosts ports; we attach a single
# virtconsole port to a pty chardev. QEMU prints the pty path on stdout
# at boot; cat that pty (e.g. `cat /dev/pts/N`) to see what the guest
# wrote and `echo foo > /dev/pts/N` to send to the guest.
exec qemu-system-x86_64 -m "$MEM" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=./OVMF_VARS_4M.fd \
    -drive file="$ESP_IMG",format=raw,if=ide \
    -chardev stdio,id=serialmux,mux=on \
    -serial chardev:serialmux \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -device virtio-rng-pci,rng=rng0,disable-modern=on,disable-legacy=off \
    -device virtio-serial-pci,disable-modern=on,disable-legacy=off,id=vser0 \
    -chardev pty,id=vcon0 \
    -device virtconsole,chardev=vcon0 \
    -no-reboot \
    $DISPLAY_FLAGS $GDB_FLAGS $TRACE_FLAGS
