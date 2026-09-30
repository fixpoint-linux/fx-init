#!/bin/sh
# tests/qemu_boot_rollback.sh — the M4 GENUINE multi-boot roll-forward proof.
#
# Three QEMU boots on ONE shared disk.img, with TWO host-built initramfs
# images (good + bad), proving the store now PERSISTS across boots and that
# fx-init's roll-forward reads a .bootlog a PRIOR boot wrote to the DISK:
#
#   boot 1 (good image, blank disk): the guest mkfs+seeds the disk store
#          from the ramfs store (ensure_disk_store in zig/src/init.zig) and
#          boots v_good ok  -> the disk .bootlog gains "<v_good> ok".
#   boot 2 (bad image):  the disk is seeded and its CURRENT (v_good) is
#          OLDER than the ramfs CURRENT (v_bad), so fx-init ADOPTS the
#          ramfs store onto the disk (PRESERVING the disk .bootlog — the
#          boot history is the whole point), boots v_bad, the crasher
#          fails inside the grace window  -> "<v_bad> failed" is appended
#          to the DISK .bootlog.
#   boot 3 (good image): the disk wins (ramfs v_good <= disk v_bad, no
#          adopt); decide_boot_version reads the DISK .bootlog whose last
#          entry is (v_bad, failed) == CURRENT, finds the newest ok below,
#          and ROLLS FORWARD — a fresh ramfs store cannot produce this
#          line, so the assertion is a persistence proof, not a simulation.
#
# The bad generation is published HOST-SIDE into a SECOND initramfs (the
# host cannot write the disk image as uid 1001 — no mount, no mtools; the
# only in-gguest publication path is fx-init's adopt-ramfs step).  The bad
# store is a COPY of the good store plus one more activation, so v_bad >
# v_good AND the good generation stays published below it in the same store
# DB — exactly what fx_store_rollback needs as its target.
#
# PERSISTENCE BELTS (plan section 3): (a) the disk.img sha256 must CHANGE
# across each boot (writes landed); (b) the roll-forward console line in
# boot 3 is only reachable from a disk .bootlog carrying a PRIOR boot's
# (v_bad, failed); (c) the rolled-to version must be > v_bad (monotonic).
#
# Env: FXSTORE/FX_ACTIVATE/FX_INIT_BIN/FX_SIBLINGS/QEMU_BOOT_TIMEOUT/
#      QEMU_KEEP — same contract as tests/qemu_boot.sh.
set -u

fail() { echo "qemu-rollback: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-rollback: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
[ -e /dev/kvm ]                   || skip "/dev/kvm absent"
[ -w /dev/kvm ]                   || skip "/dev/kvm not writable"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
CFG_GOOD="$REPO/m3/config-good.dhall"
CFG_BAD="$REPO/m3/config-bad-exit.dhall"
BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-90}"

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
WORK="$(mktemp -d "$SCRATCH/qemurb.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-rollback: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
STORE="$WORK/store"
ROOT="$WORK/root"
DISK="$WORK/disk.img"
mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp"

# ─── freeze the package sources ────────────────────────────────────────────
# The fxstore derivation hash content-addresses each package's WHOLE clean
# src tree, and the shared sibling checkouts (../../datalog-dafsa etc.) can
# be MODIFIED CONCURRENTLY by their own test runs (MEASURED: a rebuilt ./dl
# + tests/ writes drifted the hash between this harness's provisioning and
# its second activation, making the latter report the closure "not built").
# EVERY hash computation below — provisioning and both activations — must
# see the same trees, so freeze FIRST and run everything against the frozen
# copies:
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
echo "=== qemu-rollback: freezing package sources (concurrent-writer shield) ==="
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

# ─── provisioning (toolchain-free path; same shape as qemu_boot.sh) ───────
FXS="${FXSTORE:-}"
FXA="${FX_ACTIVATE:-}"
if [ -z "$FXS" ] || [ -z "$FXA" ]; then
    echo "=== qemu-rollback: toolchain-free provisioning ==="
    command -v zig >/dev/null 2>&1 || skip "zig not found (build the zig port or set FXSTORE+FX_ACTIVATE)"
    export FX_SIBLINGS="${FX_SIBLINGS:-$(cd "$REPO/.." && pwd)}"
    [ -f "$FX_SIBLINGS/datalog-dafsa/zig-out/lib/libdatalog.so" ] \
        || skip "libdatalog.so missing at $FX_SIBLINGS/datalog-dafsa/zig-out/lib"
    [ -x "$FX_SIBLINGS/dhake/dhake.com" ] || skip "prebuilt dhake.com missing"

    echo "--- zig build (this repo) ---"
    ( cd "$REPO/zig" && zig build ) >/dev/null 2>&1
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
            *)                : > "$STORE/$pd/.provisioned-by-qemu-rollback" ;;
        esac
    done
    FXINIT_TEST="${FX_INIT_BIN:-$ZB/fx-init}"
    [ -x "$FXINIT_TEST" ] || fail "fx-init not executable: $FXINIT_TEST"
    FXD=$(ls -d "$STORE"/*-fx-init | head -1)
    cp "$FXINIT_TEST" "$FXD/fx-init"
    FXA="$ZB/fx-activate"
fi

DLDIR="${FX_DATALOG_LIB:-$(cd "$REPO/.." && pwd)/datalog-dafsa/zig-out/lib}"
[ -f "$DLDIR/libdatalog.so" ] || skip "libdatalog.so not found at $DLDIR"
[ -x "$FXA" ] || skip "fx-activate not executable: $FXA"

activate() { # activate STORE CFG -> prints "activated <hash> as version <N>"
    LD_LIBRARY_PATH="$DLDIR" "$FXA" --store "$1" \
        --package-set "$PKGSET" --config "$2" 2>&1
}

# ─── the two stores ────────────────────────────────────────────────────────
# ONE store root for both activations: the fxstore derivation hash embeds
# each dep's FULL store path (root included), so packages WITH deps (fx-init,
# fx-activate, fxctl) hash differently under a different root — a store
# copied to a second root can never satisfy a fresh activation there.  So:
# activate good -> v_good, SNAPSHOT (the good image's ramfs store), activate
# bad on top -> v_bad > v_good with the good generation still published
# below it in the SAME db (fx_store_rollback's target), snapshot again.
echo "=== qemu-rollback: activating good config (store $STORE) ==="
OUT_GOOD=$(activate "$STORE" "$CFG_GOOD") || fail "activate good failed: $OUT_GOOD"
V_GOOD=$(echo "$OUT_GOOD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_GOOD" ] || fail "cannot parse good version from: $OUT_GOOD"
echo "$OUT_GOOD"
STORE_GOOD="$WORK/store-at-v$V_GOOD"
cp -a "$STORE" "$STORE_GOOD" || fail "cannot snapshot the good store"

echo "=== qemu-rollback: activating bad config (over v$V_GOOD) ==="
OUT_BAD=$(activate "$STORE" "$CFG_BAD") || fail "activate bad failed: $OUT_BAD"
V_BAD=$(echo "$OUT_BAD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_BAD" ] || fail "cannot parse bad version from: $OUT_BAD"
echo "$OUT_BAD"
[ "$V_BAD" -gt "$V_GOOD" ] || fail "bad version v$V_BAD not above good v$V_GOOD (adopt rule needs ramfs CURRENT > disk CURRENT)"
STORE_BAD="$WORK/store-at-v$V_BAD"
cp -a "$STORE" "$STORE_BAD" || fail "cannot snapshot the bad store"

# ─── the two images + the shared disk ──────────────────────────────────────
echo "=== qemu-rollback: building both initramfs images ==="
sh "$REPO/tests/mkinitramfs.sh" -s "$STORE_GOOD" -r "$ROOT" -k "$KERNEL" -o "$WORK/good.cpio.gz" \
    || fail "mkinitramfs good failed"
sh "$REPO/tests/mkinitramfs.sh" -s "$STORE_BAD"  -r "$ROOT" -k "$KERNEL" -o "$WORK/bad.cpio.gz" \
    || fail "mkinitramfs bad failed"
qemu-img create -q "$DISK" 512M || fail "qemu-img create failed"

FXD=$(ls -d "$STORE_GOOD"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

# run_boot IMAGE CONSOLE — boot once on $DISK, poll the console for the
# verdict line, then kill QEMU (fx-init loops forever as PID1).  The verdict
# line does NOT prove the durable state is fully on the disk: sync(2)-flushed
# metadata and the host page cache can lag the console, so run_boot waits for
# the disk image to go quiescent (see below) before the kill.
run_boot() {
    _img=$1 _con=$2
    : > "$_con"
    qemu-system-x86_64 \
        -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
        -kernel "$KERNEL" -initrd "$_img" \
        -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
        -nographic -no-reboot -monitor none -serial file:"$_con" \
        -drive file="$DISK",format=raw,if=virtio \
        >"$WORK/qemu.$$.out" 2>&1 &
    QPID=$!
    _i=0
    while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
        grep -q 'fx-init: boot-ok v\|fx-init: boot-FAILED v\|fx-init: no generation to boot' "$_con" && break
        kill -0 "$QPID" 2>/dev/null || break
        sleep 0.5
        _i=$((_i + 1))
    done
    # settle: the verdict line can hit the serial console before the LAST
    # sync-covered write is visible on the host (fx-init's bootlog fsync
    # precedes the verdict, but sync(2)-flushed metadata churn and the host
    # page cache lag it).  Wait for the disk image to go QUIESCENT —
    # unchanged sha256 across two consecutive polls — instead of a blind
    # sleep, so the next boot mounts a clean fs (MEASURED: killing at
    # first-verdict-line left the adopt's metadata churn unflushed and the
    # next boot hit ext4 "doubly allocated" inode errors).  The boot-timeout
    # loop above is the backstop: quiescence can only shorten the wait.
    _q=0 _prev=""
    while [ "$_q" -lt $((BOOT_TIMEOUT * 2)) ]; do
        _cur=$(disk_sha_quiet "$_img")
        if [ -n "$_cur" ] && [ "$_cur" = "$_prev" ]; then
            break
        fi
        _prev=$_cur
        sleep 0.5
        _q=$((_q + 1))
    done
    kill "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null
    return 0
}

disk_sha() { sha256sum "$DISK" | awk '{print $1}'; }

# sha of an arbitrary image, empty on error — for the quiescence poll, where
# a missing file must not satisfy the [ -n ] guard.
disk_sha_quiet() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

echo "=== boot 1: good image on the blank disk (expect seed + boot-ok v$V_GOOD) ==="
SHA0=$(disk_sha)
run_boot "$WORK/good.cpio.gz" "$WORK/console1.log"
grep -q 'fx-init: disk store mounted (current v'"$V_GOOD"')' "$WORK/console1.log" \
    || { tail -40 "$WORK/console1.log"; fail "boot 1: no disk-store line (seed)"; }
grep -q "fx-init: boot-ok v$V_GOOD" "$WORK/console1.log" \
    || { tail -40 "$WORK/console1.log"; fail "boot 1: want boot-ok v$V_GOOD"; }
SHA1=$(disk_sha)
[ "$SHA0" != "$SHA1" ] || fail "boot 1: disk.img unchanged (seed did not write)"

echo "=== boot 2: bad image (expect adopt + boot-FAILED v$V_BAD) ==="
run_boot "$WORK/bad.cpio.gz" "$WORK/console2.log"
grep -q "fx-init: disk store adopted ramfs v$V_BAD over disk v$V_GOOD" "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: no adopt line"; }
grep -q "fx-init: boot-FAILED v$V_BAD" "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: want boot-FAILED v$V_BAD"; }
SHA2=$(disk_sha)
[ "$SHA1" != "$SHA2" ] || fail "boot 2: disk.img unchanged ((v_bad,failed) never landed)"

echo "=== boot 3: good image (expect roll-forward from the DISK .bootlog) ==="
run_boot "$WORK/good.cpio.gz" "$WORK/console3.log"
# the roll-forward line: only reachable when decide_boot_version read a disk
# .bootlog whose last entry is (v_bad, failed) — a fresh ramfs cannot carry it
grep -q "fx-init: stale failed for v$V_BAD; rolling forward to v$V_GOOD" "$WORK/console3.log" \
    || { tail -40 "$WORK/console3.log"; fail "boot 3: no roll-forward line"; }
V_ROLLED=$(sed -n 's/.*fx-init: boot-ok v\([0-9][0-9]*\).*/\1/p' "$WORK/console3.log" | head -1)
[ -n "$V_ROLLED" ] || { tail -40 "$WORK/console3.log"; fail "boot 3: no boot-ok verdict"; }
[ "$V_ROLLED" -gt "$V_BAD" ] || fail "boot 3: rolled v$V_ROLLED not above v$V_BAD (not a roll-FORWARD)"
SHA3=$(disk_sha)
[ "$SHA2" != "$SHA3" ] || fail "boot 3: disk.img unchanged (roll-forward did not write)"

echo "qemu-rollback: PASS (seed v$V_GOOD -> FAILED v$V_BAD -> rolled forward to v$V_ROLLED on the persistent disk)"
exit 0
