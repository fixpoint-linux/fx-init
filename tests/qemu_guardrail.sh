#!/bin/sh
# tests/qemu_guardrail.sh — the RECOVERY GUARDRAIL proof: recovery must
# TERMINATE when restored content keeps re-failing (the never-settling
# ratchet), WITHOUT touching legitimate single-failure recovery
# (tests/qemu_ctrl.sh + tests/qemu_boot_rollback.sh stay green unchanged).
#
# DETERMINISTIC REPEATED FAILURE, NO in-guest adversarial actor: the
# flapper fixture (tests/fixtures/fakesvc/fakesvc.c mode "flapper") is
# good-ONCE then bad-forever via a marker file OUTSIDE the store at
# /fx/disk/.flap-marker — the marker survives rollback (store relations
# only) and adopt (rm -rf of the store dir only), so every recovery that
# republishes the flapper generation re-breaks: the exact shape "the
# restored bracket re-breaks".  Restoring store content does NOT remove
# the marker.
#
# ONE image + ONE shared 512M disk + FIVE boots; the host activates ONLY
# config-flapper (v_flap), the image's ramfs CURRENT = v_flap:
#
#   boot 1 (channel): the guest seeds the disk at v_flap; flapper's FIRST
#          run finds no marker -> creates it -> heartbeats -> boot-ok
#          v_flap.  With QEMU STILL RUNNING the harness uploads
#          config-bad-exit (put /etc/bad.dhall + base64 + '.') and runs
#          `activate` IN-GUEST -> "activated version v_bad" (v_bad >
#          v_flap; the host never created it).  The successful activate
#          RE-ARMS the boot decision (init.zig activate arm), so the
#          crasher's exit lands INSIDE the new grace window ->
#          "boot-FAILED v_bad" on the console AND (v_bad, failed) on the
#          DISK .bootlog.  Quiesce + kill.
#   boot 2 (no session): stale (v_bad, failed) == CURRENT -> "stale
#          failed for v_bad; rolling forward to v_flap" (content-failure
#          count for v_flap's genhash is 0 — SINGLE-FAILURE SEMANTICS
#          INTACT: a candidate with no failed history recovers EXACTLY as
#          today).  The republished flapper content re-breaks (marker
#          survived) -> "boot-FAILED v_roll1" — the first content failure.
#   boot 3 (no session): stale (v_roll1, failed) -> roll forward to v_flap
#          AGAIN — count is now 1 < 2: a FIRST re-failure still recovers
#          (transient), the plan's threshold only refuses the REPEAT.
#          Re-breaks -> "boot-FAILED v_roll2" — the second content
#          failure of the SAME genhash (genhash(v_roll1) ==
#          genhash(v_roll2) == genhash(v_flap): rollback restores the
#          generation tuple verbatim).
#   boot 4 (no session): THE ASYMMETRY — the guardrail REFUSES: the
#          give-up line, NO "rolling forward" line, disk current STILL
#          v_roll2 (the version is FROZEN — the ratchet stops; boot-FAILED
#          v_roll2 at the SAME version, not a new v_roll3), and the manual
#          control channels stay up ("virtio control up" — manual
#          activate/rollback bypass decide_boot_version entirely, so a
#          refused AUTOMATIC recovery is never an operator lockout).
#   boot 5 (channel): repeat of boot 4 — the TERMINAL STATE IS STABLE:
#          give-up line again, current STILL v_roll2, boot-FAILED v_roll2 —
#          AND the no-lockout guarantee pinned BY BEHAVIOUR: a ctrl `status`
#          request sent while the machine HOLDS must be ANSWERED (^OK$) —
#          "virtio control up" only proves the listener exists; a
#          request->response roundtrip proves an operator can reach it
#          (manual activate/rollback are the recovery paths that bypass
#          decide_boot_version entirely).
#
# PRE-FIX this lane FAILS at boot 4: without the guardrail boot 4 prints
# "rolling forward to v_flap" and boots a NEW v_roll3 (> v_roll2), the
# never-settling ratchet — the assertion "no rolling-forward + current
# frozen at v_roll2" is the fail-before/pass-after asymmetry.
#
# BELTS: the disk.img sha256 must change across each boot (bootlog
# appends still land on a held machine); "virtio control up" in EVERY
# console; the TOTAL count of "rolling forward" lines across ALL consoles
# == 2 (boots 2+3 only); the derived measurement lines (post-fix only,
# asserted AFTER the give-up was seen, so the pre-fix failure point stays
# boot 4): boot 2 "(content failed 0x before, republish #0)", boot 3
# "(content failed 1x before, republish #1)", boot 4 the content-skip
# line "failed 2x; not recovering to it".
#
# Channel: same virtio-serial + nc -U contract as qemu_ctrl.sh (no -N: the
# half-close drops the chardev before the guest's response write).
#
# Env: FXSTORE/FX_ACTIVATE/FX_INIT_BIN/FX_SIBLINGS/QEMU_BOOT_TIMEOUT/
#      QEMU_KEEP — same contract as tests/qemu_boot_rollback.sh.
set -u

fail() { echo "qemu-guardrail: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-guardrail: SKIP ($*)"; exit 77; }

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
CFG_FLAP="$REPO/m3/config-flapper.dhall"
CFG_BAD="$REPO/m3/config-bad-exit.dhall"
BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-90}"

# ─── pinned kernel (scripts/kernel-pin.txt via scripts/fetch-kernel.sh) ───
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
[ "$GOT_SHA" = "$WANT_SHA" ] || fail "kernel pin mismatch — update scripts/kernel-pin.txt (want $WANT_SHA, got $GOT_SHA for $KERNEL)"

# ─── scratch ──────────────────────────────────────────────────────────────
SCRATCH="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$SCRATCH/qemugrd.XXXXXX")" || fail mktemp
SOCK="$WORK/chardev.sock"
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-guardrail: scratch kept at $WORK"' EXIT
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
echo "qemu-guardrail: channel writer: $CTRL_TOOL"

# ctrl_session SOCK REQFILE TRANSCRIPT — ONE connection, NO half-close
# (qemu_ctrl.sh's measured rationale); the 90s window spans the in-guest
# activate + the re-armed grace window (the crasher must exit INSIDE the
# new 8s window for its (v, failed) verdict to land).
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

# ─── freeze the package sources (qemu_boot_rollback.sh's shield, verbatim:
# the store hash content-addresses each package's whole clean src tree and
# the shared siblings can be modified concurrently by their own runs) ─────
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
echo "=== qemu-guardrail: freezing package sources (concurrent-writer shield) ==="
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
    echo "=== qemu-guardrail: toolchain-free provisioning ==="
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
            *)                : > "$STORE/$pd/.provisioned-by-qemu-guardrail" ;;
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

# ─── ONE store, ONE activation: ONLY the flapper config ───────────────────
# (the image's ramfs CURRENT = v_flap; the BAD config reaches the guest
# over the channel in boot 1 — every version above v_flap is guest-written)
echo "=== qemu-guardrail: activating flapper config (store $STORE) ==="
OUT_FLAP=$(activate "$STORE" "$CFG_FLAP") || fail "activate flapper failed: $OUT_FLAP"
V_FLAP=$(echo "$OUT_FLAP" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_FLAP" ] || fail "cannot parse flapper version from: $OUT_FLAP"
echo "$OUT_FLAP"

# ─── ONE image + ONE shared disk ──────────────────────────────────────────
echo "=== qemu-guardrail: building the ONE initramfs (ramfs CURRENT = v$V_FLAP; -p ships the guest pkgset for in-guest activate) ==="
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

disk_sha() { sha256sum "$DISK" | awk '{print $1}'; }
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

# run_boot CONSOLE WITH_CHANNEL — boot the ONE image on $DISK (qemu_ctrl.sh
# machinery): the chardev is attached in EVERY boot; boots 1 and 5 run ctrl
# sessions (QEMU stays alive; the session owns the kill), boots 2..4 connect
# nobody and settle on disk quiescence before the kill.
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
        return 0   # boot 1: the ctrl session owns the kill
    fi
    wait_disk_quiet
    kill "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null
    return 0
}

# wait_console CONSOLE PATTERN — poll an ALREADY-RUNNING boot's console
# (boot 1: QEMU is alive through the ctrl session; the re-armed verdict can
# land after the transcript's receive window closed).
wait_console() { # wait_console CONSOLE PATTERN
    _con=$1 _pat=$2
    _i=0
    while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
        grep -q "$_pat" "$_con" && return 0
        kill -0 "$QPID" 2>/dev/null || break
        sleep 0.5
        _i=$((_i + 1))
    done
    return 1
}

echo "=== boot 1: channel boot — seed the disk at v$V_FLAP (flapper's FIRST run is GOOD), then activate bad IN-GUEST ==="
SHA0=$(disk_sha)
run_boot "$WORK/console1.log" 1
grep -q 'fx-init: disk store mounted (current v'"$V_FLAP"')' "$WORK/console1.log" \
    || { tail -40 "$WORK/console1.log"; kill "$QPID" 2>/dev/null; fail "boot 1: no disk-store line (seed)"; }
grep -q "fx-init: boot-ok v$V_FLAP" "$WORK/console1.log" \
    || { tail -40 "$WORK/console1.log"; kill "$QPID" 2>/dev/null; fail "boot 1: want boot-ok v$V_FLAP (flapper's first run creates the marker and heartbeats)"; }
grep -q 'fx-init: virtio control up (/dev/vport' "$WORK/console1.log" \
    || { tail -40 "$WORK/console1.log"; kill "$QPID" 2>/dev/null; fail "boot 1: no virtio control up line"; }
SHA1=$(disk_sha)
[ "$SHA0" != "$SHA1" ] || { kill "$QPID" 2>/dev/null; fail "boot 1: disk.img unchanged (seed did not write)"; }

# ── the in-guest control session (QEMU still running): upload the BAD
# config and activate it IN-GUEST — the same M4-C flow as
# qemu_boot_rollback.sh.  The activate arm RE-ARMS the boot decision, so
# the crasher's exit writes (v_bad, failed) on the DISK .bootlog DURING
# this same boot — the entry boot 2's roll-forward reads.
_i=0
while [ ! -S "$SOCK" ] && [ "$_i" -lt 60 ]; do sleep 0.5; _i=$((_i + 1)); done
[ -S "$SOCK" ] || { kill "$QPID" 2>/dev/null; fail "boot 1: chardev socket never appeared"; }
CTRL_TRANSCRIPT="$WORK/ctrl.log"
{
    echo 'put /etc/bad.dhall'
    base64 -w 76 "$CFG_BAD"
    echo '.'
    echo 'activate /etc/bad.dhall'
} > "$WORK/req1.txt"
ctrl_session "$SOCK" "$WORK/req1.txt" "$CTRL_TRANSCRIPT"
echo "--- ctrl transcript ---"; cat "$CTRL_TRANSCRIPT"; echo "-----------------------"

grep -q '^OK$' "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "put/activate: no OK in transcript"; }
PUT_BYTES=$(wc -c < "$CFG_BAD" | tr -d ' ')
grep -q "^OK put $PUT_BYTES bytes\$" "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "put: no 'OK put $PUT_BYTES bytes' line"; }
V_BAD=$(sed -n 's/^activated version \([0-9][0-9]*\)$/\1/p' "$CTRL_TRANSCRIPT" | head -1)
[ -n "$V_BAD" ] \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "activate: no 'activated version N' line in transcript"; }
[ "$V_BAD" -gt "$V_FLAP" ] \
    || { kill "$QPID" 2>/dev/null; fail "activate: v$V_BAD not above v$V_FLAP (the host never created one — the guest must)"; }
sed -n "/^activated version/,\$p" "$CTRL_TRANSCRIPT" | grep -q '^OK$' \
    || { kill "$QPID" 2>/dev/null; fail "activate: no OK after the activated line"; }

# the RE-ARMED verdict: the activated generation must FAIL its own grace
# window while QEMU is still up (the (v_bad, failed) DISK entry this whole
# lane rests on).
wait_console "$WORK/console1.log" "fx-init: boot-FAILED v$V_BAD" \
    || { tail -40 "$WORK/console1.log"; kill "$QPID" 2>/dev/null; fail "boot 1: the activated v$V_BAD never got a boot-FAILED verdict (re-arm did not run)"; }
grep -q "fx-init: boot-ok v$V_BAD" "$WORK/console1.log" \
    && { kill "$QPID" 2>/dev/null; fail "boot 1: v$V_BAD booted ok?! (the crasher must fail inside the re-armed grace window)"; }

wait_disk_quiet
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
SHA1B=$(disk_sha)
[ "$SHA1" != "$SHA1B" ] \
    || fail "boot 1: disk.img unchanged after the ctrl session (the in-guest activation/verdict did not write)"

echo "=== boot 2: roll forward to v$V_FLAP (content failed 0x — SINGLE-FAILURE SEMANTICS INTACT), then the republished content re-breaks ==="
run_boot "$WORK/console2.log" 0
grep -q 'fx-init: disk store mounted (current v'"$V_BAD"')' "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: disk current is not v$V_BAD (the in-guest activation did not persist)"; }
grep -q "fx-init: stale failed for v$V_BAD; rolling forward to v$V_FLAP" "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: no roll-forward-to-v$V_FLAP line (a zero-failure candidate MUST still recover exactly as today)"; }
V_ROLL1=$(sed -n 's/.*fx-init: boot-FAILED v\([0-9][0-9]*\).*/\1/p' "$WORK/console2.log" | head -1)
[ -n "$V_ROLL1" ] \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: no boot-FAILED verdict (the recovered flapper content must re-break — marker survived)"; }
[ "$V_ROLL1" -gt "$V_BAD" ] || fail "boot 2: republished v$V_ROLL1 not above v$V_BAD (not a roll-FORWARD)"
grep -q "fx-init: boot-ok v$V_ROLL1" "$WORK/console2.log" \
    && fail "boot 2: v$V_ROLL1 booted ok?! (the marker must make the restored bracket re-fail)"
SHA2=$(disk_sha)
[ "$SHA1B" != "$SHA2" ] || fail "boot 2: disk.img unchanged (recovery/re-failure did not write)"

echo "=== boot 3: roll forward AGAIN (count 1 < 2 — a FIRST re-failure is still transient), then the SECOND content failure ==="
run_boot "$WORK/console3.log" 0
grep -q "fx-init: stale failed for v$V_ROLL1; rolling forward to v$V_FLAP" "$WORK/console3.log" \
    || { tail -40 "$WORK/console3.log"; fail "boot 3: no roll-forward-to-v$V_FLAP line (the FIRST re-failure of the content must still recover)"; }
V_ROLL2=$(sed -n 's/.*fx-init: boot-FAILED v\([0-9][0-9]*\).*/\1/p' "$WORK/console3.log" | head -1)
[ -n "$V_ROLL2" ] \
    || { tail -40 "$WORK/console3.log"; fail "boot 3: no boot-FAILED verdict (the recovered flapper content must re-break again)"; }
[ "$V_ROLL2" -gt "$V_ROLL1" ] || fail "boot 3: republished v$V_ROLL2 not above v$V_ROLL1 (not a roll-FORWARD)"
SHA3=$(disk_sha)
[ "$SHA2" != "$SHA3" ] || fail "boot 3: disk.img unchanged"

echo "=== boot 4: THE ASYMMETRY — the guardrail REFUSES (2 distinct failed versions carry v$V_FLAP's genhash) ==="
run_boot "$WORK/console4.log" 0
grep -q 'fx-init: recovery gave up' "$WORK/console4.log" \
    || { tail -40 "$WORK/console4.log"; fail "boot 4: no give-up line (the ratchet is unbounded — this is the pre-fix failure)"; }
grep -q 'rolling forward' "$WORK/console4.log" \
    && { tail -40 "$WORK/console4.log"; fail "boot 4: a rolling-forward line (the ratchet is unbounded — this is the pre-fix failure)"; }
grep -q 'fx-init: disk store mounted (current v'"$V_ROLL2"')' "$WORK/console4.log" \
    || { tail -40 "$WORK/console4.log"; fail "boot 4: disk current is not v$V_ROLL2 (the version must be FROZEN — no republish)"; }
grep -q "fx-init: boot-FAILED v$V_ROLL2" "$WORK/console4.log" \
    || { tail -40 "$WORK/console4.log"; fail "boot 4: no boot-FAILED v$V_ROLL2 (the held machine must re-fail at the SAME version, not a new one)"; }
grep -q "fx-init: boot-ok v" "$WORK/console4.log" \
    && fail "boot 4: a boot-ok verdict?! (the held flapper content must fail)"
grep -q 'fx-init: virtio control up (/dev/vport' "$WORK/console4.log" \
    || { tail -40 "$WORK/console4.log"; fail "boot 4: no virtio control up line (a refused AUTOMATIC recovery must never lock the operator out)"; }
SHA4=$(disk_sha)
[ "$SHA3" != "$SHA4" ] || fail "boot 4: disk.img unchanged (bootlog appends must still land on a held machine)"

echo "=== boot 5: the TERMINAL STATE IS STABLE — hold again, current STILL v$V_ROLL2 — and the no-lockout guarantee BY BEHAVIOUR (a ctrl request answered during the hold) ==="
run_boot "$WORK/console5.log" 1
grep -q 'fx-init: recovery gave up' "$WORK/console5.log" \
    || { tail -40 "$WORK/console5.log"; kill "$QPID" 2>/dev/null; fail "boot 5: no give-up line (the hold must repeat every boot)"; }
grep -q 'rolling forward' "$WORK/console5.log" \
    && { tail -40 "$WORK/console5.log"; kill "$QPID" 2>/dev/null; fail "boot 5: a rolling-forward line (the hold must be terminal)"; }
grep -q 'fx-init: disk store mounted (current v'"$V_ROLL2"')' "$WORK/console5.log" \
    || { tail -40 "$WORK/console5.log"; kill "$QPID" 2>/dev/null; fail "boot 5: disk current is not v$V_ROLL2 (the frozen version moved?!)"; }
grep -q "fx-init: boot-FAILED v$V_ROLL2" "$WORK/console5.log" \
    || { tail -40 "$WORK/console5.log"; kill "$QPID" 2>/dev/null; fail "boot 5: no boot-FAILED v$V_ROLL2"; }

# ── the no-lockout guarantee, pinned BY BEHAVIOUR: the verdict above was
# emitted from inside main_loop, so PID1 is serving — send ONE real request
# over the virtio channel and require a real response.  `status` is the
# read-only first move of manual recovery (activate/rollback bypass
# decide_boot_version entirely).  "virtio control up" alone is only the
# INSPECTION claim this replaces.
_i=0
while [ ! -S "$SOCK" ] && [ "$_i" -lt 60 ]; do sleep 0.5; _i=$((_i + 1)); done
[ -S "$SOCK" ] || { kill "$QPID" 2>/dev/null; fail "boot 5: chardev socket never appeared"; }
echo 'status' > "$WORK/req5.txt"
ctrl_session "$SOCK" "$WORK/req5.txt" "$WORK/ctrl5.log"
echo "--- boot-5 hold ctrl transcript ---"; cat "$WORK/ctrl5.log"; echo "---------------------------------"
grep -q '^boot_status:$' "$WORK/ctrl5.log" \
    || { cat "$WORK/ctrl5.log"; kill "$QPID" 2>/dev/null; fail "boot 5: the status request was not answered during the hold (OPERATOR LOCKOUT — the give-up must refuse only the automatic republish)"; }
grep -q '^OK$' "$WORK/ctrl5.log" \
    || { cat "$WORK/ctrl5.log"; kill "$QPID" 2>/dev/null; fail "boot 5: no OK for the status request during the hold (OPERATOR LOCKOUT)"; }

wait_disk_quiet
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
SHA5=$(disk_sha)
[ "$SHA4" != "$SHA5" ] || fail "boot 5: disk.img unchanged"

# ── BELTS ──────────────────────────────────────────────────────────────────
# the virtio listener is image-level: up in EVERY boot's console (boots
# 2/3 already asserted their verdicts; assert the channel belt on all).
_con=1
while [ "$_con" -le 5 ]; do
    grep -q 'fx-init: virtio control up (/dev/vport' "$WORK/console$_con.log" \
        || fail "belt: boot $_con has no virtio control up line"
    _con=$((_con + 1))
done
# exactly TWO roll-forwards in the whole run (boots 2+3; the hold boots none)
_RF=$(cat "$WORK"/console1.log "$WORK"/console2.log "$WORK"/console3.log "$WORK"/console4.log "$WORK"/console5.log \
    | grep -c 'rolling forward')
[ "$_RF" = "2" ] \
    || fail "belt: want exactly 2 'rolling forward' lines across all consoles (got $_RF)"

# the DERIVED measurement lines (post-fix only — asserted here, AFTER the
# give-up, so the pre-fix failure point stays boot 4): the per-recovery
# line names the content's genhash and its PRIOR failure count + republish
# index; boot 4's skip line names the count that crossed the threshold.
grep -q 'fx-init: recovery to v'"$V_FLAP"' content genhash=' "$WORK/console2.log" \
    || fail "belt: boot 2 has no measurement line (recovery to v$V_FLAP)"
grep -q '(content failed 0x before, republish #0)' "$WORK/console2.log" \
    || fail "belt: boot 2 measurement line must say 'content failed 0x before, republish #0'"
grep -q 'fx-init: recovery to v'"$V_FLAP"' content genhash=' "$WORK/console3.log" \
    || fail "belt: boot 3 has no measurement line (recovery to v$V_FLAP)"
grep -q '(content failed 1x before, republish #1)' "$WORK/console3.log" \
    || fail "belt: boot 3 measurement line must say 'content failed 1x before, republish #1'"
grep -q 'failed 2x; not recovering to it' "$WORK/console4.log" \
    || fail "belt: boot 4 has no content-skip line ('failed 2x; not recovering to it')"
grep -q 'fx-init: recovery to v'"$V_FLAP"' content genhash=' "$WORK/console4.log" \
    && fail "belt: boot 4 must have NO recovery measurement line (nothing was recovered)"

echo "qemu-guardrail: PASS (ONE image; host built v$V_FLAP; guest activated v$V_BAD over the channel; boot2 recovered to v$V_ROLL1, boot3 to v$V_ROLL2 (both re-broke — the marker survived); boot4+5 HELD at v$V_ROLL2 with the give-up line; a ctrl status request was ANSWERED during the boot-5 hold — no operator lockout, pinned by behaviour; exactly 2 roll-forwards)"
exit 0
