# MicroNT UEFI loader — builds BOOTIA32.EFI for ia32 UEFI firmware (OVMF32).
#
# Pipeline:
#   .c  --(gcc -m32 -fshort-wchar ...)-->  .o
#   .o  --(ld with elf_ia32_efi.lds)---->  loader.so  (ELF shared object)
#   .so --(objcopy PE sections)--------->  BOOTIA32.EFI
#
# ESP / disk image assembly is handled by tools/mkdisk.py, not here.

ARCH       := ia32
EFI_INC    := /usr/include/efi
EFI_LIB    := /usr/lib32
EFI_CRT0   := $(EFI_LIB)/crt0-efi-$(ARCH).o
EFI_LDS    := $(EFI_LIB)/elf_$(ARCH)_efi.lds

CC         := gcc
LD         := ld
OBJCOPY    := objcopy

CFLAGS := \
    -m32 -ffreestanding -fno-stack-protector -fno-stack-check \
    -fshort-wchar -mno-red-zone -malign-double \
    -Wall -Wextra -Werror \
    -I$(EFI_INC) -I$(EFI_INC)/$(ARCH) \
    -DEFI_FUNCTION_WRAPPER \
    -nostdinc \
    -isystem $(EFI_INC) -isystem $(EFI_INC)/$(ARCH) \
    -isystem $(shell $(CC) -m32 -print-file-name=include)

LDFLAGS := \
    -nostdlib -znocombreloc -T $(EFI_LDS) -shared \
    -Bsymbolic -L$(EFI_LIB) -m elf_i386

OBJS := main.o com1.o fs.o memmap.o mmu.o pe.o loaderblock.o handoff.o

all: BOOTIA32.EFI

BOOTIA32.EFI: loader.so
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
	rm -f $(OBJS) loader.so BOOTIA32.EFI

.PHONY: all clean
