#!/usr/bin/env bash
#
# verify_disk.sh — sha256-audit every file on a built MicroNT disk image.
#
# Reads build/disk/manifest.tsv (one row per file: where TAB dest TAB src_path),
# extracts each file from build/disk/esp.img by partition-aware tooling
# (ntfscat for NTFS, mcopy for FAT16), and compares the sha256 against
# the source.
#
# Usage:
#     src/tools/verify_disk.sh
#     src/tools/verify_disk.sh /path/to/esp.img /path/to/manifest.tsv

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISK_IMG="${1:-$REPO_ROOT/build/disk/esp.img}"
MANIFEST="${2:-$REPO_ROOT/build/disk/manifest.tsv}"

if [ ! -f "$DISK_IMG" ];  then echo "no disk image at $DISK_IMG"  >&2; exit 1; fi
if [ ! -f "$MANIFEST" ];  then echo "no manifest at $MANIFEST"    >&2; exit 1; fi

# Parse the MBR partition table to figure out which partition holds
# what.  Each entry in the MBR is 16 bytes starting at 0x1BE.
# Field offsets within an entry:
#   +0x00: BootIndicator
#   +0x04: PartitionType   (0xEF = ESP / 0x06 = FAT16 / 0x07 = NTFS)
#   +0x08: StartingLBA     (LE u32)
#   +0x0C: TotalSectors    (LE u32)
read_le32() {
    local off=$1
    od -An -t u4 -N 4 -j "$off" "$DISK_IMG" | tr -d ' \n'
}
read_byte() {
    local off=$1
    od -An -t u1 -N 1 -j "$off" "$DISK_IMG" | tr -d ' \n'
}

declare -a PART_TYPE PART_LBA PART_SECTORS
NUM_PARTS=0
for i in 0 1 2 3; do
    base=$((0x1BE + i * 16))
    typ=$(read_byte $((base + 4)))
    if [ "$typ" -ne 0 ]; then
        PART_TYPE[$NUM_PARTS]=$typ
        PART_LBA[$NUM_PARTS]=$(read_le32 $((base + 8)))
        PART_SECTORS[$NUM_PARTS]=$(read_le32 $((base + 12)))
        NUM_PARTS=$((NUM_PARTS + 1))
    fi
done

echo "Disk: $DISK_IMG (${NUM_PARTS} partition(s))"
for i in $(seq 0 $((NUM_PARTS - 1))); do
    case "${PART_TYPE[$i]}" in
        239) kind="ESP/FAT" ;;
        6)   kind="FAT16"   ;;
        7)   kind="NTFS"    ;;
        *)   kind="type-${PART_TYPE[$i]}" ;;
    esac
    echo "  Partition $((i+1)): $kind  LBA ${PART_LBA[$i]} sectors ${PART_SECTORS[$i]}"
done

# Extract each partition into a temp file so we can use the right reader.
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT
declare -a PART_IMG PART_KIND
for i in $(seq 0 $((NUM_PARTS - 1))); do
    PART_IMG[$i]="$TMP_DIR/part$((i+1)).img"
    dd if="$DISK_IMG" of="${PART_IMG[$i]}" bs=512 \
       skip="${PART_LBA[$i]}" count="${PART_SECTORS[$i]}" status=none
    case "${PART_TYPE[$i]}" in
        239|6) PART_KIND[$i]="fat" ;;
        7)     PART_KIND[$i]="ntfs" ;;
        *)     PART_KIND[$i]="unknown" ;;
    esac
done

# Decide which partition(s) a file lives on, given the layout.
# Three layouts the orchestrator emits:
#   single        — 1 partition (FAT-typed-as-ESP); everything lands there
#   split-fat     — 2 partitions (ESP FAT, system FAT); routed by where=
#   split-ntfs    — 2 partitions (ESP FAT, system NTFS); routed by where=
#
# `where` values:
#   esp   → partition 1 only
#   root  → last partition (system) only — partition 1 in single, 2 in splits
#   both  → partition 1 AND last partition (only in split-* layouts)
file_partitions_for_where() {
    local where=$1
    if [ "$NUM_PARTS" -eq 1 ]; then
        echo "0"   # single layout: partition 1 (index 0)
    else
        case "$where" in
            esp)  echo "0" ;;
            root) echo "1" ;;
            both) echo "0 1" ;;
            *)    echo "1" ;;   # default = root
        esac
    fi
}

# Read a file from a given partition, print to stdout.
read_from_partition() {
    local pidx=$1; local dest=$2
    case "${PART_KIND[$pidx]}" in
        ntfs)
            ntfscat "${PART_IMG[$pidx]}" "/$dest" 2>/dev/null
            ;;
        fat)
            mtools_path="::/$dest"
            MTOOLS_SKIP_CHECK=1 mcopy -i "${PART_IMG[$pidx]}" \
                                       "$mtools_path" - 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# Iterate manifest, sha256 source vs disk content per file per partition.
total=0; ok=0; bad=0; missing=0
declare -a BAD_FILES

while IFS=$'\t' read -r where dest src; do
    [ -z "$where" ] && continue
    [ ! -f "$src" ] && { echo "MISSING-SRC  $src"; missing=$((missing+1)); continue; }
    src_sha=$(sha256sum "$src" | awk '{print $1}')
    for pidx in $(file_partitions_for_where "$where"); do
        total=$((total+1))
        disk_sha=$(read_from_partition "$pidx" "$dest" \
                    | sha256sum | awk '{print $1}')
        if [ "$src_sha" = "$disk_sha" ]; then
            ok=$((ok+1))
        else
            bad=$((bad+1))
            BAD_FILES+=("part$((pidx+1)) $dest  src=$src_sha  disk=$disk_sha")
        fi
    done
done < "$MANIFEST"

echo
echo "Verified $total file-copies: $ok OK, $bad bad, $missing missing-source"
if [ $bad -gt 0 ]; then
    echo
    echo "Mismatches:"
    for f in "${BAD_FILES[@]}"; do echo "  $f"; done
    exit 1
fi
