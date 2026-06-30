#!/bin/bash
#
# setup-gnu-efi.sh — fetch + build gnu-efi for the x86_64 EFI target.
#
# The boot-efi loader is gnu-efi based, but gnu-efi ships no macOS package and
# Apple's toolchain can't produce ELF/PE EFI images. This clones a pinned
# gnu-efi and builds it with the Homebrew x86_64-elf cross toolchain into a
# gitignored .gnu-efi/ tree; boot-efi/Makefile points its -I / crt0 / lds /
# -L at that tree on Darwin.
#
# Usage: ./setup-gnu-efi.sh [--force]
#   --force:  wipe .gnu-efi/ and rebuild from scratch
#
# Idempotent: a no-op once the libs exist.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH=x86_64
CROSS=x86_64-elf-
GNUEFI_REPO="https://github.com/ncroxon/gnu-efi.git"
GNUEFI_TAG="3.0.18"

SRC_DIR="$SCRIPT_DIR/.gnu-efi/src"
LIBEFI="$SRC_DIR/$ARCH/lib/libefi.a"
LIBGNUEFI="$SRC_DIR/$ARCH/gnuefi/libgnuefi.a"
CRT0="$SRC_DIR/$ARCH/gnuefi/crt0-efi-$ARCH.o"

if [ "$1" = "--force" ]; then
    echo ">>> removing $SCRIPT_DIR/.gnu-efi"
    rm -rf "$SCRIPT_DIR/.gnu-efi"
fi

# Require the cross toolchain (Homebrew: x86_64-elf-binutils + x86_64-elf-gcc).
for t in "${CROSS}gcc" "${CROSS}objcopy" "${CROSS}ld"; do
    if ! command -v "$t" >/dev/null 2>&1; then
        echo "ERROR: $t not found." >&2
        echo "Install the cross toolchain:" >&2
        echo "    brew install x86_64-elf-binutils x86_64-elf-gcc" >&2
        exit 1
    fi
done

if [ -f "$LIBEFI" ] && [ -f "$LIBGNUEFI" ] && [ -f "$CRT0" ]; then
    echo ">>> gnu-efi already built at $SRC_DIR"
    exit 0
fi

if [ ! -d "$SRC_DIR/.git" ]; then
    echo ">>> cloning gnu-efi $GNUEFI_TAG"
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "$GNUEFI_TAG" "$GNUEFI_REPO" "$SRC_DIR"
fi

# macOS (and the bare-metal cross toolchain) ship no <elf.h>; gnu-efi's
# reloc_$(ARCH).c needs a handful of 64-bit dynamic/reloc definitions. Drop a
# minimal one into inc/ (on the gnuefi build's -I path) so the angle-bracket
# include resolves.
cat > "$SRC_DIR/inc/elf.h" <<'ELF'
/* Minimal <elf.h> for gnu-efi's reloc_*.c on hosts without a system elf.h. */
#ifndef _MICRONT_MINIMAL_ELF_H
#define _MICRONT_MINIMAL_ELF_H
#include <stdint.h>
typedef uint64_t Elf64_Addr;
typedef uint64_t Elf64_Xword;
typedef int64_t  Elf64_Sxword;
typedef struct { Elf64_Sxword d_tag; union { Elf64_Xword d_val; Elf64_Addr d_ptr; } d_un; } Elf64_Dyn;
typedef struct { Elf64_Addr r_offset; Elf64_Xword r_info; } Elf64_Rel;
typedef struct { Elf64_Addr r_offset; Elf64_Xword r_info; Elf64_Sxword r_addend; } Elf64_Rela;
#define ELF64_R_TYPE(i) ((i) & 0xffffffffL)
#define ELF64_R_SYM(i)  ((i) >> 32)
#define DT_NULL    0
#define DT_RELA    7
#define DT_RELASZ  8
#define DT_RELAENT 9
#define R_X86_64_NONE     0
#define R_X86_64_RELATIVE 8
#endif
ELF

echo ">>> building gnu-efi ($ARCH) with ${CROSS}"
make -C "$SRC_DIR" CROSS_COMPILE="$CROSS" ARCH="$ARCH" lib gnuefi

if [ ! -f "$LIBEFI" ] || [ ! -f "$LIBGNUEFI" ] || [ ! -f "$CRT0" ]; then
    echo "ERROR: gnu-efi build did not produce the expected artifacts." >&2
    exit 1
fi
echo ">>> gnu-efi ready: $SRC_DIR/$ARCH"
