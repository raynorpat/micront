# MicroNT UEFI loader — builds BOOTX64.EFI for x86_64 UEFI firmware
# (OVMF64). The loader itself runs in long mode; it constructs NT's
# 32-bit page tables + descriptor state in memory, then hands off
# via a 64→32 mode-drop stub in transition.S to the NT kernel at a
# KSEG0 virtual address.
#
# Pipeline:
#   .c  --(gcc -m64 -fshort-wchar ...)-->  .o
#   .o  --(ld with elf_x86_64_efi.lds)-->  loader.so  (ELF shared object)
#   .so --(objcopy PE sections)--------->  BOOTX64.EFI
#
# ESP / disk image assembly is handled by tools/mkdisk.py, not here.

ARCH       := x86_64
UNAME_S    := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
# macOS: no system gnu-efi and no GNU binutils. Use the Homebrew x86_64-elf
# cross toolchain (brew install x86_64-elf-binutils x86_64-elf-gcc) plus a
# gnu-efi tree built from source by setup-gnu-efi.sh into .gnu-efi/ (the
# crt0 / lds / libs land in arch-split subdirs, unlike the flat /usr/lib).
GNUEFI     := .gnu-efi/src
EFI_INC    := $(GNUEFI)/inc
EFI_CRT0   := $(GNUEFI)/$(ARCH)/gnuefi/crt0-efi-$(ARCH).o
EFI_LDS    := $(GNUEFI)/gnuefi/elf_$(ARCH)_efi.lds
EFI_LIBDIRS := -L$(GNUEFI)/$(ARCH)/lib -L$(GNUEFI)/$(ARCH)/gnuefi
CC         := x86_64-elf-gcc
LD         := x86_64-elf-ld
OBJCOPY    := x86_64-elf-objcopy
# This binutils has no efi-app-* input alias; use -O (output only) so the ELF
# input is auto-detected. (GNU binutils on Linux accepts --target for both.)
EFI_OBJCOPY_FMT := -O efi-app-$(ARCH)
# The bare-metal cross gcc doesn't default to PIE the way Ubuntu's gcc does,
# so .rodata accesses emit absolute R_X86_64_32 relocs that can't go in a
# shared object. -fPIC makes them R_X86_64_RELATIVE, which crt0's _relocate
# fixes up at load. (Ubuntu's PIE default makes this implicit on Linux.)
EFI_CC_EXTRA := -fPIC
else
# Linux: gnu-efi + GNU binutils from system packages.
EFI_INC    := /usr/include/efi
EFI_LIB    := /usr/lib
EFI_CRT0   := $(EFI_LIB)/crt0-efi-$(ARCH).o
EFI_LDS    := $(EFI_LIB)/elf_$(ARCH)_efi.lds
EFI_LIBDIRS := -L$(EFI_LIB)
CC         := gcc
LD         := ld
OBJCOPY    := objcopy
EFI_OBJCOPY_FMT := --target=efi-app-$(ARCH)
EFI_CC_EXTRA :=
endif

# -mno-red-zone: UEFI has no 128-byte red zone convention; interrupts
#   can land on the stack at any point so we can't rely on SysV's red
#   zone and must disable it for freestanding + interrupt-safe code.
# -fshort-wchar: UEFI strings are UTF-16, gcc defaults to 32-bit wchar.
CFLAGS := \
    -m64 -ffreestanding -fno-stack-protector -fno-stack-check \
    -fshort-wchar -mno-red-zone $(EFI_CC_EXTRA) \
    -Wall -Wextra -Werror \
    -I$(EFI_INC) -I$(EFI_INC)/$(ARCH) \
    -DEFI_FUNCTION_WRAPPER \
    -nostdinc \
    -isystem $(EFI_INC) -isystem $(EFI_INC)/$(ARCH) \
    -isystem $(shell $(CC) -m64 -print-file-name=include)

LDFLAGS := \
    -nostdlib -znocombreloc -T $(EFI_LDS) -shared \
    -Bsymbolic $(EFI_LIBDIRS) -m elf_x86_64

OBJS := main.o com1.o fs.o memmap.o mmu.o pe.o \
        arena.o uart.o hwtree.o lpb.o handoff.o

all: BOOTX64.EFI

ifeq ($(UNAME_S),Darwin)
# Bootstrap gnu-efi on first build (idempotent). crt0 is the sentinel: if it
# is absent, setup-gnu-efi.sh clones + builds the whole tree (headers needed
# to compile the objects too, hence the order-only prereq).
$(OBJS): | $(EFI_CRT0)
$(EFI_CRT0):
	./setup-gnu-efi.sh
endif

# NOTE: -j .rodata is required with gnu-efi's stock linker script, which emits
# .rodata as its own output section. Without it, string literals and other
# read-only data are dropped from the PE, the firmware never loads them, and
# rip-relative reads hit unmapped memory (garbage). Debian's gnu-efi lds folds
# .rodata into .data so its omission goes unnoticed there — keep it explicit.
BOOTX64.EFI: loader.so
	$(OBJCOPY) \
	    -j .text -j .sdata -j .data -j .rodata -j .dynamic -j .dynsym -j .rel \
	    -j .rela -j .reloc \
	    $(EFI_OBJCOPY_FMT) $< $@

loader.so: $(OBJS) $(EFI_CRT0)
	$(LD) $(LDFLAGS) $(EFI_CRT0) $(OBJS) -o $@ -lefi -lgnuefi

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) loader.so BOOTX64.EFI

.PHONY: all clean
