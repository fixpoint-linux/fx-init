#!/bin/sh
# tests/qemu_boot.sh — the M4 QEMU boot harness (image increment).
#
# Boots the built initramfs under the host qemu-system-x86_64 (-kernel/
# -initrd, fx-init as rdinit PID1) and asserts the serial console carries
# 'fx-init: boot-ok v<N>' for the EXACT activated version N.  The verdict
# line is emitted by fx-init's own boot-decision branch (zig/src/init.zig
# evaluate_boot_ok / reap_children), so the run proves the whole chain:
# kernel unpacked the gzip'd cpio, mount_early brought up /proc /sys /dev,
# the store opened from /fx/store inside the ramfs, decide_boot_version found
# the activated generation, dhake materialized /etc + /bin, the service
# spawned + reported started within the grace window, and the datalog runtime
# committed boot_status(ok) — with no host-side fxctl involved.
#
# This harness is SELF-CONTAINED: it builds everything it needs into its own
# scratch dir and SKIPS LOUDLY (exit 77) for every missing host tool.  It is
# the THIRD boot path, alongside tests/fxinit_boot.sh (bwrap) and
# tests/fxinit_pid1.sh (nested PID ns) — neither is modified.
#
# STORE PROVISIONING — two paths, first available wins:
#   (a) TOOLCHAIN-FREE (default; needs NO cosmocc and NO palisade stage3):
#       `zig build` this repo (sibling checkouts via FX_SIBLINGS, exactly the
#       m3 recipes' env), then provision the store with activate_paths (the
#       repo's own differential-harness helper: prints each closure dir
#       <hash>-<name>; fx-activate only stats dir-ness) filling each dir with
#       the real payload — the zig-built fx-init/fxctl/fx-activate, the
#       PREBUILT dhake.com APE (--assimilated to a static ELF so the guest
#       needs neither the sh-preamble tools nor its dynamic libs), fakesvc
#       cross-compiled STATIC with `zig cc -target x86_64-linux-musl`.
#   (b) FXSTORE + FX_ACTIVATE env (the fxinit_boot.sh contract): a
#       fxstore-built store + a store-built fx-activate; provisioning is the
#       caller's job.  Present only so the same harness runs on a full host.
#
# Env:
#   FXSTORE       path to a built fxstore binary       (enables path (b))
#   FX_ACTIVATE   path to the fx-activate under test   (enables path (b))
#   FX_INIT_BIN   override the fx-init under test      (default: zig-built)
#   QEMU_CONFIG   config to activate (default m3/config-good.dhall; the
#                 negative control sets m3/config-bad-exit.dhall and expects
#                 boot-FAILED + exit 1)
#   QEMU_BOOT_TIMEOUT  seconds to wait for the verdict (default 90)
#   FX_SIBLINGS   dir with the sibling checkouts (default: repo ../..)
set -u

fail() { echo "qemu-boot: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-boot: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v timeout >/dev/null 2>&1 || skip "timeout not found"
[ -e /dev/kvm ]                   || skip "/dev/kvm absent (v1 requires kvm for a fast deterministic timeout)"
[ -w /dev/kvm ]                   || skip "/dev/kvm not writable"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
QEMU_CONFIG="${QEMU_CONFIG:-$REPO/m3/config-good.dhall}"
QEMU_BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-90}"

# ─── kernel pin (scripts/kernel-pin.txt) ──────────────────────────────────
PIN="$REPO/scripts/kernel-pin.txt"
[ -f "$PIN" ] || skip "scripts/kernel-pin.txt missing"
KERNEL=$(sed -n 's/^path //p' "$PIN")
WANT_SHA=$(sed -n 's/^sha256 //p' "$PIN")
[ -n "$KERNEL" ] && [ -n "$WANT_SHA" ] || skip "kernel pin file malformed (needs 'path ...' + 'sha256 ...')"
[ -r "$KERNEL" ] || skip "pinned kernel not readable: $KERNEL"
GOT_SHA=$(sha256sum "$KERNEL" | awk '{print $1}')
# a missing/unreadable/malformed pin skips (this host lacks the fixture), but
# a sha MISMATCH fails: a foreign or mutated kernel must never silently
# disable the test (a check that can only skip tests nothing).
[ "$GOT_SHA" = "$WANT_SHA" ] || fail "kernel pin mismatch — update scripts/kernel-pin.txt (want $WANT_SHA, got $GOT_SHA for $KERNEL)"

# ─── scratch ──────────────────────────────────────────────────────────────
SCRATCH="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$SCRATCH/qemuboot.XXXXXX")" || fail mktemp
trap 'rm -rf "$WORK"' EXIT
STORE="$WORK/store"
ROOT="$WORK/root"
mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp"

# ─── provisioning path (a): toolchain-free ────────────────────────────────
FXS="${FXSTORE:-}"
FXA="${FX_ACTIVATE:-}"
if [ -z "$FXS" ] || [ -z "$FXA" ]; then
    echo "=== qemu-boot: toolchain-free provisioning (no cosmocc/stage3 needed) ==="
    command -v zig >/dev/null 2>&1 || skip "zig not found (build the zig port or set FXSTORE+FX_ACTIVATE)"
    export FX_SIBLINGS="${FX_SIBLINGS:-$(cd "$REPO/.." && pwd)}"
    [ -f "$FX_SIBLINGS/datalog-dafsa/zig-out/lib/libdatalog.so" ] \
        || skip "libdatalog.so missing at $FX_SIBLINGS/datalog-dafsa/zig-out/lib (build the sibling)"
    [ -x "$FX_SIBLINGS/dhake/dhake.com" ] || skip "prebuilt dhake.com missing at $FX_SIBLINGS/dhake/dhake.com"

    echo "--- zig build (this repo; sibling checkouts at $FX_SIBLINGS) ---"
    # NOTE: the default install step also builds log_probe_live, which fails
    # on hosts with an unpopulated vendor/datalog-dafsa submodule (missing
    # dl.h) — pre-existing, unrelated to the image path.  Gate on the
    # binaries this harness needs, not the step's aggregate exit.
    ( cd "$REPO/zig" && zig build ) >/dev/null 2>&1
    ZB="$REPO/zig/zig-out/bin"
    DL="$FX_SIBLINGS/datalog-dafsa/zig-out/lib"
    for b in fx-init fx-activate fxctl activate_paths; do
        [ -x "$ZB/$b" ] || fail "zig build did not produce zig-out/bin/$b"
    done

    # assimilate the APE dhake to a static ELF (drops the sh-preamble's
    # gzip/dd/uname tool + $TMPDIR/APE-loader dependencies in the guest)
    cp "$FX_SIBLINGS/dhake/dhake.com" "$WORK/dhake.com"
    chmod +x "$WORK/dhake.com"
    "$WORK/dhake.com" --assimilate || fail "dhake --assimilate failed"
    file "$WORK/dhake.com" 2>/dev/null | grep -q 'statically linked' \
        || skip "dhake.com did not assimilate to a static ELF on this host"

    # static fakesvc via zig cc (musl): the m3 recipe uses cosmocc; zig cc
    # produces the same static behavior with no toolchain install
    ( cd "$REPO" && zig cc -target x86_64-linux-musl -std=gnu11 -O2 -static \
        -o "$WORK/fakesvc" tests/fixtures/fakesvc/fakesvc.c ) \
        || fail "zig cc fakesvc failed"

    # the closure dirs activate_paths prints, each filled with its payload.
    # fx-activate only stats dir-ness (fx-activate.c:545 in the C-oracle era;
    # activate_paths exists precisely to pre-create them in the diff harness).
    # The payloads must match the package-set TARGETS: fx-init fxctl
    # fx-activate fakesvc from zig cc, dhake from the prebuilt APE; the
    # datalog-dafsa/dhall-c/fxstore deps' targets are only hashed inputs, so
    # their dirs carry a marker file (their CONTENT never executes at boot).
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
            *)                : > "$STORE/$pd/.provisioned-by-qemu-boot" ;;
        esac
    done
    FXINIT_TEST="${FX_INIT_BIN:-$ZB/fx-init}"
    [ -x "$FXINIT_TEST" ] || fail "fx-init not executable: $FXINIT_TEST"
    # the fx-init under test replaces the provisioned one (same content hash
    # dir; FX_INIT_BIN lets a caller diff a variant)
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

echo "=== qemu-boot: activating $(basename "$QEMU_CONFIG") ==="
ACT_OUT=$(LD_LIBRARY_PATH="$DLDIR" "$FXACT" --store "$STORE" \
    --package-set "$REPO/m3/package-set.dhall" --config "$QEMU_CONFIG" 2>&1) \
    || fail "activate failed: $ACT_OUT"
echo "$ACT_OUT"
# "activated <genhash> as version <N>; buildfile <path>"
V=$(echo "$ACT_OUT" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V" ] || fail "cannot parse version from activate output: $ACT_OUT"

# ─── build the image ───────────────────────── provisioning done; assemble
echo "=== qemu-boot: building initramfs ==="
sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/initrd.cpio.gz" \
    || fail "mkinitramfs failed"

# rdinit target: the store's fx-init (guest-absolute)
FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

# ─── boot it ──────────────────────────────────────────────────────────────
echo "=== qemu-boot: booting (rdinit=$RDINIT, expecting version v$V) ==="
CONSOLE="$WORK/console.log"
: > "$CONSOLE"
timeout "$QEMU_BOOT_TIMEOUT" qemu-system-x86_64 \
    -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
    -kernel "$KERNEL" -initrd "$WORK/initrd.cpio.gz" \
    -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
    -nographic -no-reboot -monitor none -serial file:"$CONSOLE" \
    >"$WORK/qemu.out" 2>&1
QRC=$?

# the verdict line is unique to fx-init's boot-decision branches.  The
# harness asserts the activated version booted OK — a bad config (the
# negative control: QEMU_CONFIG=m3/config-bad-exit.dhall) MUST go red here
# with boot-FAILED on the console: the same harness that is green on good.
if grep -q 'fx-init: boot-FAILED' "$CONSOLE"; then
    echo "--- last 40 console lines ---"; tail -40 "$CONSOLE"
    fail "boot-FAILED v (want boot-ok v$V) — negative control red as designed"
fi
if grep -q "fx-init: boot-ok v$V" "$CONSOLE"; then
    echo "qemu-boot: PASS (boot-ok v$V on serial)"
    exit 0
fi
# timeout / crash / silent death
echo "--- qemu exit $QRC; last 40 console lines ---"
tail -40 "$CONSOLE"
[ -s "$WORK/qemu.out" ] && { echo "--- qemu stderr ---"; tail -5 "$WORK/qemu.out"; }
fail "no boot-ok v$V verdict within ${QEMU_BOOT_TIMEOUT}s (exit $QRC)"
