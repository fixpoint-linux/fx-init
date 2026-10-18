#!/bin/sh
# tests/qemu_disk_probe.sh -- SLICE 2 gate (HANDOFF=v86guest): fx-init's DISK PROBE.
#
# THE CHANGE UNDER TEST: pick_disk_dev() (zig/src/init.zig) is no longer
# "/dev/vda1 if present, else /dev/vda" but a PROBE over [vda1, vda, sda1, sda],
# FIRST PRESENT WINS, so the v86/ATA lane (which has NO virtio-blk at all: v86
# ships virtio_balloon/console/net only) finds its libata disk at /dev/sda.
#
# THE GATE IS AN ASYMMETRY, and every arm below pairs "the code path RAN" with
# "the code path did not run" on ONE axis:
#
#   G1 fallback  post-fix, NO disk attached          -> the PINNED pre-fix line
#                "fx-init: disk store: no /dev/vda — using ramfs store", byte
#                for byte.  This is the vda-spelling half of the contract: with
#                nothing present the probe must still name /dev/vda, because
#                fx-demo's shipped browser lane prints that exact line and it is
#                the documented pre-fix control (fx-demo docs/BOOT.md).
#   G2 mount     post-fix, PRE-FORMATTED disk        -> "disk store mounted
#                (current vN)" + the disk image CHANGES (the guest formats
#                nothing here -- it mounts, seeds the store and syncs).
#   G3 persist   post-fix, SAME disk, and an initramfs whose ramfs store is
#                EMPTY (its .db removed) -> "mounted (current vN)".  vN can then
#                ONLY have come from the disk: the ramfs this boot was handed
#                has no .db at all, so a disk that had been reformatted or
#                re-seeded would report v0 (or print the ramfs line).  This is
#                the "seeded, ramfs CURRENT <= disk: the DISK wins" branch the
#                block comment above ensure_disk_store names as persistence.
#   G4 control   PRE-FIX BINARY, same machine/disk/store -> the ramfs line AND
#                the disk image BYTE-IDENTICAL (cmp).  Same builder, same
#                kernel, same disk, same store: the ONLY difference is init.zig.
#   G5 blank     post-fix, BLANK disk                -> the LOUD PRE-FORMAT
#                REFUSAL: "not a formatted filesystem ... must be pre-formatted
#                at build time" and NO mount line.  This is a contract now, not
#                a measurement (see the FINDING below): fx-init formats nothing
#                in-guest, because the image it runs in carries no busybox and
#                no shell to do it with.
#   H1 host-arm  non-PID1 + FX_INIT_FORCE in a sandbox whose /dev is the host's
#                devtmpfs and whose /dev/sda1 + /dev/sda are scratch files ->
#                NO fx-init disk line at all, and both scratch files unchanged.
#   H2 host-arm  THE SAME sandbox with a REAL inner PID1 (bwrap keeps PID1 for
#                itself, so unshare --user --map-root-user --pid --fork nests
#                one) -> an fx-init disk line DOES appear.  H2 is the firing
#                control that makes H1's silence a measurement, not a tautology:
#                same sandbox, same shadowed devices, one axis (PID1-ness).
#   H3 host-arm  the REAL /dev/sda1 + /dev/sda visible (NOT shadowed),
#                non-PID1: no disk line AND /sys/block/sda/stat write counters
#                unchanged.  REFUSED (skip) unless the runner demonstrably
#                cannot damage the device (see real_device_safe).
#
# THE FINDING G5 WAS BUILT ON (MEASURED, then FIXED by the native-migration
# unit): the disk path used to exec /usr/bin/busybox for mkfs/ext2, cp, rm, mv
# and sync (run_bb).  NO i386 BUSYBOX OBTAINABLE CARRIED THE mkfs.ext2 APPLET:
#   Alpine netboot busybox (4 roots on this host)  -> no mkfs.ext2, no mke2fs
#   Alpine busybox-static 1.36.1-r31 (i386)        -> neither
#   Alpine busybox-extras 1.36.1-r31               -> none
#   Debian busybox-static 1.38.0-3+b1 (i386)       -> mke2fs YES, mkfs.ext2 NO
#   openSUSE x86_64 busybox (the host's, 1.38.0)   -> BOTH -- which is why the
#     x86_64 lane never noticed: tests/mkinitramfs.sh ships $(command -v busybox),
#     the host's.
# So a BLANK disk reached "fx-init: disk: mkfs.ext2 FAILED (exit 127) — disk
# store disabled" with any i386 busybox that could be pinned then, and G5
# recorded that verbatim because asserting either way would have been a lie.
# THE FIX (this unit): the four applets are NATIVE now (rm_rf / copy_tree /
# rename / syncfs_path in zig/src/init.zig), the busybox is OUT of the guest
# image, and the blank disk is a LOUD PRE-FORMAT REFUSAL — formatting is a
# BUILD condition (the host mkfs's the FILE image below, no privilege needed),
# not a guest one.  G5 asserts the refusal; the pre-formatted arm is how the
# slice's real code (the probe, the seed) is exercised.
#
# NOTE, MEASURED and worth knowing before slice 3/4: the premise that the host
# cannot build the disk image is false for a FILE-backed image.  `busybox
# mke2fs -F -t ext4 disk.img` needs no privileges -- it writes an fs image, it
# does not mount one -- so uid 1001 can pre-format the artifact.  What uid 1001
# cannot do is MOUNT it, which is why the guest still seeds it.
#
# usage: sh tests/qemu_disk_probe.sh [prepare|pins|guest|hostarm|hostreal|all]
#   prepare   build the i386 fx-init (post- and pre-fix), dhake, the stores,
#             the initramfs images and the disk images into $WORK (idempotent)
#   pins      the sha256 pins of every input (fast)
#   guest     G1..G5
#   hostarm   H1 + H2 (the sandbox pair)
#   hostreal  H3 (the real device) -- refuses when it cannot prove safety
#   all       pins + guest + hostarm + hostreal
#
# Raw evidence (serial transcripts, device hashes) lands in $WORK (regenerated
# by `prepare`; every path is printed) and `all` copies the small text captures
# into tests/evidence-slice2/ in the repo -- written AFTER the store is built,
# because of the hashing note below.
#
# Env: WORK, KERNEL, DHAKE, FXDEMO, ALPINE (unused unless a fallback is needed).

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# WORK MUST LIVE OUTSIDE THE REPO, and that is a MEASURED requirement, not
# tidiness: the fx-init package's content hash walks the WHOLE fx-init repo tree
# (m3/package-set.dhall: fx-init's src is < Path = ".." >), so any scratch file
# written under the repo MOVES that hash.  MEASURED: creating and deleting one
# file under tests/.disk-probe-work/ moved the fx-init store dir from cf5e2313
# to ab893af9 and back.  With the scratch dir inside the repo the store build
# then fails -- fx-activate's recomputed closure paths no longer match the dirs
# activate_paths created moments earlier ("N closure package(s) not built").
WORK="${WORK:-/tmp/fx-init-disk-probe}"
FXDEMO="${FXDEMO:-$HOME/fixpoint-linux/fx-demo}"
KERNEL="${KERNEL:-$HOME/futaie/souche/tests/images/vmlinuz-i386-v86guest}"
FXDHAKE="${FXDHAKE:-$HOME/fixpoint-linux/dhake}"

# ── pins (each re-verified before use; a moved input is a loud failure) ────
SHA_KERNEL=f0278a8f2893eb93a8c857f3f2d5a589a5b9aa6a45033171bc5411fc10f658cd
# Debian's busybox-static 1.38.0-3+b1 for i386: the guest's /usr/bin/busybox
# (STATIC, so the image needs no musl loader; mke2fs/cp/rm/mv/sync/mount/sh all
# present -- mkfs.ext2 is NOT, which is G5's finding).
BB_URL=https://deb.debian.org/debian/pool/main/b/busybox/busybox-static_1.38.0-3+b1_i386.deb
SHA_BUSYBOX=6391caa6c0b4c8074ceb29509e1c5a345ecbb7ec7fdabb808c9955ed1eafa4b8
# The PRE-FIX fx-init SOURCE, as a git blob in this repo's object db: the blob
# the four fx-harness gates pin.  G4's control is built from it and cmp-proved
# to differ from the working tree's binary.
PREFIX_BLOB=7c054559821da222fddf793c62989b4b65e97361
# The blob the WORKING tree must hash to (the post-fix file).  Asserted at the
# end of the pre-fix swap: the swap must be a no-op for the tree.  (Round 2,
# reviewer SF2: the false-premise comment at old :2348-2349 was corrected
# COMMENT-ONLY, line for line, so this blob moved and NO cited line did.)
# MOVED by REBOOT S3 (the soft reboot's wiring in init.zig): re-measured with
# git hash-object against this tree, not remembered.
POST_BLOB=bf8fa631e442b0c4468fb8946b0cf3deb8d05e57

# ── the candidate-safety INVARIANT pins() asserts ─────────────────────────
# DISK_DEVS in zig/src/init.zig is the probe's WHOLE candidate list, and this
# gate is safe only while it equals {refused} ∪ {shadowed}:
#   REFUSED  -- candidates the host arm declines to run beside: hostarm dies
#               outright when /dev/vda* exists (never shadowed here);
#   SHADOWED -- candidates sandbox_run binds a scratch FILE over, so the probe
#               cannot land on the real device.
# The equality is ASSERTED against the parsed literal (pins), not remembered:
# MEASURED this session, with only /dev/sda shadowed the probe picked the REAL
# /dev/sda1 and launched mkfs at the live 5.5 TB partition.  Extending the
# probe's list (sda2, sdb, ...) without extending BOTH sets must FAIL here,
# not silently reopen that hole.
REFUSED="/dev/vda1 /dev/vda"
SHADOWED="/dev/sda1 /dev/sda"

RD_POST=""; RD_EMPTY=""; RD_PREFIX=""
# zig --prefix installs into <prefix>/bin, so the PREFIX is not the bin dir.
BIN="$WORK/fxinit/bin"; BINPREFIX="$WORK/fxinit-prefix/bin"
STORE=""; STORE_EMPTY=""; V_POST=""

fails=0
pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; fails=$((fails + 1)); }
skip() { echo "  SKIP  $1"; }
die() { echo "qemu_disk_probe: FATAL: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found"; }

# The guest console is a TTY: CRLF on every line (MEASURED).  Every assertion
# reads a CR-stripped transcript (gate-m2-5.sh precedent).
norm() { tr -d '\r' < "$1"; }
assert_in()     { if norm "$2" | grep -qF -- "$1"; then pass "$3"; else fail "$3 (absent: $1)"; fi; }
assert_not_in() { if norm "$2" | grep -qF -- "$1"; then fail "$3 (present: $1)"; else pass "$3"; fi; }
assert_eq()     { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1' want '$2')"; fi; }

# ── prepare ───────────────────────────────────────────────────────────────
zig_build_fxinit() { # zig_build_fxinit PREFIX
    ( cd "$REPO/zig" && zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall \
        --prefix "$1" ) > "$WORK/build-fxinit.log" 2>&1 \
        || die "fx-init i386 build failed (see $WORK/build-fxinit.log)"
    [ -x "$1/bin/fx-init" ] || die "no fx-init at $1/bin"
}

fetch_busybox() {
    [ -x "$WORK/busybox" ] && [ "$(sha256sum "$WORK/busybox" | cut -d' ' -f1)" = "$SHA_BUSYBOX" ] && return 0
    echo "--- fetching the i386 busybox (pinned) ---"
    curl -fsSL -o "$WORK/bb.deb" "$BB_URL" || die "cannot fetch $BB_URL"
    ( cd "$WORK" && (ar x bb.deb 2>/dev/null || bsdtar -xf bb.deb) ) \
        || die "cannot unpack $WORK/bb.deb (need ar or bsdtar)"
    tar -xf "$WORK/data.tar."* -C "$WORK" || die "cannot untar busybox data.tar"
    cp "$WORK/usr/bin/busybox" "$WORK/busybox" || die "no usr/bin/busybox in the deb"
    chmod 755 "$WORK/busybox"
    [ "$(sha256sum "$WORK/busybox" | cut -d' ' -f1)" = "$SHA_BUSYBOX" ] \
        || die "busybox sha256 mismatch: $(sha256sum "$WORK/busybox")"
}

# pre-fix fx-init: swap the pinned blob into the tree, build, restore.  The
# restore is proved (the tree must hash back to POST_BLOB) and the control is
# proved to DIFFER (the house rule: a control identical to the thing under test
# is not a control).
build_prefix() {
    [ -x "$BINPREFIX/fx-init" ] && return 0
    git -C "$REPO" cat-file -e "$PREFIX_BLOB" 2>/dev/null \
        || die "pre-fix blob $PREFIX_BLOB not in this repo's object db"
    cp "$REPO/zig/src/init.zig" "$WORK/init-current.zig" || die "cannot save init.zig"
    git -C "$REPO" cat-file blob "$PREFIX_BLOB" > "$WORK/init-prefix.zig" || die "cannot read the blob"
    trap 'echo "qemu_disk_probe: restoring init.zig after an aborted pre-fix build" >&2; cp "$WORK/init-current.zig" "$REPO/zig/src/init.zig"' EXIT INT TERM
    cp "$WORK/init-prefix.zig" "$REPO/zig/src/init.zig" || die "cannot swap init.zig"
    zig_build_fxinit "$WORK/fxinit-prefix"
    cp "$WORK/init-current.zig" "$REPO/zig/src/init.zig" || die "cannot restore init.zig"
    trap - EXIT INT TERM
    [ "$(git -C "$REPO" hash-object "$REPO/zig/src/init.zig")" = "$POST_BLOB" ] \
        || die "the pre-fix swap did NOT restore the working tree (init.zig is not $POST_BLOB)"
    cmp -s "$BINPREFIX/fx-init" "$BIN/fx-init" \
        && die "the pre-fix binary is IDENTICAL to the working one — not a control"
    echo "  pre-fix control binary: $(sha256sum "$BINPREFIX/fx-init" | cut -c1-16) (differs from $(sha256sum "$BIN/fx-init" | cut -c1-16))"
}

build_store() { # build_store STORE_DIR  -> echoes the version
    rm -rf "$1"
    sh "$FXDEMO/image/build-store.sh" --store "$1" --fx-init-repo "$REPO" \
        --bin "$BIN" --dhake "$WORK/dhake/bin/dhake" \
        > "$WORK/build-store-$(basename "$1").log" 2>&1 \
        || die "build-store.sh failed (see $WORK/build-store-$(basename "$1").log)"
    sed -n 's/^  version    \([0-9][0-9]*\)$/\1/p' "$WORK/build-store-$(basename "$1").log" | head -1
}

mkinitrd() { # mkinitrd STORE ROOTDIR OUT
    sh "$FXDEMO/image/mkinitramfs.sh" -s "$1" -r "$2" -o "$3" \
        > "$WORK/mkinitrd-$(basename "$3").log" 2>&1 \
        || die "mkinitramfs.sh failed (see $WORK/mkinitrd-$(basename "$3").log)"
    [ -s "$3" ] || die "empty initramfs $3"
}

prepare() {
    mkdir -p "$WORK"
    need zig; need qemu-system-x86_64; need sha256sum; need curl; need cpio; need xz
    [ -f "$KERNEL" ] || die "no kernel at $KERNEL (set KERNEL; slice 1's artifact, sha $SHA_KERNEL)"
    [ "$(sha256sum "$KERNEL" | cut -d' ' -f1)" = "$SHA_KERNEL" ] \
        || die "kernel sha256 mismatch for $KERNEL"
    [ -f "$FXDEMO/image/build-store.sh" ] || die "no fx-demo at $FXDEMO (set FXDEMO)"
    echo "--- i386 fx-init (post-fix) ---"
    zig_build_fxinit "$WORK/fxinit"
    echo "--- i386 dhake ---"
    if [ ! -x "$WORK/dhake/bin/dhake" ]; then
        ( cd "$FXDHAKE" && zig build -Dtarget=x86-linux-musl -Doptimize=ReleaseSmall \
            --prefix "$WORK/dhake" ) > "$WORK/build-dhake.log" 2>&1 \
            || die "dhake i386 build failed (see $WORK/build-dhake.log)"
    fi
    echo "--- pre-fix fx-init (the G4 control) ---"
    build_prefix
    fetch_busybox
    echo "--- the ROOTDIR overlay: /usr/bin/busybox (the CONTROL's, not the fix's) ---"
    # fx-demo's mkinitramfs.sh ships NO busybox in the real image, and the
    # post-fix fx-init needs NONE: the disk path's rm -rf / cp -a / mv / sync
    # are native now, and a blank disk is refused rather than formatted.  The
    # busybox below is supplied through the script's own ROOTDIR extension
    # point because the G4 CONTROL is built from the PRE-FIX source (whose
    # disk path still execs /usr/bin/busybox), and the control must differ
    # from the fix in exactly one axis: init.zig.  The pinned bytes are also
    # the artifact souche's gate-m2-5-guest.sh used to boot.
    rm -rf "$WORK/root"; mkdir -p "$WORK/root/usr/bin"
    cp "$WORK/busybox" "$WORK/root/usr/bin/busybox"; chmod 755 "$WORK/root/usr/bin/busybox"
    # the pre-fix CONTROL image: the same store, plus the pre-fix binary at
    # /prefix-fx-init (rdinit points at it) so the ONLY difference between the
    # control boot and G2 is the fx-init binary.
    rm -rf "$WORK/root-prefix"; mkdir -p "$WORK/root-prefix/usr/bin"
    cp "$WORK/busybox" "$WORK/root-prefix/usr/bin/busybox"; chmod 755 "$WORK/root-prefix/usr/bin/busybox"
    cp "$BINPREFIX/fx-init" "$WORK/root-prefix/prefix-fx-init"; chmod 755 "$WORK/root-prefix/prefix-fx-init"
    echo "--- the store ---"
    STORE="$WORK/store"; V_POST="$(build_store "$STORE")"
    [ -n "$V_POST" ] || die "cannot parse the post-fix store version"
    # G3's discriminator: the SAME store with its .db removed.  Not a lower
    # version -- MEASURED, a second build-store.sh from a fresh tree also lands
    # on v3 (one activation publishes 3 snapshots), so v1<v3 is not available
    # from this builder at all.
    STORE_EMPTY="$WORK/store-empty"; rm -rf "$STORE_EMPTY"
    cp -a "$STORE" "$STORE_EMPTY" || die "cannot copy the store"
    rm -rf "$STORE_EMPTY/.db"
    [ ! -e "$STORE_EMPTY/.db/snapshots/CURRENT" ] || die "the G3 ramfs store still has a .db"
    echo "--- the initramfs images ---"
    mkinitrd "$STORE"    "$WORK/root"        "$WORK/initrd-post.xz"
    mkinitrd "$STORE_EMPTY" "$WORK/root"     "$WORK/initrd-empty.xz"
    mkinitrd "$STORE"    "$WORK/root-prefix" "$WORK/initrd-prefix.xz"
    # rdinit: the store's fx-init dir, from the builder's own report.
    RD_DIR="$(basename "$(ls -d "$STORE"/*-fx-init | head -1)")"
    RD_POST="/fx/store/$RD_DIR/fx-init"; RD_EMPTY="$RD_POST"; RD_PREFIX="/prefix-fx-init"
    echo "  rdinit $RD_POST"
    echo "--- the disk images (HOST-formatted; see the header note) ---"
    rm -f "$WORK/disk-fmt.img" "$WORK/disk-blank.img"
    truncate -s 64M "$WORK/disk-blank.img"
    cp "$WORK/disk-blank.img" "$WORK/disk-fmt.img"
    # The HOST's busybox mkfs.ext2 -- THE PRE-FORMAT STEP, which is now the
    # CONTRACT (the guest formats nothing): the image is what the guest would
    # have had to be handed.  The i386 busyboxes cannot do this at all (G5's
    # finding), which is exactly why the format is a build-time step.
    busybox mkfs.ext2 -F "$WORK/disk-fmt.img" > "$WORK/mkfs.log" 2>&1 \
        || die "host busybox mkfs.ext2 failed (see $WORK/mkfs.log)"
    python3 - "$WORK/disk-fmt.img" <<'EOF' || die "the formatted image has no ext4 superblock"
import sys
d = open(sys.argv[1], 'rb').read(2048)
assert int.from_bytes(d[1080:1082], 'little') == 0xef53, "no 0xef53 magic"
EOF
    # The arms run in their own processes (and may be invoked directly), so the
    # derived names are persisted rather than recomputed: RD_* come from the
    # store THIS run built, and the store's fx-init dir hash moves with the repo
    # tree (see the WORK note).
    cat > "$WORK/state.sh" <<EOF
STORE='$STORE'
STORE_EMPTY='$STORE_EMPTY'
V_POST='$V_POST'
RD_POST='$RD_POST'
RD_EMPTY='$RD_EMPTY'
RD_PREFIX='$RD_PREFIX'
EOF
    echo "prepare: OK (work $WORK)"
    echo "  post-fix store v$V_POST  (G3's ramfs copy: .db removed)"
    echo "  initrd-post    $(sha256sum "$WORK/initrd-post.xz" | cut -c1-32)"
    echo "  initrd-empty   $(sha256sum "$WORK/initrd-empty.xz" | cut -c1-32)"
    echo "  initrd-prefix  $(sha256sum "$WORK/initrd-prefix.xz" | cut -c1-32)"
    echo "  disk-fmt       $(sha256sum "$WORK/disk-fmt.img" | cut -c1-32)"
}

# The probe's candidate list, RESOLVED from zig/src/init.zig: the DISK_DEVS
# literal plus any named const it names (DISK_DEV_PART / DISK_DEV_BASE).  A
# parse failure exits non-zero (the caller turns it into a loud die) — never an
# empty list that would trivially match.
disk_devs_of_source() {
    python3 - "$REPO/zig/src/init.zig" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r'const DISK_DEVS\b[^{]*\{([^}]*)\}', src)
if not m:
    sys.exit("no `const DISK_DEVS = ...{ ... }` in %s" % sys.argv[1])
out = []
for tok in m.group(1).split(','):
    tok = tok.strip()
    if not tok:
        continue
    if tok.startswith('"'):
        out.append(tok.strip('"'))
    else:
        c = re.search(r'const %s\s*=\s*"([^"]*)"' % re.escape(tok), src)
        if not c:
            sys.exit("DISK_DEVS names %s but no `const %s = \"...\"` resolves it" % (tok, tok))
        out.append(c.group(1))
print('\n'.join(out))
PYEOF
}

pins() {
    load_state
    echo "=== pins ==="
    assert_eq "$(sha256sum "$KERNEL" | cut -d' ' -f1)" "$SHA_KERNEL" "kernel sha256 ($KERNEL)"
    assert_eq "$(sha256sum "$WORK/busybox" | cut -d' ' -f1)" "$SHA_BUSYBOX" "guest busybox sha256 (Debian busybox-static i386)"
    assert_eq "$(git -C "$REPO" hash-object zig/src/init.zig)" "$POST_BLOB" "working-tree init.zig blob (the post-fix pin)"
    git -C "$REPO" cat-file -e "$PREFIX_BLOB" 2>/dev/null \
        && pass "pre-fix init.zig blob present ($PREFIX_BLOB)" \
        || fail "pre-fix init.zig blob absent ($PREFIX_BLOB)"
    assert_eq "$(cat "$STORE/.db/snapshots/CURRENT")" "$V_POST" "post-fix store CURRENT"
    if [ ! -e "$STORE_EMPTY/.db/snapshots/CURRENT" ]; then pass "G3's ramfs store has NO .db (the version can only come from the disk)"; else fail "G3's ramfs store still has a .db"; fi

    # ── THE SAFETY INVARIANT: {refused} ∪ {shadowed} == the probe's whole
    # candidate list, parsed from init.zig.  This is the assertion that turns
    # "the gate author remembered to shadow both sda candidates" into a
    # property of the constant: a future probe-list extension fails HERE.
    _got="$(disk_devs_of_source)" || die "cannot parse DISK_DEVS from zig/src/init.zig"
    [ -n "$_got" ] || die "DISK_DEVS parsed EMPTY from zig/src/init.zig — the parse is broken, not the list"
    _want="$(printf '%s\n' $REFUSED $SHADOWED | sort)"
    assert_eq "$(printf '%s\n' "$_got" | sort)" "$_want" \
        "pins DISK_DEVS == {refused} ∪ {shadowed} — every candidate pick_disk_dev can return is either REFUSED by hostarm or SHADOWED by sandbox_run; extending the probe's list means extending BOTH sets"
}

# Every arm but `prepare` reads the state prepare left behind: running `guest`
# without it would produce an EMPTY rdinit= (the kernel then falls back to
# /bin/init) and empty version strings -- i.e. assertions that pass or fail for
# reasons unrelated to the change.  MEASURED: that is exactly what happened
# before this existed.
load_state() {
    [ -f "$WORK/state.sh" ] || die "no state in $WORK — run: sh tests/qemu_disk_probe.sh prepare"
    . "$WORK/state.sh"
    [ -n "$RD_POST" ] && [ -n "$RD_PREFIX" ] && [ -n "$V_POST" ] \
        || die "incomplete state in $WORK/state.sh"
}

# KVM when the device is usable, TCG otherwise (a long boot is not a failure).
KVM=""
[ -w /dev/kvm ] && KVM="-enable-kvm"

# ── the guest ─────────────────────────────────────────────────────────────
# boot_guest INITRD RDINIT LOG PATTERN [DISK]
# The guest never halts by itself (PID1 keeps running its services), so the run
# is stopped as soon as the line under test lands on the console -- otherwise
# every arm would pay the backstop timeout.  -no-reboot: a failed boot decision
# may ask for a reboot, and we want the transcript, not a second boot.
boot_guest() {
    _initrd="$1"; _rdinit="$2"; _log="$3"; _pat="$4"; _disk="${5:-}"
    : > "$_log"
    _drv=""
    [ -n "$_disk" ] && _drv="-drive file=$_disk,format=raw,if=ide"
    # shellcheck disable=SC2086
    qemu-system-x86_64 -m 256 $KVM -no-reboot \
        -kernel "$KERNEL" -initrd "$_initrd" \
        -append "console=ttyS0 tsc=unstable rdinit=$_rdinit fx.store=/fx/store" \
        $_drv -display none -serial "file:$_log" > "$_log.qemu" 2>&1 &
    _qp=$!
    _n=0
    while [ "$_n" -lt 120 ]; do
        if norm "$_log" 2>/dev/null | grep -qF -- "$_pat"; then break; fi
        kill -0 "$_qp" 2>/dev/null || break
        sleep 0.5; _n=$((_n + 1))
    done
    sleep 1   # let the lines that follow the sentinel land
    kill "$_qp" 2>/dev/null
    wait "$_qp" 2>/dev/null
    [ "$_n" -lt 120 ] || echo "  (no '$4' within 60s — transcript kept: $_log)"
    return 0
}

RAMFS_LINE='fx-init: disk store: no /dev/vda — using ramfs store'
blob() { python3 -c "
import sys
d=open(sys.argv[1],'rb').read(2048)
print('ext4' if int.from_bytes(d[1080:1082],'little')==0xef53 else 'no-superblock')" "$1"; }

guest() {
    load_state
    echo "=== gate 2b: the i386 guest ==="
    G="$WORK/g"; mkdir -p "$G"
    rm -f "$G"/disk-*.img

    # G1 -- the fallback: NOTHING present must still print the pinned line.
    boot_guest "$WORK/initrd-post.xz" "$RD_POST" "$G/g1.serial" "fx-init: disk"
    assert_in "$RAMFS_LINE" "$G/g1.serial" "G1 no disk -> the PINNED pre-fix ramfs line, byte for byte"

    # G4 FIRST (control) -- it needs an untouched copy of the formatted disk.
    # The pre-fix binary on the SAME machine, store and disk: the ramfs line and
    # a BYTE-IDENTICAL disk (it never looks at /dev/sda at all).
    cp "$WORK/disk-fmt.img" "$G/disk-control.img"
    sha_before="$(sha256sum "$G/disk-control.img" | cut -d' ' -f1)"
    boot_guest "$WORK/initrd-prefix.xz" "$RD_PREFIX" "$G/g4.serial" "fx-init: disk" "$G/disk-control.img"
    assert_in "$RAMFS_LINE" "$G/g4.serial" "G4 pre-fix control -> the same pinned ramfs line on the SAME machine (fail-before)"
    assert_eq "$(sha256sum "$G/disk-control.img" | cut -d' ' -f1)" "$sha_before" "G4 the pre-fix binary did not touch the disk (byte-identical)"

    # G2 -- the mount arm.
    cp "$WORK/disk-fmt.img" "$G/disk-persist.img"
    boot_guest "$WORK/initrd-post.xz" "$RD_POST" "$G/g2.serial" "fx-init: disk store mounted" "$G/disk-persist.img"
    assert_in "fx-init: disk store mounted (current v$V_POST)" "$G/g2.serial" "G2 post-fix -> 'disk store mounted (current v$V_POST)' on /dev/sda"
    assert_not_in "$RAMFS_LINE" "$G/g2.serial" "G2 the ramfs fallback did NOT fire with a disk present"
    assert_in "ata1.00: ATA-" "$G/g2.serial" "G2 the machine really has a libata disk (ata1.00)"
    assert_eq "$(blob "$G/disk-persist.img")" "ext4" "G2 the disk carries an ext4 superblock"
    # WHICH device did the probe pick?  The kernel names the block device it
    # was handed to mount(2), so "(sda)" vs "(sda1)" discriminates the
    # sda1-before-sda ordering directly.  The fixture is whole-disk (the
    # Attached line carries no "sda: sda1" partition suffix), so /dev/sda1
    # never exists here; with no vda* on this machine either, /dev/sda is the
    # FIRST present candidate — an unambiguous pick.
    assert_in "EXT4-fs (sda):" "$G/g2.serial" "G2 the probe picked the WHOLE DISK /dev/sda (the kernel's ext4 mount line names it), not /dev/sda1"
    assert_not_in "sda: sda1" "$G/g2.serial" "G2 the fixture disk is whole-disk (no partition table), so /dev/sda1 never exists — the pick could only be /dev/sda"
    if [ "$(sha256sum "$G/disk-persist.img" | cut -d' ' -f1)" != "$(sha256sum "$WORK/disk-fmt.img" | cut -d' ' -f1)" ]; then
        pass "G2 the guest WROTE the disk (the store was seeded and synced)"
    else
        fail "G2 the disk is byte-identical to the pre-boot image — nothing was seeded"
    fi

    # G3 -- persistence: same disk, an initramfs whose ramfs store is OLDER.
    boot_guest "$WORK/initrd-empty.xz" "$RD_EMPTY" "$G/g3.serial" "fx-init: disk store mounted" "$G/disk-persist.img"
    assert_in "fx-init: disk store mounted (current v$V_POST)" "$G/g3.serial" \
        "G3 persistence: a reboot handed an EMPTY ramfs reports the DISK's v$V_POST"
    assert_not_in "fx-init: disk store mounted (current v0)" "$G/g3.serial" "G3 the disk was NOT re-seeded (v0 would mean the ramfs store was used)"
    assert_not_in "$RAMFS_LINE" "$G/g3.serial" "G3 the re-boot found the disk again (no fallback)"

    # G5 -- the blank-disk arm: now a CONTRACT, not a measurement.  A blank
    # disk is refused by name and nothing is formatted in-guest.
    cp "$WORK/disk-blank.img" "$G/disk-blank.img"
    sha_blank_before="$(sha256sum "$G/disk-blank.img" | cut -d' ' -f1)"
    boot_guest "$WORK/initrd-post.xz" "$RD_POST" "$G/g5.serial" "fx-init: disk" "$G/disk-blank.img"
    assert_in "is not a formatted filesystem" "$G/g5.serial" "G5 a BLANK disk is REFUSED (not a formatted filesystem)"
    assert_in "must be pre-formatted at build time" "$G/g5.serial" "G5 the refusal names the build-time pre-format condition"
    assert_not_in "fx-init: disk store mounted" "$G/g5.serial" "G5 the blank disk was NOT mounted (no store on it)"
    assert_not_in "mkfs" "$G/g5.serial" "G5 no mkfs ran in the guest"
    assert_eq "$(sha256sum "$G/disk-blank.img" | cut -d' ' -f1)" "$sha_blank_before" "G5 the guest left the blank disk BYTE-IDENTICAL (it formats nothing)"
}

# ── the host arm ──────────────────────────────────────────────────────────
# H1/H2 share ONE sandbox: the host's devtmpfs bound at /dev (so dev_is_devtmpfs
# is true and the code reaches the probe — bwrap's own --dev is a tmpfs, under
# which ensure_disk_store's devtmpfs mount fails EPERM and the WHOLE disk path
# returns early, i.e. the wrong gate would answer for the right one) and every
# sda* candidate SHADOWED by a scratch file.  Shadowing ALL of them is a safety
# interlock, not tidiness: MEASURED, with only /dev/sda shadowed the probe
# picked the REAL /dev/sda1 (it is earlier in the list) and mkfs was launched at
# the live 5.5 TB partition; it failed only on file permissions.  Nothing in
# this gate may depend on that.
# The sandbox root: fx-init needs a writable / to mkdirp /fx/disk and /run/fx.
host_root() {
    rm -rf "$H/root"; mkdir -p "$H/root/bin" "$H/root/etc" "$H/root/run/fx" "$H/root/tmp"
    chmod 1777 "$H/root/tmp"
    cp "$BIN/fx-init" "$H/root/fx-init"; chmod 755 "$H/root/fx-init"
}

# The scratch file that shadows candidate /dev/xxx in the host arm: $H/xxx.img.
shadow_file() { echo "$H/$(echo "${1#/dev/}" | tr / _).img"; }

sandbox_run() { # sandbox_run ROOT INNER...
    _r="$1"; shift
    # The shadow binds are DERIVED from SHADOWED (one source of truth for the
    # binds, the scratch files, and pins()'s invariant): a candidate that is
    # declared in the invariant is therefore also bound, by construction.
    _binds=""
    for _d in $SHADOWED; do
        _binds="$_binds --bind $(shadow_file "$_d") $_d"
    done
    # shellcheck disable=SC2086
    timeout 25 bwrap --bind "$_r" / \
        --bind "$STORE" /fx/store \
        --bind /dev /dev \
        $_binds \
        --ro-bind /usr/bin/busybox /usr/bin/busybox \
        --ro-bind /usr /usr --ro-bind /lib64 /lib64 \
        --proc /proc --clearenv --setenv FX_INIT_FORCE 1 --setenv PATH /usr/bin \
        -- "$@"
}

hostarm() {
    load_state
    echo "=== gate 2c: the host arm ==="
    need bwrap
    if [ -e /dev/vda ] || [ -e /dev/vda1 ]; then
        die "/dev/vda* exists on this host — the probe picks it FIRST and this arm does not shadow it; shadow it before running"
    fi
    H="$WORK/h"; mkdir -p "$H"
    host_root
    for _d in $SHADOWED; do
        dd if=/dev/zero of="$(shadow_file "$_d")" bs=1M count=16 status=none
    done
    _before=""
    for _d in $SHADOWED; do _before="$_before $(sha256sum "$(shadow_file "$_d")" | cut -d' ' -f1)"; done

    # H1: non-PID1 (bwrap keeps PID1 for itself).  The guard must return before
    # the probe — so there must be NO disk line at all, and no device touched.
    sandbox_run "$H/root" \
        /fx-init --store /fx/store --run-dir /run/fx > "$H/h1.out" 2>&1
    assert_not_in "fx-init: disk" "$H/h1.out" "H1 non-PID1 FX_INIT_FORCE -> the disk path never ran (no disk line)"
    _after=""
    for _d in $SHADOWED; do _after="$_after $(sha256sum "$(shadow_file "$_d")" | cut -d' ' -f1)"; done
    assert_eq "$_after" "$_before" "H1 every SHADOWED candidate ($SHADOWED) is byte-identical after the run"

    # H2: the SAME sandbox, a REAL inner PID1.  The firing control.
    if unshare --user --map-root-user --pid --fork true 2>/dev/null; then
        sandbox_run "$H/root" \
            /usr/bin/unshare --user --map-root-user --pid --fork --mount-proc \
            -- /fx-init --store /fx/store --run-dir /run/fx > "$H/h2.out" 2>&1
        assert_in "fx-init: disk" "$H/h2.out" "H2 real inner PID1 in the SAME sandbox -> the disk path DID run (the firing control)"
        norm "$H/h2.out" | grep -E "fx-init: root|fx-init: disk" | sed 's/^/    H2| /'
        echo "    H2 shadows after: $(for _d in $SHADOWED; do printf '%s ' "$(sha256sum "$(shadow_file "$_d")" | cut -c1-16)"; done)"
    else
        skip "H2: this host cannot nest a user+PID namespace (unshare EPERM) — H1 has no firing control here"
    fi
}

# H3 exposes the REAL /dev/sda* to the binary.  The whole point is that the
# non-PID1 guard stops it, but a gate must not be the thing that proves that on
# the user's data: the arm REFUSES unless the runner demonstrably cannot write
# the device (not root, no write permission).
hostreal() {
    load_state
    echo "=== gate 2c (cont): the REAL device ==="
    if [ "$(id -u)" = 0 ] || [ -w /dev/sda ] || [ -w /dev/sda1 ]; then
        skip "H3: this runner CAN write /dev/sda* — refusing to expose a device it could damage (run as an unprivileged user)"
        return 0
    fi
    [ -e /dev/sda ] || { skip "H3: no /dev/sda on this host"; return 0; }
    H="$WORK/h"; mkdir -p "$H"
    need bwrap
    host_root
    # The kernel's own write counters are the only device-level observable that
    # does not need write permission on the disk, and they are NOT attributable
    # here without a noise floor: MEASURED on this host, /sys/block/sda/stat's
    # write counters move ~3.5k sectors per 10 s with the gate doing nothing at
    # all (nothing of sda is mounted in this namespace), so a non-zero delta
    # proves nothing about the arm.  The rule is stated over the measured
    # baseline and has an explicit UNDECIDED branch -- an instrument that cannot
    # return "undecided" returns something else instead.
    b1="$(awk '{print $5,$6,$7,$8}' /sys/block/sda/stat)"
    sleep 10
    b2="$(awk '{print $5,$6,$7,$8}' /sys/block/sda/stat)"
    sandbox_run_dev "$H/root" /fx-init --store /fx/store --run-dir /run/fx > "$H/h3.out" 2>&1
    after="$(awk '{print $5,$6,$7,$8}' /sys/block/sda/stat)"
    assert_not_in "fx-init: disk" "$H/h3.out" "H3 non-PID1 with the REAL /dev/sda1+sda visible -> no disk line"
    if [ "$b1" = "$b2" ]; then
        assert_eq "$after" "$b1" "H3 sda's write counters unchanged (QUIET baseline: they held over 10s before the run)"
    else
        skip "H3 counter check UNDECIDED: the host writes sda on its own (baseline 10s delta '$b1' -> '$b2'); the attributable instrument is H1's shadowed-device check"
    fi
}
# the same sandbox WITHOUT the sda* shadows (the real nodes show through)
sandbox_run_dev() { # sandbox_run_dev ROOT INNER...
    _r="$1"; shift
    timeout 25 bwrap --bind "$_r" / --bind "$STORE" /fx/store --bind /dev /dev \
        --ro-bind /usr/bin/busybox /usr/bin/busybox \
        --ro-bind /usr /usr --ro-bind /lib64 /lib64 \
        --proc /proc --clearenv --setenv FX_INIT_FORCE 1 --setenv PATH /usr/bin \
        -- "$@"
}

# The small text captures are copied into the repo for durable evidence.  This
# runs AFTER prepare (whose store build hashes the repo tree): see the WORK note.
publish_evidence() {
    E="$REPO/tests/evidence-slice2"
    mkdir -p "$E"
    for f in "$WORK"/g/*.serial "$WORK"/h/*.out; do
        [ -f "$f" ] || continue
        cp "$f" "$E/$(echo "$f" | sed "s#^$WORK/##; s#/#-#g")"
    done
    {
        echo "slice 2 (v86guest) -- qemu_disk_probe.sh evidence, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "kernel     $SHA_KERNEL  $KERNEL"
        echo "busybox    $SHA_BUSYBOX  (Debian busybox-static 1.38.0-3+b1 i386)"
        echo "initrd-post    $(sha256sum "$WORK/initrd-post.xz" 2>/dev/null | cut -d' ' -f1)"
        echo "initrd-empty   $(sha256sum "$WORK/initrd-empty.xz" 2>/dev/null | cut -d' ' -f1)"
        echo "initrd-prefix  $(sha256sum "$WORK/initrd-prefix.xz" 2>/dev/null | cut -d' ' -f1)"
        echo "store (post-fix, v$V_POST) $STORE"
        echo "store (G3 ramfs copy)      $STORE_EMPTY"
    } > "$E/hashes.txt"
    echo "evidence published to $E"
}

# shellcheck disable=SC2086
case "${1:-all}" in
    prepare) prepare ;;
    pins)    pins ;;
    guest)   guest ;;
    hostarm) hostarm ;;
    hostreal) hostreal ;;
    all)     prepare; pins; guest; hostarm; hostreal; publish_evidence ;;
    *) die "usage: sh tests/qemu_disk_probe.sh [prepare|pins|guest|hostarm|hostreal|all]" ;;
esac
echo
echo "qemu_disk_probe: $fails FAILING assertion(s)"
[ "$fails" = 0 ]
