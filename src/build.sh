#!/bin/bash
#
# MicroNT Build Script
# Builds NT 3.5 kernel components using the original Microsoft toolchain
# under wibo (a minimal Win32 PE runner).
#
# Usage: ./build.sh [--debug] [--syms] [component]
#   --debug:    enable WIBO_DEBUG tracing
#   --syms:     build kernel + drivers (NTOS) with CodeView and emit
#               <name>.DBG + <name>.dwf gdb sidecars (off by default)
#   component:  ke, rtl, ex, ob, se, ps, mm, cache, config, init, hal, all
#   If no component specified, builds all
#
# Prerequisites: a wibo binary — wibo-macos on macOS,
# wibo-x86_64 at the repo root on Linux. The src/wibo-tools/
# directory (symlinks to PUBLIC/OAK/BIN/I386 + CRTDLL.DLL) is provisioned
# automatically on first run via setup-wibo-tools.sh.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NT_ROOT="$SCRIPT_DIR/NT"
NTOS="$NT_ROOT/PRIVATE/NTOS"

# Pick the right wibo binary for the host OS: wibo-macos on macOS,
# wibo-x86_64 on Linux.
case "$(uname -s)" in
    Darwin) WIBO_BIN="$SCRIPT_DIR/wibo-macos" ;;
    *)      WIBO_BIN="$(dirname "$SCRIPT_DIR")/wibo-x86_64" ;;
esac
WIBO_TOOLS="$SCRIPT_DIR/wibo-tools"

if [ ! -x "$WIBO_BIN" ]; then
    echo "ERROR: wibo binary not found or not executable: $WIBO_BIN"
    echo "Download from https://github.com/HarryR/wibo/releases (the MicroNT-patched fork)"
    echo "and place as $WIBO_BIN, then chmod +x."
    exit 1
fi

# Populate wibo-tools/ if missing. Needs to happen before the NT_ENV_ARR
# init below, since PATH / WIBO_PATH point into it. The directory holds
# symlinks to every tool in PUBLIC/OAK/BIN/I386 plus CRTDLL.DLL and the
# cmd.exe / MC.EXE we rebuild later (via build_cmdstub / build_mc).
if [ ! -d "$WIBO_TOOLS" ]; then
    echo ">>> setting up $WIBO_TOOLS (first-time)"
    "$SCRIPT_DIR/setup-wibo-tools.sh"
fi

# Wibo only strips "Z:" and "C:" prefixes — everything is routed through Z: as
# Z:\<host-abs-path>\... Build the Windows-style equivalents once.
path_to_win() { printf 'Z:%s' "$(echo "$1" | sed 's|/|\\|g')"; }
NT_ROOT_WIN="$(path_to_win "$NT_ROOT")"
WIBO_TOOLS_WIN="$(path_to_win "$WIBO_TOOLS")"

# --syms: opt-in CodeView build that emits .DBG/.dwf gdb sidecars.
# Sets NTDEBUG=ntsd + NTDEBUGTYPE=windbg, which MAKEFILE.DEF/I386MK.INC turn
# into /Z7 compiles + -debug:full -debugtype:cv links (LINK auto-runs cvpack).
# splitsym then extracts each PE's CV blob to a <name>.DBG sidecar and
# dbg2dwf converts it to a <name>.dwf ELF gdb loads. Off by default; the
# shipped .sys/.dll are retail-identical bar a 28-byte debug-dir entry.
# Toggling the mode wipes obj/i386 (/Z7 objs can't link with non-/Z7 ones).
SYMS=0
_BUILD_ARGS=()
for _a in "$@"; do
    case "$_a" in
        --syms)    SYMS=1 ;;
        --no-syms) SYMS=0 ;;
        *)         _BUILD_ARGS+=("$_a") ;;
    esac
done
set -- "${_BUILD_ARGS[@]}"

# _NTROOT is the path component under the drive, e.g. "\home\user\...\NT".
# NT makefiles concatenate $(_NTDRIVE)$(_NTROOT) to re-form the absolute path.
_NTROOT_WIN="$(echo "$NT_ROOT" | sed 's|/|\\|g')"

# NT tool env vars. Previously a single "set X=Y&& ..." string fed to cmd.exe;
# now a bash array so we can set them directly in wibo's env with no shell.
NT_ENV_ARR=(
    "_NTDRIVE=Z:"
    "_NTROOT=${_NTROOT_WIN}"
    "BASEDIR=${NT_ROOT_WIN}"
    "NTMAKEENV=${NT_ROOT_WIN}\\PUBLIC\\OAK\\BIN"
    "386=1"
    "TARGETCPU=I386"
    "NT_UP=1"
    "NTDEBUG="
    "NTDEBUGTYPE="
    "PATH=${WIBO_TOOLS_WIN}"
    "WIBO_PATH=${WIBO_TOOLS}"
    "COMSPEC=${WIBO_TOOLS_WIN}\\cmd.exe"
    "TEMP=Z:\\tmp"
    "TMP=Z:\\tmp"
    "INCLUDE=${NT_ROOT_WIN}\\PUBLIC\\SDK\\INC;${NT_ROOT_WIN}\\PUBLIC\\OAK\\INC;${NT_ROOT_WIN}\\PUBLIC\\SDK\\INC\\CRT"
    "LIB=${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386"
)

# Resolve a tool name ("cl386", "mc", "NMAKE.EXE") to an absolute path in
# wibo-tools, case-insensitively. Returns empty if not found.
wibo_tool_path() {
    local name="$1"
    local match
    match="$(find "$WIBO_TOOLS" -maxdepth 1 -iname "$name" 2>/dev/null | head -1)"
    if [ -z "$match" ] && [[ "$name" != *.* ]]; then
        match="$(find "$WIBO_TOOLS" -maxdepth 1 -iname "${name}.exe" 2>/dev/null | head -1)"
    fi
    echo "$match"
}

# run_nmake <linux_dir> <description> [extra_nmake_args...]
#
# By default clears NTTEST / UMTEST / UMAPPL so they don't accidentally turn
# a kernel-lib build into an EXE build. For components that are intentionally
# UMAPPL builds (like gensrv, smss), set `KEEP_UMAPPL=1` in the caller env
# to preserve the SOURCES file's UMAPPL= directive.
run_nmake() {
    local linux_dir="$1"
    local desc="$2"
    shift 2
    local extra_args=("$@")

    echo "========================================"
    echo "Building: $desc"
    echo "========================================"

    if [ ! -d "$linux_dir" ]; then
        echo "ERROR: directory not found: $linux_dir"
        return 1
    fi

    mkdir -p "$linux_dir/obj/i386"

    # Ensure the shared NTOS output directory exists (TARGETPATH=..\..\obj)
    mkdir -p "$NTOS/obj/i386"

    # Always regenerate _objects.mac to stay in sync with SOURCES
    python3 "$SCRIPT_DIR/tools/gen_objects.py" "$linux_dir"

    # NMAKE-based dep tracking is unreliable for NT components: source
    # files in the parent dir of the build subdir (e.g. SE/UP builds .c
    # from SE/) and header edits anywhere don't always trigger a recompile.
    # Pre-pass: stat-compare sources against the .obj files in obj/i386 and
    # remove any stale outputs so NMAKE rebuilds them.
    #
    # Two passes:
    #   1) Per-source: if foo.c is newer than foo.obj, rm foo.obj.
    #   2) Per-header: if any .h/.hxx/.inc is newer than the OLDEST .obj,
    #      nuke ALL .obj in obj/i386 (we can't tell which TUs include
    #      which header without a real dependency graph; coarse but
    #      correct). Also covers asm/include changes.
    #
    # Doesn't cover cross-component header changes (editing a header
    # under PUBLIC/SDK/INC won't reach components that build elsewhere
    # unless we explicitly invoke their build_* target).
    {
        local _obj_dir="$linux_dir/obj/i386"
        local _src_dirs=("$linux_dir" "$linux_dir/.." "$linux_dir/i386")
        local _d _src _base _obj _stem
        local _nuked=0

        # Pass 1: stale .obj per source file
        for _d in "${_src_dirs[@]}"; do
            [ -d "$_d" ] || continue
            for _src in "$_d"/*.c "$_d"/*.cxx "$_d"/*.cpp "$_d"/*.asm \
                        "$_d"/*.C "$_d"/*.CXX "$_d"/*.CPP "$_d"/*.ASM; do
                [ -f "$_src" ] || continue
                _base="$(basename "$_src")"
                _stem="${_base%.*}"
                # Match case-insensitive against existing .obj
                _obj="$(find "$_obj_dir" -maxdepth 1 -iname "${_stem}.obj" 2>/dev/null | head -1)"
                if [ -n "$_obj" ] && [ "$_src" -nt "$_obj" ]; then
                    echo "  stale: $_base (newer than $(basename "$_obj"))"
                    rm -f "$_obj"
                fi
            done
        done

        # Pass 2: header edits invalidate everything (can't tell which TU
        # includes which .h without a real dep scanner)
        if [ -d "$_obj_dir" ] && ls "$_obj_dir"/*.obj >/dev/null 2>&1; then
            local _oldest_obj
            _oldest_obj="$(ls -t "$_obj_dir"/*.obj 2>/dev/null | tail -1)"
            for _d in "${_src_dirs[@]}"; do
                [ -d "$_d" ] || continue
                for _src in "$_d"/*.h "$_d"/*.hxx "$_d"/*.hpp "$_d"/*.inc \
                            "$_d"/*.H "$_d"/*.HXX "$_d"/*.HPP "$_d"/*.INC; do
                    [ -f "$_src" ] || continue
                    if [ -n "$_oldest_obj" ] && [ "$_src" -nt "$_oldest_obj" ]; then
                        echo "  header changed: $(basename "$_src") (newer than $(basename "$_oldest_obj")) — nuking $_obj_dir/*.obj"
                        rm -f "$_obj_dir"/*.obj "$_obj_dir"/*.pch
                        _nuked=1
                        break 2
                    fi
                done
            done
        fi
    }

    local rel_path="${linux_dir#$NT_ROOT}"
    local makedir_win="${NT_ROOT_WIN}$(echo "$rel_path" | sed 's|/|\\|g')"

    local umappl_override="UMAPPL="
    if [ "${KEEP_UMAPPL:-}" = "1" ]; then
        umappl_override=""
    fi

    # --syms: build kernel + drivers (PRIVATE/NTOS) with CodeView so we can
    # emit .dwf gdb sidecars. NTDEBUG/NTDEBUGTYPE here override the empty
    # NT_ENV_ARR entries (env: last assignment wins). Scoped to NTOS so host
    # tools (SDKTOOLS/RPC) and the Win32 userland keep their retail/coff
    # build — cvpack only needs to exist for the NTOS links.
    local syms_env=()
    if [ "$SYMS" = "1" ] && [[ "$linux_dir" == *"/PRIVATE/NTOS/"* ]]; then
        syms_env=("NTDEBUG=ntsdnodbg" "NTDEBUGTYPE=windbg")
    fi

    env -i HOME="$HOME" TERM="${TERM:-dumb}" ${WIBO_DEBUG:+"WIBO_DEBUG=$WIBO_DEBUG"} \
        "${NT_ENV_ARR[@]}" "${syms_env[@]}" "MAKEDIR=${makedir_win}" \
        "$WIBO_BIN" --chdir "$linux_dir" \
            "${WIBO_TOOLS}/NMAKE.EXE" /NOLOGO NTTEST= UMTEST= \
            ${umappl_override:+"$umappl_override"} "${extra_args[@]}"

    local rc=$?

    if [ $rc -eq 0 ]; then
        echo ">>> $desc: OK"
    else
        echo ">>> $desc: FAILED (rc=$rc)"
    fi
    return $rc
}

# run_wibo_cmd <description> <win_cmd>
#
# Runs a NT-style command under wibo with the standard NT env. Accepts the
# same single-string form the old cmd.exe-based wrapper took, including
# optional leading "X:&& cd \PATH\TO\DIR&& ..." sequences which we translate
# into --chdir on the host.
run_wibo_cmd() {
    local desc="$1"
    local win_cmd="$2"
    local cwd="$SCRIPT_DIR"

    # Strip optional "X:&& cd \WIN\PATH&& " prefix (cmd.exe drive+cd).
    if [[ "$win_cmd" =~ ^[A-Za-z]:\&\&[[:space:]]*cd[[:space:]]+\\([^\&]+)\&\&[[:space:]]*(.*)$ ]]; then
        local winpath="${BASH_REMATCH[1]}"
        win_cmd="${BASH_REMATCH[2]}"
        # Trim trailing whitespace from winpath.
        winpath="${winpath%"${winpath##*[![:space:]]}"}"
        cwd="$NT_ROOT/${winpath//\\/\/}"
    fi

    # Split on whitespace; args in this codebase don't contain spaces.
    read -ra tokens <<<"$win_cmd"
    local tool_name="${tokens[0]}"
    local tool_path
    tool_path="$(wibo_tool_path "$tool_name")"
    if [ -z "$tool_path" ]; then
        # Not a wibo-tools binary — e.g. Z:\tmp\geni386.exe. Use as-is.
        tool_path="$(echo "$tool_name" | sed "s|^Z:|| ; s|\\\\|/|g")"
        if [ ! -f "$tool_path" ]; then
            echo ">>> $desc: tool not found: $tool_name" >&2
            return 1
        fi
    fi
    local args=("${tokens[@]:1}")

    env -i HOME="$HOME" TERM="${TERM:-dumb}" ${WIBO_DEBUG:+"WIBO_DEBUG=$WIBO_DEBUG"} \
        "${NT_ENV_ARR[@]}" \
        "$WIBO_BIN" --chdir "$cwd" "$tool_path" "${args[@]}"

    local rc=$?
    if [ $rc -ne 0 ]; then
        echo ">>> $desc: FAILED (rc=$rc)"
    fi
    return $rc
}

# run_wibo_tool <cwd> <tool> [args...]
#
# Invoke a single tool directly (no cmd.exe-style string parsing). Call sites
# that used `wine cmd /c "$env&& tool args"` are simpler to express this way
# because PATH/INCLUDE are already set via NT_ENV_ARR.
run_wibo_tool() {
    local cwd="$1" tool_name="$2"; shift 2
    local tool_path
    tool_path="$(wibo_tool_path "$tool_name")"
    if [ -z "$tool_path" ]; then
        echo "ERROR: tool not found in wibo-tools: $tool_name" >&2
        return 1
    fi
    local args=("$@")
    env -i HOME="$HOME" TERM="${TERM:-dumb}" ${WIBO_DEBUG:+"WIBO_DEBUG=$WIBO_DEBUG"} \
        "${NT_ENV_ARR[@]}" \
        "$WIBO_BIN" --chdir "$cwd" "$tool_path" "${args[@]}"
}

# --- Generate struct offset headers (KS386.INC, HAL386.INC) ---
# These MUST match our compiler's struct layout or ASM/C code will disagree.

build_geni386() {
    echo "========================================"
    echo "Building: GENI386 (struct offset generator)"
    echo "========================================"

    local geni_src="$NT_ROOT/PRIVATE/NTOS/KE/I386/GENI386.C"
    local geni_dir="$NTOS/INIT/UP/obj/i386"
    mkdir -p "$geni_dir"
    local geni_dir_win; geni_dir_win="$(path_to_win "$geni_dir")"

    if [ ! -f "$geni_src" ]; then
        echo "ERROR: GENI386.C not found"
        return 1
    fi

    run_wibo_tool "$SCRIPT_DIR" cl386 \
        -nologo -c -Zp8 -Gz -Di386=1 -D_X86_=1 -DNT_UP=1 -DSTD_CALL \
        -DCONDITION_HANDLING=1 -DWIN32_LEAN_AND_MEAN=1 -D_NTSYSTEM_ -DDBG=0 -DDEVL=1 \
        "-I${NT_ROOT_WIN}\\PRIVATE\\NTOS\\INC" \
        "-I${NT_ROOT_WIN}\\PRIVATE\\NTOS\\KE" \
        "-I${NT_ROOT_WIN}\\PRIVATE\\INC" \
        "-I${NT_ROOT_WIN}\\PUBLIC\\OAK\\INC" \
        "-I${NT_ROOT_WIN}\\PUBLIC\\SDK\\INC" \
        "-I${NT_ROOT_WIN}\\PUBLIC\\SDK\\INC\\CRT" \
        "${NT_ROOT_WIN}\\PRIVATE\\NTOS\\KE\\I386\\GENI386.C" \
        "-Fo${geni_dir_win}\\geni386.obj" || return 1

    run_wibo_tool "$SCRIPT_DIR" link \
        -nologo -subsystem:console \
        "-out:${geni_dir_win}\\geni386.exe" \
        "${geni_dir_win}\\geni386.obj" \
        "${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386\\LIBC.LIB" \
        "${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386\\KERNEL32.LIB" || return 1

    env -i HOME="$HOME" TERM="${TERM:-dumb}" ${WIBO_DEBUG:+"WIBO_DEBUG=$WIBO_DEBUG"} \
        "${NT_ENV_ARR[@]}" \
        "$WIBO_BIN" --chdir "$SCRIPT_DIR" \
            "$geni_dir/geni386.exe" \
            "${NT_ROOT_WIN}\\PUBLIC\\SDK\\INC\\KS386.INC" \
            "${NT_ROOT_WIN}\\PRIVATE\\NTOS\\INC\\HAL386.INC" || return 1

    echo ">>> GENI386: KS386.INC and HAL386.INC regenerated"
}

# --- Kernel library components (each produces a .lib in NTOS/obj/i386/) ---

build_ke()     { run_nmake "$NTOS/KE/UP"      "KE - Kernel Core"; }
# RTL needs NTSTATUS→DOS error tables (error.h) generated from GENERR.C
# before error.c compiles. tools/generr.py is a Python port of the
# original generr.exe.
_ensure_error_h() {
    python3 "$SCRIPT_DIR/tools/generr.py" "$NTOS/RTL/error.h"
}
build_rtl()    { _ensure_error_h; run_nmake "$NTOS/RTL/UP"      "RTL - Runtime Library"; }
# bugcodes.rc / bugcodes.h are generated from NTOS/NLS/BUGCODES.MC by
# mc.exe. ntoskrnl.rc #includes bugcodes.rc; NTOS/INC/bugcodes.h is
# referenced by NTOS.H / NTDDK.H / NTHAL.H / NTIFS.H.
_ensure_bugcodes() {
    local nls="$NTOS/NLS"
    if [ -f "$nls/bugcodes.rc" ] && [ -f "$NTOS/INC/bugcodes.h" ] \
       && [ "$nls/bugcodes.rc" -nt "$nls/BUGCODES.MC" ]; then
        return 0
    fi
    echo ">>> mc bugcodes.mc -> bugcodes.h/.rc"
    run_wibo_tool "$nls" mc BUGCODES.MC \
        || { echo "!!! mc on BUGCODES.MC failed"; return 1; }
    # mc.exe emits BUGCODES.rc / BUGCODES.h in the case of the .MC input; Linux
    # is case-sensitive, so match explicitly.
    cp -f "$nls/BUGCODES.rc" "$NTOS/INIT/bugcodes.rc"
    cp -f "$nls/BUGCODES.h"  "$NTOS/INC/bugcodes.h"
    cp -f "$nls/MSG00001.bin" "$NTOS/INIT/msg00001.bin"
}
build_ex()     { run_nmake "$NTOS/EX/UP"       "EX - Executive"; }
build_ob()     { run_nmake "$NTOS/OB/UP"       "OB - Object Manager"; }
build_se()     { run_nmake "$NTOS/SE/UP"       "SE - Security"; }
build_ps()     { run_nmake "$NTOS/PS/UP"       "PS - Process Structure"; }
build_mm()     { run_nmake "$NTOS/MM/UP"       "MM - Memory Manager"; }
build_cache()  { run_nmake "$NTOS/CACHE/UP"    "CACHE - Cache Manager"; }
build_config() { run_nmake "$NTOS/CONFIG/UP"   "CONFIG - Registry"; }
build_lpc()    { run_nmake "$NTOS/LPC/UP"      "LPC - Local Procedure Call"; }
build_dbgk()   { run_nmake "$NTOS/DBGK/UP"    "DBGK - Debug Subsystem"; }
build_io()     { run_nmake "$NTOS/IO/UP"       "IO - I/O Manager"; }
build_kd()     { run_nmake "$NTOS/KD/UP"       "KD - Kernel Debugger"; }
build_fsrtl()  { run_nmake "$NTOS/FSRTL/UP"    "FSRTL - File System RTL"; }
build_raw()    { run_nmake "$NTOS/RAW/UP"      "RAW - Raw File System"; }
build_vdm()    { run_nmake "$NTOS/VDM/UP"      "VDM - Virtual DOS Machine"; }

# --- Boot device / filesystem drivers (TARGETTYPE=DRIVER) ---
# serial.sys has its own message catalog (serlog.mc) that mc.exe compiles
# into serlog.rc + serlog.h + msg00001.bin. serial.rc #includes serlog.rc,
# and initunlo.c #includes serlog.h (error codes). Run mc before nmake —
# same pattern as _ensure_bugcodes for ntoskrnl.
_ensure_serlog() {
    local dir="$NTOS/DD/SERIAL"
    if [ -f "$dir/serlog.rc" ] && [ -f "$dir/serlog.h" ] \
       && [ "$dir/serlog.rc" -nt "$dir/SERLOG.MC" ]; then
        return 0
    fi
    echo ">>> mc SERLOG.MC -> serlog.h/.rc"
    run_wibo_tool "$dir" mc SERLOG.MC \
        || { echo "!!! mc on SERLOG.MC failed"; return 1; }
    # mc.exe emits case-matching names on Windows; normalise for our
    # case-sensitive Linux FS so #include "serlog.rc" / "serlog.h" resolve.
    # On a case-insensitive FS (macOS) SERLOG.rc and serlog.rc are the same
    # file, so skip the copy there — cp -f onto itself errors and returns 1.
    [ -f "$dir/SERLOG.rc" ] && ! [ "$dir/SERLOG.rc" -ef "$dir/serlog.rc" ] \
        && cp -f "$dir/SERLOG.rc" "$dir/serlog.rc"
    [ -f "$dir/SERLOG.h" ] && ! [ "$dir/SERLOG.h" -ef "$dir/serlog.h" ] \
        && cp -f "$dir/SERLOG.h" "$dir/serlog.h"
    return 0
}
build_atdisk() { run_nmake "$NTOS/DD/HARDDISK" "ATDISK - IDE disk driver"; }
build_serial() { _ensure_serlog && run_nmake "$NTOS/DD/SERIAL" "SERIAL - NT 3.5 serial port driver"; }
build_null()   { run_nmake "$NTOS/DD/NULL"     "NULL - null device driver"; }
build_fastfat(){ run_nmake "$NTOS/FASTFAT"     "FASTFAT - FAT filesystem driver"; }
build_npfs()   { run_nmake "$NTOS/NPFS"       "NPFS - Named Pipe filesystem driver"; }
build_msfs()   { run_nmake "$NTOS/MAILSLOT"  "MSFS - Mailslot filesystem driver"; }
# NTFS: lfs.lib (Log File Service, LIBRARY) is linked into ntfs.sys, so
# build it first. ntfs.sys declines FAT volumes and mounts NTFS ones.
build_lfs()    { run_nmake "$NTOS/LFS"  "LFS - Log File Service (lfs.lib)"; }
build_ntfs()   { build_lfs || return 1; run_nmake "$NTOS/NTFS" "NTFS - NT filesystem driver"; }
build_hello()  { run_nmake "$NTOS/DD/HELLO"    "HELLO - MicroNT visibility driver"; }

# --- virtio shared lib + device drivers -------------------------------------
# virtio.lib — shared bus / split-ring / PCI legacy transport. Every
# virtio device driver links against it. Adapted from Unikraft (BSD-3).
build_virtio_lib() { run_nmake "$NTOS/VIRTIO" "VIRTIO - bus + ring + PCI legacy (virtio.lib)"; }
build_viorng()   { run_nmake "$NTOS/DD/VIORNG"   "VIORNG - virtio-rng entropy driver"; }
build_vioser()   { run_nmake "$NTOS/DD/VIOSER"   "VIOSER - virtio-console driver"; }
build_vioinput() { run_nmake "$NTOS/DD/VIOINPUT" "VIOINPUT - virtio-input keyboard/mouse driver"; }
# Whole virtio subsystem: shared lib + every consumer .sys. The mtime
# prepass only sees per-component .c/.h, so a change to RING.C / BUS.C /
# PCI.C won't relink the .sys files unless we walk consumers here.
# vionet lives under NDIS/VIONET but links virtio.lib like the rest.
build_virtio() {
    build_virtio_lib   || return $?
    build_viorng       || return $?
    build_vioser       || return $?
    build_vioinput     || return $?
    build_ndis_vionet  || return $?
}

# --- SCSI subsystem ---------------------------------------------------------
# Dependency order: class.lib -> scsiport.sys -> scsidisk.sys; nvme2k is
# a SCSI miniport on top of scsiport. Each needs its own obj/i386 (nmake
# won't create it when the parent dir is fresh).
build_dd_class()    { mkdir -p "$NTOS/DD/CLASS/obj/i386";    run_nmake "$NTOS/DD/CLASS"    "CLASS - SCSI class-driver helper lib"; }
build_dd_scsiport() { mkdir -p "$NTOS/DD/SCSIPORT/obj/i386"; run_nmake "$NTOS/DD/SCSIPORT" "SCSIPORT - SCSI miniport framework" makedll=1; }
build_dd_scsidisk() { mkdir -p "$NTOS/DD/SCSIDISK/obj/i386"; run_nmake "$NTOS/DD/SCSIDISK" "SCSIDISK - SCSI disk class driver"; }
build_dd_nvme2k()   { mkdir -p "$NTOS/DD/NVME2K/obj/i386";   run_nmake "$NTOS/DD/NVME2K"   "NVME2K - NVMe storage controller (SCSI miniport)"; }

# --- NDIS framework + virtio-net miniport -----------------------------------
# ndis.sys — NDIS wrapper / framework (EXPORT_DRIVER, produces ndis.lib).
# vionet.sys — virtio-net NDIS 3.0 miniport; links virtio.lib + ndis.lib.
build_ndis_wrapper() { mkdir -p "$NTOS/NDIS/WRAPPER/obj/i386"; run_nmake "$NTOS/NDIS/WRAPPER" "NDIS - NDIS wrapper / framework" makedll=1; }
build_ndis_vionet()  { mkdir -p "$NTOS/NDIS/VIONET/obj/i386";  run_nmake "$NTOS/NDIS/VIONET"  "VIONET - virtio-net NDIS miniport"; }

# --- TDI + TCPIP + AFD ------------------------------------------------------
# tdi.sys -> ip.lib -> tcpip.sys (TCP/UDP transport). afd.sys is the
# socket emulation layer above TDI; links tdi.lib so builds after it.
build_tdi_wrapper()   { mkdir -p "$NTOS/TDI/WRAPPER/obj/i386"; run_nmake "$NTOS/TDI/WRAPPER" "TDI - TDI wrapper (tdi.sys)" makedll=1; }
build_tdi_tcpip_ip()  { mkdir -p "$NTOS/TDI/TCPIP/IP/obj/i386"; mkdir -p "$NTOS/TDI/TCPIP/obj/i386"; run_nmake "$NTOS/TDI/TCPIP/IP" "TDI/TCPIP/IP - IP/ARP/ICMP (ip.lib)"; }
build_tdi_tcpip_tcp() { mkdir -p "$NTOS/TDI/TCPIP/TCP/obj/i386"; run_nmake "$NTOS/TDI/TCPIP/TCP" "TDI/TCPIP/TCP - TCP/UDP transport (tcpip.sys)"; }
build_afd()           { mkdir -p "$NTOS/AFD/obj/i386"; run_nmake "$NTOS/AFD" "AFD - socket emulation driver (afd.sys)"; }

# --- NetBT: NetBIOS over TCP/IP ---------------------------------------------
# nbt.lib (core, platform-independent NetBIOS-over-TCP engine) links into
# netbt.sys (the NT driver wrapper). netbt.sys binds over tcpip via TDI and
# is what SMB (rdr/srv) rides on. -DPROXY_NODE per its SOURCES.
build_nbt_lib() { mkdir -p "$NTOS/NBT/NBT/obj/i386"; run_nmake "$NTOS/NBT/NBT" "NBT - NetBIOS-over-TCP core (nbt.lib)"; }
build_netbt()   { build_nbt_lib || return 1; mkdir -p "$NTOS/NBT/NT/obj/i386"; run_nmake "$NTOS/NBT/NT" "NETBT - NetBIOS over TCP driver (netbt.sys)" makedll=1; }
# netbios.sys — the NetBIOS interface driver (\Device\Netbios). Maps the NCB
# API (Netbios() in the prebuilt netapi32) onto the TDI transports bound
# under its registry Linkage (netbt). Not on the SMB critical path (rdr
# binds netbt directly), but makes user-mode NetBIOS work.
build_netbios() { mkdir -p "$NTOS/NETBIOS/obj/i386"; run_nmake "$NTOS/NETBIOS" "NETBIOS - NetBIOS interface driver (netbios.sys)" makedll=1; }

# --- SMB redirector (client) ------------------------------------------------
# rdr.sys — the SMB client / network filesystem. Links two helper libs:
# smbtrsup (SMB transport support) + bowser (Computer Browser support). Rides
# on netbt (TDI). LanmanWorkstation service points at it.
build_smbtrsup() { mkdir -p "$NTOS/SMBTRSUP/obj/i386"; run_nmake "$NTOS/SMBTRSUP" "SMBTRSUP - SMB transport support (smbtrsup.lib)"; }
build_bowser()   { mkdir -p "$NTOS/BOWSER/obj/i386"; run_nmake "$NTOS/BOWSER" "BOWSER - Computer Browser support (bowser.lib)"; }
build_rdr() {
    build_smbtrsup || return 1
    build_bowser   || return 1
    mkdir -p "$NTOS/RDR/DAYTONA/obj/i386"
    run_nmake "$NTOS/RDR/DAYTONA" "RDR - SMB redirector (rdr.sys)" makedll=1
}
# srv.sys — the SMB server (serve local shares). Links tdi.lib + smbtrsup.lib
# (already built for the redirector). LanmanServer service drives it.
build_srv() {
    build_smbtrsup || return 1
    mkdir -p "$NTOS/SRV/DAYTONA/obj/i386"
    run_nmake "$NTOS/SRV/DAYTONA" "SRV - SMB server (srv.sys)" makedll=1
}

# wkssvc.dll — the Workstation service. Hosted by services.exe (SCM), it
# binds the redirector (rdr.sys) to transports and services net-use RPCs.
# MIDL generates wkssvc.h + client/server stubs from WKSSVC.IDL; the client
# stub compiles into wkssvc.lib, the server stub into wkssvc.dll.
build_wkssvc_idl() {
    local dir="$NET/SVCDLLS/WKSSVC"
    # -oldnames so MIDL emits wkssvc_ServerIfHandle (referenced by wsmain.c),
    # not wkssvc_v1_0_s_ifspec.
    run_wibo_tool "$dir" midl /ms_ext /c_ext /app_config /D MIDL_PASS /D _M_IX86 /D _X86_ \
        -oldnames /I "$NT_ROOT_WIN\\PRIVATE\\INC" WKSSVC.IDL || return 1
    # midl emits into WKSSVC/ as WKSSVC_c.c / WKSSVC_s.c (uppercase base from
    # WKSSVC.IDL, lowercase _c/_s suffix). Locate each case-insensitively — a
    # fixed-case cp works on macOS by luck but misses the mixed case on Linux —
    # and copy to the lowercase names the CLIENT/SERVER SOURCES compile.
    local cstub sstub
    cstub="$(find "$dir" -maxdepth 1 -iname 'wkssvc_c.c' | head -1)"
    sstub="$(find "$dir" -maxdepth 1 -iname 'wkssvc_s.c' | head -1)"
    [ -n "$cstub" ] || { echo "!!! wkssvc: MIDL produced no client stub"; return 1; }
    [ -n "$sstub" ] || { echo "!!! wkssvc: MIDL produced no server stub"; return 1; }
    cp -f "$cstub" "$dir/CLIENT/wkssvc_c.c"
    cp -f "$sstub" "$dir/SERVER/wkssvc_s.c"
}
build_wkssvc_lib() { build_wkssvc_idl || return 1; run_nmake "$NET/SVCDLLS/WKSSVC/CLIENT" "WKSSVC/CLIENT - wkssvc.lib (RPC client stub)"; }
build_wkssvc() {
    build_wkssvc_idl || return 1
    build_wkssvc_lib || return 1
    run_nmake "$NET/SVCDLLS/WKSSVC/SERVER/DAYTONA" "WKSSVC - Workstation service (wkssvc.dll)" makedll=1
}

# srvsvc.dll — the Server service. Hosted by services.exe, it starts/binds
# the SMB server (srv.sys) and manages shares. srvcomn.lib is its shared
# helper; MIDL generates the client/server stubs from SRVSVC.IDL.
build_srvsvc_idl() {
    local dir="$NET/SVCDLLS/SRVSVC"
    run_wibo_tool "$dir" midl /ms_ext /c_ext /app_config /D MIDL_PASS /D _M_IX86 /D _X86_ \
        -oldnames /I "$NT_ROOT_WIN\\PRIVATE\\INC" SRVSVC.IDL || return 1
    # MIDL emits SRVSVC_c.c / SRVSVC_s.c (mixed case); find case-insensitively
    # so this works on case-sensitive Linux, not just macOS.
    local cstub sstub
    cstub="$(find "$dir" -maxdepth 1 -iname 'srvsvc_c.c' | head -1)"
    sstub="$(find "$dir" -maxdepth 1 -iname 'srvsvc_s.c' | head -1)"
    [ -n "$cstub" ] || { echo "!!! srvsvc: MIDL produced no client stub"; return 1; }
    [ -n "$sstub" ] || { echo "!!! srvsvc: MIDL produced no server stub"; return 1; }
    cp -f "$cstub" "$dir/CLIENT/srvsvc_c.c"
    cp -f "$sstub" "$dir/SERVER/srvsvc_s.c"
}
build_srvcomn()    { build_srvsvc_idl || return 1; run_nmake "$NET/SVCDLLS/SRVSVC/LIB" "SRVSVC/LIB - srvcomn.lib (server service helpers)"; }
build_srvsvc_lib() { build_srvsvc_idl || return 1; run_nmake "$NET/SVCDLLS/SRVSVC/CLIENT" "SRVSVC/CLIENT - srvsvc.lib (RPC client stub)"; }
# srvsvc.dll — the Server service. Serves shares over RPC, and remotes the
# downlevel (LanMan/OS2 RAP) admin API to older clients via the transaction
# server — so it links xactsrv.lib, which comes from the xactsrv<->browser
# circular build below.
build_srvsvc() {
    build_srvsvc_idl     || return 1
    build_srvcomn        || return 1
    build_srvsvc_lib     || return 1
    build_xactsrv_browser || return 1   # provides xactsrv.lib (+ browser.dll)
    run_nmake "$NET/SVCDLLS/SRVSVC/SERVER" "SRVSVC - Server service (srvsvc.dll)" makedll=1
}

# --- Computer Browser + downlevel transaction server -----------------------
# browser.dll (the Computer Browser service, "Network Neighborhood") and
# xactsrv.dll (the LanMan/OS2 downlevel RAP transaction server) have a
# circular DLL import: browser links xactsrv.lib, xactsrv links browser.lib.
# It's broken the same way as samsrv<->lsasrv: compile both to objs, then
# synthesize each import lib from its .def (+ objs for @N decorations), then
# link both DLLs. xactsrv also needs the RPCXLATE stack (dosprint marshalling
# + rxcommon/rxapi RAP descriptors + netrap).
build_dosprint() { run_nmake "$NET/DOSPRINT"          "NET/DOSPRINT - DosPrint API (dosprint.lib)"; }
build_rxcommon() { run_nmake "$NET/RPCXLATE/RXCOMMON" "NET/RXCOMMON - RAP marshalling common (rxcommon.lib)"; }
build_rxapi()    { run_nmake "$NET/RPCXLATE/RXAPI"    "NET/RXAPI - RAP API descriptors (rxapi.lib)"; }
build_netrap()   { build_netlib || return 1; run_nmake "$NET/RAP" "NET/RAP - Remote Admin Protocol (netrap.dll)" makedll=1; }
build_brcommon() { build_browser_idl || return 1; run_nmake "$NET/SVCDLLS/BROWSER/COMMON" "BROWSER/COMMON - browser helpers (brcommon.lib)"; }
# BOWSER.IDL -> bowser.h + client/server stubs. -oldnames for the ServerIfHandle.
build_browser_idl() {
    local dir="$NET/SVCDLLS/BROWSER"
    run_wibo_tool "$dir" midl /ms_ext /c_ext /app_config /D MIDL_PASS /D _M_IX86 /D _X86_ \
        -oldnames /I "$NT_ROOT_WIN\\PRIVATE\\INC" BOWSER.IDL || return 1
    # MIDL emits BOWSER_c.c / BOWSER_s.c (mixed case); find case-insensitively
    # so this works on case-sensitive Linux, not just macOS.
    local cstub raw
    cstub="$(find "$dir" -maxdepth 1 -iname 'bowser_c.c' | head -1)"
    [ -n "$cstub" ] || { echo "!!! browser: MIDL produced no client stub"; return 1; }
    cp -f "$cstub" "$dir/CLIENT/bowser_c.c"
    # The SERVER build wraps the raw server stub with precomp.h via a .mdl->.c
    # rule (BROWSER/SERVER/MAKEFILE.INC) that shells out to cmd's `type`
    # builtin — which our wibo cmd-stub can't exec. Do the wrap here instead:
    # emit bowser_s.mdl (raw stub, the makefile prerequisite) and a ready
    # bowser_s.c (precomp header + stub) that's newer, so the rule never fires.
    raw="$(find "$dir" -maxdepth 1 -iname 'bowser_s.c' | head -1)"
    [ -n "$raw" ] || { echo "!!! browser: MIDL produced no server stub"; return 1; }
    cp -f "$raw" "$dir/SERVER/bowser_s.mdl"
    { printf '#include "precomp.h"\n#pragma hdrstop\n'; cat "$raw"; } > "$dir/SERVER/bowser_s.c"
    touch "$dir/SERVER/bowser_s.c"
}
build_browser_client() { build_browser_idl || return 1; run_nmake "$NET/SVCDLLS/BROWSER/CLIENT" "BROWSER/CLIENT - bowser.lib (RPC client stub)"; }
# Break the xactsrv<->browser circular import: compile both, then generate
# both import libs from their .def files, then link both DLLs.
build_xactsrv_browser() {
    build_dosprint       || return 1
    build_rxcommon       || return 1
    build_rxapi          || return 1
    build_netrap         || return 1
    build_brcommon       || return 1
    build_browser_idl    || return 1
    build_browser_client || return 1
    build_srvsvc_lib     || return 1
    # browser links public\sdk\lib\srvsvc.lib, but the srvsvc SERVER that
    # publishes that import lib is built AFTER this browser pass (the
    # xactsrv<->browser<->srvsvc circular build). On a fresh tree that file
    # doesn't exist yet, so stage the CLIENT stub there to satisfy the link.
    # Skip when an import lib is already present (full-build second pass) so we
    # don't clobber the real one.
    if [ ! -f "$NT_ROOT/PUBLIC/SDK/LIB/I386/srvsvc.lib" ]; then
        cp -f "$NET/SVCDLLS/SRVSVC/CLIENT/obj/i386/srvsvc.lib" \
              "$NT_ROOT/PUBLIC/SDK/LIB/I386/srvsvc.lib" || return 1
    fi

    local xdir="$NET/XACTSRV"
    local bdir="$NET/SVCDLLS/BROWSER/SERVER"
    local xobj="$xdir/obj/i386/*.obj"
    local bobj="$bdir/obj/i386/*.obj"
    # Compile-only passes so the obj files exist (links fail — no import libs yet).
    if ! compgen -G "$xobj" > /dev/null; then _nmake_only_compile "$xdir" "XACTSRV compile-only (pre-imports)"; fi
    if ! compgen -G "$bobj" > /dev/null; then _nmake_only_compile "$bdir" "BROWSER compile-only (pre-imports)"; fi
    _lib_from_def xactsrv.lib "$xdir/XACTSRV.DEF"       "$xobj" || return 1
    _lib_from_def browser.lib "$bdir/BROWSER.DEF"       "$bobj" || return 1
    # Now both import libs exist; link the DLLs.
    run_nmake "$xdir" "NET/XACTSRV - downlevel transaction server (xactsrv.dll)" makedll=1 || return 1
    run_nmake "$bdir" "BROWSER - Computer Browser service (browser.dll)" makedll=1
}
build_browser() { build_xactsrv_browser; }

# net.exe — the `net` command (net use / net view / ...). Built from the
# NETCMD tree: common.lib (shared helpers) + netlib.lib feed the NETUSE
# component whose UMAPPL=net produces net.exe. The netcmd/netlib tree pulls
# the DosPrint API headers (dosprint.h/rxprint.h/xsdef16.h) via the shared
# port header (NETCMD/INC/port1632.h); those were absent from the NT leaks
# and restored from the OpenNT tree into PRIVATE/INC.
build_netlib() {
    run_nmake "$NET/NETLIB" "NET/NETLIB - net helper lib (netlib.lib)" || return 1
    # SOURCES TARGETNAME is 'NetLib' → NetLib.lib, but consumers (NET/RAP,
    # NETCMD/NETUSE) link 'netlib.lib'. Alias the lowercase name so the link
    # resolves on case-sensitive Linux. On case-insensitive macOS the two names
    # are already the same file (-ef), so skip the copy there.
    local lib="$NT_ROOT/PUBLIC/SDK/LIB/I386"
    if [ -f "$lib/NetLib.lib" ] && ! [ "$lib/NetLib.lib" -ef "$lib/netlib.lib" ]; then
        cp -f "$lib/NetLib.lib" "$lib/netlib.lib"
    fi
}
build_netcmd_common(){ run_nmake "$NET/NETCMD/COMMON" "NETCMD/COMMON - net command shared lib (common.lib)"; }
build_net() {
    build_netlib       || return 1
    build_netcmd_common || return 1
    KEEP_UMAPPL=1 run_nmake "$NET/NETCMD/NETUSE" "NETCMD/NETUSE - net.exe" makedll=1
}

# --- RPC stack ---------------------------------------------------------------
# NT 3.5's RPC runtime is 180k LoC across NDRLIB + NDR20 + RUNTIME.
# Builds in dependency order: NDRLIB (NDR marshaling primitives, the
# smallest piece) → NDR20 (NDR 2.0 client/server stub support) →
# RUNTIME (full rpcrt4.dll with transports + endpoint mapper).
#
# rpcndrp.lib is the "ndr private" lib linked into rpcrt4.dll itself.
build_rpcndrp() { run_nmake "$NT_ROOT/PRIVATE/RPC/NDRLIB" "RPC/NDRLIB - NDR marshaling primitives"; }
build_rpcndr()  { run_nmake "$NT_ROOT/PRIVATE/RPC/NDRMEM" "RPC/NDRMEM - NDR 1.0 stub helpers (rpcndr.lib)"; }
build_rpcndr20(){ run_nmake "$NT_ROOT/PRIVATE/RPC/NDR20"  "RPC/NDR20 - NDR 2.0 client/server support"; }
build_rpcrt4_idls() {
    # Run our home-bootstrapped midl on the RTIFS interfaces. Generates
    # {nbase,conv,epmp,mgmt}.h + _c.c + _s.c. Order matters: conv/epmp/mgmt
    # are processed first while nbase.h does not yet exist in the RTIFS dir,
    # so midl falls back to ../mtrt/nbase.h (the hand-written, properly-
    # guarded one). nbase.idl is processed last to emit its own nbase.h.
    local rtifs="$NT_ROOT/PRIVATE/RPC/RUNTIME/RTIFS"
    echo ">>> RPC/RTIFS midl: generating conv/epmp/mgmt/nbase stubs"
    rm -f "$rtifs"/nbase.h "$rtifs"/{conv,epmp,mgmt}.h "$rtifs"/{conv,epmp,mgmt}_{c,s}.c
    for idl in conv epmp mgmt nbase; do
        run_wibo_tool "$rtifs" midl /ms_ext /c_ext /app_config /D MIDL_PASS /I ..\\mtrt "$idl.idl" \
            || { echo "!!! RPC/RTIFS midl gen failed ($idl)"; return 1; }
    done
    # Drop generated headers + stubs into MTRT (where SOURCES expects them).
    # MTRT keeps its hand-written NBASE.H (has guards midl's doesn't), so we
    # don't copy nbase.h.
    local mtrt="$NT_ROOT/PRIVATE/RPC/RUNTIME/MTRT"
    cp -f "$rtifs"/{conv,epmp,mgmt}.h "$mtrt/"
    cp -f "$rtifs"/{conv,mgmt,epmp}_c.c "$mtrt/"
    cp -f "$rtifs"/{conv,mgmt}_s.c "$mtrt/"
    echo ">>> RPC/RTIFS midl: OK (stubs copied into MTRT)"
}
build_rpcrt4()  {
    build_rpcrt4_idls || return 1
    run_nmake "$NT_ROOT/PRIVATE/RPC/RUNTIME/MTRT" "RPC/RUNTIME/MTRT - rpcrt4.dll (main RPC runtime)" makedll=1
}
build_rpclts1() { run_nmake "$NT_ROOT/PRIVATE/RPC/RUNTIME/TRANS/WIN32/SVRNP" "RPC transport - rpclts1.dll (named pipe server)" makedll=1; }
build_rpcltc1() { run_nmake "$NT_ROOT/PRIVATE/RPC/RUNTIME/TRANS/WIN32/CLNTNP" "RPC transport - rpcltc1.dll (named pipe client)" makedll=1; }

# --- advapi32 stack ----------------------------------------------------------
# advapi32.dll is a façade over four subsystems:
#   - LSA (lsacomm, lsaudll, sys003)
#   - EventLog (elfapi)
#   - SCM (sclib, svcctrl)
#   - Registry (winreg, wrlib, perflib, localreg)
# Built bottom-up: each piece is a static .lib that advapi32 then aggregates.
# Shared MIDL invocation for advapi32-stack interfaces. /D _M_IX86 /D _X86_
# is needed so winnt.h's CONTEXT block becomes visible during midl pass
# (same MIDL_PASS gate as MTRT/RTIFS).
_midl_advapi_idl() {
    local dir="$1"; shift
    local extra_inc="${1:-}"; shift
    local extra_inc_args=()
    # extra_inc may look like "/I inc" — split it into separate tokens.
    if [ -n "$extra_inc" ]; then read -ra extra_inc_args <<<"$extra_inc"; fi
    for idl in "$@"; do
        run_wibo_tool "$dir" midl /ms_ext /c_ext /app_config /D MIDL_PASS /D _M_IX86 /D _X86_ \
            "${extra_inc_args[@]}" "$idl.idl" || return 1
    done
}
build_winreg_idl(){
    # -oldnames so MIDL generates winreg_ServerIfHandle (not winreg_v1_0_s_ifspec)
    # which is what WINREG/SERVER/INIT.C references.
    local dir="$NT_ROOT/PRIVATE/WINDOWS/SCREG/WINREG"
    run_wibo_tool "$dir" midl /ms_ext /c_ext /app_config /D MIDL_PASS /D _M_IX86 /D _X86_ \
        -oldnames regrpc.idl || return 1
}
build_wrlib()    { build_winreg_idl || return 1; run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SCREG/WINREG/LIB"  "WINREG/LIB - wrlib.lib"; }
build_perflib()  { run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SCREG/WINREG/PERFLIB" "WINREG/PERFLIB - perflib.lib"; }
build_localreg() { build_winreg_idl || return 1; run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SCREG/WINREG/LOCAL"    "WINREG/LOCAL - localreg.lib"; }
build_winreg()   { build_winreg_idl || return 1; run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SCREG/WINREG/CLIENT"   "WINREG/CLIENT - winreg.lib"; }
build_winregsrv(){ build_winreg_idl || return 1; run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SCREG/WINREG/SERVER"   "WINREG/SERVER - winreg.lib (server)"; }
build_sc_idl()   {
    # -oldnames so MIDL emits svcctl_ServerIfHandle (not svcctl_v1_0_s_ifspec),
    # which SC/SERVER/svcctrl.c references. The client doesn't name the ifspec.
    local dir="$NT_ROOT/PRIVATE/WINDOWS/SCREG/SC"
    run_wibo_tool "$dir" midl /ms_ext /c_ext /app_config /D MIDL_PASS /D _M_IX86 /D _X86_ \
        -oldnames /I inc svcctl.idl || return 1
    # sclib + svcctrl #include <svcctl.h>; their INCLUDES point at SC/INC but
    # midl emits into SC/ — copy the header over.
    cp -f "$NT_ROOT/PRIVATE/WINDOWS/SCREG/SC/svcctl.h" "$NT_ROOT/PRIVATE/WINDOWS/SCREG/SC/INC/"
    # The SCM server (SC/SERVER/DAYTONA) compiles ..\svcctl_s.c — i.e.
    # SC/SERVER/svcctl_s.c — so drop the generated server stub there too
    # (MAKEFIL0 did this via `copy svcctl_s.c .\server`).
    cp -f "$NT_ROOT/PRIVATE/WINDOWS/SCREG/SC/svcctl_s.c" "$NT_ROOT/PRIVATE/WINDOWS/SCREG/SC/SERVER/"
}
build_sclib()    { build_sc_idl || return 1; run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SCREG/SC/LIB"    "SC/LIB - sclib.lib"; }
build_svcctrl()  { build_sc_idl || return 1; run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SCREG/SC/CLIENT" "SC/CLIENT - svcctrl.lib"; }
# Service Control Manager *server* — services.exe. Hosts service DLLs
# (wkssvc, etc.) and starts drivers per the registry. winlogon execs it
# during system startup. svcslib is its shared helper; the SERVER/DAYTONA
# SOURCES is a LIBRARY+UMAPPL (svcctrl.lib + services.exe), same pattern as
# lsass, so KEEP_UMAPPL=1.
build_svcslib()  { run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SCREG/SC/SVCSLIB" "SC/SVCSLIB - svcslib.lib"; }
build_scserver() {
    build_sc_idl     || return 1
    build_sclib      || return 1
    build_svcslib    || return 1
    build_winregsrv  || return 1
    build_wrlib      || return 1
    build_rpcutil    || return 1
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SCREG/SC/SERVER/DAYTONA" "SC/SERVER - services.exe (SCM)" makedll=1
}
build_elf_idl()  { _midl_advapi_idl "$NT_ROOT/PRIVATE/EVENTLOG" "" elf; }
build_elfapi()   { build_elf_idl || return 1; run_nmake "$NT_ROOT/PRIVATE/EVENTLOG/ELFCLNT" "EVENTLOG/ELFCLNT - elfapi.lib"; }
build_lsa_idl()  {
    # lsarpc.idl imports lsaimp.idl, which #include's <lsaimp.h> — the
    # shipped header in PRIVATE/INC that pulls in the full NT SDK for
    # its typedefs. Those SDK headers contain C function prototypes with
    # PVOID/HANDLE params; stock MIDL 2.00.71 rejected them, but our
    # patched MIDL silently skips the NON_RPC_PARAM_VOID check when the
    # proc came from an imported file (FRONT/SEMANTIC.CXX). So we can
    # just drive MIDL the way LSA/MAKEFIL0 intended — separate client
    # and server passes with their own ACFs.
    local dir="$NT_ROOT/PRIVATE/LSA"
    local flags=(/D MIDL_PASS /D _M_IX86 /D _X86_ /D _WCHAR_T_DEFINED
        -mode c_port -oldnames -error allocation -error ref /I inc /I ..\\inc)
    run_wibo_tool "$dir" midl "${flags[@]}" -acf lsacli.acf -header lsarpc_c.h lsarpc.idl || return 1
    run_wibo_tool "$dir" midl "${flags[@]}" -acf lsasrv.acf -header lsarpc.h   lsarpc.idl || return 1
    # lsarpc_c.h is consumed by UCLIENT + SERVER via #include "lsarpc_c.h"
    # (LSA/INC is on their /I ..\inc path). lsarpc.h (server header) is
    # pulled via <lsarpc.h> from NEWSAM and other components that talk
    # to the LSA server interface, so drop both into PRIVATE/INC too.
    cp -f "$NT_ROOT/PRIVATE/LSA/lsarpc_c.h" "$NT_ROOT/PRIVATE/LSA/INC/"
    cp -f "$NT_ROOT/PRIVATE/LSA/lsarpc.h"   "$NT_ROOT/PRIVATE/INC/"
}
build_lsacomm()  { build_lsa_idl || return 1; run_nmake "$NT_ROOT/PRIVATE/LSA/COMMON" "LSA/COMMON - lsacomm.lib"; }
build_lsaudll()  { build_lsa_idl || return 1; run_nmake "$NT_ROOT/PRIVATE/LSA/UCLIENT" "LSA/UCLIENT - lsaudll.lib"; }
build_lsadll()   { run_nmake "$NT_ROOT/PRIVATE/LSA/CLIENT/USER" "LSA/CLIENT/USER - lsadll.lib"; }
# LSA crypto. CRYPT/ENGINE shipped only as .OBJ in the original leak
# (export-controlled); DES/RC4/ECB source restored from the nt35_patches
# tree. CRYPT/DLL is the public wrapper exposed as sys003.lib (alias for
# crypt.lib, per its MAKEFILE.INC).
build_crypt_engine() { run_nmake "$NT_ROOT/PRIVATE/LSA/CRYPT/ENGINE" "LSA/CRYPT/ENGINE - engine.lib (DES/RC4/ECB/MD4)"; }
build_sys003()       { build_crypt_engine || return 1; run_nmake "$NT_ROOT/PRIVATE/LSA/CRYPT/DLL" "LSA/CRYPT/DLL - sys003.lib (crypt wrapper)"; }
build_rpcutil()  { run_nmake "$NT_ROOT/PRIVATE/RPCUTIL" "RPC/RPCUTIL - rpcutil.lib (MIDL user helpers)"; }
build_nlrepl()   {
    build_sam_idl || return 1
    run_nmake "$NT_ROOT/PRIVATE/NLSECUTL" "NLSECUTL - nlrepl.lib (NetLogon helpers)"
}
# SAM (Security Account Manager). Dual MIDL pass per NEWSAM/MAKEFIL0 —
# client + server each with their own ACF. samrpc_c.h / samrpc.h are
# consumed by NLSECUTL, LSA/SERVER, NEWSAM/CLIENT and /SERVER.
build_sam_idl()  {
    local dir="$NT_ROOT/PRIVATE/NEWSAM"
    local flags=(/D MIDL_PASS /D _M_IX86 /D _X86_ /D _WCHAR_T_DEFINED
        -mode c_port -oldnames -error allocation -error ref /I ..\\inc)
    run_wibo_tool "$dir" midl "${flags[@]}" -acf samcli.acf -header samrpc_c.h samrpc.idl || return 1
    run_wibo_tool "$dir" midl "${flags[@]}" -acf samsrv.acf -header samrpc.h   samrpc.idl || return 1
    # Drop samrpc headers into PRIVATE/INC where other components expect them.
    cp -f "$NT_ROOT/PRIVATE/NEWSAM/samrpc_c.h" "$NT_ROOT/PRIVATE/INC/"
    cp -f "$NT_ROOT/PRIVATE/NEWSAM/samrpc.h"   "$NT_ROOT/PRIVATE/INC/"
}
build_samlib()   { build_sam_idl || return 1; run_nmake "$NT_ROOT/PRIVATE/NEWSAM/CLIENT" "NEWSAM/CLIENT - samlib.dll" makedll=1; }
build_samsrv()   {
    build_sam_idl || return 1
    build_lsasrv_imports || return 1  # samsrv links against lsasrv.lib
    run_nmake "$NT_ROOT/PRIVATE/NEWSAM/SERVER" "NEWSAM/SERVER - samsrv.dll" makedll=1
}
# LSA/SERVER builds lsasrv.dll + lsass.exe (UMAPPL=lsass in its SOURCES).
# It links against samsrv.lib and samsrv links against lsasrv.lib — a
# circular DLL dep. Break it by pre-generating the import libs from
# their .def files before either DLL gets linked.
# Build an import lib from a .def file. When given an obj dir that's
# already been populated by a compile pass, lib -def picks up the
# stdcall @N decorations from the obj symbols, producing a proper
# decorated import lib. Without the objs, @N is stripped, which
# breaks cross-DLL references for any stdcall-exported function.
_lib_from_def() {
    local libname="$1"
    local def_path="$2"
    local objs_glob="${3:-}"
    # def_path / objs_glob are host abs paths under NT_ROOT; convert to Z:\<...>.
    local defwin libwin
    defwin="$(path_to_win "$def_path")"
    libwin="${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386\\$libname"
    local obj_args=()
    if [ -n "$objs_glob" ]; then
        # Expand the glob on the host, then translate each to Z:\<...>.
        local f
        for f in $objs_glob; do obj_args+=("$(path_to_win "$f")"); done
    fi
    echo ">>> pre-generating $libname from $(basename "$def_path")${obj_args:+ + objs}"
    run_wibo_tool "$SCRIPT_DIR" lib -nologo -machine:i386 \
        "-def:$defwin" "${obj_args[@]}" "-out:$libwin" \
        || { echo "!!! lib -def on $def_path failed"; return 1; }
}
# The samsrv<->lsasrv circular import is broken by compiling each DLL's
# obj files once (no link), then using `lib -def:X.def obj/*.obj` to
# produce decorated import libs. After that, both DLLs can link.
_nmake_only_compile() {
    # Force nmake to stop at the compile step (before link) by requesting
    # the obj dir as the target. Easiest way: run normal nmake but accept
    # link failure. The obj files are what we care about.
    run_nmake "$1" "$2" 2>&1 | tail -3 || true
}
build_lsasrv_imports() {
    # Force compile-only pass on both DLLs so the obj files exist, then
    # synthesize import libs with proper @N decorations from the objs.
    local sam_obj="$NT_ROOT/PRIVATE/NEWSAM/SERVER/obj/i386/*.obj"
    local lsa_obj="$NT_ROOT/PRIVATE/LSA/SERVER/obj/i386/*.obj"
    if ! compgen -G "$sam_obj" > /dev/null; then
        _nmake_only_compile "$NT_ROOT/PRIVATE/NEWSAM/SERVER" "NEWSAM/SERVER compile-only (pre-imports)"
    fi
    if ! compgen -G "$lsa_obj" > /dev/null; then
        _nmake_only_compile "$NT_ROOT/PRIVATE/LSA/SERVER" "LSA/SERVER compile-only (pre-imports)"
    fi
    _lib_from_def lsasrv.lib "$NT_ROOT/PRIVATE/LSA/SERVER/LSASRV.DEF"    "$lsa_obj" || return 1
    _lib_from_def samsrv.lib "$NT_ROOT/PRIVATE/NEWSAM/SERVER/SAMSRV.DEF" "$sam_obj" || return 1
}
build_lsasrv() {
    build_lsa_idl || return 1
    build_sam_idl || return 1
    # Break the samsrv<->lsasrv circular import by generating both .lib
    # import stubs from .def first.
    build_lsasrv_imports || return 1
    # KEEP_UMAPPL=1 preserves UMAPPL=lsass so the same SOURCES produces
    # both lsasrv.dll (DYNLINK) and lsass.exe (native UMAPPL using
    # lsasrv.dll's entry).
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/LSA/SERVER" "LSA/SERVER - lsasrv.dll + lsass.exe" makedll=1
}
build_msv1_0() { run_nmake "$NT_ROOT/PRIVATE/LSA/MSV1_0" "MSV1_0 - NT LAN Manager auth package" makedll=1; }
build_advapi32() { build_rpcutil || return 1; run_nmake "$NT_ROOT/PRIVATE/WINDOWS/BASE/ADVAPI" "advapi32.dll" makedll=1; }

# --- Winsock / TCP-IP userland (PRIVATE/NET/SOCKETS) --------------------------
# wsock32.dll — the Win32 sockets DLL, layered on afd.sys. Three helper libs
# build first: libuemul (BSD compat: getopt/getpass/nls), sockreg (winsock
# registry helpers), sockutil (gethostbyname/rcmd/rexec). libuemul and winsock
# each ship a message catalog that mc.exe compiles into a .h/.rc before the C
# sources build — same pre-pass pattern as _ensure_bugcodes.
NET="$NT_ROOT/PRIVATE/NET"
# Run mc on <dir>/<MCFILE>, then normalise the emitted <stem>.h/.rc to
# lowercase so #include "stem.h" resolves on a case-sensitive FS (Linux).
# On macOS the copies are no-ops (same file).
_mc_gen() {
    local dir="$1" mcfile="$2" stem="$3"
    run_wibo_tool "$dir" mc -v "$mcfile" \
        || { echo "!!! mc on $mcfile failed"; return 1; }
    [ -f "$dir/$stem.h" ]  || { [ -f "$dir/${stem^^}.h" ]  && cp -f "$dir/${stem^^}.h"  "$dir/$stem.h"; }
    [ -f "$dir/$stem.rc" ] || { [ -f "$dir/${stem^^}.rc" ] && cp -f "$dir/${stem^^}.rc" "$dir/$stem.rc"; }
    return 0
}
build_libuemul() {
    local dir="$NET/SOCKETS/LIBUEMUL"
    if [ ! -f "$dir/libuemul.h" ] || [ "$dir/LIBUEMUL.MC" -nt "$dir/libuemul.h" ]; then
        echo ">>> mc LIBUEMUL.MC -> libuemul.h/.rc"
        _mc_gen "$dir" LIBUEMUL.MC libuemul || return 1
    fi
    run_nmake "$dir" "NET/LIBUEMUL - BSD compat lib (libuemul.lib)"
}
build_sockreg()  { run_nmake "$NET/SOCKETS/SOCKREG"  "NET/SOCKREG - winsock registry helper (sockreg.lib)"; }
build_sockutil() { run_nmake "$NET/SOCKETS/SOCKUTIL" "NET/SOCKUTIL - winsock util lib (sockutil.lib)"; }
# wsock32's catalog is libuemul.mc + localmsg.mc concatenated into nlstxt.mc,
# then compiled by mc (per WINSOCK/MAKEFILE.INC).
_ensure_winsock_nlstxt() {
    local dir="$NET/SOCKETS/WINSOCK"
    if [ -f "$dir/nlstxt.h" ] && [ "$dir/nlstxt.h" -nt "$dir/LOCALMSG.MC" ] \
       && [ "$dir/nlstxt.h" -nt "$NET/SOCKETS/LIBUEMUL/LIBUEMUL.MC" ]; then
        return 0
    fi
    echo ">>> winsock: concat libuemul.mc + localmsg.mc -> nlstxt.mc; mc"
    cat "$NET/SOCKETS/LIBUEMUL/LIBUEMUL.MC" "$dir/LOCALMSG.MC" > "$dir/nlstxt.mc"
    _mc_gen "$dir" nlstxt.mc nlstxt
}
build_wsock32() {
    build_libuemul || return 1
    build_sockreg  || return 1
    build_sockutil || return 1
    _ensure_winsock_nlstxt || return 1
    run_nmake "$NET/SOCKETS/WINSOCK" "NET/WINSOCK - wsock32.dll" makedll=1
}
# wshtcpip.dll — the TCP/IP Winsock helper. wsock32 LoadLibrary()'s it at
# socket() time to map AF_INET triples to \Device\Tcp / \Device\Udp. The NT
# 3.5 tree shipped it only as a prebuilt lib, so this is a minimal source
# reimplementation (see WSHTCPIP/wshtcpip.c). Links wsock32.lib, so build
# wsock32 first.
build_wshtcpip() {
    build_wsock32 || return 1
    run_nmake "$NET/SOCKETS/WSHTCPIP" "NET/WSHTCPIP - wshtcpip.dll (TCP/IP Winsock helper)" makedll=1
}
# icmp.dll — the ICMP Echo API (IcmpCreateFile/IcmpSendEcho). Leak-absent
# (shipped as a binary), so this is a reimplementation that drives the IP
# driver's IOCTL_ICMP_ECHO_REQUEST on \Device\Ip. ping.exe links its import.
build_icmp() { run_nmake "$NET/SOCKETS/ICMP" "NET/ICMP - icmp.dll (ICMP Echo API)" makedll=1; }
# ping.exe — the classic ICMP echo tool. Links icmp.lib (echo API) + wsock32
# (name resolution). Console UMAPPL, so KEEP_UMAPPL=1.
build_ping() {
    build_icmp    || return 1
    build_wsock32 || return 1
    KEEP_UMAPPL=1 run_nmake "$NET/SOCKETS/PING" "NET/PING - ping.exe" makedll=1
}
# tracert.exe — traceroute. Same icmp.lib + wsock32 deps as ping; walks the
# path by sending echoes with an increasing IP TTL.
build_tracert() {
    build_icmp    || return 1
    build_wsock32 || return 1
    KEEP_UMAPPL=1 run_nmake "$NET/SOCKETS/TRACERT" "NET/TRACERT - tracert.exe" makedll=1
}

# dhcpcsvc.dll — the DHCP client service. Hosted by services.exe (SCM), it does
# the DISCOVER/OFFER/REQUEST/ACK exchange over UDP (wsock32, :68->:67) and
# writes the leased address into the running stack via IOCTL_IP_SET_ADDRESS on
# \Device\Ip (+ NetBT/redirector notifications). Two static libs build first:
# dhcplib (packet build/parse/dump helpers) and dhcpcli2 (the lease state
# machine). A mc pre-pass turns DHCPMSG.MC into CLIENT/INC/dhcpmsg.h (event
# message ids, included by dhcpcli2) + NEWNT/dhcpmsg.rc (pulled by dhcp.rc).
# DHCPDIR (not DHCP — that name is the DHCP=1 disk-assembly env toggle).
DHCPDIR="$NET/SOCKETS/TCPCMD/DHCP"
build_dhcplib()  { run_nmake "$DHCPDIR/LIB"         "NET/DHCP/LIB - dhcplib.lib"; }
# dhcpcli2's SOURCES writes its lib to ..\..\..\obj (TCPCMD/obj), which the
# dhcpcsvc link then reads — create it so the lib step doesn't silently fail.
build_dhcpcli2() { mkdir -p "$NET/SOCKETS/TCPCMD/obj/i386"; run_nmake "$DHCPDIR/CLIENT/DHCP" "NET/DHCP/CLIENT - dhcpcli2.lib (lease state machine)"; }
_ensure_dhcpmsg() {
    local dir="$DHCPDIR/CLIENT/NEWNT" hdr="$DHCPDIR/CLIENT/INC/dhcpmsg.h"
    if [ -f "$hdr" ] && [ "$hdr" -nt "$dir/DHCPMSG.MC" ]; then
        return 0
    fi
    echo ">>> mc DHCPMSG.MC -> CLIENT/INC/dhcpmsg.h + NEWNT/dhcpmsg.rc"
    run_wibo_tool "$dir" mc -d -r ".\\" -h "..\\inc" DHCPMSG.MC \
        || { echo "!!! mc on DHCPMSG.MC failed"; return 1; }
    # Lowercase-normalise for a case-sensitive FS (no-op on macOS).
    [ -f "$hdr" ]            || { [ -f "$DHCPDIR/CLIENT/INC/DHCPMSG.H" ] && cp -f "$DHCPDIR/CLIENT/INC/DHCPMSG.H" "$hdr"; }
    [ -f "$dir/dhcpmsg.rc" ] || { [ -f "$dir/DHCPMSG.RC" ]           && cp -f "$dir/DHCPMSG.RC" "$dir/dhcpmsg.rc"; }
    return 0
}
build_dhcpcsvc() {
    build_wsock32   || return 1
    _ensure_dhcpmsg || return 1
    build_dhcplib   || return 1
    build_dhcpcli2  || return 1
    run_nmake "$DHCPDIR/CLIENT/NEWNT" "NET/DHCP - DHCP client service (dhcpcsvc.dll)" makedll=1
}

# --- TCP/IP command-line utilities (NTOS/TDI/TCPIP/UTILS) --------------------
# arp.exe / route.exe query and manage the kernel TCP/IP stack directly via
# TDI IOCTLs (not Winsock). Both link tcpinfo.lib, a shared helper that talks
# to \Device\Tcp. These are UMAPPL console apps, so KEEP_UMAPPL=1.
TCPUTILS="$NTOS/TDI/TCPIP/UTILS"
build_tcpinfo_lib() { mkdir -p "$TCPUTILS/obj/i386"; run_nmake "$TCPUTILS/TCPINFO" "TCPIP/UTILS/TCPINFO - tcpinfo.lib (TDI query helper)"; }
build_arp()   { build_tcpinfo_lib || return 1; KEEP_UMAPPL=1 run_nmake "$TCPUTILS/ARP/ARP" "TCPIP/UTILS/ARP - arp.exe"; }
build_route() { build_tcpinfo_lib || return 1; KEEP_UMAPPL=1 run_nmake "$TCPUTILS/IP/ROUTE" "TCPIP/UTILS/ROUTE - route.exe"; }

# --- Host tools (sdktools bootstrap phase) -----------------------------------
# These are wine-executable host tools consumed by later build steps — not
# targets shipped in the disk image. They land in PUBLIC/OAK/BIN/I386 so
# nmake rules can invoke them by bare name, same pattern as gensrv.
#
# MIDL bootstrap chain (for generating RPC stubs from IDL):
#   midleb    — error-recovery DB generator (MIDLNEW/EREC)
#   midlyacc  — custom yacc (MIDLNEW/YACC, bootstraps via shipped YACCP.EXE)
#   midlpg    — parser post-generator (MIDLNEW/PG)
#   midl      — the MIDL compiler itself (MIDL20/FRONT, links support+expr+
#               analysis+codegen libs). Invoked on RUNTIME/RTIFS/*.idl to
#               generate conv.h / epmp.h / mgmt.h / nbase.h.
install_host_tool() {
    local built="$1"
    local name="$2"
    if [ -f "$built" ]; then
        cp "$built" "$NT_ROOT/PUBLIC/OAK/BIN/I386/$name"
        # Ensure wibo-tools has a symlink — the tool may not have existed
        # when wibo-tools was first provisioned (e.g. MC.EXE, midl, gensrv
        # are built from source and only appear after their build step).
        # Relative target (../NT/...) since `ln -r` is GNU-only (no macOS).
        ln -sf "../NT/PUBLIC/OAK/BIN/I386/$name" "$WIBO_TOOLS/$name"
        echo ">>> installed $name"
    else
        echo "!!! $name: expected output $built not found" >&2
        return 1
    fi
}
build_midleb() {
    run_nmake "$NT_ROOT/PRIVATE/RPC/MIDLNEW/EREC" "MIDL/EREC - error-recovery DB generator (midleb.exe)"
    install_host_tool "$NT_ROOT/PRIVATE/RPC/MIDLNEW/EREC/obj/i386/midleb.exe" "midleb.exe"
}
# LINK (linker). Rebuilt from source to:
#   - Compile with -DNDEBUG (bufio.c:2134 assert compiles out)
#   - Include errmsg.i STRINGTABLE resources via UMRES= (error messages)
# Dependencies: PDB/DBI, CVTOMF, DISASM, DISASM68.
build_link() {
    local link_dir="$NT_ROOT/PRIVATE/SDKTOOLS/VCTOOLS/LINK"
    local pdb_dir="$NT_ROOT/PRIVATE/SDKTOOLS/VCTOOLS/PDB"
    echo "========================================"
    echo "Building: LINK.EXE (patched for wibo)"
    echo "========================================"
    run_nmake "$pdb_dir/DBI"        "pdb/dbi.lib"           || return 1
    run_nmake "$link_dir/CVTOMF"    "link/cvtomf.lib"       || return 1
    run_nmake "$link_dir/DISASM"    "link/disasm.lib"       || return 1
    run_nmake "$link_dir/DISASM68"  "link/disasm68.lib"     || return 1
    run_nmake "$link_dir/COFF"      "link/coff (link.exe)"  || return 1
    install_host_tool "$link_dir/COFF/obj/i386/link.exe" "LINK.EXE"
    # install_host_tool already refreshed the wibo-tools/LINK.EXE symlink.
    echo ">>> LINK.EXE rebuilt with error message resources"
}

# --- Debug toolchain: CV4 -> DWARF host tools --------------------------------
# Ported from main-lua. imagehlp.dll exposes splitsym (CV -> .DBG sidecar
# extractor) + MapDebugInformation (consumed by dbg2dwf); dbg2dwf converts
# the .DBG sidecar to a DWARF-2 ELF gdb loads via add-symbol-file. cvpack
# consolidates CodeView post-link (mkmsg builds its message resources);
# cvdump inspects raw CV4 records. All host EXEs installed into wibo-tools.
build_mkmsg() {
    local dir="$NT_ROOT/PRIVATE/SDKTOOLS/VCTOOLS/MSG"
    run_nmake "$dir" "MKMSG - message-resource compiler" || return 1
    install_host_tool "$dir/obj/i386/mkmsg.exe" "MKMSG.EXE"
}
build_imagehlp() {
    # IMAGEHLP/MAKEFILE.INC pulls rtl_user's imagedir.obj — build it first.
    build_rtl_user || return 1
    local dir="$NT_ROOT/PRIVATE/SDKTOOLS/IMAGEHLP"
    KEEP_UMAPPL=1 run_nmake "$dir" "IMAGEHLP - imagehlp.dll + splitsym + binplace" makedll=1 || return 1
    install_host_tool "$NT_ROOT/PUBLIC/SDK/LIB/I386/imagehlp.dll" "IMAGEHLP.DLL" || return 1
    install_host_tool "$dir/obj/i386/splitsym.exe" "SPLITSYM.EXE" || return 1
    install_host_tool "$dir/obj/i386/binplace.exe" "BINPLACE.EXE"
}
build_cvpack() {
    build_mkmsg || return 1
    run_nmake "$NT_ROOT/PRIVATE/SDKTOOLS/VCTOOLS/PDB/DBI" "pdb/dbi.lib" || return 1
    local dir="$NT_ROOT/PRIVATE/SDKTOOLS/VCTOOLS/CVPACK"
    run_nmake "$dir" "CVPACK - CodeView packer" || return 1
    install_host_tool "$dir/obj/i386/cvpack.exe" "CVPACK.EXE" || return 1
    install_host_tool "$dir/obj/i386/cvpack.err" "cvpack.err"
}
build_cvdump() {
    build_imagehlp || return 1
    local dir="$NT_ROOT/PRIVATE/SDKTOOLS/VCTOOLS/CVDUMP"
    run_nmake "$dir" "CVDUMP - CodeView inspector" || return 1
    install_host_tool "$dir/obj/i386/cvdump.exe" "CVDUMP.EXE"
}
build_dbg2dwf() {
    build_imagehlp || return 1
    local dir="$NT_ROOT/PRIVATE/SDKTOOLS/VCTOOLS/DBG2DWF"
    run_nmake "$dir" "DBG2DWF - .DBG to DWARF ELF" || return 1
    install_host_tool "$dir/obj/i386/dbg2dwf.exe" "DBG2DWF.EXE"
}
# Whole debug host-tool set. imagehlp built once up front; the leaf tools
# re-check it (nmake no-ops when current).
build_debugtools() {
    build_imagehlp || return $?
    build_dbg2dwf  || return $?
    build_cvdump   || return $?
    build_cvpack   || return $?
}

# --syms guard: /Z7 objs and non-/Z7 objs can't be linked together, so a
# mode toggle must start from clean obj trees. Stamp the last mode and wipe
# every component obj/i386 when it changes.
_syms_guard() {
    local stamp; stamp="$(dirname "$SCRIPT_DIR")/build/.syms-mode"
    local prev="0"; [ -f "$stamp" ] && prev="$(cat "$stamp")"
    if [ "$prev" != "$SYMS" ]; then
        echo ">>> --syms toggled ($prev -> $SYMS); wiping NTOS obj/i386 trees"
        find "$NTOS" -type d -path '*/obj/i386' -prune -exec rm -rf {} + 2>/dev/null
        mkdir -p "$(dirname "$stamp")"; echo "$SYMS" > "$stamp"
    fi
}

# splitsym a PE into <name>.DBG, then dbg2dwf into <name>.dwf gdb sidecar.
# Skips up-to-date outputs and PEs with no CV debug directory.
_dwf_one() {
    local img="$1"; [ -f "$img" ] || return 0
    local stem="${img%.*}" dbg="${img%.*}.DBG" dwf="${img%.*}.dwf"
    [ -f "$dwf" ] && [ "$dwf" -nt "$img" ] && return 0
    run_wibo_tool "$WIBO_TOOLS" SPLITSYM.EXE -a "$(path_to_win "$img")" >/dev/null 2>&1 || true
    if [ ! -f "$dbg" ]; then echo "    skip $(basename "$img"): no CV debug dir"; return 0; fi
    # dbg2dwf rejects retail (coff) .DBGs — expected for any non-CodeView
    # image (e.g. a driver built before --syms), so skip rather than abort.
    if ! run_wibo_tool "$WIBO_TOOLS" DBG2DWF.EXE "$(path_to_win "$dbg")" "$(path_to_win "$dwf")" >/dev/null 2>&1; then
        echo "    skip $(basename "$img"): no CodeView (retail build?)"
        return 0
    fi
    echo ">>> dwf: ${dwf#$NT_ROOT/}"
}
_dwf_sweep_dir() {
    local d="$1"; [ -d "$d" ] || return 0
    local f
    for f in "$d"/*.sys "$d"/*.dll "$d"/*.exe; do [ -f "$f" ] && { _dwf_one "$f" || return 1; }; done
}
# Generate .DBG/.dwf for every built kernel/driver image (post-build pass).
_dwf_generate() {
    echo "========================================"
    echo "Generating .DBG/.dwf gdb sidecars"
    echo "========================================"
    _dwf_sweep_dir "$NT_ROOT/PUBLIC/SDK/LIB/I386" || return 1   # drivers + DLLs land here
    _dwf_one "$NTOS/INIT/UP/obj/i386/ntoskrnl.exe" || return 1  # gdb's primary target
    _dwf_one "$NTOS/NTHALS/HAL/obj/i386/hal.dll"   || return 1
}
# Standalone: build the host tools then emit sidecars for whatever's built.
build_dwf() {
    if [ "$SYMS" != "1" ]; then
        echo "build_dwf: pass --syms (CodeView build) first — nothing to convert."
        return 0
    fi
    build_debugtools || return 1
    _dwf_generate
}

# Attach gdb to a running `boot.sh --gdb` qemu (gdbstub on :1234), with full
# DWARF symbols for the kernel + HAL and the `nt` command helpers loaded.
# Symbols come from a --syms build; .dwf carry absolute VAs so no slide.
build_gdb() {
    local kdwf="$NTOS/INIT/UP/obj/i386/ntoskrnl.dwf"
    local hdwf="$NTOS/NTHALS/HAL/obj/i386/hal.dwf"
    command -v gdb >/dev/null || { echo "ERROR: gdb not in PATH"; return 1; }
    if [ ! -f "$kdwf" ]; then
        echo "ERROR: $kdwf not found — build symbols first:  ./build.sh --syms"
        return 1
    fi
    local addhal=(); [ -f "$hdwf" ] && addhal=(-ex "add-symbol-file $hdwf")
    exec gdb \
        -iex 'set confirm off' -iex 'set pagination off' \
        -ex "symbol-file $kdwf" "${addhal[@]}" \
        -ex "source $SCRIPT_DIR/tools/gdb.init" \
        -ex "source $SCRIPT_DIR/tools/gdb_nt.py" \
        -ex 'target remote :1234'
}

# --- C Runtime (CRT) from source ---------------------------------------------
# Ported from main-lua's build.lua CRT chain. The CRT (BASE/{CRT32,CRT32NT,
# FP32,FP32NT}) builds in flavors (NT/ST/MT/DLL) that SHARE one source tree,
# so each subdir carries a .crt-variant stamp and its obj/ is wiped on a
# flavor change — otherwise the wrong-variant .obj re-archives (e.g.
# _environ_dll vs _environ). CRTLIB then lib-combines the per-flavor outputs
# into the release libs, which replace the prebuilt seeds in PUBLIC/SDK/LIB.
BASE_D="$NT_ROOT/PRIVATE/BASE"

# _crt_variant <root> <variant> <desc> <subdir>...
_crt_variant() {
    local root="$1" variant="$2" desc="$3"; shift 3
    mkdir -p "$root/obj/i386"
    local d sub stamp prev
    for d in "$@"; do
        sub="$root/$d"
        [ -f "$sub/SOURCES" ] || continue
        stamp="$sub/obj/i386/.crt-variant"
        prev=""; [ -f "$stamp" ] && prev="$(cat "$stamp" 2>/dev/null)"
        if [ -n "$prev" ] && [ "$prev" != "$variant" ]; then
            echo ">>> CRT variant change ($prev -> $variant); wiping $d/obj"
            rm -rf "$sub/obj"
        fi
        run_nmake "$sub" "$desc/$d" "CRTLIBTYPE=$variant" "386=1" || return 1
        mkdir -p "$sub/obj/i386"; echo "$variant" > "$stamp"
    done
    # Top-level roll-up: hand-written MAKEFILE (no SOURCES) lib-archives the
    # per-subdir .obj into the flavor's libc<suffix>.lib. Run nmake directly.
    echo "========================================"
    echo "Building: $desc - roll-up"
    echo "========================================"
    run_wibo_tool "$root" NMAKE.EXE /NOLOGO "CRTLIBTYPE=$variant" "386=1"
}

# TYPES — regenerate the composite OLE public headers (objbase.h, ole2.h)
# from BASE/TYPES the way NT's types project does: MIDL the .idl component
# files (wtypes/unknwn/com, ole2x) then concatenate the .X prologue + the
# generated component headers (with their __xxx_h__ guards intact) + the .Y
# epilogue of API prototypes. The embedded-with-guard wtypes block is what
# makes objbase.h self-suppress against the standalone wtypes.h that iface.h
# pulls in — the source of the old duplicate-definition collisions.
_types_midl() {
    # _types_midl <subdir> <import_dirs_win> <idl> [<idl>...]
    local sub="$1" imp="$2"; shift 2
    local inc="${NT_ROOT_WIN}\\PRIVATE\\BASE\\CINC;${NT_ROOT_WIN}\\PUBLIC\\SDK\\INC;${NT_ROOT_WIN}\\PUBLIC\\OAK\\INC"
    [ -n "$imp" ] && inc="$imp;$inc"
    mkdir -p "$sub/gen"
    local idl
    for idl in "$@"; do
        run_wibo_tool "$sub" midl "$idl.idl" -header "gen\\$idl.h" \
            -Zp8 -I"$inc" -Oi -no_warn -char unsigned -error allocation -mode c_port -DMIDL_PASS \
            -cpp_cmd "$(wibo_tool_path cl)" -cpp_opt "-nologo -DMIDL_PASS -I$inc -E -Tc" \
            || { echo "!!! types: midl $idl failed"; return 1; }
    done
}
build_types() {
    echo "========================================"
    echo "Building: TYPES — regenerate objbase.h / ole2.h public headers"
    echo "========================================"
    local TY="$BASE_D/TYPES" inc="$NT_ROOT/PUBLIC/SDK/INC"
    local compobj_win="${NT_ROOT_WIN}\\PRIVATE\\BASE\\TYPES\\COMPOBJ"
    _types_midl "$TY/COMPOBJ" "" wtypes unknwn com || return 1
    _types_midl "$TY/NEW_OLE" "$compobj_win" ole2x   || return 1
    python3 "$SCRIPT_DIR/tools/assemble_ole_header.py" objbase "$TY/COMPOBJ" "$TY/COMPOBJ/gen" "$inc/OBJBASE.H" || return 1
    python3 "$SCRIPT_DIR/tools/assemble_ole_header.py" ole2    "$TY/NEW_OLE" "$TY/NEW_OLE/gen"   "$inc/OLE2.H"    || return 1
    # The standalone wtypes/unknwn/com public headers come from the same MIDL
    # run — keep them in lockstep with what objbase.h embeds. Normalize MIDL's
    # "generated ... at <date>" stamp so regeneration stays byte-deterministic.
    python3 - "$TY/COMPOBJ/gen" "$inc" <<'PY' || return 1
import re, sys
gen, inc = sys.argv[1], sys.argv[2]
ts = re.compile(r'^(\s*\*?\s*at )\w{3} \w{3} .* \d{4}\s*$')
for lo, up in (("wtypes.h","WTYPES.H"),("unknwn.h","UNKNWN.H"),("com.h","COM.H")):
    src = open(f"{gen}/{lo}", encoding="latin-1").read().splitlines()
    open(f"{inc}/{up}","w",encoding="latin-1",newline="").write(   # CRLF to match tree
        "\r\n".join(ts.sub(r'\1<generated>', l) for l in src) + "\r\n")
PY
    # objbase.h/ole2.h feed CAIROLE's precompiled headers (com2int.pch for COM,
    # le2int.pch for OLE232); a stale PCH baked from old headers silently
    # overrides these, so drop them.
    rm -f "$BASE_D/CAIROLE/COM/INC/DAYTONA/obj/i386/com2int.pch" \
          "$BASE_D/CAIROLE/COM/INC/DAYTONA/obj/i386/com2int.obj" \
          "$BASE_D/CAIROLE/OLE232/INC/DAYTONA/obj/i386/le2int.pch" \
          "$BASE_D/CAIROLE/OLE232/INC/DAYTONA/obj/i386/le2int.obj"
    # TYPES "pass 2": build uuid.lib with the IID definitions the CAIROLE DLLs
    # reference. The interface IIDs come from MIDL's self-contained _i.c files
    # (com_i.c, ole2x_i.c); the internal proxy/remoting IIDs (IProxyManager,
    # IInternalMoniker, IOlePresObj, ...) come from OLEPRX32's hand-written
    # cguid_i.c (it #defines INITGUID then includes ole2.h, so it allocates).
    run_wibo_tool "$TY/COMPOBJ"        cl386 -nologo -c -Fogen\\com_i.obj   com_i.c   || return 1
    run_wibo_tool "$TY/NEW_OLE"        cl386 -nologo -c -Fogen\\ole2x_i.obj ole2x_i.c || return 1
    run_wibo_tool "$TY/OLEPRX32/DAYTONA" cl386 -nologo -c -DWIN32=100 -D_X86_=1 -Di386=1 \
        -Focguid_i.obj CGUID_I.C || return 1
    run_wibo_tool "$TY/COMPOBJ" LIB.EXE -nologo -machine:ix86 -out:gen\\uuid.lib \
        gen\\com_i.obj ..\\NEW_OLE\\gen\\ole2x_i.obj ..\\OLEPRX32\\DAYTONA\\cguid_i.obj || return 1
    cp "$TY/COMPOBJ/gen/uuid.lib" "$NT_ROOT/PUBLIC/SDK/LIB/I386/uuid.lib" && echo ">>> installed uuid.lib (interface + internal IIDs)"
    echo ">>> TYPES: OK"
}

# CAIROLE (OLE2/COM) — built incrementally from source under BASE/CAIROLE.
# Each component is a DIRS tree whose leaves (mostly <comp>/<sub>/DAYTONA)
# carry a SOURCES; _cairole_leaves builds every leaf under a component dir.
_cairole_leaves() {
    local root="$BASE_D/CAIROLE/$1"
    local s d
    while IFS= read -r s; do
        d="$(dirname "$s")"
        run_nmake "$d" "CAIROLE/${d#$BASE_D/CAIROLE/}" || return 1
    done < <(find "$root" -name SOURCES | sort)
}
build_cairole_common() { _cairole_leaves COMMON; }
# ILIB builds its own uuid.lib (OLE1/private CLSIDs from uuidole.cxx) to its obj
# dir; ole32 links it there directly. The *standard* interface IIDs come from
# the TYPES uuid.lib in public\sdk\lib (see build_types pass 2).
build_cairole_ilib() { _cairole_leaves ILIB; }
build_cairole_com() {
    # COM/IDL runs MIDL (NTTARGETFILE0=allidl) to generate iface.h and the
    # other interface headers the rest of COM #includes; INC adds more shared
    # headers. Both must precede the alphabetical leaf walk.
    run_nmake "$BASE_D/CAIROLE/COM/IDL/DAYTONA" "CAIROLE/COM/IDL (MIDL headers)" || return 1
    [ -f "$BASE_D/CAIROLE/COM/INC/DAYTONA/SOURCES" ] && \
        { run_nmake "$BASE_D/CAIROLE/COM/INC/DAYTONA" "CAIROLE/COM/INC" || return 1; }
    _cairole_leaves COM
}

# Later CAIROLE components build their shared INC/COMMON leaf first (the rest
# #include its headers / share its precompiled header), then the LIBRARY
# leaves, then the DYNLINK (the component DLL links the sub-libs, so it goes
# last). PROGRAM leaves are tests/tools (DRT, UTEST, STGVIEW, ...) — skipped.
# phase (2nd arg): "libs" builds only INC/COMMON + LIBRARY leaves; "dlls"
# builds only the DYNLINK + PROGRAM leaves; "all" (default) does everything.
# The split lets build_cairole interleave: STG's sub-libs must precede ole32,
# but STG's storag32.dll links ole32 (via the compob32 alias), so it follows.
# makedll (3rd arg, default 1): when 0, DYNLINK leaves stop at the import lib
# (compile-verified) instead of linking the runtime .dll — used for the DLLs
# that don't apply to 32-bit micront (storag32 is redundant with ole32's
# embedded storage; olethk32 is a 16-bit thunk needing ntvdm/VDM).
_cairole_comp() {
    local comp="$1" phase="${2:-all}" makedll="${3:-1}" root="$BASE_D/CAIROLE/$1" pre s d tt
    if [ "$phase" != dlls ]; then
        for pre in INC COMMON; do
            [ -f "$root/$pre/DAYTONA/SOURCES" ] && \
                { run_nmake "$root/$pre/DAYTONA" "CAIROLE/$comp/$pre" || return 1; }
        done
    fi
    local libs=() dlls=() progs=()
    while IFS= read -r s; do
        d="$(dirname "$s")"
        case "$d/" in                                                      # trailing / so a
                                                                           # dir that ENDS in the
                                                                           # name still matches
            "$root"/INC/DAYTONA/|"$root"/COMMON/DAYTONA/) continue ;;      # built above
            */DRT/*|*/UTEST/*|*/UTILS/*|*/TOOLS/*)                          # tests + tools
                echo ">>> skip (test/tool): ${d#$BASE_D/CAIROLE/}"; continue ;;
        esac
        tt="$(grep -ioE 'TARGETTYPE=[[:space:]]*[A-Za-z]+' "$s" | head -1 | tr -d ' \t\r' | cut -d= -f2)"
        case "$tt" in
            [Ll][Ii][Bb][Rr][Aa][Rr][Yy]) libs+=("$d") ;;   # sub-libs first
            [Dd][Yy][Nn][Ll][Ii][Nn][Kk]) dlls+=("$d") ;;   # the component DLL(s)
            *)                             progs+=("$d") ;;  # PROGRAM (scm.exe, ...)
        esac
    done < <(find "$root" -name SOURCES | sort)
    # libs → DLLs (makedll=1 so LINK actually emits the .dll, not just the
    # import lib) → programs (which link the DLLs above).
    if [ "$phase" != dlls ]; then
        for d in "${libs[@]}"; do run_nmake "$d" "CAIROLE/${d#$BASE_D/CAIROLE/}" || return 1; done
    fi
    if [ "$phase" != libs ]; then
        local mk=(); [ "$makedll" = 1 ] && mk=(makedll=1)
        for d in "${dlls[@]}";  do run_nmake "$d" "CAIROLE/${d#$BASE_D/CAIROLE/}" "${mk[@]}" || return 1; done
        for d in "${progs[@]}"; do run_nmake "$d" "CAIROLE/${d#$BASE_D/CAIROLE/}"            || return 1; done
    fi
}
build_cairole_ole232()   { _cairole_comp OLE232; }
build_cairole_stg()      { _cairole_comp STG; }
build_cairole_dll()      { _cairole_comp DLL; }
build_cairole_scm()      { _cairole_comp SCM; }
build_cairole_olecnv32() { _cairole_comp OLECNV32; }
# olethk32 is the 16-bit OLE thunk; its .dll link needs ntvdm.lib (VDM), absent
# in 32-bit micront — build the objects + import lib only.
build_cairole_olethunk() { _cairole_comp OLETHUNK all 0; }

# oleprx32.dll — the OLE interface marshaling proxy/stub DLL (TYPES OLEPRX32).
# Built directly (the TYPES makefile.inc isn't wibo-friendly): the MIDL proxy
# files com_p.c/ole2x_p.c (from build_types) + call_as.c + dlldata.c +
# transmit.cxx, linked against ole32/uuid/gdi32p/rpcrt4/crtdll. dlldata.c wires
# only the com + ole2x proxies (OLEAUTO_PROXYTYPES is empty upstream). Needs
# ole32.lib (cairole) and gdi32p.lib (gui GDI), so it follows both.
build_cairole_oleprx32() {
    local prx="$BASE_D/TYPES/OLEPRX32/DAYTONA" o="obj\\i386"
    local com_p="$BASE_D/TYPES/COMPOBJ/com_p.c" ole2x_p="$BASE_D/TYPES/NEW_OLE/ole2x_p.c"
    [ -f "$com_p" ] && [ -f "$ole2x_p" ] || { echo "!!! oleprx32: proxy _p.c missing — run build_types"; return 1; }
    [ -f "$NT_ROOT/PUBLIC/SDK/LIB/I386/gdi32p.lib" ] || { echo "!!! oleprx32: gdi32p.lib missing — build the gui GDI first"; return 1; }
    echo "========================================"
    echo "Building: CAIROLE/OLEPRX32 - oleprx32.dll (OLE marshaling proxy)"
    echo "========================================"
    mkdir -p "$prx/obj/i386"
    cp "$com_p" "$prx/com_p.c"; cp "$ole2x_p" "$prx/ole2x_p.c"
    # Minimal link def in obj/ (NOT the tracked OLEPRX32.DEF, which is the same
    # file on a case-insensitive FS). These two exports are what a proxy DLL
    # needs — the SCM calls DllGetClassObject to fetch the PSFactory.
    printf 'LIBRARY OLEPRX32\nEXPORTS\n    DllGetClassObject   PRIVATE\n    DllCanUnloadNow     PRIVATE\n' \
        > "$prx/obj/i386/oleprx32.def"
    local W="$NT_ROOT_WIN" defs=(-DWIN32=100 -D_NT1X_=100 -D_X86_=1 -Di386=1 -DSTD_CALL -DUNICODE -D_UNICODE -DFLAT)
    local incs=(-I"$W\\PRIVATE\\BASE\\TYPES\\NEW_OLE\\gen" -I"$W\\PRIVATE\\BASE\\CINC" -I"$W\\PRIVATE\\BASE\\CAIROLE\\IH" -I.)
    local f
    for f in com_p ole2x_p call_as dlldata; do
        run_wibo_tool "$prx" cl386 -nologo -c "${defs[@]}" "${incs[@]}" -Fo$o\\$f.obj $f.c || return 1
    done
    run_wibo_tool "$prx" cl386 -nologo -c "${defs[@]}" "${incs[@]}" -Fo$o\\transmit.obj transmit.cxx || return 1
    local L="$W\\PUBLIC\\SDK\\LIB\\I386"
    run_wibo_tool "$prx" LINK.EXE -nologo -dll -noentry -def:$o\\oleprx32.def -merge:.text=.orpc \
        -base:@"$W\\PUBLIC\\SDK\\LIB\\coffbase.txt",oleprx32 -out:$o\\oleprx32.dll -nodefaultlib \
        $o\\com_p.obj $o\\ole2x_p.obj $o\\call_as.obj $o\\dlldata.obj $o\\transmit.obj \
        "$L\\ole32.lib" "$L\\uuid.lib" "$L\\gdi32p.lib" "$L\\rpcrt4.lib" "$L\\kernel32.lib" "$L\\CRTDLL.LIB" \
        || return 1
    echo ">>> CAIROLE/OLEPRX32: oleprx32.dll ($(ls -l "$prx/obj/i386/oleprx32.dll" | awk '{print $5}') bytes)"
}

# ole32.dll + scm link rpcns4.lib (RPC name service), but CAIROLE makes no
# RpcNs* calls and micront doesn't build rpcns4 — provide an empty import lib
# so the (dead) link reference resolves.
_ensure_rpcns4_stub() {
    local lib="$NT_ROOT/PUBLIC/SDK/LIB/I386/rpcns4.lib"
    [ -f "$lib" ] && return 0
    local d="$BASE_D/CAIROLE/ILIB/DAYTONA"
    printf 'LIBRARY rpcns4\nEXPORTS\n' > "$d/rpcns4.def"
    run_wibo_tool "$d" LIB.EXE -nologo -machine:ix86 -def:rpcns4.def -out:rpcns4.lib || return 1
    cp "$d/rpcns4.lib" "$lib" && echo ">>> installed rpcns4.lib (empty stub)"
    rm -f "$d/rpcns4.def" "$d/rpcns4.exp" "$d/rpcns4.lib"
}

# micront unifies COM into ole32 (no separate compob32.dll), but Daytona's
# storag32 still links compob32.lib. ole32 exports the same CoXxx APIs, so
# alias compob32.lib -> ole32.lib (built just before).
_ensure_compob32_alias() {
    local lib="$NT_ROOT/PUBLIC/SDK/LIB/I386"
    [ -f "$lib/ole32.lib" ] || { echo "!!! compob32 alias: ole32.lib not built yet"; return 1; }
    cp "$lib/ole32.lib" "$lib/compob32.lib" && echo ">>> aliased compob32.lib -> ole32.lib"
}

# uuid.lib (standard IIDs) + the regenerated OLE headers come from build_types;
# build it once if uuid.lib is absent (run `./build.sh types` to force a refresh
# after editing the TYPES .idl/.x/.y sources).
_ensure_types() {
    [ -f "$NT_ROOT/PUBLIC/SDK/LIB/I386/uuid.lib" ] && return 0
    build_types
}

# Full CAIROLE build. ole32 (DLL) links the com/ole232/stg sub-libs + uuid,
# so those precede it; storag32 (STG/DLL) and scm link ole32, so they follow.
build_cairole() {
    _ensure_types             || return 1
    build_cairole_common      || return 1
    build_cairole_ilib        || return 1
    build_cairole_com         || return 1
    build_cairole_ole232      || return 1
    _cairole_comp STG libs    || return 1   # docfile/exp/msf (ole32 links these)
    build_cairole_olecnv32    || return 1
    _ensure_rpcns4_stub       || return 1
    build_cairole_dll         || return 1   # ole32.dll (the unified OLE runtime)
    _ensure_compob32_alias    || return 1
    # storag32 is the Daytona split-model storage DLL — redundant here since
    # ole32 embeds storage; build it import-lib-only (compile-verified).
    _cairole_comp STG dlls 0  || return 1
    build_cairole_scm         || return 1   # scm.exe (links ole32)
    build_cairole_olethunk    || return 1   # olethk32: import lib only (16-bit/VDM)
    build_cairole_oleprx32    || return 1   # oleprx32.dll (marshaling proxy)
    echo ">>> CAIROLE: all components built (ole32.dll, olecnv32.dll, oleprx32.dll,"
    echo "    scm.exe; storag32/olethk32 compile-verified, runtime .dll N/A for 32-bit)"
}

# INT64.LIB — 64-bit integer helpers (LLMUL/LLDIV/...) built from the
# MSVC 2.2 helper ASM imported into CRT32/HELPER/I386.
build_int64() {
    run_nmake "$BASE_D/CRT32/HELPER" "CRT32/HELPER - INT64.LIB" "CRTLIBTYPE=ST" "386=1" || return 1
    local src="$BASE_D/CRT32/obj/i386/helper.lib" dst="$NT_ROOT/PUBLIC/SDK/LIB/I386/INT64.LIB"
    [ -f "$src" ] || { echo "!!! int64: missing $src"; return 1; }
    cp "$src" "$dst" && echo ">>> installed INT64.LIB"
}

# Build the whole CRT from source and install the release libs over the
# prebuilt seeds. Chain order matches build.lua: ends with the CRT32 MT
# flavor so CRTLIB's client SUPPOBJS (txtmode.obj, etc.) archive MT-built.
# crt32 "NT" flavor is intentionally omitted — the NT-subset CRT comes from
# the separate CRT32NT tree, not CRT32-with-CRTLIBTYPE=NT.
build_crt() {
    local B="$BASE_D"
    _crt_variant "$B/FP32NT"  NT  "FP32NT"    TRAN || return 1
    _crt_variant "$B/CRT32NT" NT  "CRT32NT"   CONVERT MISC STARTUP STDIO STRING HACK || return 1
    _crt_variant "$B/FP32"    ST  "FP32-ST"   CONV TRAN || return 1
    _crt_variant "$B/FP32"    DLL "FP32-DLL"  CONV TRAN || return 1
    _crt_variant "$B/FP32"    MT  "FP32-MT"   CONV TRAN || return 1
    _crt_variant "$B/CRT32"   DLL "CRT32-DLL" CONVERT MISC STARTUP STDIO STRING TIME WINHEAP DLLSTUFF DIRECT DOS EXEC IOSTREAM LOWIO MBSTRING || return 1
    _crt_variant "$B/CRT32"   ST  "CRT32-ST"  CONVERT MISC STARTUP STDIO STRING LINKOPTS TIME WINHEAP DIRECT DOS EXEC IOSTREAM LOWIO SMALL MBSTRING || return 1
    _crt_variant "$B/CRT32"   MT  "CRT32-MT"  CONVERT MISC STARTUP STDIO STRING TIME WINHEAP DIRECT DOS EXEC IOSTREAM LOWIO MBSTRING || return 1
    build_int64 || return 1
    echo "========================================"
    echo "Building: CRTLIB - release roll-up"
    echo "========================================"
    run_wibo_tool "$B/CRTLIB" NMAKE.EXE /NOLOGO "386=1" || return 1
    # Install the release set over the prebuilt seeds (uppercase names).
    local out="$B/CRTLIB/LIB/I386" lib="$NT_ROOT/PUBLIC/SDK/LIB/I386" pair s d
    for pair in crtdll.dll:CRTDLL.DLL crtdll.lib:CRTDLL.LIB libcntpr.lib:LIBCNTPR.LIB \
                libc.lib:LIBC.LIB libcmt.lib:LIBCMT.LIB exsup.lib:EXSUP.LIB; do
        s="$out/${pair%%:*}"; d="$lib/${pair##*:}"
        [ -f "$s" ] || { echo "!!! crtlib: missing $s"; return 1; }
        cp "$s" "$d" && echo ">>> installed ${pair##*:}"
    done
}

# MC (message compiler). Two patches live in our source tree relative to
# stock NT 3.5 mc.c:
#   - MC.C drops user32!CharToOem (wibo has no stub; safe for ASCII .mc).
#   - MCUTIL.C hardcodes CodePage=437 (wibo has no GetOEMCP).
#
# We *cannot* drive this build through nmake: nmake's LINK invocation uses
# -MERGE:, -SECTION:, -base:@coffbase.txt,usermode and -debug:MINIMAL, one
# of which trips an internal assertion in LINK.EXE's bufio.c:2134 under
# wibo (not reproduced with minimal flags). So we compile + link directly
# via our own run_wibo_tool helpers with the minimum flags needed.
# cmd-stub: minimal cmd.exe replacement used as NMAKE's COMSPEC. Compiles
# src/cmd-stub/cmd.c under wibo via CL + LINK (self-hosted; no mingw or
# wine required). Output lands in wibo-tools/cmd.exe so the COMSPEC env
# var in NT_ENV_ARR resolves to it.
build_cmdstub() {
    local src_dir="$SCRIPT_DIR/cmd-stub"
    if [ ! -f "$src_dir/cmd.c" ]; then
        echo "ERROR: cmd-stub source not found at $src_dir/cmd.c"
        return 1
    fi

    echo "========================================"
    echo "Building: cmd-stub (NMAKE COMSPEC replacement)"
    echo "========================================"

    rm -f "$src_dir/cmd.obj" "$src_dir/cmd.exe"
    # Use inline env — we can't call run_wibo_tool yet; COMSPEC isn't wired
    # until after cmd.exe exists. CL's combined compile+link via -link
    # handles both stages in a single wibo invocation.
    env -i HOME="$HOME" TERM="${TERM:-dumb}" ${WIBO_DEBUG:+"WIBO_DEBUG=$WIBO_DEBUG"} \
        "INCLUDE=${NT_ROOT_WIN}\\PUBLIC\\SDK\\INC;${NT_ROOT_WIN}\\PUBLIC\\SDK\\INC\\CRT" \
        "LIB=${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386" \
        "PATH=${WIBO_TOOLS_WIN}" \
        "WIBO_PATH=${WIBO_TOOLS}" \
        "$WIBO_BIN" --chdir "$src_dir" \
            "${WIBO_TOOLS}/CL.EXE" -nologo cmd.c \
            -link -subsystem:console -out:cmd.exe -nodefaultlib:oldnames \
            "${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386\\LIBC.LIB" \
            "${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386\\KERNEL32.LIB" \
        || { echo ">>> cmd-stub: FAILED"; return 1; }
    # -nodefaultlib:oldnames: cmd.c uses the _-prefixed CRT names (_stricmp,
    # etc.), so it needs no OLDNAMES.lib aliases. The MS SDK's OLDNAMES.lib
    # isn't part of this tree, and CL emits a -defaultlib:OLDNAMES directive
    # that would otherwise make LINK fail with LNK1104.

    cp "$src_dir/cmd.exe" "$WIBO_TOOLS/cmd.exe"
    echo ">>> cmd-stub: $(ls -l "$WIBO_TOOLS/cmd.exe" | awk '{print $5}') bytes -> wibo-tools/cmd.exe"
}

build_mc() {
    local mc_dir="$NT_ROOT/PRIVATE/SDKTOOLS/VCTOOLS/MC"
    local obj_dir="$mc_dir/obj/i386"

    echo "========================================"
    echo "Building: MC - message compiler (patched for wibo)"
    echo "========================================"

    mkdir -p "$obj_dir"

    # Flags mirror what nmake would pass through MAKEFILE.DEF, minus anything
    # that would only matter at link time. WIN32_LEAN_AND_MEAN keeps objbase
    # / OLE off the windows.h dependency chain.
    local cflags=(
        -nologo -c
        -I .  # mc.h is in the source dir and #included with angle brackets
        -D_X86_=1 -Di386=1 -DWIN32_LEAN_AND_MEAN=1 -DWIN32=100
        -DCOMMAND=1 -DENABLE_NLS=0
        -DUNICODE -D_UNICODE
        -DSTD_CALL -DCONDITION_HANDLING=1
        -DDBG=0 -DDEVL=1
    )

    local src
    for src in mc mclex mcparse mcout mcutil; do
        echo ">>> CL $src.c"
        run_wibo_tool "$mc_dir" CL "${cflags[@]}" \
            -Fo"obj/i386/$src.obj" "$src.c" || return 1
    done

    echo ">>> LINK mc.exe"
    run_wibo_tool "$mc_dir" LINK -nologo -subsystem:console -machine:i386 \
        -out:obj/i386/mc.exe \
        obj/i386/mc.obj obj/i386/mclex.obj obj/i386/mcparse.obj \
        obj/i386/mcout.obj obj/i386/mcutil.obj \
        user32.lib libc.lib kernel32.lib advapi32.lib || return 1

    install_host_tool "$obj_dir/mc.exe" "MC.EXE"
    # wibo-tools/MC.EXE is a symlink into OAK/BIN/I386; the install above
    # overwrote the target, so the symlink now resolves to our build.
    echo ">>> $(basename "$obj_dir/mc.exe"): $(ls -l "$obj_dir/mc.exe" | awk '{print $5}') bytes"
}
build_rc() {
    local rcdll_dir="$NT_ROOT/PRIVATE/SDKTOOLS/VCTOOLS/RCDLL"
    local rc_dir="$NT_ROOT/PRIVATE/SDKTOOLS/VCTOOLS/RC"
    echo "========================================"
    echo "Building: RC.EXE + RCDLL.DLL (resource compiler from source)"
    echo "========================================"
    run_nmake "$rcdll_dir" "RCDLL - rcdll.dll" makedll=1 || return 1
    KEEP_UMAPPL=1 run_nmake "$rc_dir" "RC - rc.exe" || return 1
    install_host_tool "$rcdll_dir/obj/i386/rcdll.dll" "RCDLL.DLL"
    install_host_tool "$rc_dir/obj/i386/rc.exe" "RC.EXE"
}
build_midlyacc() {
    run_nmake "$NT_ROOT/PRIVATE/RPC/MIDLNEW/YACC" "MIDL/YACC - custom yacc (midlyacc.exe)"
    install_host_tool "$NT_ROOT/PRIVATE/RPC/MIDLNEW/YACC/obj/i386/midlyacc.exe" "midlyacc.exe"
}
build_midlpg() {
    run_nmake "$NT_ROOT/PRIVATE/RPC/MIDLNEW/PG" "MIDL/PG - parser post-generator (midlpg.exe)"
    install_host_tool "$NT_ROOT/PRIVATE/RPC/MIDLNEW/PG/obj/i386/midlpg.exe" "midlpg.exe"
}
# MIDL20 static libs (link-time deps of midl.exe). Each has TARGETPATH=..\lib
# so outputs land at MIDL20/lib/i386/{support,exprlib,analysis,codegen}.lib.
_midl20_lib_prep() { mkdir -p "$NT_ROOT/PRIVATE/RPC/MIDL20/lib/i386"; }
build_midl_support() { _midl20_lib_prep; run_nmake "$NT_ROOT/PRIVATE/RPC/MIDL20/SUPPORT"  "MIDL20/SUPPORT - support.lib"; }
build_midl_expr()    { _midl20_lib_prep; run_nmake "$NT_ROOT/PRIVATE/RPC/MIDL20/EXPR"     "MIDL20/EXPR - exprlib.lib"; }
build_midl_analysis(){ _midl20_lib_prep; run_nmake "$NT_ROOT/PRIVATE/RPC/MIDL20/ANALYSIS" "MIDL20/ANALYSIS - analysis.lib"; }
build_midl_codegen() { _midl20_lib_prep; run_nmake "$NT_ROOT/PRIVATE/RPC/MIDL20/CODEGEN"  "MIDL20/CODEGEN - codegen.lib"; }

# FRONT pre-generation: midlyacc → midlpg → midleb. Originally driven by
# MAKEFILE.INC inside nmake, but the rules used `qgrep` (resource-kit grep)
# to strip #line directives. We patched midlyacc to gate #line behind a -L
# flag (default off), so the pipeline is now: yacc → pg → midleb, no filter.
# Generates grammar.cxx, acfgram.cxx (compiled by FRONT) and
# include/{idlerec.h, acferec.h} (consumed by FRONT sources).
_midl_front_gen() {
    local front="$NT_ROOT/PRIVATE/RPC/MIDL20/FRONT"
    # Use existing uppercase INCLUDE — Linux is case-sensitive and wibo's path
    # resolver does a case-insensitive fallback, so writing through an
    # uppercase INCLUDE dir avoids duplicate-dir confusion.
    local inc="$NT_ROOT/PRIVATE/RPC/MIDL20/INCLUDE"
    echo ">>> MIDL/FRONT gen: midlyacc + midlpg + midleb"
    # midlyacc emits FOO.C/FOO.H/FOO.I (uppercase). Case-insensitive FS lets
    # cl pick up FOO.C when SOURCES says foo.cxx, so we delete the .C/.H/.I
    # after midlpg consumes them.
    run_wibo_tool "$front" midlyacc -his -t "YYSTATIC " grammar.y       || return 1
    run_wibo_tool "$front" midlpg grammar.C   > "$front/grammar.cxx"    || return 1
    run_wibo_tool "$front" midleb - xlatidl.dat IDL > "$inc/idlerec.h"  || return 1
    # Keep grammar.h (lex.cxx includes it) by moving into INCLUDE; drop .C/.I
    # so cl doesn't pick up grammar.C instead of grammar.cxx.
    mv -f "$front/grammar.H" "$inc/grammar.h" && rm -f "$front/grammar.C" "$front/grammar.I"
    run_wibo_tool "$front" midlyacc -hi  -t "YYSTATIC " acfgram.y       || return 1
    run_wibo_tool "$front" midlpg acfgram.C  > "$front/acfgram.cxx"     || return 1
    run_wibo_tool "$front" midleb - xlatacf.dat ACF > "$inc/acferec.h"  || return 1
    mv -f "$front/acfgram.H" "$inc/acfgram.h" && rm -f "$front/acfgram.C" "$front/acfgram.I"
    echo ">>> MIDL/FRONT gen: OK (grammar.cxx, acfgram.cxx, idlerec.h, acferec.h)"
}
build_midl() {
    # FRONT links against all four static libs — build them first.
    build_midl_support  || return 1
    build_midl_expr     || return 1
    build_midl_analysis || return 1
    build_midl_codegen  || return 1
    _midl_front_gen     || return 1
    run_nmake "$NT_ROOT/PRIVATE/RPC/MIDL20/FRONT" "MIDL20/FRONT - midl.exe (compiler driver)"
    install_host_tool "$NT_ROOT/PRIVATE/RPC/MIDL20/lib/i386/midl.exe" "midl.exe"
}

# --- GUI-side drivers (input + video) ----------------------------------------
# Input: PS/2 port driver (i8042prt) sits under the class drivers
# (kbdclass + mouclass). kbdclass/mouclass are the public NT driver
# interface; i8042prt is the hardware-specific back-end.
build_i8042prt() { run_nmake "$NTOS/DD/I8042PRT" "I8042PRT - PS/2 port driver (kb + mouse)"; }
build_kbdclass() { run_nmake "$NTOS/DD/KBDCLASS" "KBDCLASS - keyboard class driver"; }
build_mouclass() { run_nmake "$NTOS/DD/MOUCLASS" "MOUCLASS - mouse class driver"; }

# Video: videoprt.sys is the common miniport framework that VGA.SYS
# (and all other video drivers in real NT) links against. Build order
# matters — videoprt first because vga imports videoprt.lib.
build_videoprt()    { run_nmake "$NTOS/VIDEO/PORT" "VIDEOPRT - video miniport framework" makedll=1; }
build_vga_miniport(){
    build_videoprt
    run_nmake "$NTOS/VIDEO/VGA" "VGA - VGA miniport driver"
}
build_bochsvga(){
    build_videoprt
    run_nmake "$NTOS/VIDEO/BOCHSVGA" "BOCHSVGA - Bochs VGA miniport (QEMU stdvga)"
}
build_framebuf(){
    run_nmake "$GDI/DISPLAYS/FRAMEBUF" "FRAMEBUF - generic framebuffer display driver" makedll=1
}
build_kbdus(){
    # kbdus SOURCES has TARGETPATH=..\obj (the KBDLYOUT-shared obj dir),
    # but nmake/build only auto-creates per-target obj dirs — not the
    # shared one. Make it here so fresh checkouts build cleanly.
    mkdir -p "$USER/KBDLYOUT/obj/i386"
    run_nmake "$USER/KBDLYOUT/US" "USER/KBDLYOUT/US - US keyboard layout DLL" makedll=1
}
build_mpr(){
    # MPR = Multiple Provider Router, the Win32 abstraction over network
    # filesystems (Lanman/NetWare/etc). On MicroNT we don't have network
    # providers yet, but userinit.exe imports MPR.dll for the one call to
    # WNetRestoreConnection (which walks HKCU\Network and re-mounts saved
    # drive letters — a no-op here). MPR.dll is still needed for the
    # import-table resolution at userinit startup.
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/MPR" "WINDOWS/MPR - mpr.dll" makedll=1
}
build_pwin32(){
    # Win16 → Win32 portability-layer static lib. Progman (ported from
    # Windows 3.1) references its PWIN32_* macros via pwin32.lib, so
    # without this progman won't link.
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/PORT1632" "WINDOWS/PORT1632 - pwin32.lib"
}
build_userpri(){
    # SHELL/USERPRI — shared Unicode C-runtime helpers (unicrt.obj,
    # unifile.obj). Progman links a single .obj (unicrt.obj) from here.
    # TARGETPATH=lib (relative, per SOURCES); lib/i386 isn't auto-created.
    mkdir -p "$NT_ROOT/PRIVATE/WINDOWS/SHELL/USERPRI/lib/i386"
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/USERPRI" "SHELL/USERPRI - userpri.lib"
}
build_shell32(){
    build_pwin32   || return 1
    build_userpri  || return 1
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/LIBRARY" "SHELL/LIBRARY - shell32.dll" makedll=1
}
build_comdlg32(){
    # Common dialogs (File Open/Save, Color, Font, Print). progman LoadLibrary's
    # it at runtime for the Browse button; links kernel32/user32/gdi32/shell32/
    # advapi32, all built earlier in the gui tier.
    build_shell32 || return 1
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/COMDLG" "SHELL/COMDLG - comdlg32.dll" makedll=1
}
build_progman(){
    build_shell32  || return 1
    # SOURCES builds progman.lib first then UMAPPL links to progman.exe —
    # KEEP_UMAPPL=1 tells our run_nmake wrapper to run the UMAPPL pass.
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/PROGMAN" "SHELL/PROGMAN - progman.exe"
}
build_cmd(){
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/WINDOWS/CMD" "WINDOWS/CMD - cmd.exe"
}
# --- Classic NT 3.5 shell apps (Tier 1: no new libraries) -------------------
# Each is TARGETTYPE=LIBRARY (or UMAPPL_NOLIB) + UMAPPL=<name>, the same
# pattern build_progman uses: KEEP_UMAPPL=1 runs the UMAPPL link pass that
# produces the .exe. They link only comdlg32/shell32/user32/ntdll, all built
# earlier in the gui tier.
build_notepad(){
    build_comdlg32 || return 1
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/ACCESORY/NOTEPAD" "SHELL/NOTEPAD - notepad.exe"
}
build_taskman(){
    build_shell32 || return 1
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/TASKMAN" "SHELL/TASKMAN - taskman.exe"
}
build_clock(){
    build_comdlg32 || return 1
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/ACCESORY/CLOCK" "SHELL/CLOCK - clock.exe"
}
build_control(){
    # Control Panel launcher (UMAPPL_NOLIB). Enumerates + launches *.cpl files;
    # inert until an applet (main.cpl, Tier 3) is staged. Links shell32 + the
    # userpri.lib that build_shell32 produces.
    build_shell32 || return 1
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/CONTROL/CPANEL" "SHELL/CONTROL - control.exe"
}
# --- File Manager (Tier 2: +comctl32.dll) -----------------------------------
build_comctl32(){
    # Common controls (listview/treeview/toolbar/property sheets). DYNLINK →
    # makedll=1, same as build_comdlg32. Links only kernel32/user32/gdi32/
    # advapi32, all built earlier in the gui tier. WinFile is the only Tier 1/2
    # app that needs it.
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/COMMCTRL" "SHELL/COMMCTRL - comctl32.dll" makedll=1
}
build_winfile(){
    # File Manager (WinFile). TARGETTYPE=LIBRARY + UMAPPL=winfile → KEEP_UMAPPL.
    # Links shell32 + comctl32 + user32p + ntdll.
    build_comctl32 || return 1
    build_shell32  || return 1
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/WINFILE" "SHELL/WINFILE - winfile.exe"
}
# --- Control Panel applet (Tier 3: main.cpl + its 4-lib sub-chain) -----------
# lz32/version/t1instal are DYNLINK DLLs (→ makedll=1, land in SDK_LIB);
# prsinf is a plain LIBRARY; main.cpl is a DYNLINK with TARGETEXT=cpl.
build_winlza(){
    # LZ core routines (winlza.lib) — the LZEXPAND DLL links this static lib.
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/LZ/LIBS" "SHELL/LZ/LIBS - winlza.lib"
}
build_lz32(){
    # LZ decompression DLL. main.cpl links lz32.lib for font/driver install.
    build_winlza || return 1
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/LZ/LZEXPAND" "SHELL/LZ - lz32.dll" makedll=1
}
build_version(){
    # Version-resource DLL (GetFileVersionInfo). main.cpl links version.lib.
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/VERSION" "SHELL/VERSION - version.dll" makedll=1
}
build_prsinf(){
    # INF-file parser (prsinf.lib) — used by main.cpl's driver/font install.
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/PRSINF" "WINDOWS/PRSINF - prsinf.lib"
}
build_t1instal(){
    # Type-1 font installer DLL (Adobe .pfb/.pfm → .ttf). main.cpl links it.
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/CONTROL/T1INSTAL" "SHELL/CONTROL/T1INSTAL - t1instal.dll" makedll=1
}
build_main_cpl(){
    # Main Control Panel applet (Color/Date-Time/Mouse/Keyboard/Ports/Fonts/
    # International). DYNLINK with TARGETEXT=cpl → main.cpl. Links the four libs
    # above plus user32/kernel32/advapi32/gdi32/comdlg32/shell32/libc + userpri.
    build_lz32     || return 1
    build_version  || return 1
    build_prsinf   || return 1
    build_t1instal || return 1
    build_comdlg32 || return 1
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/CONTROL/MAIN" "SHELL/CONTROL/MAIN - main.cpl" makedll=1
}
# --- Phase 4a: self-contained Control Panel applets -------------------------
# Each is DYNLINK + TARGETEXT=cpl + DllInitialize → makedll=1. They link only
# libs already built in Tiers 1-3; control.exe auto-discovers the *.cpl.
build_cursors(){
    build_shell32 || return 1
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/CONTROL/CURSORS" "SHELL/CONTROL/CURSORS - cursors.cpl" makedll=1
}
build_profile(){
    build_shell32 || return 1
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/CONTROL/PROFILE" "SHELL/CONTROL/PROFILE - profile.cpl" makedll=1
}
build_display(){
    # Display applet (VIDEO → display.cpl) — resolution/color depth. Links
    # prsinf (from Tier 3) for driver-INF parsing.
    build_shell32 || return 1
    build_prsinf  || return 1
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/CONTROL/VIDEO" "SHELL/CONTROL/VIDEO - display.cpl" makedll=1
}
build_ups(){
    build_shell32 || return 1
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/CONTROL/UPS" "SHELL/CONTROL/UPS - ups.cpl" makedll=1
}
build_scrnsavers(){
    # Screen savers (SCRNSAVE DIRS): the scrnsave.lib framework (COMMON) then
    # each saver (UMAPPL_NOLIB + UMAPPLEXT=.scr → <name>.scr). Savers link
    # scrnsave.lib, which COMMON stages into SDK_LIB.
    local SS="$NT_ROOT/PRIVATE/WINDOWS/SHELL/CONTROL/SCRNSAVE"
    build_shell32 || return 1
    run_nmake "$SS/COMMON" "SCRNSAVE/COMMON - scrnsave.lib" || return 1
    local s
    for s in DEFAULT BEZIER MARQUEE MYSTIFY STARS LOGON; do
        KEEP_UMAPPL=1 run_nmake "$SS/$s" "SCRNSAVE/$s - .scr" || return 1
    done
}
# --- GUI userland (USER + GDI + console + winsrv + winlogon) ----------------
#
# GDI dependency chain: efloat (FP math) + font drivers (fscaler, ttfd, bmfd,
# vtfd) + halftone → gdisrvl.lib (GRE engine) → gdi32.dll (client).
# USER: usersrvl.lib (server) → user32.dll (client).
# Console: consrvl.lib (server).
# winsrv.dll aggregates usersrvl + gdisrvl + consrvl + basesrv.

GDI="$NT_ROOT/PRIVATE/WINDOWS/GDI"
USER="$NT_ROOT/PRIVATE/WINDOWS/USER"

_ensure_user_headers() {
    # Generate USER client/server dispatch files from .TPL + .LST via listmung.
    local inc="$USER/INC"
    local svr="$USER/SERVER"
    local cli="$USER/CLIENT"

    if [ ! -f "$inc/callback.h" ] || [ "$inc/CB.LST" -nt "$inc/callback.h" ]; then
        echo ">>> listmung: generating USER dispatch headers + source"
        # listmung writes to stdout — redirect to target file.
        # INC headers
        run_wibo_tool "$inc" listmung CB.LST CALLBACK.TPL  > "$inc/callback.h" || return 1
        run_wibo_tool "$inc" listmung CF.LST CSUSER.TPL    > "$inc/csuser.h"   || return 1
        run_wibo_tool "$inc" listmung SCF.LST CSCALL.TPL   > "$inc/cscall.h"   || return 1
        # SERVER generated .c files
        run_wibo_tool "$svr" listmung ..\\inc\\CF.LST DISPCF.TPL  > "$svr/dispcf.c"  || return 1
        run_wibo_tool "$svr" listmung ..\\inc\\SCF.LST CALLCF.TPL > "$svr/callcf.c"  || return 1
        # CLIENT generated .c files
        run_wibo_tool "$cli" listmung ..\\inc\\CB.LST DISPCB.TPL  > "$cli/dispcb.c"   || return 1
    fi
}

build_gdi_efloat()   { run_nmake "$GDI/MATH"               "GDI/MATH - efloat.lib (FP for GDI)"; }
build_gdi_fscaler()  { run_nmake "$GDI/FONDRV/TT/SCALER"   "GDI/FONDRV/TT/SCALER - fscaler.lib"; }
build_gdi_ttfd()     { run_nmake "$GDI/FONDRV/TT/TTFD"     "GDI/FONDRV/TT/TTFD - ttfd.lib"; }
build_gdi_bmfd()     { run_nmake "$GDI/FONDRV/BMFD"        "GDI/FONDRV/BMFD - bmfd.lib"; }
build_gdi_vtfd()     { run_nmake "$GDI/FONDRV/VTFD"        "GDI/FONDRV/VTFD - vtfd.lib"; }
build_gdi_halftone() { run_nmake "$GDI/HALFTONE/HT"        "GDI/HALFTONE - halftone.lib"; }

build_gdi_geni386() {
    echo "========================================"
    echo "Building: GDI GENI386 (struct offset generator)"
    echo "========================================"

    local gre="$GDI/GRE"
    local geni_src="$gre/I386/GENI386.CXX"
    local obj_dir="$gre/obj/i386"
    local out_inc="$GDI/INC/GDII386.INC"
    mkdir -p "$obj_dir"

    if [ ! -f "$geni_src" ]; then
        echo "ERROR: GENI386.CXX not found at $geni_src"
        return 1
    fi

    local obj_dir_win; obj_dir_win="$(path_to_win "$obj_dir")"
    local out_inc_win; out_inc_win="$(path_to_win "$out_inc")"

    # Compile with the same flags as gdisrvl — same include paths, same
    # defines, same packing — so OFFSET() produces the same values the
    # engine objects see.
    run_wibo_tool "$gre" cl386 \
        -nologo -c -Zp8 -Gz \
        -Di386=1 -D_X86_=1 -DNT_UP=1 -DSTD_CALL \
        -DCONDITION_HANDLING=1 -DWIN32_LEAN_AND_MEAN=1 -DNOICM \
        -DDBG=0 -DDEVL=1 -DPRECOMPILED_GRE -DWIN32=100 -D_NT1X_=100 \
        "-I." \
        "-I..\\inc" \
        "-I..\\..\\inc" \
        "-I${NT_ROOT_WIN}\\PUBLIC\\OAK\\INC" \
        "-I${NT_ROOT_WIN}\\PUBLIC\\SDK\\INC" \
        "-I${NT_ROOT_WIN}\\PUBLIC\\SDK\\INC\\CRT" \
        "-I${NT_ROOT_WIN}\\PRIVATE\\WINDOWS\\GDI\\MATH\\I386" \
        "I386\\GENI386.CXX" \
        "-Fo${obj_dir_win}\\gdi_geni386.obj" || return 1

    run_wibo_tool "$gre" link \
        -nologo -subsystem:console \
        "-out:${obj_dir_win}\\gdi_geni386.exe" \
        "${obj_dir_win}\\gdi_geni386.obj" \
        "${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386\\LIBC.LIB" \
        "${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386\\KERNEL32.LIB" || return 1

    env -i HOME="$HOME" TERM="${TERM:-dumb}" ${WIBO_DEBUG:+"WIBO_DEBUG=$WIBO_DEBUG"} \
        "${NT_ENV_ARR[@]}" \
        "$WIBO_BIN" --chdir "$gre" \
            "$obj_dir/gdi_geni386.exe" \
            "$out_inc_win" || return 1

    echo ">>> GDI GENI386: $out_inc regenerated"
}

build_gdisrv() {
    # gdi_geni386 is hoisted to the front of USERLAND_GUI_TARGETS so
    # MATH (efloat) can include GDII386.INC. By the time we run here
    # the .inc is already in GDI/INC/.
    run_nmake "$GDI/GRE"                "GDI/GRE - gdisrvl.lib (GDI engine)"
}

# user32 ↔ gdi32 have a circular import dependency (user32 links
# gdi32p.lib, gdi32 links user32p.lib). Break the cycle by pre-
# generating both private import libs from their DEF files before
# either DLL links — same pattern as samsrv ↔ lsasrv.
build_gui_import_stubs() {
    # user32 ↔ gdi32 circular import. Compile both to .obj (no link),
    # then generate decorated import libs from DEF + objs. Same pattern
    # as build_lsasrv_imports for samsrv ↔ lsasrv.
    #
    # Run the compile-only pass unconditionally: nmake's own dep tracking
    # rebuilds only what changed. Skipping on "some objs exist" leaves
    # missed/failed objs invisible and breaks _lib_from_def downstream.
    # Show full output so a compile error isn't hidden behind `tail -3`.
    _ensure_user_headers
    echo ">>> GUI import stubs: compile-only pass"
    local user_obj="$USER/CLIENT/obj/i386/*.obj"
    local gdi_obj="$GDI/CLIENT/obj/i386/*.obj"
    run_nmake "$USER/CLIENT" "USER/CLIENT compile-only (pre-imports)" NTTARGETFILE0= NTTARGETFILE1= || return 1
    run_nmake "$GDI/CLIENT"  "GDI/CLIENT compile-only (pre-imports)"  NTTARGETFILE0= NTTARGETFILE1= || return 1
    echo ">>> GUI import stubs: generating user32p.lib + gdi32p.lib"
    # NT generates user32p.def from USER32.DEF via `cl -EP -DPRIVATE=`,
    # stripping the PRIVATE keyword so those exports become normal import
    # stubs. Without this, `lib -def:` skips PRIVATE exports entirely.
    sed -E 's/[[:space:]]+PRIVATE([[:space:]]|$)/\1/' "$USER/CLIENT/USER32.DEF" > "$USER/CLIENT/user32p.def"
    _lib_from_def user32p.lib "$USER/CLIENT/user32p.def" "$user_obj" || return 1
    _lib_from_def gdi32p.lib "$GDI/CLIENT/gdi32p.def"  "$gdi_obj"  || return 1
}

build_gdi32() {
    build_gui_import_stubs || return 1
    local saved
    for i in "${!NT_ENV_ARR[@]}"; do
        if [[ "${NT_ENV_ARR[$i]}" == "NTDEBUG=" ]]; then
            saved=$i
            NT_ENV_ARR[$i]="NTDEBUG=sym"
        fi
    done
    run_nmake "$GDI/CLIENT" "GDI/CLIENT - gdi32.dll" makedll=1
    [ -n "${saved:-}" ] && NT_ENV_ARR[$saved]="NTDEBUG="
}

build_usersrv() {
    _ensure_user_headers
    run_nmake "$USER/SERVER" "USER/SERVER - usersrvl.lib"
}
build_user32() {
    build_gui_import_stubs || return 1
    local saved
    for i in "${!NT_ENV_ARR[@]}"; do
        if [[ "${NT_ENV_ARR[$i]}" == "NTDEBUG=" ]]; then
            saved=$i
            NT_ENV_ARR[$i]="NTDEBUG=sym"
        fi
    done
    run_nmake "$USER/CLIENT" "USER/CLIENT - user32.dll" makedll=1
    [ -n "${saved:-}" ] && NT_ENV_ARR[$saved]="NTDEBUG="
}

build_consrv()       { run_nmake "$NT_ROOT/PRIVATE/WINDOWS/WINCON/SERVER/DAYTONA" "WINCON/SERVER - consrvl.lib"; }

build_winsrv() {
    mkdir -p "$NT_ROOT/PRIVATE/WINDOWS/WINSRV/DAYTONA/obj/i386"
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/WINSRV/DAYTONA" "WINSRV - winsrv.dll (USER+GDI+console aggregator)" makedll=1
}

build_winlogon() {
    KEEP_UMAPPL=1 run_nmake "$USER/WINLOGON/DAYTONA" "WINLOGON - winlogon.exe"
}

build_userinit() {
    KEEP_UMAPPL=1 run_nmake "$USER/USERINIT" "USERINIT - userinit.exe"
}

build_listmung() {
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/SDKTOOLS/LISTMUNG" "LISTMUNG - template list expander"
    install_host_tool "$NT_ROOT/PRIVATE/SDKTOOLS/LISTMUNG/obj/i386/listmung.exe" "listmung.exe"
}

build_gensrv() {
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/SDKTOOLS/GENSRV" "GENSRV - NT syscall stub generator"
    install_host_tool "$NT_ROOT/PRIVATE/SDKTOOLS/GENSRV/obj/i386/gensrv.exe" "gensrv.exe"
}
build_rtl_user() {
    _ensure_error_h
    # TARGETPATH=..\obj puts rtl.lib at RTL/obj/i386/ — ensure it exists.
    mkdir -p "$NTOS/RTL/obj/i386"
    run_nmake "$NTOS/RTL/USER" "RTL_USER - user-mode runtime library"
}
build_ntdll()  {
    # gensrv writes i386/usrstubs.asm into the DAYTONA build dir — create it.
    mkdir -p "$NTOS/DLL/DAYTONA/i386"
    # makedll=1 tells MAKEFILE.DEF to actually link the DLL (not just import lib)
    run_nmake "$NTOS/DLL/DAYTONA" "NTDLL - user-mode runtime library" makedll=1
}
build_urtl()   { run_nmake "$NT_ROOT/PRIVATE/URTL" "URTL - native-app startup library (nt.lib)"; }
build_smlib()  { run_nmake "$NT_ROOT/PRIVATE/SM/CLIENT" "SM client library"; }
build_smss()   {
    # Build smss with NTDEBUG so KdPrint() calls are compiled in and we can
    # see "SMSS: ..." output on serial (via our KDTRAP.C tee). Swap the
    # NTDEBUG= entry in NT_ENV_ARR for NTDEBUG=sym, then restore.
    local i saved
    for i in "${!NT_ENV_ARR[@]}"; do
        if [[ "${NT_ENV_ARR[$i]}" == "NTDEBUG=" ]]; then
            saved=$i
            NT_ENV_ARR[$i]="NTDEBUG=sym"
            break
        fi
    done
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/SM/SERVER" "SMSS - Session Manager"
    local rc=$?
    [ -n "${saved:-}" ] && NT_ENV_ARR[$saved]="NTDEBUG="
    return $rc
}

# --- Client-Server Runtime Subsystem ---
#
# CSR/SERVER builds BOTH csrsrv.dll (TARGETNAME) AND csrss.exe (UMAPPL) in
# a single nmake pass. csrsrv is the subsystem runtime (LPC port listener,
# process/thread bookkeeping, registration). csrss.exe is the hosting
# process — tiny, just calls into csrsrv's ServerDllInitialization loop.
#
# basesrv.dll is the kernel32 server-side: CreateProcess, heap base-named
# objects, NLS server-side, atom table. Loaded by csrss at startup via
# the registry's ServerDll entries under Session Manager\SubSystems.
build_csrss()   {
    # Two toggles needed:
    #   KEEP_UMAPPL=1  — link the EXE (csrss.exe) half of the SOURCES,
    #                    otherwise SOURCES' UMAPPL= directive gets stripped
    #                    by our wrapper and the EXE is skipped.
    #   makedll=1      — tell MAKEFILE.DEF to actually LINK csrsrv.dll,
    #                    not just emit the import lib (same quirk as ntdll).
    KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/CSR/SERVER" "CSRSS + CSRSRV - Client-Server Runtime" makedll=1
}
build_basesrv() {
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/BASE/SERVER" "BASESRV - kernel32 subsystem server" makedll=1
}

# --- Win32 user-mode libraries (kernel32.dll chain) ---
#
# Dependency order: baselib <- nlslib <- conlib <- kernel32.dll
#   baselib   = BASE/RTL    (atom.c, handle.c)  -> baselib.lib
#   nlslib    = WINNLS                          -> nlslib.lib
#   conlib    = WINCON/CLIENT (console client)  -> conlib.lib
#   kernel32  = BASE/CLIENT (DAYTONA)           -> kernel32.dll
build_baselib() {
    # TARGETPATH=..\obj -> baselib.lib lands at BASE/obj/i386/
    mkdir -p "$NT_ROOT/PRIVATE/WINDOWS/BASE/obj/i386"
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/BASE/RTL" "BASELIB - kernel32 support lib"
}
build_nlslib() {
    # TARGETPATH=..\obj -> nlslib.lib lands at WINDOWS/obj/i386/
    mkdir -p "$NT_ROOT/PRIVATE/WINDOWS/obj/i386"
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/WINNLS" "NLSLIB - NLS/codepage lib for kernel32"
}
build_conlib() {
    # TARGETPATH=..\..\obj -> conlib.lib lands at WINDOWS/obj/i386/
    mkdir -p "$NT_ROOT/PRIVATE/WINDOWS/obj/i386"
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/WINCON/CLIENT" "CONLIB - console client lib for kernel32"
}
build_nlsmsg() {
    # mc.exe compiles WINERROR.MC -> winerror.h, winerror.rc, msg00001.bin.
    # kernel32's MAKEFILE.INC copies these from WINDOWS/NLSMSG/ into
    # BASE/CLIENT/ at build time.
    local dir="$NT_ROOT/PRIVATE/WINDOWS/NLSMSG"
    echo "========================================"
    echo "Building: NLSMSG - Win32 error messages (mc)"
    echo "========================================"
    run_wibo_tool "$dir" mc -s winerror.mc
    echo ">>> NLSMSG: WINERROR.MC -> winerror.h / winerror.rc / MSG00001.bin"
    ls -la "$dir/winerror.h" "$dir/winerror.rc" "$dir/MSG00001.bin" 2>/dev/null || true
}
build_kernel32() {
    # kernel32 uses DAYTONA-style build dir (like ntdll).
    mkdir -p "$NT_ROOT/PRIVATE/WINDOWS/BASE/CLIENT/DAYTONA/i386"
    # Ensure NLSMSG outputs exist (mc.exe writes MSG00001.bin in uppercase).
    if [ ! -f "$NT_ROOT/PRIVATE/WINDOWS/NLSMSG/MSG00001.bin" ]; then
        build_nlsmsg
    fi
    run_nmake "$NT_ROOT/PRIVATE/WINDOWS/BASE/CLIENT/DAYTONA" "KERNEL32 - Win32 base DLL" makedll=1
}

# --- INIT: links all libs into NTOSKRNL.EXE ---

build_hal_stubs() {
    # Build hal.lib + hal.exp from HAL.SRC before INIT so NTOSKRNL.EXE's
    # link can resolve Ke*Irql and other Hal* imports. The stubs-only
    # part of HAL's build is driven by MAKEFILE.INC's lib rule, which
    # runs lib -def:hal.def obj\i386\*.obj. We invoke just that rule.
    local hal_dir="$NTOS/NTHALS/HAL"
    mkdir -p "$hal_dir/obj/i386"
    # Running full nmake here is fine — it'll also compile the HAL objs
    # (needed by lib -def for @N decoration). Link happens later in build_hal.
    run_nmake "$hal_dir" "HAL - stubs lib (for ntoskrnl link)"
}

build_init() {
    build_hal_stubs || return 1
    _ensure_bugcodes || return 1
    # INIT is special: NTTEST=ntoskrnl builds the kernel EXE via MAKEFILE.DEF
    # We must NOT override NTTEST for this component
    local linux_dir="$NTOS/INIT/UP"
    local desc="INIT - NTOSKRNL.EXE"

    echo "========================================"
    echo "Building: $desc"
    echo "========================================"

    mkdir -p "$linux_dir/obj/i386"
    python3 "$SCRIPT_DIR/tools/gen_objects.py" "$linux_dir"

    local rel_path="${linux_dir#$NT_ROOT}"
    local makedir_win="${NT_ROOT_WIN}$(echo "$rel_path" | sed 's|/|\\|g')"

    # --syms: build the kernel EXE with CodeView (MAKEFILE.DEF -> /Z7 +
    # -debugtype:cv + cvpack) so splitsym/dbg2dwf can emit ntoskrnl.dwf.
    local syms_env=()
    [ "$SYMS" = "1" ] && syms_env=("NTDEBUG=ntsdnodbg" "NTDEBUGTYPE=windbg")

    env -i HOME="$HOME" TERM="${TERM:-dumb}" ${WIBO_DEBUG:+"WIBO_DEBUG=$WIBO_DEBUG"} \
        "${NT_ENV_ARR[@]}" "${syms_env[@]}" "MAKEDIR=${makedir_win}" \
        "$WIBO_BIN" --chdir "$linux_dir" \
            "${WIBO_TOOLS}/NMAKE.EXE" /NOLOGO UMTEST= UMAPPL=

    local rc=$?

    if [ $rc -eq 0 ]; then
        echo ">>> $desc: OK"
        ls -la "$linux_dir/obj/i386/ntoskrnl.exe"
    else
        echo ">>> $desc: FAILED (rc=$rc)"
    fi
    return $rc
}

# --- HAL: builds lib, then links HAL.DLL ---

build_hal() {
    local hal_dir="$NTOS/NTHALS/HAL"

    # Step 1: Build the HAL as a library (via nmake/MAKEFILE.DEF)
    run_nmake "$hal_dir" "HAL - MicroNT HAL (lib)"

    echo "========================================"
    echo "Building: HAL - MicroNT HAL (DLL link)"
    echo "========================================"

    mkdir -p "$hal_dir/obj/i386"

    # --syms: link with CodeView (objs are already /Z7 from the nmake lib
    # step above); LINK auto-runs cvpack. Retail otherwise.
    local hal_dbg=(-DEBUG:MINIMAL -DEBUGTYPE:COFF)
    [ "$SYMS" = "1" ] && hal_dbg=(-DEBUG:FULL -DEBUGTYPE:CV)

    # Link HAL.DLL (no RC file — no version resources needed)
    run_wibo_tool "$hal_dir" link \
        -OUT:obj\\i386\\hal.dll -DLL -MACHINE:i386 -BASE:0x80400000 \
        -SUBSYSTEM:NATIVE -ENTRY:HalInitSystem@8 -NODEFAULTLIB \
        -RELEASE "${hal_dbg[@]}" -OPT:REF \
        obj\\i386\\*.obj \
        "${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386\\ntoskrnl.lib" \
        "${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386\\LIBCNTPR.LIB" \
        "${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386\\INT64.LIB" \
        "${NT_ROOT_WIN}\\PUBLIC\\SDK\\LIB\\I386\\hal.exp"

    if [ -f "$hal_dir/obj/i386/hal.dll" ]; then
        echo ">>> HAL - MicroNT HAL (DLL): OK"
        ls -la "$hal_dir/obj/i386/hal.dll"
    else
        echo ">>> HAL - MicroNT HAL (DLL): FAILED"
        return 1
    fi
}

# --- Main ---

# Self-bootstrap: if cmd-stub hasn't been built yet, do it now. Safe to call
# at every invocation — no-op when the EXE is already present and fresh.
if [ ! -f "$WIBO_TOOLS/cmd.exe" ] \
   || [ "$SCRIPT_DIR/cmd-stub/cmd.c" -nt "$WIBO_TOOLS/cmd.exe" ]; then
    build_cmdstub || exit $?
fi

# Parse flags.
while [[ "${1:-}" == -* ]]; do
    case "$1" in
        --debug) export WIBO_DEBUG=1; shift ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

# --- Group targets -----------------------------------------------------------
#
# Adding a new component: add its build_foo function above, then add it to
# exactly one of the arrays below. `all` is just the union.
#
# Order matters within each array (deps build first).

#
# Target split: headless vs GUI.
#
#   headless = kernel + storage/fs drivers + Win32-subsystem base
#              (csrss + csrsrv + basesrv + kernel32 + advapi32 + small
#              client DLLs that don't need USER or GDI).
#   gui      = headless + input drivers + VGA + usersrv/user32/gdisrv/
#              gdi32/consrv/winsrv/winlogon/userinit.
#
# The build-time split only gates what gets COMPILED. Disk-image
# composition (mkdisk.py + mkhive.py) chooses which of the compiled
# binaries to stage. That means you can build `all` (== gui) once and
# then flip between headless-boot and gui-boot at disk-build time.
#
# Order inside each array matters — deps first.

# Tools built from source — must run before any component that invokes
# them via nmake rules or build.sh helpers. Order matters: LINK first
# (needed by everything), MC before any .mc compilation, midl before
# any .idl compilation, gensrv before ntdll.
TOOL_TARGETS=(
    link
    mc
    rc
    listmung
    midleb midlyacc midlpg
    midl_support midl_expr midl_analysis midl_codegen midl
    gensrv
)

NTOSKRNL_TARGETS=(
    geni386
    ke rtl ex ob se ps mm cache config lpc dbgk io kd fsrtl raw vdm
    init
    hal
)

# Drivers needed regardless of mode — disk, FS, visibility/null stubs,
# serial (user-facing COM console + Lua I/O).
DRIVER_TARGETS=(
    atdisk null fastfat ntfs npfs msfs serial
    # ndis_wrapper produces ndis.lib, consumed by virtio's vionet link
    # step — must come before `virtio`.
    ndis_wrapper
    virtio
    # SCSI subsystem (class.lib -> scsiport -> scsidisk); nvme2k is a
    # SCSI miniport on top of scsiport.
    dd_class
    dd_scsiport
    dd_scsidisk
    dd_nvme2k
    # Network stack: tcpip.sys depends on ndis.lib + tdi.lib + ip.lib;
    # afd depends on tdi.lib.
    tdi_wrapper
    tdi_tcpip_ip
    tdi_tcpip_tcp
    afd
    # NetBIOS: netbt.sys (NetBIOS-over-TCP, binds tcpip via TDI) + netbios.sys
    # (the \Device\Netbios NCB interface). SMB (rdr/srv) rides on netbt.
    netbt
    netbios
    # SMB redirector (client). rdr.sys mounts remote shares over netbt.
    rdr
    # SMB server. srv.sys serves local shares over netbt.
    srv
)

# Drivers only useful with the GUI (input + video).
DRIVER_GUI_TARGETS=(
    i8042prt kbdclass mouclass
    vga_miniport bochsvga
)

# micront = minimum-viable NT kernel + smss only, NO Win32 subsystem.
# smss comes up, looks for its initial command, done. Useful for
# validating the native-NT boot chain with zero GUI/subsystem weight.
MICRONT_USERLAND_TARGETS=(
    rtl_user
    ntdll
    urtl
    smlib
    smss
    # kernel32/basesrv/csrss etc. are not built in micront — it's
    # just the NT kernel + session manager. Any "init" program must
    # be a native NT binary linked against nt.lib (no Win32).
)

# headless = micront + the Win32 base subsystem (csrss, basesrv,
# kernel32 + its support libs). No USER/GDI, no console server.
# This is what we have working today.
USERLAND_TARGETS=(
    "${MICRONT_USERLAND_TARGETS[@]}"
    baselib nlslib conlib nlsmsg
    kernel32
    # Win32 subsystem: csrsrv + csrss.exe first, then basesrv.dll which
    # depends on csrsrv.lib + baselib.
    csrss
    basesrv
    # RPC runtime + advapi32 stack. MIDL + gensrv are built in the tools
    # phase; rpcrt4 depends on midl-generated stubs. advapi32 pulls in
    # LSA + EventLog + SCM + registry — the full security/services
    # fabric the headless profile needs.
    rpcndrp rpcndr rpcndr20 rpcrt4 rpclts1 rpcltc1
    wrlib perflib localreg winreg
    sclib svcctrl
    elfapi
    lsacomm lsaudll
    crypt_engine sys003
    rpcutil
    advapi32
    # Security subsystem: SAM + LSA + NetLogon helpers → lsass.exe.
    # samsrv<->lsasrv have a circular DLL dep that's resolved inside
    # build_lsasrv_imports (compile-only pass, then `lib -def:X.def
    # obj/*.obj` to produce decorated import stubs).
    nlrepl
    samlib samsrv
    lsasrv msv1_0
    # Winsock: wsock32.dll (+ libuemul/sockreg/sockutil helper libs) on top
    # of afd.sys, plus wshtcpip.dll (the TCP/IP transport helper wsock32
    # loads at socket() time). User-mode sockets — useful headless.
    wsock32 wshtcpip
    # DHCP client service (dhcpcsvc.dll) — leases the adapter address from
    # QEMU's NAT DHCP server instead of the hardcoded static IP. Hosted by
    # services.exe; needs afd.sys/tcpip.sys up.
    dhcpcsvc
)

# GUI userland: pulls in the whole Win32 window/drawing stack. advapi32
# lives here, not in headless, because its SOURCES links against 14
# .libs from RPC/LSA/SCM/eventlog/remote-registry — effectively the
# whole Win32 security/services infrastructure, which isn't tractable
# for a "small DLL" port. winlogon is the main caller.
USERLAND_GUI_TARGETS=(
    # GDI struct-offset generator — must run first because GDI/MATH's
    # assembly (.asm files under gdi_efloat) includes the generated
    # GDII386.INC. Same pattern as geni386 leading NTOSKRNL_TARGETS.
    gdi_geni386
    # GDI support libs (font drivers + math) — built before gdisrvl
    gdi_efloat gdi_fscaler gdi_ttfd gdi_bmfd gdi_vtfd gdi_halftone
    # GDI server (engine) + client DLL
    gdisrv gdi32
    # USER server + client DLL
    usersrv user32
    # Console server
    consrv
    # winsrv.dll — aggregator (usersrv + gdisrv + consrv + basesrv)
    winsrv
    # LSA client stub + winreg server lib (winlogon links both)
    lsadll winregsrv
    # Framebuffer display driver (pairs with bochsvga.sys miniport)
    framebuf
    # US keyboard layout DLL — USERSRV xxLoadKeyboardLayoutEx loads
    # kbdus.dll to translate i8042 scancodes → VKEY + WCHAR. Without
    # this, edit controls receive WM_KEYDOWN but no WM_CHAR.
    kbdus
    # MPR — network-provider router. userinit.exe imports it for a
    # single no-op WNetRestoreConnection call; without MPR.dll present,
    # userinit aborts with STATUS_DLL_NOT_FOUND and the shell never
    # launches.
    mpr
    # Shell libs: pwin32 (Win16→Win32 port layer, macro-only but progman
    # pulls it), userpri (unicrt.obj for shell32), shell32 (ShellExecute/
    # DragAcceptFiles/env helpers used by progman and most classic apps).
    pwin32 userpri shell32
    # Common dialogs DLL — progman loads it for the Browse file picker.
    comdlg32
    # SMB services: the SCM server (services.exe) + the Workstation service
    # (wkssvc.dll, client), Server service (srvsvc.dll, serve shares), and
    # Computer Browser (browser.dll + its xactsrv) it hosts. winlogon execs
    # services.exe.
    scserver wkssvc srvsvc browser
    # Login + shell
    winlogon userinit
    # Program Manager (the default NT 3.5 shell) and cmd.exe.
    progman cmd
    # Classic NT 3.5 shell apps (Tier 1) — Notepad, Task Manager, Clock, and
    # the Control Panel launcher; then File Manager (Tier 2) with its common
    # controls DLL. All reachable via Progman → File → Run.
    notepad taskman clock control
    comctl32 winfile
    # Control Panel applet (Tier 3) — the four support libs then main.cpl,
    # which makes control.exe functional (Color / Date-Time / Mouse / etc.).
    lz32 version prsinf t1instal main_cpl
    # Phase 4a — self-contained Control Panel applets + screen savers.
    cursors profile display ups scrnsavers
    # TCP/IP command-line utilities (arp, route, ping, tracert) — console
    # apps run from cmd. ping/tracert pull in icmp.dll (ICMP Echo API).
    arp route ping tracert
    # net.exe — the `net` command (net use / net view). Drives the SMB
    # redirector via the Workstation service.
    net
)

build_group() {
    local group_name="$1"; shift
    echo ""
    echo "########################################"
    echo "# Group: $group_name"
    echo "########################################"
    for t in "$@"; do
        "build_$t"
    done
}

build_tools()            { build_group tools            "${TOOL_TARGETS[@]}"; }
build_ntoskrnl()         { build_group ntoskrnl         "${NTOSKRNL_TARGETS[@]}"; }
build_drivers()          { build_group drivers          "${DRIVER_TARGETS[@]}"; }
build_drivers_gui()      { build_group drivers_gui      "${DRIVER_GUI_TARGETS[@]}"; }
build_userland_micront() { build_group userland_micront "${MICRONT_USERLAND_TARGETS[@]}"; }
build_userland()         { build_group userland         "${USERLAND_TARGETS[@]}"; }
build_userland_gui()     { build_group userland_gui     "${USERLAND_GUI_TARGETS[@]}"; }

build_efi() {
    echo ""
    echo "========================================"
    echo "Building: UEFI bootloader (BOOTX64.EFI)"
    echo "========================================"
    make -C "$SCRIPT_DIR/boot-efi" BOOTX64.EFI
}

build_disk() {
    local profile="${1:-${PROFILE:-headless}}"
    local out_dir="$(dirname "$SCRIPT_DIR")/build/$profile"
    local efi_bin="$SCRIPT_DIR/boot-efi/BOOTX64.EFI"

    echo ""
    echo "========================================"
    echo "Building boot disk image ($profile)"
    echo "========================================"

    # Always run the EFI loader build — `make` is a no-op when BOOTX64.EFI is
    # up to date, but rebuilds when boot-efi sources change. (A bare
    # `[ ! -f ]` guard served a stale loader after main.c changed — e.g. the
    # NVMe/SCSI boot-driver set was added but the old loader still only loaded
    # atdisk, so q35+nvme bugchecked 0x7B INACCESSIBLE_BOOT_DEVICE.)
    build_efi

    mkdir -p "$out_dir"
    # DHCP=1 leases the adapter IP via the DHCP client service instead of the
    # hardcoded static 10.0.2.15 (see DHCP-PLAN.md); default is static.
    local dhcp_arg=()
    [ "${DHCP:-0}" = "1" ] && dhcp_arg=(--dhcp)
    python3 "$SCRIPT_DIR/tools/mkhive.py" --profile "$profile" "${dhcp_arg[@]}" "$out_dir/SYSTEM"
    python3 "$SCRIPT_DIR/tools/mkdisk.py" --profile "$profile" \
        --output-dir "$out_dir" --efi-binary "$efi_bin"
}

#
# Profile builders. Each builds a strict superset of the previous,
# then assembles the disk with the matching profile. Disk assembly
# respects the $PROFILE env var — see boot-efi/Makefile and
# tools/mkhive.py --profile. A previous `./build.sh gui` + later
# `PROFILE=headless ./build.sh disk` is a valid flow (compile once,
# assemble many ways), but the top-level targets set PROFILE for you.
#

# Compile phases — no disk assembly, no PROFILE mutation.
# The CRT (libcntpr/libc/libcmt/crtdll) is built from source under BASE/ and
# linked by the host tools, the kernel, and all userland — so it must exist
# before build_tools. It's not shipped prebuilt; build it once if missing
# (force a rebuild after editing CRT source with `./build.sh crt`).
_ensure_crt() {
    local lib="$NT_ROOT/PUBLIC/SDK/LIB/I386"
    if [ -f "$lib/LIBCNTPR.LIB" ] && [ -f "$lib/LIBC.LIB" ] && [ -f "$lib/CRTDLL.LIB" ]; then
        return 0
    fi
    echo ">>> CRT libs missing — building from source (BASE/CRT*)"
    build_crt
}

_compile_micront() {
    _ensure_crt
    build_tools
    build_ntoskrnl
    build_drivers
    build_userland_micront
}

_compile_headless() {
    _compile_micront
    build_userland
}

_compile_gui() {
    _compile_headless
    build_drivers_gui
    build_userland_gui
}

# Profile builders — compile everything needed, then assemble the disk
# with the correct PROFILE. Each is the single entry point users invoke.
build_headless() {
    export PROFILE=headless
    _compile_headless
    build_disk
}

build_gui() {
    export PROFILE=gui
    _compile_gui
    build_disk
}

# `all` == compile everything, then assemble the GUI profile disk.
build_all() { build_gui; }

# --- Main dispatch -----------------------------------------------------------

_dispatch_one() {
    local comp="$1"
    case "$comp" in
        all)               build_all ;;
        gui)               build_gui ;;
        headless)          build_headless ;;
        ntoskrnl)          build_ntoskrnl ;;
        drivers)           build_drivers ;;
        drivers-gui)       build_drivers_gui ;;
        userland-micront)  build_userland_micront ;;
        userland)          build_userland ;;
        userland-gui)      build_userland_gui ;;
        disk)              build_disk ;;
        disk-gui)          build_disk gui ;;
        disk-headless)     build_disk headless ;;
        *)
            if declare -F "build_$comp" > /dev/null; then
                "build_$comp"
            else
                echo "Unknown component: $comp"
                echo ""
                echo "Profile targets: all (=gui), gui, headless"
                echo "Group targets:   ntoskrnl, drivers, drivers-gui,"
                echo "                 userland-micront, userland, userland-gui, disk"
                echo "C runtime:       crt (build LIBC/LIBCMT/CRTDLL/LIBCNTPR/EXSUP/INT64 from BASE source)"
                echo "Debug toolchain: debugtools (imagehlp+splitsym, dbg2dwf, cvdump, cvpack)"
                echo "                 gdb (attach gdb to a boot.sh --gdb session w/ DWARF symbols)"
                echo "Flags:           --syms  build NTOS with CodeView + emit .DBG/.dwf gdb"
                echo "                         sidecars (e.g. ./build.sh --syms ntoskrnl); --no-syms"
                echo ""
                echo "Individual components (in build order):"
                echo "  ntoskrnl:          ${NTOSKRNL_TARGETS[*]}"
                echo "  drivers:           ${DRIVER_TARGETS[*]}"
                echo "  drivers-gui:       ${DRIVER_GUI_TARGETS[*]}"
                echo "  userland-micront:  ${MICRONT_USERLAND_TARGETS[*]}"
                echo "  userland:          ${USERLAND_TARGETS[*]}"
                echo "  userland-gui:      ${USERLAND_GUI_TARGETS[*]}"
                exit 1
            fi
            ;;
    esac
}

# Always run the guard so a mode change in EITHER direction (retail<->syms)
# wipes the now-incompatible NTOS objs. Then, for --syms, build the debug
# host tools up front so cvpack.exe is on PATH when the CodeView links run.
_syms_guard
if [ "$SYMS" = "1" ]; then
    build_debugtools || exit 1
fi

if [ $# -eq 0 ]; then
    _dispatch_one all
else
    for comp in "$@"; do
        _dispatch_one "$comp"
    done
fi

# --syms: convert every freshly-built CodeView image to a .DBG/.dwf sidecar.
if [ "$SYMS" = "1" ]; then
    _dwf_generate || exit 1
fi
