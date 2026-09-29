#!/bin/sh
# tests/pivot_gate_reject.sh — POSITIVE test for the pivot gate's rejection
# diagnostic (the FIX-2 test gap from the image-pivot review).
#
# tests/fxinit_pid1.sh asserts the same diagnostic where it is EXPECTED (its
# PID1 boots on the host fs), but that harness needs FXSTORE + a nested
# userns and SKIPS on most hosts.  This one is the cheapest rung that can
# actually run anywhere unshare works: run the REAL zig-built fx-init as the
# genuine PID1 of a fresh PID namespace whose root is the HOST filesystem
# (fstype btrfs/overlay/whatever — anything but an initramfs "rootfs"), and
# assert the gate REJECTS it loudly:
#
#   fx-init: root fstype is 'btrfs' (not rootfs) — pivot not attempted
#
# Why this is the gate-rejection path and not something else: the pivot gate
# (pivot_root_to_tmpfs, zig/src/init.zig) fires only when getpid()==1 AND the
# /proc/mounts root entry's fstype is "rootfs".  Here fx-init IS PID1 (the
# unshare --pid --fork child) and the root fstype is the host's — the one
# combination where the SECOND condition must reject, visibly.  A regression
# that silences, rewords, or mis-wires the diagnostic (e.g. a wrong ROOTFS_FST
# literal, or the gate passing on a non-initramfs root) fails this test.
#
# Safety: nothing is pivoted (that is the point), no store is required (an
# empty dir makes the boot fail AFTER the gate line), and ensure_disk_store is
# inert here — no /dev/vda in a --mount-proc namespace's own devtmpfs view
# means it returns before touching anything (and ext4 mounts are EPERM from a
# user namespace regardless).
#
# Env:
#   FX_INIT_BIN  fx-init under test (default: the zig-built zig-out/bin/fx-init)
#   FX_DATALOG_LIB  dir with libdatalog.so (default: sibling datalog-dafsa)
set -u

fail() { echo "pivot-gate: FAIL: $*" >&2; exit 1; }
skip() { echo "pivot-gate: SKIP ($*)"; exit 77; }

command -v unshare >/dev/null 2>&1 || skip "unshare not found"
command -v timeout >/dev/null 2>&1 || skip "timeout not found"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"

FX_INIT_BIN="${FX_INIT_BIN:-$REPO/zig/zig-out/bin/fx-init}"
[ -x "$FX_INIT_BIN" ] || skip "fx-init not built ($FX_INIT_BIN — run: cd zig && zig build)"
DLDIR="${FX_DATALOG_LIB:-$(cd "$REPO/.." && pwd)/datalog-dafsa/zig-out/lib}"
[ -f "$DLDIR/libdatalog.so" ] || skip "libdatalog.so not found at $DLDIR"

# a userns+pidns must be creatable (rattan-style sandboxes block it)
unshare --user --map-root-user --pid --fork --mount-proc -- true 2>/dev/null \
    || skip "nested user+pid namespace unavailable"

WORK="$(mktemp -d -t pivotgate.XXXXXX)" || fail mktemp
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/store" "$WORK/run"   # EMPTY store: boot fails AFTER the gate

# fx-init as the namespace's genuine PID1.  --kill-child=TERM tears the whole
# namespace down when we kill unshare (fx-init otherwise loops forever).
LD_LIBRARY_PATH="$DLDIR" timeout 30 \
    unshare --user --map-root-user --pid --fork --mount-proc --kill-child=TERM \
    -- "$FX_INIT_BIN" --store "$WORK/store" --run-dir "$WORK/run" \
    >"$WORK/out" 2>&1 &
UPID=$!

# the gate line prints early in main (before any store work); a moment is
# enough, then assert and tear down — no need to wait for the boot verdict.
for i in 1 2 3 4 5 6 7 8 9 10; do
    grep -q 'pivot not attempted' "$WORK/out" 2>/dev/null && break
    kill -0 "$UPID" 2>/dev/null || break
    sleep 0.5
done

if grep -q -- '— pivot not attempted' "$WORK/out" 2>/dev/null; then
    echo "gate rejection OK: $(grep -m1 'pivot not attempted' "$WORK/out")"
else
    { echo "--- fx-init console ($WORK/out) ---"; cat "$WORK/out" 2>/dev/null; }
    kill "$UPID" 2>/dev/null
    wait "$UPID" 2>/dev/null
    fail "the pivot gate did NOT reject this non-initramfs PID1 root (no 'pivot not attempted' diagnostic)"
fi

kill "$UPID" 2>/dev/null
wait "$UPID" 2>/dev/null

# the gate must have rejected BEFORE any pivot step ran: no pivot warnings,
# no proof line — silence here is the gate never entering the sequence.
if grep -q 'staying on initramfs root\|pivoted to tmpfs root' "$WORK/out" 2>/dev/null; then
    { echo "--- fx-init console ($WORK/out) ---"; cat "$WORK/out" 2>/dev/null; }
    fail "a pivot step RAN on a non-initramfs root (gate passed when it should reject)"
fi

echo "pivot-gate: PASS"
