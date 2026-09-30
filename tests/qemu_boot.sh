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
# Sources are FROZEN into the scratch dir before anything else (see the
# freeze_src block below): the fxstore derivation hash content-addresses
# each package's whole clean src tree, and the shared sibling checkouts can
# be edited concurrently by other agents — the same shield as
# qemu_boot_rollback.sh / qemu_ctrl.sh.
#
# Env:
#   FXSTORE       path to a built fxstore binary       (enables path (b))
#   FX_ACTIVATE   path to the fx-activate under test   (enables path (b))
#   FX_INIT_BIN   override the fx-init under test      (default: zig-built)
#   QEMU_CONFIG   config to activate (default m3/config-good.dhall; the
#                 negative control sets m3/config-bad-exit.dhall and expects
#                 boot-FAILED + exit 1)
#   QEMU_BOOT_TIMEOUT  seconds to wait for the verdict (default 90)
#   QEMU_DISK     path to the virtio disk image (default: a fresh 512M
#                 qemu-img in the scratch dir; the rollback harness points
#                 this at ONE shared disk across its 3 boots)
#   QEMU_STORE_ARG  fx.store= value appended to the kernel command line
#                 (default /fx/store — today's value, so the default run is
#                 unchanged; B5: fx-init parses it as the pre-disk store, and
#                 the banner assertion below proves it with a non-default)
#   FX_SIBLINGS   dir with the sibling checkouts (default: repo ../..)
#   QEMU_KEEP=1   keep the scratch dir (debugging; prints its path)
set -u

fail() { echo "qemu-boot: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-boot: SKIP ($*)"; exit 77; }

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

# ─── pinned kernel (scripts/kernel-pin.txt via scripts/fetch-kernel.sh) ───
# The kernel is FETCHED from the pinned RPM and hash-verified — never the
# build host's /boot (removing that host dependency is this increment).
# fetch-kernel exit: 0 = verified cache, 77 = offline (SKIP loudly — there
# is deliberately NO host-kernel fallback), anything else = real failure.
PIN="$REPO/scripts/kernel-pin.txt"
[ -f "$PIN" ] || skip "scripts/kernel-pin.txt missing"
FETCH_OUT=$(sh "$REPO/scripts/fetch-kernel.sh" 2>&1)
FETCH_RC=$?
echo "$FETCH_OUT"
[ "$FETCH_RC" = 0 ] || [ "$FETCH_RC" = 77 ] || fail "fetch-kernel failed (rc=$FETCH_RC)"
[ "$FETCH_RC" = 0 ] || skip "pinned kernel artifact unavailable (offline) — no host-kernel fallback by design"
KERNEL="${FX_KERNEL_CACHE:-$REPO/.kernel-cache}/kernel/vmlinuz"
WANT_SHA=$(sed -n 's/^vmlinuz_sha256 //p' "$PIN")
[ -n "$WANT_SHA" ] || skip "kernel pin file malformed (needs 'vmlinuz_sha256 ...')"
[ -r "$KERNEL" ] || skip "fetched vmlinuz missing at $KERNEL"
GOT_SHA=$(sha256sum "$KERNEL" | awk '{print $1}')
# a missing/unreadable/malformed pin skips (this host lacks the fixture), but
# a sha MISMATCH fails: a foreign or mutated kernel must never silently
# disable the test (a check that can only skip tests nothing).
[ "$GOT_SHA" = "$WANT_SHA" ] || fail "kernel pin mismatch — update scripts/kernel-pin.txt (want $WANT_SHA, got $GOT_SHA for $KERNEL)"

# ─── scratch ──────────────────────────────────────────────────────────────
SCRATCH="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$SCRATCH/qemuboot.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-boot: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
STORE="$WORK/store"
ROOT="$WORK/root"
mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp"

# ─── freeze the package sources ────────────────────────────────────────────
# The fxstore derivation hash content-addresses each package's WHOLE clean
# src tree, and the shared sibling checkouts (../../datalog-dafsa etc.) can
# be MODIFIED CONCURRENTLY by their own agents/runs (MEASURED: activation
# reported the closure "not built" because the tree hash drifted between
# this harness's provisioning step and its activation step).  EVERY hash
# computation below — provisioning AND activation — must see the same
# trees, so freeze FIRST and run everything against the frozen copies:
#   - snapshot the siblings + the repo src into the scratch dir, skipping
#     exactly the trees the clean walk itself excludes (copying them would
#     only waste space; skipping them keeps the snapshot's clean-tree hash
#     identical to the live tree's at snapshot time);
#   - rewrite m3/package-set.dhall's `Path = "..."` values to the frozen
#     absolute locations (relative paths resolve against the package-set
#     file, which is why the rewrite must be total).
# This is a HARNESS-only stabilization: it changes no store semantics.
freeze_src() { # freeze_src SRC DST
    mkdir -p "$2"
    ( cd "$1" && find . \
        -not -path "./.git/*"       -not -name ".git" \
        -not -path "./build-tmp/*"  -not -name "build-tmp" \
        -not -path "./zig-out/*"    -not -name "zig-out" \
        -not -path "./zig/zig-out/*" \
        -not -path "./zig/.zig-cache/*" -not -path "./zig/.zig-global/*" \
        -not -path "./node_modules/*" -not -name "node_modules" \
        -not -path "./elm-stuff/*" -not -name "elm-stuff" \
        -not -path "./dist/*"     -not -name "dist" \
        -not -name "*.o" -not -name "*.a" -not -name "*.so" -not -name "*.com" \
        -not -name "dl-test-*" -not -name ".ape-*" \
        -print0 | cpio -pdm0 "$2" ) >/dev/null 2>&1 \
        || fail "cannot snapshot $1 -> $2"
}
echo "=== qemu-boot: freezing package sources (concurrent-writer shield) ==="
SIBS="$(cd "$REPO/.." && pwd)"
mkdir -p "$WORK/frozen/siblings"
freeze_src "$SIBS/datalog-dafsa" "$WORK/frozen/siblings/datalog-dafsa"
freeze_src "$SIBS/dhall-c"       "$WORK/frozen/siblings/dhall-c"
freeze_src "$SIBS/fxstore"       "$WORK/frozen/siblings/fxstore"
freeze_src "$REPO"               "$WORK/frozen/fx-init"
sed -e "s|< Path = \"../../datalog-dafsa\" >|< Path = \"$WORK/frozen/siblings/datalog-dafsa\" >|" \
    -e "s|< Path = \"../../dhall-c\" >|< Path = \"$WORK/frozen/siblings/dhall-c\" >|" \
    -e "s|< Path = \"../../fxstore\" >|< Path = \"$WORK/frozen/siblings/fxstore\" >|" \
    -e "s|< Path = \"..\" >|< Path = \"$WORK/frozen/fx-init\" >|" \
    -e "s|< Path = \"../vendor/dhake\" >|< Path = \"$WORK/frozen/fx-init/vendor/dhake\" >|" \
    "$REPO/m3/package-set.dhall" > "$WORK/frozen/package-set.dhall"
grep -q "$WORK/frozen" "$WORK/frozen/package-set.dhall" \
    || fail "package-set rewrite produced no frozen paths"
PKGSET="$WORK/frozen/package-set.dhall"

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
        --store "$STORE" --package-set "$PKGSET" \
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
    --package-set "$PKGSET" --config "$QEMU_CONFIG" 2>&1) \
    || fail "activate failed: $ACT_OUT"
echo "$ACT_OUT"
# "activated <genhash> as version <N>; buildfile <path>"
V=$(echo "$ACT_OUT" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V" ] || fail "cannot parse version from activate output: $ACT_OUT"

# ─── build the image ───────────────────────── provisioning done; assemble
echo "=== qemu-boot: building initramfs ==="
sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/initrd.cpio.gz" \
    || fail "mkinitramfs failed"

# ─── the persistent disk store (M4): a blank virtio-blk image; the GUEST
# insmods virtio_blk+ext4, mkfs.ext2 -F's it, seeds it from the ramfs store
# and mounts it at /fx/disk/store (ensure_disk_store in zig/src/init.zig).
# The host cannot mkfs/populate an fs image as uid 1001 — the guest does.
DISK="${QEMU_DISK:-$WORK/disk.img}"
if [ ! -f "$DISK" ]; then
    qemu-img create -q "$DISK" 512M || fail "qemu-img create failed"
fi
DISK_SHA_BEFORE=$(sha256sum "$DISK" | awk '{print $1}')

# rdinit target: the store's fx-init (guest-absolute)
FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

# ─── boot it ──────────────────────────────────────────────────────────────
echo "=== qemu-boot: booting (rdinit=$RDINIT, expecting version v$V, disk=$DISK) ==="
CONSOLE="$WORK/console.log"
: > "$CONSOLE"
QEMU_STORE_ARG="${QEMU_STORE_ARG:-/fx/store}"
timeout "$QEMU_BOOT_TIMEOUT" qemu-system-x86_64 \
    -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
    -kernel "$KERNEL" -initrd "$WORK/initrd.cpio.gz" \
    -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=$QEMU_STORE_ARG panic=-1 oops=panic" \
    -nographic -no-reboot -monitor none -serial file:"$CONSOLE" \
    -drive file="$DISK",format=raw,if=virtio \
    >"$WORK/qemu.out" 2>&1
QRC=$?

# the disk path ran: fx-init's ensure_disk_store succeeded (the negative
# insmod/mkfs/mount warnings all end in "disk store disabled", so grepping
# for the success line + NOT the disabled marker covers both directions)
if ! grep -q 'fx-init: disk store mounted (current v' "$CONSOLE"; then
    echo "--- last 40 console lines ---"; tail -40 "$CONSOLE"
    fail "no 'disk store mounted' line — the disk store path did not run"
fi
if grep -q 'disk store disabled\|insmod .* FAILED' "$CONSOLE"; then
    echo "--- last 40 console lines ---"; tail -40 "$CONSOLE"
    fail "disk store bring-up FAILED (insmod/mkfs/mount)"
fi
# the banner must name the store the command line carried ($QEMU_STORE_ARG,
# default /fx/store): guards the knob's wiring into -append AND that fx-init
# applied it (boot 2 proves the parse with a non-default; this pins that the
# DEFAULT path parses identically)
if ! grep -q "fx-init: boot start store $QEMU_STORE_ARG" "$CONSOLE"; then
    echo "--- last 40 console lines ---"; tail -40 "$CONSOLE"
    fail "banner does not name the command-line store $QEMU_STORE_ARG"
fi
# PERSISTENCE: the disk image must have been WRITTEN (mkfs/seed), not just
# read — its sha must differ from the pre-boot blank image
DISK_SHA_AFTER=$(sha256sum "$DISK" | awk '{print $1}')
if [ "$DISK_SHA_BEFORE" = "$DISK_SHA_AFTER" ]; then
    fail "disk.img unchanged by the boot — the store was not written to disk"
fi

# the verdict line is unique to fx-init's boot-decision branches.  The
# harness asserts the activated version booted OK — a bad config (the
# negative control: QEMU_CONFIG=m3/config-bad-exit.dhall) MUST go red here
# with boot-FAILED on the console: the same harness that is green on good.
if grep -q 'fx-init: boot-FAILED' "$CONSOLE"; then
    echo "--- last 40 console lines ---"; tail -40 "$CONSOLE"
    fail "boot-FAILED v (want boot-ok v$V) — negative control red as designed"
fi
# timeout / crash / silent death
if ! grep -q "fx-init: boot-ok v$V" "$CONSOLE"; then
    echo "--- qemu exit $QRC; last 40 console lines ---"
    tail -40 "$CONSOLE"
    [ -s "$WORK/qemu.out" ] && { echo "--- qemu stderr ---"; tail -5 "$WORK/qemu.out"; }
    fail "no boot-ok v$V verdict within ${QEMU_BOOT_TIMEOUT}s (exit $QRC)"
fi

# ─── B5: the kernel command line's fx.store= is AUTHORITATIVE for the
# PRE-DISK store (rdinit gets no argv — the command line is the only channel
# a boot has to name one).  Second boot, same image, ONE variable changed:
# fx.store=/fx/store-alt.  The assertion PAIR is the asymmetry the feature
# needs:
#   (a) the banner names /fx/store-alt — with parsing ABSENT the banner
#       prints the built-in default /fx/store and this FAILS (proves the
#       command line was actually read and applied);
#   (b) the boot still SUCCEEDS with the disk store mounted — the disk arm
#       relocated g_store to /fx/disk/store afterwards exactly as before
#       (proves the fx.store= parse did not break the disk path or change
#       its precedence).
STORE_ALT="/fx/store-alt"
CONSOLE2="$WORK/console-alt.log"
DISK2="$WORK/disk-alt.img"
: > "$CONSOLE2"
qemu-img create -q "$DISK2" 512M || fail "qemu-img create (alt) failed"
echo "=== qemu-boot: booting with fx.store=$STORE_ALT (expecting banner + boot-ok v$V) ==="
timeout "$QEMU_BOOT_TIMEOUT" qemu-system-x86_64 \
    -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
    -kernel "$KERNEL" -initrd "$WORK/initrd.cpio.gz" \
    -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=$STORE_ALT panic=-1 oops=panic" \
    -nographic -no-reboot -monitor none -serial file:"$CONSOLE2" \
    -drive file="$DISK2",format=raw,if=virtio \
    >"$WORK/qemu-alt.out" 2>&1
QRC2=$?
if ! grep -q "fx-init: store from kernel command line fx.store=$STORE_ALT" "$CONSOLE2"; then
    echo "--- last 40 console-alt lines ---"; tail -40 "$CONSOLE2"
    fail "no 'store from kernel command line' line for $STORE_ALT (fx.store= not applied?)"
fi
if ! grep -q "fx-init: boot start store $STORE_ALT" "$CONSOLE2"; then
    echo "--- last 40 console-alt lines ---"; tail -40 "$CONSOLE2"
    fail "banner does not name the kernel-command-line store $STORE_ALT (fx.store= not parsed?)"
fi
if ! grep -q 'fx-init: disk store mounted (current v' "$CONSOLE2"; then
    echo "--- last 40 console-alt lines ---"; tail -40 "$CONSOLE2"
    fail "no 'disk store mounted' line with fx.store=$STORE_ALT — the disk arm did not run"
fi
if grep -q 'fx-init: boot-FAILED' "$CONSOLE2"; then
    echo "--- last 40 console-alt lines ---"; tail -40 "$CONSOLE2"
    fail "boot-FAILED with fx.store=$STORE_ALT (disk arm broken by the cmdline store?)"
fi
if ! grep -q "fx-init: boot-ok v$V" "$CONSOLE2"; then
    echo "--- qemu exit $QRC2; last 40 console-alt lines ---"; tail -40 "$CONSOLE2"
    [ -s "$WORK/qemu-alt.out" ] && { echo "--- qemu stderr ---"; tail -5 "$WORK/qemu-alt.out"; }
    fail "no boot-ok v$V with fx.store=$STORE_ALT (exit $QRC2)"
fi
echo "qemu-boot: PASS (boot-ok v$V on serial, cmdline store $STORE_ALT honored pre-disk)"
exit 0
