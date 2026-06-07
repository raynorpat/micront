#!/bin/bash
#
# setup-wibo-tools.sh — provision src/wibo-tools/
#
# Populates src/wibo-tools/ with symlinks to every host tool in
# NT/PUBLIC/OAK/BIN/I386, plus CRTDLL.DLL from the SDK LIB tree. build.sh
# points PATH / WIBO_PATH at this directory so the MS toolchain runs under
# wibo. The cmd.exe / MC.EXE that build.sh rebuilds later land here too.
#
# Idempotent: re-running refreshes the symlinks (ln -f) without touching
# anything build.sh dropped in afterward.
#
# Usage: ./setup-wibo-tools.sh [--force]
#   --force:  remove an existing wibo-tools/ and reprovision from scratch
#
# Relative symlinks are computed by hand rather than via `ln -r`, which is
# a GNU coreutils extension absent from the macOS / BSD ln.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NT_ROOT="$SCRIPT_DIR/NT"
WIBO_TOOLS="$SCRIPT_DIR/wibo-tools"

# wibo-tools/ and the source trees both live under src/, so a symlink's
# target is always "../NT/..." relative to wibo-tools/.
OAK_REL="../NT/PUBLIC/OAK/BIN/I386"
CRTDLL_REL="../NT/PUBLIC/SDK/LIB/I386/CRTDLL.DLL"

OAK_DIR="$NT_ROOT/PUBLIC/OAK/BIN/I386"
CRTDLL="$NT_ROOT/PUBLIC/SDK/LIB/I386/CRTDLL.DLL"

if [ ! -d "$OAK_DIR" ]; then
    echo "ERROR: source tools not found: $OAK_DIR"
    echo "Is the NT source tree checked out under $NT_ROOT?"
    exit 1
fi
if [ ! -f "$CRTDLL" ]; then
    echo "ERROR: CRTDLL.DLL not found: $CRTDLL"
    exit 1
fi

if [ "$1" = "--force" ] && [ -d "$WIBO_TOOLS" ]; then
    echo ">>> removing existing $WIBO_TOOLS"
    rm -rf "$WIBO_TOOLS"
fi

echo ">>> provisioning $WIBO_TOOLS"
mkdir -p "$WIBO_TOOLS"

count=0
for f in "$OAK_DIR"/*; do
    ln -sf "$OAK_REL/$(basename "$f")" "$WIBO_TOOLS/$(basename "$f")"
    count=$((count + 1))
done

# CRTDLL.DLL lives in the SDK LIB tree, not in OAK/BIN. NMAKE and most
# MSVC-era tools import from it, so wibo needs to find it alongside the
# host binaries (via WIBO_PATH or cwd).
ln -sf "$CRTDLL_REL" "$WIBO_TOOLS/CRTDLL.DLL"

echo ">>> linked $count tool(s) + CRTDLL.DLL into wibo-tools/"
