# MicroNT PVH loader (boot/vmlinuz) — a 32-bit ELF booted by
# qemu-system-x86_64 -kernel via the x86/HVM (PVH) direct boot ABI.
#
# Shares the entry-agnostic boot core in boot/*.c, built freestanding and
# -m32. The skeleton shares com1 only; more core files join as their
# freestanding seams (be_alloc_pages, be_log, be_memory_regions) land.

CC := gcc
LD := ld

# 64-bit divide/modulo on i386 emits calls to libgcc helpers
# (__udivdi3/__umoddi3); we link -nostdlib, so pull in the 32-bit libgcc.
LIBGCC := $(shell $(CC) -m32 -print-libgcc-file-name)

CFLAGS := \
    -m32 -g -ffreestanding -fno-stack-protector -fno-stack-check \
    -fno-pic -fno-pie -mno-red-zone -fshort-wchar \
    -fno-tree-loop-distribute-patterns \
    -Wall -Wextra -Werror \
    -I. -I.. -nostdinc \
    -isystem $(shell $(CC) -m32 -print-file-name=include)

LDFLAGS := -m elf_i386 -nostdlib -z noexecstack -T vmlinux.lds

# Shared core sources (../*.c) found via VPATH; objects build into this dir.
VPATH := ..

# Entry-agnostic core, shared with boot/efi/ (compiled freestanding -m32).
COMMON_OBJS := com1.o uart.o fwcfg.o cmdline.o pe.o arena.o hwtree.o \
               mmu.o memmap.o lpb.o fatread.o fatbuild.o zipread.o bootdrv.o
# PVH entry + adapters (local to boot/vmlinuz/). blog.c is this entry's
# bxlog() sink (-> com1); bootenv_pvh.c is its be_* contract impl
# (be_memory_regions from e820, be_alloc_pages bump allocator); handoff.S
# is the 32-bit CR3/GDT/IDT/TSS install + jump into KiSystemStartup;
# bootfs_pvh.c binds the bfs_* contract (bootdrv.h) to the FAT16 reader.
# puff.c is the vendored DEFLATE inflater (zip method 8), kept here rather
# than in the shared core since the EFI build never decompresses; setjmp.S
# backs the freestanding <setjmp.h> puff bails out through.
PVH_OBJS    := head.o main.o blog.o bootenv_pvh.o handoff.o bootfs_pvh.o \
               puff.o setjmp.o

OBJS := $(PVH_OBJS) $(COMMON_OBJS)

all: vmlinux

vmlinux: $(OBJS) vmlinux.lds
	$(LD) $(LDFLAGS) $(OBJS) $(LIBGCC) -o $@

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) vmlinux

.PHONY: all clean
