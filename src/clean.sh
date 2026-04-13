#!/bin/bash
#
# MicroNT Clean Script
# Removes all build artifacts so build.sh produces a fully clean build
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NT_ROOT="$SCRIPT_DIR/NT"
NTOS="$NT_ROOT/PRIVATE/NTOS"

echo "Cleaning build artifacts..."

# Component obj/ directories (where .obj, .lib, .res, _objects.mac go)
COMP_DIRS=(
    "$NTOS/KE/UP"
    "$NTOS/RTL/UP"
    "$NTOS/EX/UP"
    "$NTOS/OB/UP"
    "$NTOS/SE/UP"
    "$NTOS/PS/UP"
    "$NTOS/MM/UP"
    "$NTOS/CACHE/UP"
    "$NTOS/CONFIG/UP"
    "$NTOS/LPC/UP"
    "$NTOS/DBGK/UP"
    "$NTOS/IO/UP"
    "$NTOS/KD/UP"
    "$NTOS/FSRTL/UP"
    "$NTOS/RAW/UP"
    "$NTOS/VDM/UP"
    "$NTOS/INIT/UP"
    "$NTOS/NTHALS/HAL"
    "$NTOS/DD/HARDDISK"
    "$NTOS/DD/NULL"
    "$NTOS/FASTFAT"
    "$NT_ROOT/PRIVATE/WINDOWS/BASE/RTL"
    "$NT_ROOT/PRIVATE/WINDOWS/BASE/CLIENT/DAYTONA"
    "$NT_ROOT/PRIVATE/WINDOWS/WINCON/CLIENT"
    "$NT_ROOT/PRIVATE/WINDOWS/WINNLS"
)

# Shared Windows-subsystem obj/ (baselib.lib / conlib.lib / nlslib.lib land here
# via TARGETPATH=..\obj or ..\..\obj).
WIN_OBJS=(
    "$NT_ROOT/PRIVATE/WINDOWS/BASE/obj"
    "$NT_ROOT/PRIVATE/WINDOWS/obj"
)
for dir in "${WIN_OBJS[@]}"; do
    if [ -d "$dir" ]; then
        rm -rf "$dir"
        echo "  cleaned $dir/"
    fi
done

for dir in "${COMP_DIRS[@]}"; do
    if [ -d "$dir/obj" ]; then
        rm -rf "$dir/obj"
        echo "  cleaned $dir/obj/"
    fi
done

# Shared NTOS obj/ directory (where component .lib files are collected)
if [ -d "$NTOS/obj" ]; then
    rm -rf "$NTOS/obj"
    echo "  cleaned $NTOS/obj/"
fi

# RC temp files (rc.exe leaves these behind on failure).
# Pattern: R[CD][a-d]<5 digits> (matches .gitignore), nothing else.
RC_TEMP_GLOB='R[CD][a-d][0-9][0-9][0-9][0-9][0-9]'
find "$NTOS" -maxdepth 4 -name "$RC_TEMP_GLOB" -delete 2>/dev/null
find "$NT_ROOT/PRIVATE/WINDOWS" -maxdepth 6 -name "$RC_TEMP_GLOB" -delete 2>/dev/null
find "$NT_ROOT/PRIVATE/SM" -maxdepth 4 -name "$RC_TEMP_GLOB" -delete 2>/dev/null

# mc.exe-generated message resources (rebuilt each time).
rm -f "$NT_ROOT/PRIVATE/WINDOWS/NLSMSG/winerror.h" \
      "$NT_ROOT/PRIVATE/WINDOWS/NLSMSG/winerror.rc" \
      "$NT_ROOT/PRIVATE/WINDOWS/NLSMSG/MSG00001.bin" \
      "$NT_ROOT/PRIVATE/WINDOWS/BASE/CLIENT/winerror.rc" \
      "$NT_ROOT/PRIVATE/WINDOWS/BASE/CLIENT/DAYTONA/MSG00001.bin" 2>/dev/null

# Generated boot disk image
rm -f "$SCRIPT_DIR/boot/data/disk.raw" 2>/dev/null && echo "  cleaned boot/data/disk.raw"

# Build products in PUBLIC/SDK/LIB that we generate
for f in ntoskrnl.lib ntoskrnl.exp hal.lib hal.exp tmp.lib tmp.exp \
         atdisk.sys null.sys fastfat.sys \
         kernel32.dll kernel32.exp; do
    if [ -f "$NT_ROOT/PUBLIC/SDK/LIB/I386/$f" ]; then
        rm -f "$NT_ROOT/PUBLIC/SDK/LIB/I386/$f"
        echo "  cleaned PUBLIC/SDK/LIB/I386/$f"
    fi
done

echo "Clean complete."
