# MicroNT `cr` — mingw-w64 cross-build of LuaJIT into run.exe, the
# initial user-mode process the kernel spawns via Control\Init\Exe.
#
# Ubuntu packages:
#   gcc-mingw-w64-i686 binutils-mingw-w64-i686 mingw-w64-i686-dev
#   gcc-multilib libc6-dev-i386   (buildvm needs a 32-bit host compiler)
#
# Output: run.exe — subsystem=native (1). Imports ntdll.dll only.
# Links librt.a (full freestanding NT runtime: NtProcessStartup entry,
# CRT-shape libc_*, Win32-shape kernel32 surface backed by ntdll).
# No csrss, no kernel32.dll, no user32/gdi32 — MicroNT has no Win32.
#
# Top-level targets:
#   make             — build run.exe (default)
#   make boot        — build + stage on disk + boot under QEMU/OVMF
#   make selftest    — same as boot but pointed at selftest.lua
#   make info        — dump PE header (subsystem/version/imports)
#   make clean       — wipe local .o / .a / .exe
#   make luajit-clean — also wipe LuaJIT's build tree

CROSS    := i686-w64-mingw32-
CC       := $(CROSS)gcc
AR       := $(CROSS)ar
OBJDUMP  := $(CROSS)objdump

# -ffreestanding: no hosted CRT assumptions.
# -fno-builtin: stop gcc rewriting calls into libc shapes.
# -fno-asynchronous-unwind-tables: strip .eh_frame; native NT has no
#     mingw-style DWARF unwinder.
CFLAGS := \
    -m32 -Os -Wall -Wextra \
    -ffreestanding -fno-builtin \
    -fno-asynchronous-unwind-tables \
    -fno-stack-protector \
    -D_CRTBLD \
    -Irt

# RELEASE=1 enables size-oriented build:
#   -ffunction-sections / -fdata-sections + -Wl,--gc-sections drops
#     unreferenced functions/data at link time.
#   -fno-ident drops the GCC version string.
#   -Wl,-s strips the symbol table from the final image.
# Untoggled by default — dev iteration stays fast.
#
# Tried -flto: segfaults mingw-w64's ld in this freestanding +
# -nostdlib + custom-entry configuration. Section-GC + strip together
# give most of the benefit without LTO's fragility.
#
# Entry points and exported symbols still carry __attribute__((used))
# so a future LTO retry doesn't need to re-add them.
RELEASE       ?= 0
ifeq ($(RELEASE),1)
RELEASE_CFLAGS  := -ffunction-sections -fdata-sections -fno-ident
RELEASE_LDFLAGS := -Wl,--gc-sections -Wl,-s
CFLAGS          += $(RELEASE_CFLAGS)
else
RELEASE_CFLAGS  :=
RELEASE_LDFLAGS :=
endif

# Anchor paths to this Makefile's location.
MKFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
REPO       := $(abspath $(MKFILE_DIR)/../..)
SRC        := $(REPO)/src
TOOLS      := $(SRC)/tools
BOOT_EFI   := $(SRC)/boot-efi
BUILD      := $(REPO)/build/disk

LUAJIT_SRC := $(MKFILE_DIR)luajit/src
LUAJIT_OUT := $(LUAJIT_SRC)/luajit.exe

# Init args override. mkhive.py's defaults already point at lua\run.exe
# and \SystemRoot\lua\main.lua with stdio on \Device\Serial0; the only
# thing we override here is the script the kernel hands to run.exe,
# so `make selftest` can swap main.lua for selftest.lua without
# re-running the rest of the toolchain. Empty by default → mkhive
# bakes its own defaults.
INIT_ARGS_FLAG ?=

# Default target: build run.exe. Must come before any other rule so
# `make` with no args picks it up.
all: run.exe

# ---------------- librt + cr_thread ----------------------------------

# librt.a — full freestanding NT runtime: NtProcessStartup trampoline
# (entry.o), CRT-shape API (libc_*.o), Win32-shape kernel32 surface
# (k32_*.o backed by ntdll). There is no kernel32.dll on the target,
# so these shims are load-bearing for anything LuaJIT calls.
RT_OBJS := rt/entry.o \
           $(patsubst %.c,%.o,$(wildcard rt/libc_*.c)) \
           $(patsubst %.c,%.o,$(wildcard rt/k32_*.c))

librt.a: $(RT_OBJS)
	$(AR) rcs $@ $^

# cr_thread.o — the irreducible C trampoline that brings up a fresh
# lua_State on a spawned OS thread. Uses only ntdll + the LuaJIT C API.
cr_thread.o: cr_thread.c
	$(CC) $(CFLAGS) -I$(LUAJIT_SRC) -c -o $@ $<

# ---------------- LuaJIT cross-build --------------------------------
#
# -D_KERNEL32_/_USER32_/_GDI32_ kill dllimport on kernel32/user32/gdi32
# prototypes so LuaJIT's calls resolve to librt's static implementations.
# _CRTBLD: pretend we're building the CRT itself, kills _CRTIMP markers
# + the __mingw_ovr printf inlines.

LUAJIT_TFLAGS := -m32 -Os -fno-builtin -fno-stack-protector \
                 -fno-asynchronous-unwind-tables \
                 -D_CRTBLD \
                 -DLUAJIT_DISABLE_LIB_IO -DLUAJIT_DISABLE_LIB_OS \
                 -DLUAJIT_DISABLE_PROFILE \
                 -D_KERNEL32_ -D_USER32_ -D_GDI32_ \
                 $(RELEASE_CFLAGS)

LUAJIT_LDFLAGS := -nostdlib -nostartfiles -nodefaultlibs \
                  -Wl,--major-os-version,3,--minor-os-version,50 \
                  -Wl,--major-subsystem-version,3,--minor-subsystem-version,50 \
                  -Wl,--image-base,0x00400000 \
                  -Wl,--file-alignment,0x200,--section-alignment,0x1000 \
                  -Wl,--subsystem,native \
                  -Wl,--entry,_NtProcessStartup@4 \
                  -L$(MKFILE_DIR) \
                  $(RELEASE_LDFLAGS)

XLIBS := $(MKFILE_DIR)cr_thread.o \
         -lrt -lmingwex -lntdllcrt -lntdll -lgcc

LUAJIT_SOURCES := $(wildcard $(LUAJIT_SRC)/*.c $(LUAJIT_SRC)/*.h)

run.exe: librt.a cr_thread.o $(LUAJIT_SOURCES)
	$(MAKE) -C $(LUAJIT_SRC) clean
	rm -f $(LUAJIT_OUT)
	$(MAKE) -C $(LUAJIT_SRC) \
	    HOST_CC="gcc -m32" \
	    HOST_CFLAGS="-DLUAJIT_DISABLE_PROFILE" \
	    CROSS=$(CROSS) \
	    TARGET_SYS=Windows \
	    BUILDMODE=static \
	    TARGET_LFSFLAGS= \
	    TARGET_FLAGS='$(LUAJIT_TFLAGS)' \
	    TARGET_LDFLAGS='$(LUAJIT_LDFLAGS)' \
	    TARGET_XLIBS='$(XLIBS)'
	cp $(LUAJIT_OUT) $(MKFILE_DIR)run.exe

# Force a fresh rebuild (e.g. when LuaJIT submodule moves but its .c
# file timestamps don't, or to recover from a half-built state).
rebuild:
	rm -f $(MKFILE_DIR)run.exe
	$(MAKE) all

luajit-clean:
	$(MAKE) -C $(LUAJIT_SRC) clean
	rm -f $(MKFILE_DIR)run.exe

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Dump the PE header fields that matter for NT 3.5 compatibility.
info: all
	@echo "=== run.exe ==="
	@$(OBJDUMP) -p $(MKFILE_DIR)run.exe | grep -E 'Subsystem|MajorOSVer|MinorOSVer|MajorSubsys|MinorSubsys'
	@echo "-- imports --"
	@$(OBJDUMP) -p $(MKFILE_DIR)run.exe | awk '/DLL Name:/{p=1} p' | head -10

clean:
	rm -f *.o *.exe *.a rt/*.o

# Iteration loop: build run.exe, bake a hive (Control\Init pointing at
# our run.exe + args overrides from this Makefile), boot under QEMU/OVMF.
# mkdisk's _lua_tree_files stages run.exe + the whole lua/ tree.
disk: all
	mkdir -p $(BUILD)
	python3 $(TOOLS)/mkhive.py $(INIT_ARGS_FLAG) $(BUILD)/SYSTEM
	python3 $(TOOLS)/mkdisk.py \
	    --output-dir $(BUILD) \
	    --efi-binary $(BOOT_EFI)/BOOTX64.EFI

boot: disk
	$(SRC)/boot.sh

selftest: INIT_ARGS_FLAG = --init-args '\SystemRoot\lua\selftest.lua'
selftest: boot

.PHONY: all rebuild clean info disk boot selftest luajit-clean
