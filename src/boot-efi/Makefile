# MicroNT UEFI loader — builds BOOTIA32.EFI for ia32 UEFI firmware (OVMF32).
#
# Pipeline:
#   .c  --(gcc -m32 -fshort-wchar ...)-->  .o
#   .o  --(ld with elf_ia32_efi.lds)---->  loader.so  (ELF shared object)
#   .so --(objcopy PE sections)--------->  BOOTIA32.EFI
#
# Place BOOTIA32.EFI at /EFI/BOOT/BOOTIA32.EFI on the ESP.

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
    -fshort-wchar -mno-red-zone -Wall -Wextra -Werror \
    -I$(EFI_INC) -I$(EFI_INC)/$(ARCH) \
    -DEFI_FUNCTION_WRAPPER \
    -nostdinc \
    -isystem $(EFI_INC) -isystem $(EFI_INC)/$(ARCH) \
    -isystem $(shell $(CC) -m32 -print-file-name=include)

LDFLAGS := \
    -nostdlib -znocombreloc -T $(EFI_LDS) -shared \
    -Bsymbolic -L$(EFI_LIB) -m elf_i386

OBJS := main.o com1.o fs.o memmap.o mmu.o pe.o loaderblock.o handoff.o

# ESP image: FAT16 volume holding /EFI/BOOT/BOOTIA32.EFI + a full NT
# System32 tree, so the single partition serves as both UEFI ESP and the
# NT boot volume. UEFI spec allows FAT12/16/32 equally for ESP; we use
# FAT16 because the kernel's fastfat driver is FAT12/16 only.
ESP_IMG_SIZE_MB := 64

# Repo-relative paths to the NT build outputs that belong on the ESP.
# Each line is "<dest-on-esp>:<source-in-tree>". The order here determines
# copy order (and thus the root-dir listing order).
NT_ROOT       := ../NT
NTOS          := $(NT_ROOT)/PRIVATE/NTOS
SYSTEM_FILES := \
    System32/ntoskrnl.exe:$(NTOS)/INIT/UP/obj/i386/ntoskrnl.exe \
    System32/hal.dll:$(NTOS)/NTHALS/HAL/obj/i386/hal.dll \
    System32/ntdll.dll:$(NT_ROOT)/PUBLIC/SDK/LIB/I386/ntdll.dll \
    System32/kernel32.dll:$(NT_ROOT)/PUBLIC/SDK/LIB/I386/kernel32.dll \
    System32/smss.exe:$(NT_ROOT)/PRIVATE/SM/SERVER/obj/i386/smss.exe \
    System32/c_1252.nls:$(NT_ROOT)/PRIVATE/WINDOWS/WINNLS/DATA/C_1252.NLS \
    System32/c_437.nls:$(NT_ROOT)/PRIVATE/WINDOWS/WINNLS/DATA/C_437.NLS \
    System32/l_intl.nls:$(NT_ROOT)/PRIVATE/WINDOWS/WINNLS/DATA/L_INTL.NLS \
    System32/config/SYSTEM:./SYSTEM \
    System32/Drivers/atdisk.sys:$(NT_ROOT)/PUBLIC/SDK/LIB/I386/atdisk.sys \
    System32/Drivers/fastfat.sys:$(NT_ROOT)/PUBLIC/SDK/LIB/I386/fastfat.sys

# Extract just the <source> paths for prerequisites. Build the source list by
# splitting each mapping at the ':' — second half via $(word 2,$(subst :, ,X)).
SYSTEM_SRCS := $(foreach m,$(SYSTEM_FILES),$(word 2,$(subst :, ,$(m))))

all: esp.img

BOOTIA32.EFI: loader.so
	$(OBJCOPY) \
	    -j .text -j .sdata -j .data -j .dynamic -j .dynsym -j .rel \
	    -j .rela -j .reloc \
	    --target=efi-app-$(ARCH) $< $@

loader.so: $(OBJS) $(EFI_CRT0)
	$(LD) $(LDFLAGS) $(EFI_CRT0) $(OBJS) -o $@ -lefi -lgnuefi
	# Complain if there are unresolved relocs
	@if ! $(LD) $(LDFLAGS) $(EFI_CRT0) $(OBJS) -lefi -lgnuefi -o $@ 2>&1 | tee /tmp/efi_ld.log; then \
	    grep -q 'undefined' /tmp/efi_ld.log && exit 1; \
	fi

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S
	$(CC) $(CFLAGS) -c $< -o $@

# Regenerate the SYSTEM hive from tools/mkhive.py whenever that script
# changes. The hive is tiny; rebuilding it every image run is fine.
SYSTEM: ../tools/mkhive.py
	python3 ../tools/mkhive.py $@

esp.img: BOOTIA32.EFI $(SYSTEM_SRCS)
	@# Verify every required source exists before touching the image
	@missing=""; for f in $(SYSTEM_SRCS); do \
	    [ -f "$$f" ] || missing="$$missing $$f"; \
	done; \
	if [ -n "$$missing" ]; then \
	    echo "ERROR: esp.img requires the following files (run ../build.sh):"; \
	    for f in $$missing; do echo "  - $$f"; done; \
	    exit 1; \
	fi
	dd if=/dev/zero of=$@ bs=1M count=$(ESP_IMG_SIZE_MB) status=none
	@# No -F flag -> mformat picks FAT16 for volumes under ~2 GB.
	mformat -i $@
	mmd     -i $@ ::/EFI ::/EFI/BOOT ::/System32 ::/System32/config ::/System32/Drivers
	mcopy   -i $@ BOOTIA32.EFI ::/EFI/BOOT/BOOTIA32.EFI
	@# Copy each system file to its destination path on the image
	@for pair in $(SYSTEM_FILES); do \
	    dest=":`echo $$pair | cut -d: -f1`"; \
	    src=`echo $$pair | cut -d: -f2`; \
	    echo "  -> $$dest  ($$src)"; \
	    mcopy -i $@ "$$src" "::$${dest#:}" || exit 1; \
	done

clean:
	rm -f $(OBJS) loader.so BOOTIA32.EFI esp.img SYSTEM
	rm -f *.out *.log *.fd

# Inspect the built ESP: FAT variant + recursive directory listing.
info: esp.img
	@echo "--- minfo ---"
	@minfo -i esp.img | grep -Ei 'fat|cluster|sector|size|serial|name' || true
	@echo "--- mdir / ---"
	@mdir -i esp.img ::/
	@echo "--- mdir /EFI/BOOT ---"
	@mdir -i esp.img ::/EFI/BOOT
	@echo "--- mdir /System32 ---"
	@mdir -i esp.img ::/System32
	@echo "--- mdir /System32/config ---"
	@mdir -i esp.img ::/System32/config
	@echo "--- mdir /System32/Drivers ---"
	@mdir -i esp.img ::/System32/Drivers

.PHONY: all clean info
