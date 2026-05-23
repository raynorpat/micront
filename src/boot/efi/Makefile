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
# ESP / disk image assembly is handled by pkg/ntosbe (Lua), not here.
#
# Layout: the entry-agnostic boot core lives one level up in boot/*.c
# (shared with future entry points, e.g. boot/vmlinuz/). This directory
# holds only the EFI entry (main.c) and its firmware-specific adapters
# (fs.c, handoff.S). Shared sources are pulled in via VPATH below.

ARCH       := x86_64
EFI_INC    := /usr/include/efi
EFI_LIB    := /usr/lib
EFI_CRT0   := $(EFI_LIB)/crt0-efi-$(ARCH).o
EFI_LDS    := $(EFI_LIB)/elf_$(ARCH)_efi.lds

CC         := gcc
LD         := ld
OBJCOPY    := objcopy

# -mno-red-zone: UEFI has no 128-byte red zone convention; interrupts
#   can land on the stack at any point so we can't rely on SysV's red
#   zone and must disable it for freestanding + interrupt-safe code.
# -fshort-wchar: UEFI strings are UTF-16, gcc defaults to 32-bit wchar.
CFLAGS := \
    -m64 -ffreestanding -fno-stack-protector -fno-stack-check \
    -fshort-wchar -mno-red-zone \
    -Wall -Wextra -Werror \
    -I.. -I$(EFI_INC) -I$(EFI_INC)/$(ARCH) \
    -DEFI_FUNCTION_WRAPPER -DBOOTENV_EFI \
    -nostdinc \
    -isystem $(EFI_INC) -isystem $(EFI_INC)/$(ARCH) \
    -isystem $(shell $(CC) -m64 -print-file-name=include)

LDFLAGS := \
    -nostdlib -znocombreloc -T $(EFI_LDS) -shared \
    -Bsymbolic -L$(EFI_LIB) -m elf_x86_64

# Shared boot core (../*.c) found via VPATH; objects build into this dir.
VPATH := ..

# Entry-agnostic core, shared with other boot entries.
COMMON_OBJS := com1.o uart.o fwcfg.o pe.o arena.o hwtree.o lpb.o \
               memmap.o mmu.o cmdline.o bootdrv.o
# EFI entry + firmware-specific adapters (local to boot/efi/).
# bootfs_efi.o binds the bfs_* contract (bootdrv.h) to UEFI SimpleFileSystem.
EFI_OBJS    := main.o fs.o handoff.o bootenv_efi.o memmap_efi.o bootfs_efi.o

OBJS := $(EFI_OBJS) $(COMMON_OBJS)

all: BOOTX64.EFI

BOOTX64.EFI: loader.so
	$(OBJCOPY) \
	    -j .text -j .sdata -j .data -j .dynamic -j .dynsym -j .rel \
	    -j .rela -j .reloc \
	    --target=efi-app-$(ARCH) $< $@

loader.so: $(OBJS) $(EFI_CRT0)
	$(LD) $(LDFLAGS) $(EFI_CRT0) $(OBJS) -o $@ -lefi -lgnuefi

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) loader.so BOOTX64.EFI

.PHONY: all clean
