#!/bin/sh
# debug.sh — one-shot UEFI loader gdb session.
#
#   ./debug.sh                  # uses gdb.script
#   ./debug.sh some-other.gdb   # uses an alternate script
#
# Kills any leftover QEMU on :1234, starts a fresh paused instance,
# attaches gdb with the provided script, and tears the QEMU down.

set -e
SCRIPT="${1:-gdb.script}"
[ -r "$SCRIPT" ] || { echo "no script: $SCRIPT" >&2; exit 1; }

# Kill leftovers.
pkill -9 -f 'qemu-system-i386 .* -gdb tcp' 2>/dev/null || true
pkill -9 -f 'qemu-system-i386 .* -s '       2>/dev/null || true
sleep 1

# Start QEMU paused; redirect serial+log so they don't pollute terminal.
"$(dirname "$0")/../boot.sh" --gdb > debug.out 2>&1 &
QEMU_PID=$!
trap 'kill -9 $QEMU_PID 2>/dev/null' EXIT INT TERM

# Wait for the gdb stub to be listening (up to ~5s).
for i in 1 2 3 4 5; do
    if ss -tln 2>/dev/null | grep -q ':1234 '; then break; fi
    sleep 1
done

# Run the gdb script. Output goes to stdout for easy capture.
gdb -batch -nx -x "$SCRIPT" 2>&1
