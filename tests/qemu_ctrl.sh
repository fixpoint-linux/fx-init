#!/bin/sh
# tests/qemu_ctrl.sh — M4 SECTION C: drive the fx-init control socket
# IN-GUEST over a virtio-serial channel (plan: handoff-image-bc-plan, C).
#
# ONE image + ONE shared 512M disk + THREE boots; the store is advanced
# WITHOUT building a second host-activated initramfs:
#
#   host side: activate config-bad-exit FIRST (v_bad), then config-good
#          (v_good > v_bad) on ONE store — so v_bad is published BELOW
#          v_good in the same store db (fx_store_rollback's target).  ONE
#          initramfs is built whose ramfs CURRENT = v_good (the whole
#          store ships in the initramfs, v_bad published below v_good).
#   boot 1 (with the channel): the guest seeds the disk at v_good and boots
#          it ok.  With QEMU STILL RUNNING the harness connects to the
#          virtserialport's chardev unix socket and sends two commands:
#            "status"     -> expect the boot_status/generation_current
#                            tables ending in OK (live-guest proof)
#            "rollback N" (N = v_bad) -> expect
#                            "rolled back to version N (current v_ctrl)"
#                            then OK — the guest REPUBLISHES v_bad as
#                            v_ctrl > v_good, a pure in-guest store op.
#          Then the disk is drained (quiescence) and QEMU is killed with
#          the channel socket closed.
#   boot 2 (SAME image, NO channel): disk CURRENT v_ctrl > ramfs v_good =>
#          no adopt (directional rule) => boots v_ctrl.  v_ctrl NEVER
#          EXISTED at image build time — the host activated only v_bad and
#          v_good, and the image carries no v_ctrl anywhere — so the ONLY
#          possible writer of v_ctrl is the guest's own rollback over the
#          channel.  The crasher fails in grace => "boot-FAILED v_ctrl".
#          This is the in-guest proof: a host-built-state boot cannot
#          produce this line.
#   boot 3 (SAME image): disk last = (v_ctrl, failed) == CURRENT =>
#          "stale failed for v_ctrl; rolling forward to v_good" and
#          boot-ok v_roll with v_roll > v_ctrl > v_good.
#
# BELTS: the disk.img sha256 must change across each boot; the console
# must carry "fx-init: virtio control up (/dev/vportNpM)" in EVERY boot
# (the listener is image-level, not boot-1-only).
#
# Channel: qemu -chardev socket,server=on,wait=off -device virtio-serial-pci
# -device virtserialport,chardev=fxctl0,name=fxctl0 (CONFIG_VIRTIO_CONSOLE=y
# + CONFIG_VIRTIO_PCI=y built into the pinned kernel — no module to ship).
# Host writer: nc -w 5 -U (NOT -N: MEASURED on this host, -N's half-close makes
# qemu tear the chardev down before the guest's response write, silently
# dropping it); the guest needs no EOF — requests are newline-delimited, so nc
# idles out via -w 5 after the responses arrive.  python3 fallback if no nc -U.
#
# Env: FXSTORE/FX_ACTIVATE/FX_INIT_BIN/FX_SIBLINGS/QEMU_BOOT_TIMEOUT/
#      QEMU_KEEP — same contract as tests/qemu_boot_rollback.sh.
set -u

fail() { echo "qemu-ctrl: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-ctrl: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
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

# ─── scratch (mktemp defines $WORK before anything references it) ─────────
SCRATCH="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$SCRATCH/qemuctl.XXXXXX")" || fail mktemp
SOCK="$WORK/chardev.sock"
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-ctrl: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
STORE="$WORK/store"
ROOT="$WORK/root"
DISK="$WORK/disk.img"
mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp"

# ─── host writer for the channel ──────────────────────────────────────────
# OpenBSD nc at /usr/bin/nc (MEASURED: -U listed in `nc -h`); the
# python3 fallback exists but was not needed on this host.
CTRL_TOOL=""
if nc -h 2>&1 | grep -q -- '-U.*UNIX domain socket'; then
    CTRL_TOOL=nc
elif command -v python3 >/dev/null 2>&1; then
    CTRL_TOOL=python3
else
    skip "no nc with -U and no python3 — cannot write the virtio chardev socket"
fi
echo "qemu-ctrl: channel writer: $CTRL_TOOL"

# ctrl_session SOCK REQFILE TRANSCRIPT — send the request file's lines over
# the chardev socket in ONE connection (NO half-close — MEASURED: -N makes
# qemu tear the chardev down before the guest's response write, silently
# dropping it); requests are newline-delimited, so the guest needs no EOF.
# nc idles out via -w 5 after the responses arrive; timeout(1) is the hard
# backstop.
ctrl_session() { # ctrl_session SOCK REQFILE TRANSCRIPT
    _sock=$1 _req=$2 _out=$3
    case "$CTRL_TOOL" in
        nc) timeout 30 nc -w 5 -U "$_sock" < "$_req" > "$_out" 2>&1 ;;
        python3) timeout 30 python3 -c '
import socket, sys, time
sock, req = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.sendall(open(req, "rb").read())
# NO shutdown(SHUT_WR): the guest writes responses on the same connection
# and a half-close makes qemu drop the chardev before they are written.
s.settimeout(8)
chunks = []
deadline = time.time() + 8
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

# ─── freeze the package sources (REQUIRED: two activations must hash the
# same trees — cloned verbatim from qemu_boot_rollback.sh) ──────────────────
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
echo "=== qemu-ctrl: freezing package sources (concurrent-writer shield) ==="
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

# ─── provisioning (toolchain-free path; same shape as qemu_boot_rollback.sh) ──
FXS="${FXSTORE:-}"
FXA="${FX_ACTIVATE:-}"
if [ -z "$FXS" ] || [ -z "$FXA" ]; then
    echo "=== qemu-ctrl: toolchain-free provisioning ==="
    command -v zig >/dev/null 2>&1 || skip "zig not found (build the zig port or set FXSTORE+FX_ACTIVATE)"
    export FX_SIBLINGS="${FX_SIBLINGS:-$(cd "$REPO/.." && pwd)}"
    [ -f "$FX_SIBLINGS/datalog-dafsa/zig-out/lib/libdatalog.so" ] \
        || skip "libdatalog.so missing at $FX_SIBLINGS/datalog-dafsa/zig-out/lib"
    [ -x "$FX_SIBLINGS/dhake/dhake.com" ] || skip "prebuilt dhake.com missing"

    echo "--- zig build (this repo) ---"
    # NOTE: plain `zig build` fails on this repo at HEAD for an UNRELATED
    # target (log_probe_live: its C driver needs vendor/datalog-dafsa/src/dl.h,
    # absent at HEAD — measured).  Everything this harness needs (fx-init,
    # fx-activate, fxctl, activate_paths) is installed before that failure.
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
            *)                : > "$STORE/$pd/.provisioned-by-qemu-ctrl" ;;
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
# (rollback harness composition: v_bad stays published BELOW v_good in the
# same db — fx_store_rollback's target.  The image's ramfs CURRENT = v_good.)
echo "=== qemu-ctrl: activating bad-exit config FIRST (store $STORE) ==="
OUT_BAD=$(activate "$STORE" "$CFG_BAD") || fail "activate bad failed: $OUT_BAD"
V_BAD=$(echo "$OUT_BAD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_BAD" ] || fail "cannot parse bad version from: $OUT_BAD"
echo "$OUT_BAD"

echo "=== qemu-ctrl: activating good config on top (over v$V_BAD) ==="
OUT_GOOD=$(activate "$STORE" "$CFG_GOOD") || fail "activate good failed: $OUT_GOOD"
V_GOOD=$(echo "$OUT_GOOD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_GOOD" ] || fail "cannot parse good version from: $OUT_GOOD"
echo "$OUT_GOOD"
[ "$V_GOOD" -gt "$V_BAD" ] || fail "good version v$V_GOOD not above bad v$V_BAD (rollback needs v_bad published below v_good)"

# ─── ONE image + ONE shared disk ──────────────────────────────────────────
echo "=== qemu-ctrl: building the ONE initramfs (ramfs CURRENT = v$V_GOOD, v$V_BAD published below) ==="
sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/img.cpio.gz" \
    || fail "mkinitramfs failed"
qemu-img create -q "$DISK" 512M || fail "qemu-img create failed"
# Format the disk with a JOURNALED ext4 BEFORE the first boot.  The guest's
# busybox mkfs.ext2 cannot add a journal (no -J/-O), and a NOJOURNAL ext4
# leaves inode/block BITMAPS to lazy writeback — an abrupt harness kill then
# tears them off the inode table and the NEXT boot's first inode allocation
# dies at __ext4_new_inode:1284 "doubly allocated?" (MEASURED: e2fsck -fn
# on a killed nojournal disk shows both missing allocations and missing
# frees in the bitmaps).  A journal makes the kill crash-safe the same way
# ext4 does on a real power cut.  The guest's ext4.ko already pulls in
# jbd2.ko (DISK_MODULE_ORDER in init.zig), so it mounts a journaled fs
# unchanged; ensure_disk_store's blank-disk mkfs path is simply never taken.
# MEASURED: the host (uid 1001) can mke2fs a regular image file (no block
# device needed); the journal size 4M is ample for a 512M fs.
"$MKE2FS" -q -t ext4 -J size=4 "$DISK" >/dev/null 2>&1 \
    || fail "mke2fs -t ext4 (journaled) failed — install e2fsprogs or set a host mke2fs on PATH"

FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

disk_sha() { sha256sum "$DISK" | awk '{print $1}'; }
# sha of an arbitrary image, empty on error — for the quiescence poll, where
# a missing file must not satisfy the [ -n ] guard.
disk_sha_quiet() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# wait_disk_quiet — the rollback harness's quiescence poll, verbatim in
# spirit: the verdict can precede the last sync-covered write, so wait for
# the disk image's sha256 to stop changing before the abrupt kill.
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

# run_boot CONSOLE WITH_SESSION — boot the ONE image on $DISK.  The
# virtio-serial chardev + devices are attached in EVERY boot (the plan's
# "per boot adds"); the listener must come up each time (belt below).  The
# difference is only WHO USES it: boot 1 runs the ctrl session (QEMU stays
# alive; the session owns the kill), boots 2/3 connect nobody — the port
# sits unconnected (peer-gone latched, inert) and the boot proves the
# DISK state alone.
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
    _verdict=0
    while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
        if grep -q 'fx-init: boot-ok v\|fx-init: boot-FAILED v\|fx-init: no generation to boot' "$_con"; then
            _verdict=1
            break
        fi
        kill -0 "$QPID" 2>/dev/null || break
        sleep 0.5
        _i=$((_i + 1))
    done
    if [ "$_chan" = "1" ]; then
        return 0   # boot 1: the ctrl session owns the kill
    fi
    # boots 2/3: settle on disk quiescence (the verdict can precede the last
    # sync-covered write), THEN kill — leaving QEMU alive would lock the
    # disk against the next boot (MEASURED: boot 3 died on the write lock).
    wait_disk_quiet
    kill "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null
    return 0
}

echo "=== boot 1: channel boot — seed the disk at v$V_GOOD, then drive the ctrl session IN-GUEST ==="
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
CTRL_TRANSCRIPT="$WORK/ctrl.log"
printf 'status\nrollback %s\n' "$V_BAD" > "$WORK/req.txt"
ctrl_session "$SOCK" "$WORK/req.txt" "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; fail "ctrl session: the channel write failed (exit $? — connect/timeout)"; }
echo "--- ctrl transcript ---"; cat "$CTRL_TRANSCRIPT"; echo "-----------------------"

# "status" must answer the live tables + OK.
grep -q '^OK$' "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; echo "--- console tail ---"; tail -20 "$WORK/console1.log"; kill "$QPID" 2>/dev/null; fail "status: no OK in transcript (guest did not answer over the channel)"; }
grep -q 'generation_current:' "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "status: no generation_current table in transcript"; }

# "rollback $V_BAD" — response format MEASURED (init.zig handle_request):
#   "rolled back to version <v> (current <new>)" + OK.
V_CTRL=$(sed -n "s/^rolled back to version $V_BAD (current \([0-9][0-9]*\))$/\1/p" "$CTRL_TRANSCRIPT" | head -1)
[ -n "$V_CTRL" ] \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "rollback: no 'rolled back to version $V_BAD (current N)' line in transcript"; }
[ "$V_CTRL" -gt "$V_GOOD" ] \
    || { kill "$QPID" 2>/dev/null; fail "rollback: new current v$V_CTRL not above v$V_GOOD (republish must be monotonic)"; }
sed -n "/^rolled back to version/,\$p" "$CTRL_TRANSCRIPT" | grep -q '^OK$' \
    || { kill "$QPID" 2>/dev/null; fail "rollback: no OK after the rollback line"; }

# ── the put/rm round trip (M4 E): put under /etc/ (OUTSIDE the old /run/
# whitelist) + rm it back; a negative rm on an allowlist-escape path proves
# the gate.  Same connection discipline (no half-close).
{
    echo 'put /etc/probe-e.dhall'
    base64 -w 76 "$CFG_GOOD"
    echo '.'
    echo 'rm /etc/probe-e.dhall'
    echo 'rm /bin/sh'
    echo 'put /bin/sh'
} > "$WORK/req-e.txt"
CTRL_TRANSCRIPT="$WORK/ctrl-e.log"
ctrl_session "$SOCK" "$WORK/req-e.txt" "$CTRL_TRANSCRIPT"
echo "--- ctrl-e transcript (put/rm round trip) ---"; cat "$CTRL_TRANSCRIPT"; echo "----------------------------------------------"
ETC_BYTES=$(wc -c < "$CFG_GOOD" | tr -d ' ')
# put /etc/probe-e.dhall opened + landed with the byte-count line
grep -q '^OK$' "$CTRL_TRANSCRIPT" || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "put/rm: no OK in transcript"; }
grep -q "^OK put $ETC_BYTES bytes\$" "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "put: no 'OK put $ETC_BYTES bytes' line (the /etc/ widen did not take)"; }
# rm of the just-put file succeeded
grep -q '^OK rm /etc/probe-e.dhall$' "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "rm: no 'OK rm /etc/probe-e.dhall' line"; }
# the allowlist gate: /bin/sh is outside /run/,/etc/,/tmp/ -> ERR both ways
grep -q "^ERR rm: path must be under" "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "rm /bin/sh: no ERR line (the allowlist gate did not reject it)"; }
grep -q '^ERR put: path must be under' "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "put /bin/sh: no ERR line (the allowlist gate did not reject it)"; }
# and the guest still HAS its /bin/sh (the rm never ran) — the ERR above is
# the gate proof; belt-and-braces: exactly ONE 'OK rm' line in the transcript
# (the /etc/probe-e.dhall one), never a second for /bin/sh.
[ "$(grep -c '^OK rm ' "$CTRL_TRANSCRIPT")" = "1" ] \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "rm: expected exactly one 'OK rm' line (got $(grep -c '^OK rm ' "$CTRL_TRANSCRIPT")) — the /bin/sh rm must not succeed"; }

# ── quiescence kill: the ctrl-session writes must be ON THE DISK before the
# abrupt kill (the rollback branch's sync() flushes CURRENT; this poll waits
# out the remaining metadata churn).  The channel socket is closed by nc
# exiting, so the guest latches peer-gone — no channel session can race the
# kill. ────────────────────────────────────────────────────────────────────
wait_disk_quiet
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
SHA1B=$(disk_sha)
[ "$SHA1" != "$SHA1B" ] \
    || fail "boot 1: disk.img unchanged after the ctrl session (the rollback did not write)"

echo "=== boot 2: SAME image, no session — the guest-written v$V_CTRL must boot and FAIL ==="
run_boot "$WORK/console2.log" 0
grep -q 'fx-init: disk store mounted (current v'"$V_CTRL"')' "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: disk current is not v$V_CTRL (the in-guest rollback did not persist)"; }
grep -q 'fx-init: virtio control up (/dev/vport' "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: no virtio control up line"; }
grep -q "fx-init: boot-FAILED v$V_CTRL" "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: want boot-FAILED v$V_CTRL"; }
grep -q "fx-init: boot-ok v$V_CTRL" "$WORK/console2.log" \
    && fail "boot 2: v$V_CTRL booted ok?! (the crasher must fail in grace)"
SHA2=$(disk_sha)
[ "$SHA1B" != "$SHA2" ] || fail "boot 2: disk.img unchanged ((v$V_CTRL,failed) never landed)"

echo "=== boot 3: SAME image — roll-forward past the failed v$V_CTRL ==="
run_boot "$WORK/console3.log" 0
grep -q "fx-init: stale failed for v$V_CTRL; rolling forward to v$V_GOOD" "$WORK/console3.log" \
    || { tail -40 "$WORK/console3.log"; fail "boot 3: no roll-forward line"; }
grep -q 'fx-init: virtio control up (/dev/vport' "$WORK/console3.log" \
    || { tail -40 "$WORK/console3.log"; fail "boot 3: no virtio control up line"; }
V_ROLLED=$(sed -n 's/.*fx-init: boot-ok v\([0-9][0-9]*\).*/\1/p' "$WORK/console3.log" | head -1)
[ -n "$V_ROLLED" ] || { tail -40 "$WORK/console3.log"; fail "boot 3: no boot-ok verdict"; }
[ "$V_ROLLED" -gt "$V_CTRL" ] || fail "boot 3: rolled v$V_ROLLED not above v$V_CTRL (not a roll-FORWARD)"
SHA3=$(disk_sha)
[ "$SHA2" != "$SHA3" ] || fail "boot 3: disk.img unchanged (roll-forward did not write)"

echo "qemu-ctrl: PASS (host built v$V_BAD,v$V_GOOD; guest rolled back over the channel to v$V_CTRL; boot2 FAILED on the guest-written v$V_CTRL; boot3 rolled forward to v$V_ROLLED)"
exit 0
