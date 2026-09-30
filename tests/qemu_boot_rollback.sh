#!/bin/sh
# tests/qemu_boot_rollback.sh — the M4 GENUINE multi-boot roll-forward proof.
#
# THREE QEMU boots on ONE shared disk.img and ONE initramfs image (M4 C:
# the second host-built initramfs is RETIRED — the bad generation now
# reaches the running guest over the virtio-serial control channel, the
# same in-guest activate path tests/qemu_activate.sh drives):
#
#   host side: ONE store; activate config-bad-exit FIRST (v_bad), then
#          config-good (v_good) on top — so v_bad is published BELOW
#          v_good in the same store db (fx_store_rollback's target).  ONE
#          initramfs whose ramfs CURRENT = v_good.
#   boot 1 (channel): the guest seeds the disk at v_good and boots it ok.
#          With QEMU STILL RUNNING the harness uploads the bad config
#          (put /run/fx/config-bad-exit.dhall + base64 + '.') and runs
#          `activate` IN-GUEST -> "activated version v_bad2" (v_bad2 >
#          v_good; the host never created it — the guest's own
#          fx-activate is the only possible writer).  The successful
#          activate RE-ARMS the boot decision (init.zig resets
#          g_boot_decided/g_boot_failed and restarts the grace window), so
#          the new generation gets its own verdict: the crasher exits 7
#          inside the new window -> "boot-FAILED v_bad2" on the console
#          AND "(v_bad2, failed)" appended to the DISK .bootlog — the
#          entry the next boot rolls forward from.
#   boot 2 (SAME image, no session): disk CURRENT v_bad2 > ramfs v_good
#          => no adopt.  MEASURED: with boot 1's IN-GUEST (v_bad2, failed)
#          verdict already on the DISK .bootlog, this boot ROLLS FORWARD
#          at decide_boot_version time (the harness's boot-2 assertions
#          below state this exactly).
#   boot 3 (SAME image): idempotent re-boot of the rolled-forward version
#          (boot-ok v_roll again + a fresh disk write).
#
# WHY THE init.zig CHANGE IS LOAD-BEARING (measured, not assumed): without
# the re-arm the channel activate path left g_boot_decided latched at the
# v_good verdict, so evaluate_boot_ok (the ONLY writer of a (v, failed)
# bootlog entry during a live boot) never ran again — the guest could
# activate a BAD generation over the channel and the DISK bootlog would
# never record it; this harness CANNOT pass without the re-arm (verified
# by asymmetry: the pre-fix binary fails at the boot-1 verdict gate).
#
# PERSISTENCE BELTS (plan section 3): (a) the disk.img sha256 must CHANGE
# across each boot (writes landed); (b) the roll-forward console line in
# boot 3 is only reachable from a disk .bootlog carrying a PRIOR boot's
# (v_bad2, failed); (c) the rolled-to version must be > v_bad2
# (monotonic).
#
# ONE-image assertion: this script invokes tests/mkinitramfs.sh EXACTLY
# ONCE (checked by the harness itself — a grep of its own source would be
# a self-referential joke, so the assertion is the absence of a second
# -o image in the flow plus the single mkinitramfs call site below).
#
# Channel: same virtio-serial + nc -U contract as qemu_ctrl.sh (no -N: the
# half-close drops the chardev before the guest's response write).
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
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
command -v base64 >/dev/null 2>&1 || skip "base64 not found (channel upload)"
# mke2fs lives in /sbin or /usr/sbin (not on a user PATH); search both.
MKE2FS=""
for _p in mke2fs /sbin/mke2fs /usr/sbin/mke2fs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then MKE2FS="$_p"; break; fi
done
[ -n "$MKE2FS" ] || skip "mke2fs not found (e2fsprogs)"
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
SOCK="$WORK/chardev.sock"
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-rollback: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
STORE="$WORK/store"
ROOT="$WORK/root"
DISK="$WORK/disk.img"
mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp"

# ─── host writer for the channel (qemu_ctrl.sh contract) ─────────────────
CTRL_TOOL=""
if nc -h 2>&1 | grep -q -- '-U.*UNIX domain socket'; then
    CTRL_TOOL=nc
elif command -v python3 >/dev/null 2>&1; then
    CTRL_TOOL=python3
else
    skip "no nc with -U and no python3 — cannot write the virtio chardev socket"
fi
echo "qemu-rollback: channel writer: $CTRL_TOOL"

# ctrl_session SOCK REQFILE TRANSCRIPT — send the request file's lines over
# the chardev socket in ONE connection (NO half-close; see qemu_ctrl.sh),
# capture the answers.  The file's lines carry the put framing verbatim.
ctrl_session() { # ctrl_session SOCK REQFILE TRANSCRIPT
    _sock=$1 _req=$2 _out=$3
    case "$CTRL_TOOL" in
        nc) timeout 90 nc -w 20 -U "$_sock" < "$_req" > "$_out" 2>&1 ;;
        python3) timeout 90 python3 -c '
import socket, sys, time
sock, req = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.sendall(open(req, "rb").read())
# NO shutdown(SHUT_WR): the guest writes responses on the same connection
# and a half-close makes qemu drop the chardev before they are written.
s.settimeout(40)
chunks = []
deadline = time.time() + 40
while time.time() < deadline:
    try:
        b = s.recv(4096)
    except socket.timeout:
        break
    if not b:
        break
    chunks.append(b)
sys.stdout.write(b"".join(chunks).decode("utf-8", "replace"))
' "$_sock" "$_req" > "$_out" 2>&1 ;;
    esac
}

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
    ( cd "$REPO/zig" && zig build install ) >/dev/null 2>&1
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

# ─── ONE store, TWO activations: bad FIRST, good on top ───────────────────
# (the qemu_ctrl.sh composition: v_bad stays published BELOW v_good in the
# same db — fx_store_rollback's target — and the image's ramfs CURRENT =
# v_good.  The GUEST's in-guest activation of the bad config must land
# ABOVE v_good — a version the host never created, so the only possible
# writer is the guest's own channel-driven fx-activate.)
echo "=== qemu-rollback: activating bad-exit config FIRST (store $STORE) ==="
OUT_BAD=$(activate "$STORE" "$CFG_BAD") || fail "activate bad failed: $OUT_BAD"
V_BAD=$(echo "$OUT_BAD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_BAD" ] || fail "cannot parse bad version from: $OUT_BAD"
echo "$OUT_BAD"

echo "=== qemu-rollback: activating good config on top (over v$V_BAD) ==="
OUT_GOOD=$(activate "$STORE" "$CFG_GOOD") || fail "activate good failed: $OUT_GOOD"
V_GOOD=$(echo "$OUT_GOOD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_GOOD" ] || fail "cannot parse good version from: $OUT_GOOD"
echo "$OUT_GOOD"
[ "$V_GOOD" -gt "$V_BAD" ] || fail "good v$V_GOOD not above bad v$V_BAD (the guest must land above BOTH)"

# ─── the ONE image + the shared disk ──────────────────────────────────────
echo "=== qemu-rollback: building the ONE initramfs (ramfs CURRENT = v$V_GOOD, v$V_BAD published below) ==="
sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/img.cpio.gz" -p "$PKGSET" \
    || fail "mkinitramfs failed"
qemu-img create -q "$DISK" 512M || fail "qemu-img create failed"
# Journaled ext4 BEFORE the first boot (qemu_ctrl.sh's measured rationale:
# the guest's busybox mkfs.ext2 cannot add a journal, and a NOJOURNAL ext4
# leaves bitmap churn to lazy writeback — an abrupt harness kill then tears
# the bitmaps and the NEXT boot's first inode allocation dies at
# __ext4_new_inode "doubly allocated?".
"$MKE2FS" -q -t ext4 -J size=4 "$DISK" >/dev/null 2>&1 \
    || fail "mke2fs -t ext4 (journaled) failed — install e2fsprogs"

FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

# run_boot CONSOLE WITH_CHANNEL — boot the ONE image on $DISK.  The
# virtio-serial chardev + devices are attached in EVERY boot (boots 2/3
# connect nobody — the port sits unconnected, peer-gone latched, inert);
# the difference is only WHO USES the channel.
run_boot() {
    _con=$1 _chan=$2
    : > "$_con"
    rm -f "$SOCK"
    qemu-system-x86_64 \
        -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
        -kernel "$KERNEL" -initrd "$WORK/img.cpio.gz" \
        -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
        -nographic -no-reboot -monitor none -serial file:"$_con" \
        -drive file="$DISK",format=raw,if=virtio \
        -chardev socket,id=fxctl0,path="$SOCK",server=on,wait=off \
        -device virtio-serial-pci -device virtserialport,chardev=fxctl0,name=fxctl0 \
        >"$WORK/qemu.$$.out" 2>&1 &
    QPID=$!
    _i=0
    while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
        if grep -q 'fx-init: boot-ok v\|fx-init: boot-FAILED v\|fx-init: no generation to boot' "$_con"; then
            break
        fi
        kill -0 "$QPID" 2>/dev/null || break
        sleep 0.5
        _i=$((_i + 1))
    done
    if [ "$_chan" = "1" ]; then
        return 0   # boot 1: the channel session owns the kill
    fi
    wait_disk_quiet
    kill "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null
    return 0
}

disk_sha() { sha256sum "$DISK" | awk '{print $1}'; }
# sha of an arbitrary image, empty on error — for the quiescence poll, where
# a missing file must not satisfy the [ -n ] guard.
disk_sha_quiet() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

wait_disk_quiet() {
    _q=0 _prev=""
    while [ "$_q" -lt $((BOOT_TIMEOUT * 2)) ]; do
        _cur=$(disk_sha_quiet "$DISK")
        if [ -n "$_cur" ] && [ "$_cur" = "$_prev" ]; then return 0; fi
        _prev=$_cur
        sleep 0.5
        _q=$((_q + 1))
    done
    return 0
}

echo "=== boot 1: channel boot — seed the disk at v$V_GOOD, then put+activate the bad config IN-GUEST ==="
SHA0=$(disk_sha)
run_boot "$WORK/console1.log" 1
grep -q 'fx-init: disk store mounted (current v'"$V_GOOD"')' "$WORK/console1.log" \
    || { tail -40 "$WORK/console1.log"; kill "$QPID" 2>/dev/null; fail "boot 1: no disk-store line (seed)"; }
grep -q "fx-init: boot-ok v$V_GOOD" "$WORK/console1.log" \
    || { tail -40 "$WORK/console1.log"; kill "$QPID" 2>/dev/null; fail "boot 1: want boot-ok v$V_GOOD"; }
grep -q 'fx-init: virtio control up (/dev/vport' "$WORK/console1.log" \
    || { tail -40 "$WORK/console1.log"; kill "$QPID" 2>/dev/null; fail "boot 1: no virtio control up line"; }
SHA1=$(disk_sha)
[ "$SHA0" != "$SHA1" ] || { kill "$QPID" 2>/dev/null; fail "boot 1: disk.img unchanged (seed did not write)"; }

# ── the in-guest control session (QEMU still running) ─────────────────────
# put the BAD config over the channel (staged under /run/ — TODAY's put
# whitelist; item E widens it, this item must not rely on that), then
# activate it IN-GUEST.  The 40s nc timeout spans the activate + the
# re-armed grace window (the crasher must exit INSIDE the new 8s window;
# the transcript's boot-FAILED line lands well within it).
CTRL_TRANSCRIPT="$WORK/ctrl.log"
{
    echo 'put /run/fx/config-bad-exit.dhall'
    base64 -w 76 "$CFG_BAD"
    echo '.'
    echo 'activate /run/fx/config-bad-exit.dhall'
} > "$WORK/req1.txt"
_i=0
while [ ! -S "$SOCK" ] && [ "$_i" -lt 60 ]; do sleep 0.5; _i=$((_i + 1)); done
[ -S "$SOCK" ] || { kill "$QPID" 2>/dev/null; fail "boot 1: chardev socket never appeared"; }
ctrl_session "$SOCK" "$WORK/req1.txt" "$CTRL_TRANSCRIPT"
echo "--- ctrl transcript ---"; cat "$CTRL_TRANSCRIPT"; echo "-----------------------"

# put: opened (OK), then terminated with the byte-count line
grep -q '^OK$' "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "put/activate: no OK in transcript"; }
PUT_BYTES=$(wc -c < "$CFG_BAD" | tr -d ' ')
grep -q "^OK put $PUT_BYTES bytes\$" "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "put: no 'OK put $PUT_BYTES bytes' line"; }

# activate: "activated version V_BAD2" then OK; V_BAD2 > v_good (the host
# never created a version above v_good — the only writer is the guest)
V_BAD2=$(sed -n 's/^activated version \([0-9][0-9]*\)$/\1/p' "$CTRL_TRANSCRIPT" | head -1)
[ -n "$V_BAD2" ] \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "activate: no 'activated version N' line in transcript"; }
[ "$V_BAD2" -gt "$V_GOOD" ] \
    || { kill "$QPID" 2>/dev/null; fail "activate: v$V_BAD2 not above v$V_GOOD (the host never created one — the guest must)"; }
sed -n "/^activated version/,\$p" "$CTRL_TRANSCRIPT" | grep -q '^OK$' \
    || { kill "$QPID" 2>/dev/null; fail "activate: no OK after the activated line"; }

# ── the RE-ARMED verdict: the activated generation must FAIL its own
# grace window — the console line (same verdict fx-init emits at boot)
# proves the boot decision ran AGAIN for the new generation.  Poll the
# console: the crasher exits within the 8s grace, but the transcript's
# 40s receive window may have closed first.
_i=0
while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
    grep -q "fx-init: boot-FAILED v$V_BAD2" "$WORK/console1.log" && break
    kill -0 "$QPID" 2>/dev/null || break
    sleep 0.5
    _i=$((_i + 1))
done
grep -q "fx-init: boot-FAILED v$V_BAD2" "$WORK/console1.log" \
    || { tail -40 "$WORK/console1.log"; kill "$QPID" 2>/dev/null; fail "boot 1: the activated v$V_BAD2 never got a boot-FAILED verdict (the re-arm did not run — g_boot_decided stayed latched for v_good)"; }
grep -q "fx-init: boot-ok v$V_BAD2" "$WORK/console1.log" \
    && { kill "$QPID" 2>/dev/null; fail "boot 1: v$V_BAD2 booted ok?! (the crasher must fail inside the re-armed grace window)"; }

# ── quiescence kill: the activation + the FAILED verdict's bootlog append
# must be ON THE DISK before the abrupt kill.
wait_disk_quiet
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
SHA1B=$(disk_sha)
[ "$SHA1" != "$SHA1B" ] \
    || fail "boot 1: disk.img unchanged after the ctrl session (the in-guest activation/verdict did not write)"

echo "=== boot 2: SAME image, no session — roll-forward from the DISK .bootlog past the failed v$V_BAD2 ==="
# MEASURED (first one-image run): after boot 1's IN-GUEST (v$V_BAD2,failed)
# verdict, the disk .bootlog's last entry is (v_bad2, failed) == CURRENT, so
# EVERY subsequent boot rolls forward at decide_boot_version time — BEFORE any
# service starts.  The two-image harness's middle boot (a DIFFERENT image
# re-failing v_bad via the adopt path) cannot exist in the one-image flow;
# the roll-forward proof lands HERE, on the first boot after the in-guest
# failure.
run_boot "$WORK/console2.log" 0
grep -q 'fx-init: disk store mounted (current v'"$V_BAD2"')' "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: disk current is not v$V_BAD2 (the in-guest activation did not persist)"; }
# the roll-forward line: only reachable when decide_boot_version read a disk
# .bootlog whose last entry is (v_bad2, failed) — a fresh ramfs cannot carry it
grep -q "fx-init: stale failed for v$V_BAD2; rolling forward to v" "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: no roll-forward line (the DISK .bootlog never recorded the in-guest failure)"; }
V_ROLLED=$(sed -n 's/.*fx-init: boot-ok v\([0-9][0-9]*\).*/\1/p' "$WORK/console2.log" | head -1)
[ -n "$V_ROLLED" ] || { tail -40 "$WORK/console2.log"; fail "boot 2: no boot-ok verdict after the roll-forward"; }
[ "$V_ROLLED" -gt "$V_BAD2" ] || fail "boot 2: rolled v$V_ROLLED not above v$V_BAD2 (not a roll-FORWARD)"
SHA2=$(disk_sha)
[ "$SHA1B" != "$SHA2" ] || fail "boot 2: disk.img unchanged (roll-forward did not write)"

echo "=== boot 3: SAME image — idempotent re-boot of the rolled-forward v$V_ROLLED ==="
run_boot "$WORK/console3.log" 0
grep -q "fx-init: boot-ok v$V_ROLLED" "$WORK/console3.log" \
    || { tail -40 "$WORK/console3.log"; fail "boot 3: want boot-ok v$V_ROLLED again (idempotence)"; }
SHA3=$(disk_sha)
[ "$SHA2" != "$SHA3" ] || fail "boot 3: disk.img unchanged (bootlog append missing)"

echo "qemu-rollback: PASS (ONE image; host built v$V_BAD,v$V_GOOD; guest put+activated the bad config to v$V_BAD2 over the channel; v$V_BAD2 FAILED in-guest; boot 2 rolled forward to v$V_ROLLED from the DISK .bootlog; boot 3 re-booted v$V_ROLLED ok)"
exit 0
