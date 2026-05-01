#!/bin/sh
#
# Boot MicroNT UEFI loader under OVMF in QEMU.
#
# Usage: boot.sh [--vga] [--gdb] [--trace] [--netdump] [--mem MB]
#   --vga       Open a VGA window (stdvga) in addition to serial.
#               Default: serial-console-only (-display none).
#   --gdb       Pause CPU at boot and listen for gdb on :1234.
#               Connect with `gdb -x boot-efi/gdb.init` from another shell.
#   --trace     Log int / cpu_reset / in_asm to ./qemu.log.
#               Produces a large file; opt-in for exception debugging.
#   --netdump   Dump every virtio-net frame to ./vionet.pcap (override
#               with NETDUMP_FILE=...). Open with wireshark/tshark to
#               see ARP, DHCP, outbound IP exactly as it leaves the guest.
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
NETDUMP_FLAGS=""
MEM=128

# Honour `NETDUMP=1` from the environment so wrapper Makefiles (e.g.
# `make selftest NETDUMP=1`) can opt into the pcap without rewriting
# their boot.sh invocation. The --netdump flag below also turns it on.
if [ -n "$NETDUMP" ] && [ "$NETDUMP" != "0" ]; then
    set -- --netdump "$@"
fi

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
        --netdump)
            # Capture every frame on the virtio-net netdev to a pcap so
            # we can see ARP / DHCP / outbound IP exactly as it leaves
            # the guest. Open the result with wireshark / tshark.
            NETDUMP_FILE="${NETDUMP_FILE:-./vionet.pcap}"
            NETDUMP_FLAGS="-object filter-dump,id=netdump0,netdev=n0,file=$NETDUMP_FILE"
            echo "[boot.sh] capturing virtio-net traffic to $NETDUMP_FILE"
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
    echo "ERROR: $ESP_IMG not found. Run: src/build.sh disk" >&2
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
# Virtio devices: our virtio.lib speaks the modern transport (PCI
# capabilities + MMIO common-config + INTx interrupts), no MSI-X. We
# accept both modern (0x1040+) and transitional (0x1000-0x103F) PCI
# device IDs in the drivers; QEMU's default for the classic device
# classes (rng, console, blk, etc.) is transitional, which exposes
# both interfaces simultaneously and our drivers drive via modern
# transport regardless. Modern-only classes (input, gpu, vsock, fs)
# get their 0x1040+ IDs unconditionally.
#
#   virtio-rng-pci          ->  1AF4:1005 (transitional default)  ->  viorng.sys
#   virtio-serial-pci       ->  1AF4:1003 (transitional default)  ->  vioser.sys
#   virtio-keyboard-pci     ->  1AF4:1052 (modern only)            ->  vioinput.sys
#   virtio-mouse-pci        ->  1AF4:1052 (modern only)            ->  vioinput.sys
#   virtio-net-pci          ->  1AF4:1000 (transitional default)   ->  vionet.sys
#                                                                       (NDIS 3.0 miniport; tcpip.sys binds on top)
#
# Networking: -netdev user gives QEMU's built-in user-mode NAT +
# DHCP server (10.0.2.2). No host bridge configuration required.
# Guest gets 10.0.2.15 from QEMU's DHCP, gateway 10.0.2.2, DNS 10.0.2.3.
#
# Storage profiles (atdisk / nvme / virtio-scsi) are coming as a
# follow-up; for now boot.sh ships only the IDE path.  Same boot disk
# image must mount cleanly across all three — that's what the profile
# matrix exists to verify.
#
# virtio-serial: the PCI device hosts ports; we attach a single
# virtconsole port to a pty chardev. QEMU prints the pty path on stdout
# at boot; cat that pty (e.g. `cat /dev/pts/N`) to see what the guest
# wrote and `echo foo > /dev/pts/N` to send to the guest.
# PCI BAR window: NT 3.5 is 32-bit non-PAE, so it can only address
# physical memory below 4 GiB. OVMF on qemu-system-x86_64 + i440fx
# defaults to a 64-bit PCI MMIO window above 4 GiB and happily places
# device BARs there (e.g. virtio at paddr=0x800000000) which the
# guest can't reach. The HAL handles this in HalpRelocateHighPciBars
# (see src/NT/PRIVATE/NTOS/NTHALS/HAL/I386/ixpcibus.c) - it walks
# every device at boot and rewrites any BAR placed above 4 GiB into
# the low 32-bit MMIO window before drivers see it. We deliberately
# do NOT pass -global i440FX-pcihost.pci-hole64-size=0 here so this
# path is exercised end-to-end, matching cloud / non-QEMU firmware
# that may not honour such tweaks.
exec qemu-system-x86_64 -m "$MEM" \
    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
    -drive if=pflash,format=raw,file=./OVMF_VARS_4M.fd \
    -drive file="$ESP_IMG",format=raw,if=ide \
    -chardev stdio,id=serialmux,mux=on \
    -serial chardev:serialmux \
    -object rng-random,id=rng0,filename=/dev/urandom \
    -device virtio-rng-pci,rng=rng0 \
    -device virtio-serial-pci,id=vser0 \
    -chardev pty,id=vcon0 \
    -device virtconsole,chardev=vcon0 \
    -device virtio-keyboard-pci \
    -device virtio-mouse-pci \
    -netdev user,id=n0 \
    -device virtio-net-pci,netdev=n0 \
    -no-reboot \
    $DISPLAY_FLAGS $GDB_FLAGS $TRACE_FLAGS $NETDUMP_FLAGS
