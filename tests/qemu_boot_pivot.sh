#!/bin/sh
# tests/qemu_boot_pivot.sh — the M4 PIVOT harness (real-rootfs increment).
#
# Boots the built initramfs under the host qemu-system-x86_64 (fx-init as
# rdinit PID1) and asserts fx-init PIVOTED to a materialized tmpfs root
# (pivot_root_to_tmpfs in zig/src/init.zig) BEFORE materializing anything —
# and that the WHOLE boot chain then works ON the new root:
#
#   (a) 'fx-init: pivoted to tmpfs root (magic 0x1021994)' present — the
#       proof line.  It prints ONLY when the /proc/mounts root entry's fstype
#       is "tmpfs" AND statfs("/") reports TMPFS_MAGIC; on the initramfs root
#       the mounts entry reads fstype "rootfs" (MEASURED on the pinned
#       kernel), so the line cannot appear without the pivot.  Note the
#       statfs magic ALONE proves nothing here: with CONFIG_TMPFS=y the
#       initramfs rootfs is tmpfs-backed and reports the SAME magic — the
#       fstype is the discriminator, the magic the belt.
#   (b) the contrasting diagnostic '— pivot not attempted' ABSENT (a
#       mis-wired gate must be VISIBLE as a failure, not a silent skip).
#   (c) 'fx-init: boot-ok v<N>' for the EXACT activated version N — dhake
#       materialization (/etc /bin /run), service spawn, grace-window
#       verdict and the runtime commit all ran on the NEW root.
#   (d) 'fx-init: disk store mounted (current v' still present — the ext4
#       disk store mount TRAVELLED into the new root (MS_MOVE) and the store
#       opened from there afterwards.
#
# NEGATIVE CONTROL: QEMU_CONFIG=m3/config-bad-exit.dhall must FAIL (exit 1)
# with 'fx-init: boot-FAILED v' — the same harness that is green on good goes
# red on bad, ON the new root (asymmetry: the pivot cannot be masking a
# broken verdict path).
#
# Provisioning is TOOLCHAIN-FREE and cloned from tests/qemu_boot.sh (this
# harness does not refactor it): zig build this repo + activate_paths closure
# dirs + the prebuilt assimilated dhake.com APE + a static zig-cc fakesvc.
# Same kernel pin + skip-77 contract as qemu_boot.sh.
#
# Env: FXSTORE/FX_ACTIVATE/FX_INIT_BIN/FX_SIBLINGS/QEMU_CONFIG/
#      QEMU_BOOT_TIMEOUT/QEMU_DISK/QEMU_KEEP — same contract as qemu_boot.sh.
set -u

fail() { echo "qemu-pivot: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-pivot: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v timeout >/dev/null 2>&1 || skip "timeout not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found (disk store)"
[ -e /dev/kvm ]                   || skip "/dev/kvm absent (v1 requires kvm for a fast deterministic timeout)"
[ -w /dev/kvm ]                   || skip "/dev/kvm not writable"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
QEMU_CONFIG="${QEMU_CONFIG:-$REPO/m3/config-good.dhall}"
QEMU_BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-90}"

# ─── kernel pin (scripts/kernel-pin.txt; same contract as qemu_boot.sh) ───
PIN="$REPO/scripts/kernel-pin.txt"
[ -f "$PIN" ] || skip "scripts/kernel-pin.txt missing"
KERNEL=$(sed -n 's/^path //p' "$PIN")
WANT_SHA=$(sed -n 's/^sha256 //p' "$PIN")
[ -n "$KERNEL" ] && [ -n "$WANT_SHA" ] || skip "kernel pin file malformed"
[ -r "$KERNEL" ] || skip "pinned kernel not readable: $KERNEL"
GOT_SHA=$(sha256sum "$KERNEL" | awk '{print $1}')
[ "$GOT_SHA" = "$WANT_SHA" ] || fail "kernel pin mismatch (want $WANT_SHA, got $GOT_SHA for $KERNEL)"

# ─── scratch ──────────────────────────────────────────────────────────────
SCRATCH="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$SCRATCH/qemupivot.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-pivot: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
STORE="$WORK/store"
ROOT="$WORK/root"
mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp"

# ─── provisioning (toolchain-free path; cloned from qemu_boot.sh) ─────────
FXS="${FXSTORE:-}"
FXA="${FX_ACTIVATE:-}"
if [ -z "$FXS" ] || [ -z "$FXA" ]; then
    echo "=== qemu-pivot: toolchain-free provisioning (no cosmocc/stage3 needed) ==="
    command -v zig >/dev/null 2>&1 || skip "zig not found (build the zig port or set FXSTORE+FX_ACTIVATE)"
    export FX_SIBLINGS="${FX_SIBLINGS:-$(cd "$REPO/.." && pwd)}"
    [ -f "$FX_SIBLINGS/datalog-dafsa/zig-out/lib/libdatalog.so" ] \
        || skip "libdatalog.so missing at $FX_SIBLINGS/datalog-dafsa/zig-out/lib"
    [ -x "$FX_SIBLINGS/dhake/dhake.com" ] || skip "prebuilt dhake.com missing"

    echo "--- zig build (this repo) ---"
    # NOTE (qemu_boot.sh): the default install step also builds log_probe_live,
    # which fails on hosts with an unpopulated vendor/datalog-dafsa submodule
    # (missing dl.h) — pre-existing, unrelated to the image path.  Gate on the
    # binaries this harness needs, not the step's aggregate exit.
    #
    # The build's EXIT CODE is the stale-binary check.  An mtime heuristic
    # ("is any source newer than fx-init?") was tried here and is UNSOUND:
    # `zig build` is content-hash cached, so a `touch` (a git checkout, an
    # editor save, a scratch file added and removed) relinks nothing and
    # leaves the binary older than the sources even though it is perfectly
    # current — it fired on healthy builds.  The condition that actually
    # matters is "did the build fail, leaving the previous binary in place",
    # and the exit code answers exactly that.  (It was unavailable when the
    # heuristic was added: `zig build` failed on an unrelated vendored-header
    # gap, so the harness gated on binaries and discarded this status.  That
    # gap is fixed, so the sound instrument is usable.)
    if ! ( cd "$REPO/zig" && zig build ) >/dev/null 2>&1; then
        fail "zig build failed — refusing to test a possibly stale binary (run 'cd zig && zig build' and read its errors)"
    fi
    ZB="$REPO/zig/zig-out/bin"
    DL="$FX_SIBLINGS/datalog-dafsa/zig-out/lib"
    for b in fx-init fx-activate fxctl activate_paths; do
        [ -x "$ZB/$b" ] || fail "zig build did not produce zig-out/bin/$b"
    done

    cp "$FX_SIBLINGS/dhake/dhake.com" "$WORK/dhake.com"
    chmod +x "$WORK/dhake.com"
    "$WORK/dhake.com" --assimilate || fail "dhake --assimilate failed"
    file "$WORK/dhake.com" 2>/dev/null | grep -q 'statically linked' \
        || skip "dhake.com did not assimilate to a static ELF on this host"

    ( cd "$REPO" && zig cc -target x86_64-linux-musl -std=gnu11 -O2 -static \
        -o "$WORK/fakesvc" tests/fixtures/fakesvc/fakesvc.c ) \
        || fail "zig cc fakesvc failed"

    echo "--- provisioning store closure at $STORE ---"
    PATHS=$(LD_LIBRARY_PATH="$DL" "$ZB/activate_paths" \
        --store "$STORE" --package-set "$REPO/m3/package-set.dhall" \
        dhake fx-init fxctl fx-activate fake-service datalog-dafsa dhall-c fxstore) \
        || fail "activate_paths failed"
    [ -n "$PATHS" ] || fail "activate_paths printed no closure"
    echo "$PATHS" | while IFS= read -r pd; do
        mkdir -p "$STORE/$pd" || exit 1
        case "$pd" in
            *-fx-init)        cp "$ZB/fx-init"        "$STORE/$pd/fx-init"; chmod 755 "$STORE/$pd/fx-init" ;;
            *-fxctl)          cp "$ZB/fxctl"          "$STORE/$pd/fxctl";   chmod 755 "$STORE/$pd/fxctl" ;;
            *-fx-activate)    cp "$ZB/fx-activate"    "$STORE/$pd/fx-activate"; chmod 755 "$STORE/$pd/fx-activate" ;;
            *-fake-service)   cp "$WORK/fakesvc"      "$STORE/$pd/fakesvc"; chmod 755 "$STORE/$pd/fakesvc" ;;
            *-dhake)          cp "$WORK/dhake.com"    "$STORE/$pd/dhake.com"; chmod 755 "$STORE/$pd/dhake.com" ;;
            *)                : > "$STORE/$pd/.provisioned-by-qemu-pivot" ;;
        esac
    done
    FXINIT_TEST="${FX_INIT_BIN:-$ZB/fx-init}"
    [ -x "$FXINIT_TEST" ] || fail "fx-init not executable: $FXINIT_TEST"
    FXD=$(ls -d "$STORE"/*-fx-init | head -1)
    cp "$FXINIT_TEST" "$FXD/fx-init"
    FXA="$ZB/fx-activate"
fi

# ─── activate the config (both paths use the REAL fx-activate) ────────────
FXACT="${FX_ACTIVATE:-$FXA}"
[ -n "$FXACT" ] || fail "no fx-activate (set FX_ACTIVATE or let the toolchain-free path build it)"
[ -x "$FXACT" ] || skip "fx-activate not executable: $FXACT"
DLDIR="${FX_DATALOG_LIB:-$(cd "$REPO/.." && pwd)/datalog-dafsa/zig-out/lib}"
[ -f "$DLDIR/libdatalog.so" ] || skip "libdatalog.so not found at $DLDIR"

case "$QEMU_CONFIG" in /*) ;; *) QEMU_CONFIG="$REPO/$QEMU_CONFIG" ;; esac
[ -r "$QEMU_CONFIG" ] || skip "config not readable: $QEMU_CONFIG"

echo "=== qemu-pivot: activating $(basename "$QEMU_CONFIG") ==="
ACT_OUT=$(LD_LIBRARY_PATH="$DLDIR" "$FXACT" --store "$STORE" \
    --package-set "$REPO/m3/package-set.dhall" --config "$QEMU_CONFIG" 2>&1) \
    || fail "activate failed: $ACT_OUT"
echo "$ACT_OUT"
V=$(echo "$ACT_OUT" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V" ] || fail "cannot parse version from activate output: $ACT_OUT"

# ─── build the image + the persistent disk ────────────────────────────────
echo "=== qemu-pivot: building initramfs ==="
sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/initrd.cpio.gz" \
    || fail "mkinitramfs failed"

DISK="${QEMU_DISK:-$WORK/disk.img}"
if [ ! -f "$DISK" ]; then
    qemu-img create -q "$DISK" 512M || fail "qemu-img create failed"
fi
DISK_SHA_BEFORE=$(sha256sum "$DISK" | awk '{print $1}')

FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

# ─── boot it ──────────────────────────────────────────────────────────────
echo "=== qemu-pivot: booting (rdinit=$RDINIT, expecting v$V on the PIVOTED root, disk=$DISK) ==="
CONSOLE="$WORK/console.log"
: > "$CONSOLE"
timeout "$QEMU_BOOT_TIMEOUT" qemu-system-x86_64 \
    -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
    -kernel "$KERNEL" -initrd "$WORK/initrd.cpio.gz" \
    -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
    -nographic -no-reboot -monitor none -serial file:"$CONSOLE" \
    -drive file="$DISK",format=raw,if=virtio \
    >"$WORK/qemu.out" 2>&1
QRC=$?

dump() { echo "--- last 40 console lines ---"; tail -40 "$CONSOLE"; }

# (d) the disk-store line FIRST: if the disk path broke, every later
# assertion is explained by that, and the dump says so.
if ! grep -q 'fx-init: disk store mounted (current v' "$CONSOLE"; then
    dump
    fail "(d) no 'disk store mounted' line — the disk store path did not run"
fi
if grep -q 'disk store disabled\|insmod .* FAILED' "$CONSOLE"; then
    dump
    fail "(d) disk store bring-up FAILED (insmod/mkfs/mount)"
fi

# (b) the contrasting diagnostic must be ABSENT: its presence means the gate
# rejected the boot (mis-wired) or a pivot step warned and returned.
if grep -q -- '— pivot not attempted' "$CONSOLE"; then
    dump
    fail "(b) 'pivot not attempted' diagnostic present — the pivot gate rejected this boot"
fi
if grep -q 'staying on initramfs root' "$CONSOLE"; then
    dump
    fail "(b) a pivot step failed and returned ('staying on initramfs root')"
fi

# (a) the proof line: /proc/mounts fstype "tmpfs" + TMPFS magic at / — both
# impossible on the initramfs root (fstype "rootfs" there; MEASURED).
if ! grep -q 'fx-init: pivoted to tmpfs root (magic 0x1021994)' "$CONSOLE"; then
    dump
    fail "(a) no pivot proof line — the pivot did not happen on this boot"
fi

# (c) the whole chain ON the new root: the verdict for the EXACT version.
# The negative control (config-bad-exit) MUST go red here with boot-FAILED.
if grep -q 'fx-init: boot-FAILED' "$CONSOLE"; then
    dump
    fail "(c) boot-FAILED (want boot-ok v$V) — negative control red as designed"
fi
if grep -q "fx-init: boot-ok v$V" "$CONSOLE"; then
    # PERSISTENCE belt (same as qemu_boot.sh): the disk must have been written.
    DISK_SHA_AFTER=$(sha256sum "$DISK" | awk '{print $1}')
    if [ "$DISK_SHA_BEFORE" = "$DISK_SHA_AFTER" ]; then
        fail "disk.img unchanged by the boot — the store was not written to disk"
    fi
    echo "qemu-pivot: PASS (pivoted to tmpfs root; boot-ok v$V on the NEW root; disk store travelled with it)"
    exit 0
fi
# timeout / crash / silent death
echo "--- qemu exit $QRC; last 40 console lines ---"
tail -40 "$CONSOLE"
[ -s "$WORK/qemu.out" ] && { echo "--- qemu stderr ---"; tail -5 "$WORK/qemu.out"; }
fail "(c) no boot-ok v$V verdict within ${QEMU_BOOT_TIMEOUT}s (exit $QRC)"
