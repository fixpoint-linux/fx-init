#!/bin/sh
# scripts/fx-image-run.sh — boot a fx-image-built raw image under the host
# qemu (the fx-image 'run' convenience; the plan's P5).
#
# Boots with NO -kernel/-initrd — the image's own MBR/FX-header boot region
# carries the kernel + initrd (that is the whole point of the artifact).
# The serial console shows the full chain: stage1/stage2 debugcon markers,
# the kernel banner, and fx-init's verdict.
#
# -cpu host (same as tests/qemu_boot.sh): the zig-native fx-init binary
# uses instructions the default qemu64 CPU model lacks — without it fx-init
# traps 'invalid opcode' as PID1 and panic=-1 reboot-loops.
#
# usage: scripts/fx-image-run.sh IMAGE.raw [extra qemu args...]
#   FX_IMAGE_RUN_LOG  capture the serial console to this file (default:
#                     a mktemp file whose tail is printed on exit)
#   FX_IMAGE_TIMEOUT  seconds before the run is killed (default 60)
set -u

fail() { echo "fx-image-run: FAIL: $*" >&2; exit 1; }
skip() { echo "fx-image-run: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v timeout >/dev/null 2>&1        || skip "timeout not found"

[ $# -ge 1 ] || fail "usage: scripts/fx-image-run.sh IMAGE.raw [extra qemu args...]"
IMG=$1; shift
[ -f "$IMG" ] || fail "image not found: $IMG"
case "$IMG" in /*) ;; *) IMG="$(pwd)/$IMG" ;; esac

LOG="${FX_IMAGE_RUN_LOG:-$(mktemp "${TMPDIR:-/tmp}/fximg-run.XXXXXX.log")}"
TIMEOUT="${FX_IMAGE_TIMEOUT:-60}"

cleanup() { [ -n "${FX_IMAGE_RUN_LOG:-}" ] || rm -f "$LOG"; }
trap cleanup EXIT

echo "fx-image-run: booting $IMG (console -> $LOG, ${TIMEOUT}s cap)"
timeout "$TIMEOUT" qemu-system-x86_64 \
    -machine q35 -accel kvm -cpu host -m 2048 \
    -nographic \
    -drive file="$IMG",format=raw,if=virtio \
    "$@" >"$LOG.run" 2>&1
RC=$?
cat "$LOG" 2>/dev/null
[ -s "$LOG.run" ] && tail -5 "$LOG.run"
echo "fx-image-run: qemu exited $RC after ${TIMEOUT}s (console above; full log $LOG)"
exit "$RC"
