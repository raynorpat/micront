# MicroNT `cr` — mingw-w64 cross-build of LuaJIT into three subsystem-
# specialised binaries that share the same Lua runtime.
#
# Ubuntu packages:
#   gcc-mingw-w64-i686 binutils-mingw-w64-i686 mingw-w64-i686-dev
#   gcc-multilib libc6-dev-i386   (buildvm needs a 32-bit host compiler)
#
# Output binaries (all staged at \SystemRoot\lua\ on the disk image):
#   run.exe    — subsystem=native  (1).  Loaded directly by the kernel
#                via Control\InitExe (cr testbed boot-direct path).
#                Imports: ntdll only.  Links: librt (full set).
#   runc.exe   — subsystem=console (3).  Launched by userinit; csrss
#                allocates a console + stdio handles.  Imports: ntdll +
#                kernel32.  Links: librtw (libc helpers, no k32 shim).
#   runw.exe   — subsystem=windows (2).  Launched by userinit as the
#                Win32 GUI shell.  csrss registers as a GUI process so
#                chunks can ffi.load("user32" / "gdi32").  Imports +
#                links: same as runc, only the subsystem flag differs.
#
# All three statically embed LuaJIT, cr_thread.o and the shared lua/
# tree (the lua/ tree is staged at runtime by mkdisk, not embedded).
# LuaJIT itself compiles twice (the dllimport story for kernel32
# functions differs between native and Win32 hosts), the second compile
# links twice (once for runc, once for runw) sharing the .o cache.
#
# Top-level targets:
#   make             — build all three .exes (default)
#   make boot        — build + stage on disk + boot under QEMU/OVMF32
#                      using run.exe as Control\InitExe (cr testbed)
#   make selftest    — same as boot but pointed at selftest.lua
#   make info        — dump PE header (subsystem/version/imports) for all 3
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
BUILD      := $(REPO)/build/micront

LUAJIT_SRC := $(MKFILE_DIR)luajit/src
LUAJIT_OUT := $(LUAJIT_SRC)/luajit.exe

# Boot-time Control\Init values — only set on the micront profile,
# which boots run.exe directly. Headless and GUI ignore these (their
# boot path goes through smss → winlogon → userinit).
INIT_EXE   ?= lua\run.exe
INIT_ARGS  ?= \SystemRoot\lua\main.lua
INIT_STDIO ?= \Device\Serial0

# Default target: build all three .exes. Must come before any other
# rule so `make` with no args picks it up (Make uses first rule by
# default, not first target alphabetically).
all: run.exe runc.exe runw.exe

# ---------------- librt + librtw + cr_thread -------------------------

# librt.a — full freestanding NT runtime: NtProcessStartup trampoline
# (entry.o), CRT-shape API (libc_*.o), Win32-shape kernel32 surface
# (k32_*.o backed by ntdll). Used ONLY by run.exe, where there's no
# real kernel32 to provide the Win32 surface.
RT_OBJS := rt/entry.o \
           $(patsubst %.c,%.o,$(wildcard rt/libc_*.c)) \
           $(patsubst %.c,%.o,$(wildcard rt/k32_*.c))

librt.a: $(RT_OBJS)
	$(AR) rcs $@ $^

# librtw.a — libc helpers (memmove, strchr, strtod, _errno, getenv,
# etc.) plus a small kernel32 compat shim for NT-4+ functions that
# NT 3.5's kernel32 doesn't export (GetModuleHandleExA,
# GetSystemTimeAsFileTime). The linker prefers static defs over
# library imports, so providing these here drops the failed kernel32
# imports from runc/runw's IAT and the loader is happy on NT 3.5.
# Adding more compat shims to rtw/k32compat.c is the path when a
# future LuaJIT/CRT use surfaces another NT-4+ kernel32 import.
RTW_OBJS := $(patsubst %.c,%.o,$(wildcard rt/libc_*.c)) \
            rtw/k32compat.o

librtw.a: $(RTW_OBJS)
	$(AR) rcs $@ $^

# cr_thread.o — the irreducible C trampoline that brings up a fresh
# lua_State on a spawned OS thread. Same .o in all three binaries
# (uses only ntdll + the LuaJIT C API).
cr_thread.o: cr_thread.c
	$(CC) $(CFLAGS) -I$(LUAJIT_SRC) -c -o $@ $<

# rtw/winentry.o — freestanding entry adapter for runc + runw. Tokenises
# CommandLine from PEB and calls main(); kernel32's ExitProcess on
# return. No mingw mainCRTStartup.
rtw/winentry.o: rtw/winentry.c
	$(CC) $(CFLAGS) -c -o $@ $<

# ---------------- LuaJIT cross-build, twice --------------------------
#
# LuaJIT compiles its source files based on TARGET_FLAGS. The flag
# -D_KERNEL32_ kills dllimport on kernel32 prototypes — needed for
# native run.exe (links librt's k32 shim) but wrong for runc/runw
# (which want kernel32 imports). So LuaJIT compiles twice with
# different TARGET_FLAGS; we orchestrate via clean-then-build.
#
# Within the Win32 compile, runc.exe and runw.exe share the .o cache
# and only the link step differs (subsystem field + entry symbol).

# Common compile flags. _CRTBLD: pretend we're building the CRT
# itself, kills _CRTIMP markers + the __mingw_ovr printf inlines.
# RELEASE_CFLAGS adds -flto + sections-split when RELEASE=1.
LUAJIT_TFLAGS_BASE := -m32 -Os -fno-builtin -fno-stack-protector \
                      -fno-asynchronous-unwind-tables \
                      -D_CRTBLD \
                      -DLUAJIT_DISABLE_LIB_IO -DLUAJIT_DISABLE_LIB_OS \
                      -DLUAJIT_DISABLE_PROFILE \
                      $(RELEASE_CFLAGS)

# Native: kill kernel32/user32/gdi32 dllimport so LuaJIT's calls resolve
# to librt's static implementations.
LUAJIT_TFLAGS_NATIVE := $(LUAJIT_TFLAGS_BASE) \
                        -D_KERNEL32_ -D_USER32_ -D_GDI32_

# Win32: leave dllimport in place so LuaJIT's kernel32 calls go through
# the IAT to the real kernel32.dll.
LUAJIT_TFLAGS_WIN32  := $(LUAJIT_TFLAGS_BASE)

LUAJIT_LDFLAGS_BASE := -nostdlib -nostartfiles -nodefaultlibs \
                       -Wl,--major-os-version,3,--minor-os-version,50 \
                       -Wl,--major-subsystem-version,3,--minor-subsystem-version,50 \
                       -Wl,--image-base,0x00400000 \
                       -Wl,--file-alignment,0x200,--section-alignment,0x1000 \
                       -L$(MKFILE_DIR) \
                       $(RELEASE_LDFLAGS)

# Per-binary LDFLAGS — subsystem field + entry symbol differ.
LDFLAGS_NATIVE  := $(LUAJIT_LDFLAGS_BASE) \
                   -Wl,--subsystem,native \
                   -Wl,--entry,_NtProcessStartup@4
LDFLAGS_CONSOLE := $(LUAJIT_LDFLAGS_BASE) \
                   -Wl,--subsystem,console \
                   -Wl,--entry,_StartConsole@0
LDFLAGS_WINDOW  := $(LUAJIT_LDFLAGS_BASE) \
                   -Wl,--subsystem,windows \
                   -Wl,--entry,_StartWindows@0

# Per-binary XLIBS — librt vs librtw, +winentry, +kernel32 (Win32).
XLIBS_NATIVE  := $(MKFILE_DIR)cr_thread.o \
                 -lrt    -lmingwex -lntdllcrt -lntdll -lgcc
XLIBS_CONSOLE := $(MKFILE_DIR)cr_thread.o $(MKFILE_DIR)rtw/winentry.o \
                 -lrtw   -lmingwex -lntdllcrt -lntdll -lkernel32 -lgcc
XLIBS_WINDOW  := $(XLIBS_CONSOLE)

# Driver macro for invoking LuaJIT's submake.
#   $(1) TARGET_FLAGS
#   $(2) TARGET_LDFLAGS
#   $(3) TARGET_XLIBS
define LUAJIT_BUILD
	rm -f $(LUAJIT_OUT)
	$(MAKE) -C $(LUAJIT_SRC) \
	    HOST_CC="gcc -m32" \
	    HOST_CFLAGS="-DLUAJIT_DISABLE_PROFILE" \
	    CROSS=$(CROSS) \
	    TARGET_SYS=Windows \
	    BUILDMODE=static \
	    TARGET_LFSFLAGS= \
	    TARGET_FLAGS='$(1)' \
	    TARGET_LDFLAGS='$(2)' \
	    TARGET_XLIBS='$(3)'
endef

# Build all three .exes from a single stamp recipe. The .exes get
# produced by ONE invocation that runs LuaJIT's submake three times
# (native compile + native link, win32 compile + console link, win32
# relink + windows link). A stamp file lets make track "everything is
# current" without using GNU Make 4.3+'s grouped-target syntax.
#
# Source-file dependencies on the stamp ensure: if any cr_thread.c /
# rt/*.c / rtw/*.c / lua C source changes, OR any of the per-binary
# helper objects/libs are out of date, the whole batch rebuilds. If
# nothing changed, `make` is a no-op.
#
# Order of operations:
#   1. Native build   → run.exe   (LuaJIT clean, recompile with NATIVE flags)
#   2. Win32 build    → runc.exe  (LuaJIT clean, recompile with WIN32 flags)
#   3. Win32 relink   → runw.exe  (rm luajit.exe, relink only, fast)

EXES_STAMP := .exes-built

LUAJIT_SOURCES := $(wildcard $(LUAJIT_SRC)/*.c $(LUAJIT_SRC)/*.h)

$(EXES_STAMP): librt.a librtw.a cr_thread.o rtw/winentry.o $(LUAJIT_SOURCES)
	# Native build → run.exe
	$(MAKE) -C $(LUAJIT_SRC) clean
	$(call LUAJIT_BUILD,$(LUAJIT_TFLAGS_NATIVE),$(LDFLAGS_NATIVE),$(XLIBS_NATIVE))
	cp $(LUAJIT_OUT) $(MKFILE_DIR)run.exe
	# Win32 build → runc.exe (clean + full rebuild with Win32 flags)
	$(MAKE) -C $(LUAJIT_SRC) clean
	$(call LUAJIT_BUILD,$(LUAJIT_TFLAGS_WIN32),$(LDFLAGS_CONSOLE),$(XLIBS_CONSOLE))
	cp $(LUAJIT_OUT) $(MKFILE_DIR)runc.exe
	# Same Win32 .o cache → runw.exe (relink only)
	$(call LUAJIT_BUILD,$(LUAJIT_TFLAGS_WIN32),$(LDFLAGS_WINDOW),$(XLIBS_WINDOW))
	cp $(LUAJIT_OUT) $(MKFILE_DIR)runw.exe
	touch $@

# .exes get rebuilt as a batch via the stamp recipe.
run.exe runc.exe runw.exe: $(EXES_STAMP)

# Force a fresh rebuild of all three (e.g. when LuaJIT submodule moves
# but its .c file timestamps don't, or to recover from a half-built
# state).
rebuild:
	rm -f $(EXES_STAMP)
	$(MAKE) all

luajit-clean:
	$(MAKE) -C $(LUAJIT_SRC) clean
	rm -f $(EXES_STAMP) $(MKFILE_DIR)run.exe \
	      $(MKFILE_DIR)runc.exe $(MKFILE_DIR)runw.exe

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Dump the PE header fields that matter for NT 3.5 compatibility.
info: all
	@for exe in run.exe runc.exe runw.exe; do \
	    echo "=== $$exe ==="; \
	    $(OBJDUMP) -p $(MKFILE_DIR)$$exe | grep -E 'Subsystem|MajorOSVer|MinorOSVer|MajorSubsys|MinorSubsys'; \
	    echo "-- imports --"; \
	    $(OBJDUMP) -p $(MKFILE_DIR)$$exe | awk '/DLL Name:/{p=1} p' | head -10; \
	    echo ""; \
	done

clean:
	rm -f *.o *.exe *.a rt/*.o rtw/*.o $(EXES_STAMP)

# Iteration loop: build all, bake a micront hive (with Control\Init
# pointing at \SystemRoot\lua\run.exe), boot under OVMF32/QEMU. The
# lua/ tree and run.exe/runc.exe/runw.exe are staged into the image by
# mkdisk's _lua_tree_files() — part of every profile's core, so this
# target only drives the boot wiring, not the staging.
disk: all
	mkdir -p $(BUILD)
	python3 $(TOOLS)/mkhive.py --profile micront \
	    --init-exe '$(INIT_EXE)' \
	    --init-args '$(INIT_ARGS)' \
	    --init-stdio '$(INIT_STDIO)' \
	    $(BUILD)/SYSTEM
	python3 $(TOOLS)/mkdisk.py --profile micront \
	    --output-dir $(BUILD) \
	    --efi-binary $(BOOT_EFI)/BOOTX64.EFI

boot: disk
	$(BOOT_EFI)/boot.sh micront

selftest: INIT_ARGS = \SystemRoot\lua\selftest.lua
selftest: boot

.PHONY: all rebuild clean info disk boot selftest luajit-clean
