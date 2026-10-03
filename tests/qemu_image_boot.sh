#!/bin/sh
# tests/qemu_image_boot.sh — the M-1 STANDALONE BOOT harness (fx-image).
#
# Proves the property the whole fx-image lane exists for: ONE raw disk
# image built from a Dhall config by `fx-image` boots UNDER ITS OWN
# POWER — qemu gets -drive ONLY, no -kernel and no -initrd — and the
# serial console carries fx-init's verdict `boot-ok v<N>` for the EXACT
# version N the build activated.  The verdict line is emitted by
# fx-init's own boot-decision branch (zig/src/init.zig), so a green run
# proves the whole chain: stage1's MBR handoff, stage2's header parse +
# kernel/initrd placement at 0x1000000/0x2000000, the 16-bit setup
# entry contract, the gzip'd cpio unpack from the image's own boot
# region, mount_early, the store open, dhake materialization, the
# service spawn, and the datalog boot_status(ok) commit.
#
# The property is NOT trivially satisfied — three guards:
#   (1) STRUCTURAL: the built bytes are checked directly (55aa at 510,
#       FXIMGv1 magic at 512, partition 1 bootable 0x80 / type 0x83 at
#       LBA 65536, sidecar sha256) — an image that cannot describe
#       itself never reaches qemu;
#   (2) THE GATE: boot-ok v$V where V is PARSED from the build's own
#       `activated version <N>` line (never hardcoded) — the version
#       that booted is the version that was activated;
#   (3) NEGATIVE CONTROL (the asymmetry): a SECOND image built with the
#       bad-exit config must print `fx-init: boot-FAILED` and must NOT
#       print boot-ok — the same harness shape, run red on purpose.  A
#       verdict line that could not fail would test nothing.
#
# ONE-SHOT SHAPE (deliberate): at write time fx-init's first-boot disk-store
# init mkfs'd the WHOLE disk, whose ext4 metadata landed over the boot region
# (a second boot of the same disk halted at stage1 `SEH6`); a fix was landing
# in parallel (zig/src/init.zig, prefer /dev/vda1).  This harness deliberately
# depends on NEITHER state: it asserts ONLY the FIRST boot of each image and
# builds a FRESH image per arm; a persistence/rollback harness is the M-2
# work, not this gate.
#
# Env:
#   QEMU_CONFIG      good-arm config (default m3/config-good.dhall)
#   QEMU_NEG_CONFIG  negative-arm config (default m3/config-bad-exit.dhall;
#                    must be a config whose boot FAILS — the harness
#                    asserts boot-FAILED + NOT boot-ok)
#   QEMU_BOOT_TIMEOUT seconds to wait per boot verdict (default 120)
#   FX_IMAGE_BIN     override the fx-image under test (default: the
#                    zig-built zig-out/bin/fx-image; built first if absent)
#   FX_KERNEL_CACHE  kernel cache override (fetch-kernel + fx-image)
#   FX_SIBLINGS      sibling checkouts (fx-image default: repo/..)
#   QEMU_KEEP=1      keep the scratch dir (debugging; prints its path)
set -u

fail() { echo "image-boot: FAIL: $*" >&2; exit 1; }
skip() { echo "image-boot: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v timeout >/dev/null 2>&1 || skip "timeout not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v python3 >/dev/null 2>&1 || skip "python3 not found (structural image asserts)"
[ -e /dev/kvm ]                   || skip "/dev/kvm absent (standalone boot requires kvm)"
[ -w /dev/kvm ]                   || skip "/dev/kvm not writable"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
QEMU_CONFIG="${QEMU_CONFIG:-$REPO/m3/config-good.dhall}"
QEMU_NEG_CONFIG="${QEMU_NEG_CONFIG:-$REPO/m3/config-bad-exit.dhall}"
QEMU_BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-120}"
# for triage on other hosts (qemu/SeaBIOS drift changes stage1/2 behavior)
qemu-system-x86_64 --version | head -1

# ─── pinned kernel pre-flight (scripts/kernel-pin.txt) ─────────────────────
# fx-image fetches + verifies the kernel itself; the harness runs the same
# fetch FIRST so an OFFLINE host skips loudly (77) instead of burning a
# 53s build that then fails.  fetch-kernel exit: 0 = verified cache,
# 77 = offline — there is deliberately NO host-kernel fallback.
PIN="$REPO/scripts/kernel-pin.txt"
[ -f "$PIN" ] || skip "scripts/kernel-pin.txt missing"
FETCH_OUT=$(sh "$REPO/scripts/fetch-kernel.sh" 2>&1)
FETCH_RC=$?
echo "$FETCH_OUT"
[ "$FETCH_RC" = 0 ] || [ "$FETCH_RC" = 77 ] || fail "fetch-kernel failed (rc=$FETCH_RC)"
[ "$FETCH_RC" = 0 ] || skip "pinned kernel artifact unavailable (offline) — no host-kernel fallback by design"

# ─── the builder under test ────────────────────────────────────────────────
FXIMAGE="${FX_IMAGE_BIN:-$REPO/zig/zig-out/bin/fx-image}"
if [ ! -x "$FXIMAGE" ]; then
    command -v zig >/dev/null 2>&1 || skip "zig not found and $FXIMAGE absent (build it or set FX_IMAGE_BIN)"
    echo "=== image-boot: fx-image absent — zig build ==="
    ( cd "$REPO/zig" && zig build ) >/dev/null 2>&1
    [ -x "$FXIMAGE" ] || skip "zig build did not produce zig-out/bin/fx-image"
fi

# ─── scratch ───────────────────────────────────────────────────────────────
SCRATCH="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$SCRATCH/qemuimg.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "image-boot: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
# fx-image's --work: the FIXED store root is a derivation-hash input and a
# shared default (/tmp/fx-image-work) would collide with any concurrent
# builder — the harness gives the run its own root inside the scratch dir.
FXWORK="$WORK/fxwork"

case "$QEMU_CONFIG" in /*) ;; *) QEMU_CONFIG="$REPO/$QEMU_CONFIG" ;; esac
case "$QEMU_NEG_CONFIG" in /*) ;; *) QEMU_NEG_CONFIG="$REPO/$QEMU_NEG_CONFIG" ;; esac
[ -r "$QEMU_CONFIG" ]     || skip "good config not readable: $QEMU_CONFIG"
[ -r "$QEMU_NEG_CONFIG" ] || skip "negative config not readable: $QEMU_NEG_CONFIG"

# ─── build one image (with the concurrent-peer retry) ──────────────────────
# fx-image runs `zig build` on the LIVE repo tree; a peer editing zig/src
# can hold the zig cache lock transiently — one retry, then it is real.
# What the build picks up from an in-flight tree is fine to boot: the
# verdict gate holds either way (the harness never pins a stale binary).
# Progress goes to STDERR: the caller reads the activated version from the
# build log — a function that echoed it into stdout would hand the caller
# a MULTILINE value, and grep splits a newline-bearing pattern into
# alternates (MEASURED), quietly turning 'boot-ok v$V' into a vacuous
# 'line contains 3'.  parse_version + the token guard below make that
# bug class loud instead.
build_image() { # build_image CONFIG OUT LOGTAG (log at $WORK/build-LOGTAG.log)
    _cfg=$1 _out=$2 _log="$WORK/build-$3.log" _try=0
    while :; do
        echo "=== image-boot: fx-image --config $(basename "$_cfg") -> $(basename "$_out") ===" >&2
        if "$FXIMAGE" --config "$_cfg" \
            --package-set "$REPO/m3/package-set.dhall" \
            --pin "$PIN" --out "$_out" --size-mb 512 \
            --work "$FXWORK" >"$_log" 2>&1; then
            break
        fi
        _try=$((_try + 1))
        if [ "$_try" -ge 2 ]; then
            echo "--- fx-image build log (last 40) ---" >&2; tail -40 "$_log" >&2
            fail "fx-image build failed for $(basename "$_cfg") (rc above; log $_log)"
        fi
        echo "--- fx-image attempt 1 failed (zig cache contention with a concurrent peer is the expected transient) — retrying once ---" >&2
    done
    cat "$_log" >&2
    [ -f "$_out.sha256" ] || fail "fx-image wrote no $_out.sha256 sidecar"
}

# "=== fx-image: activated version <N> (rdinit /fx/store/<hash>-fx-init/fx-init) ==="
parse_version() { # parse_version LOGTAG -> the single numeric token
    sed -n 's/.*activated version \([0-9][0-9]*\).*/\1/p' "$WORK/build-$1.log" | head -1
}

# ─── structural asserts (assertion 1) ──────────────────────────────────────
# An image that cannot describe itself never reaches qemu: MBR signature,
# FX header magic, partition 1 geometry (bootable Linux at LBA 65536,
# spanning the rest of the disk = outside the boot region), and the
# builder's own sha256 sidecar over the whole image.
check_structure() { # check_structure IMG SIDECAR
    python3 - "$1" "$2" <<'PYEOF' || fail "structural check failed for $1"
import sys, hashlib
img = open(sys.argv[1], 'rb').read()
side = open(sys.argv[2]).read().split()[0]
errs = []
if img[510:512] != b'\x55\xaa': errs.append("no 55aa MBR signature at 510")
if img[512:520] != b'FXIMGv1\n': errs.append("no FXIMGv1\\n magic at 512")
status, ptype = img[446], img[450]
start = int.from_bytes(img[454:458], 'little')
span  = int.from_bytes(img[458:462], 'little')
total = len(img) // 512
if status != 0x80: errs.append("partition 1 not bootable (status 0x%02x)" % status)
if ptype  != 0x83: errs.append("partition 1 type not 0x83 (0x%02x)" % ptype)
if start != 65536: errs.append("partition 1 starts at LBA %d, want 65536" % start)
if span  != total - 65536: errs.append("partition 1 spans %d sectors, want %d" % (span, total - 65536))
got = hashlib.sha256(img).hexdigest()
if got != side: errs.append("sha256 mismatch: image %s, sidecar %s" % (got, side))
if errs:
    print("image-boot: structural FAIL: " + "; ".join(errs)); sys.exit(1)
print("image-boot: structural OK (%d MiB: 55aa, FXIMGv1, part1 bootable 0x80 type 0x83 LBA %d span %d, sha256 %s matches sidecar)" % (total // 2048, start, span, got[:16] + '...'))
PYEOF
}

# ─── boot one image and wait for a verdict ─────────────────────────────────
# -cpu host is REQUIRED (the zig-native fx-init traps invalid-opcode under
# qemu64's default model — same as tests/qemu_boot.sh:274).  NO -kernel and
# NO -initrd: the image's own boot region carries both — that is the
# property.  The image has no panic-reboot exit: after the verdict fx-init
# keeps running as PID1, so qemu never exits on its own — poll the console
# and stop qemu the moment a verdict lands (the timeout is only the
# failure cap; a fixed wait would burn it on every green run).
boot_image() { # boot_image IMG CONSOLE TAG -> sets QEMU_RC
    : > "$2"
    timeout "$QEMU_BOOT_TIMEOUT" qemu-system-x86_64 \
        -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
        -nographic -no-reboot -monitor none \
        -serial file:"$2" \
        -drive file="$1",format=raw,if=virtio \
        >"$WORK/qemu-$3.out" 2>&1 &
    _pid=$!
    _waited=0
    while [ "$_waited" -lt "$QEMU_BOOT_TIMEOUT" ]; do
        grep -q 'fx-init: boot-' "$2" && break
        kill -0 "$_pid" 2>/dev/null || break
        sleep 1
        _waited=$((_waited + 1))
    done
    kill "$_pid" 2>/dev/null
    wait "$_pid" 2>/dev/null
    QEMU_RC=$?
}

# ═══ ARM 1 — the good config must reach boot-ok v$V (assertion 2) ═════════
GOOD="$WORK/good.raw"
GOOD_CONSOLE="$WORK/console-good.log"
build_image "$QEMU_CONFIG" "$GOOD" good
V=$(parse_version good)
# one numeric token, nothing else — a version polluted by build-log noise
# would (see build_image) quietly vacuousize every verdict grep below
case $V in ''|*[!0-9]*) fail "cannot parse 'activated version <N>' from fx-image output: $(tail -5 "$WORK/build-good.log")";; esac
echo "=== image-boot: build activated version v$V ==="
check_structure "$GOOD" "$GOOD.sha256"

echo "=== image-boot: booting $(basename "$GOOD") with -drive ONLY (no -kernel, no -initrd), expecting boot-ok v$V ==="
boot_image "$GOOD" "$GOOD_CONSOLE" good
# chain evidence before the verdict: the initrd came from the image's boot
# region at the loader's fixed address, and PID1 is the store's fx-init
grep -q 'RAMDISK: \[mem 0x02000000' "$GOOD_CONSOLE" || {
    echo "--- last 40 console lines ---"; tail -40 "$GOOD_CONSOLE"
    fail "no RAMDISK line at the loader-placed 0x02000000 — the image's initrd did not reach the kernel"; }
grep -q 'Run /fx/store/.*-fx-init/fx-init as init process' "$GOOD_CONSOLE" || {
    echo "--- last 40 console lines ---"; tail -40 "$GOOD_CONSOLE"
    fail "no 'Run /fx/store/...-fx-init/fx-init as init process' — the baked rdinit did not exec"; }
if grep -q 'fx-init: boot-FAILED' "$GOOD_CONSOLE"; then
    echo "--- last 40 console lines ---"; tail -40 "$GOOD_CONSOLE"
    fail "good config printed boot-FAILED (want boot-ok v$V)"
fi
if ! grep -q "fx-init: boot-ok v$V" "$GOOD_CONSOLE"; then
    echo "--- qemu exit $QEMU_RC; last 40 console lines ---"; tail -40 "$GOOD_CONSOLE"
    [ -s "$WORK/qemu-good.out" ] && { echo "--- qemu stderr ---"; tail -5 "$WORK/qemu-good.out"; }
    fail "no boot-ok v$V verdict within ${QEMU_BOOT_TIMEOUT}s (exit $QEMU_RC) — THE GATE"
fi
echo "good arm verdict:   $(grep 'fx-init: boot-' "$GOOD_CONSOLE" | head -1)"

# ═══ ARM 2 — the bad config must go RED (assertion 3, the asymmetry) ══════
BAD="$WORK/bad.raw"
BAD_CONSOLE="$WORK/console-bad.log"
build_image "$QEMU_NEG_CONFIG" "$BAD" bad
VNEG=$(parse_version bad)
case $VNEG in ''|*[!0-9]*) fail "cannot parse 'activated version <N>' from fx-image output: $(tail -5 "$WORK/build-bad.log")";; esac
echo "=== image-boot: negative build activated version v$VNEG ==="
check_structure "$BAD" "$BAD.sha256"

echo "=== image-boot: booting $(basename "$BAD") (negative control, expecting boot-FAILED) ==="
boot_image "$BAD" "$BAD_CONSOLE" bad
if grep -q 'fx-init: boot-ok' "$BAD_CONSOLE"; then
    echo "--- last 40 console lines ---"; tail -40 "$BAD_CONSOLE"
    fail "negative control printed boot-ok — the gate would be trivially satisfiable"
fi
if ! grep -q 'fx-init: boot-FAILED' "$BAD_CONSOLE"; then
    echo "--- qemu exit $QEMU_RC; last 40 console lines ---"; tail -40 "$BAD_CONSOLE"
    [ -s "$WORK/qemu-bad.out" ] && { echo "--- qemu stderr ---"; tail -5 "$WORK/qemu-bad.out"; }
    fail "no boot-FAILED verdict in the negative control within ${QEMU_BOOT_TIMEOUT}s (exit $QEMU_RC)"
fi
echo "negative verdict:   $(grep 'fx-init: boot-' "$BAD_CONSOLE" | head -1)"

echo "image-boot: PASS (standalone image boots with -drive only: boot-ok v$V; negative control boot-FAILED as designed)"
exit 0
