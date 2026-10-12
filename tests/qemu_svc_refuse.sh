#!/bin/sh
# tests/qemu_svc_refuse.sh — THE REFUSED IN-GUEST ACTIVATION PROOF: a
# refused activation must leave an HONEST record and a PINNED boot decision,
# not a vacuous boot-ok and no marker.
#
# THE TWO DEFECTS THIS LANE MEASURES (both in zig/src/init.zig's in-guest
# `activate` arm, both fixed by the re-arm-accounting unit):
#  (1) the refusal arm returned WITHOUT pinning the boot decision's latch and
#      WITHOUT re-arming, so the main loop kept judging an EMPTY service
#      table (read_store_facts frees it) and at grace expiry recorded a
#      VACUOUS "boot-ok" for the generation PID1 had just REFUSED — the
#      store then holds an ok verdict for a configuration the substrate
#      rejected, and the next boot's roll-forward reads it.  The boot path
#      pre-decides exactly this away (init.zig:4772-4778); the activate path
#      did not;
#  (2) the activation wrote NO on-disk marker for the activated version: a
#      refused generation left NOTHING in .bootlog, so the next boot had no
#      record to roll forward from.
#
# WHAT THIS LANE DOES — ONE store, ONE image, THREE configs, TWO boots per
# arm (treatment = working tree; control = git archive of the pinned pre-fix
# revision):
#   host side: ONE store; activate cfg-ok (v1: one healthy fakesvc service,
#          bootGraceMs 8000).  ONE initramfs built with -p (ships
#          /usr/fx/package-set.dhall, the frozen-absolute pkgset the in-guest
#          fx-activate needs).
#   boot 1: the guest seeds the 512M disk at v1 and boots it ok.  With QEMU
#          STILL RUNNING the harness uploads two configs over the
#          virtio-serial channel and drives the SAME fx-activate the in-guest
#          handler drives:
#            * cfg-ok2 (healthy, hostname changed, bootGraceMs 15000) -> v2.
#              The successful activate RE-ARMS the boot decision and opens a
#              LONG grace window; v1's own verdict is already ok on the
#              disk, which is what makes boot 2's roll-forward reachable.
#            * cfg-wide (70 services) -> v3, REFUSED in-guest (read_store_facts
#              rc -2, the SVC_MAX bound).  The refusal lands INSIDE v2's
#              re-armed grace window — the defect's precondition exactly:
#              the latch is 0 and the table is empty.
#          TREATMENT: the console MUST NOT carry "boot-ok v3"; the DISK
#            .bootlog MUST end with "<v3> in-progress" followed by "<v3>
#            failed" (the activated window's marker, then the honest verdict).
#          CONTROL (pinned pre-fix revision): the console MUST carry the
#            vacuous "boot-ok v3", and the disk .bootlog MUST carry NO
#            "in-progress" line for v3 — the fail-before, on the SAME
#            sequence of control commands.
#   boot 2: SAME image, no session.
#          TREATMENT: "stale failed for v3; rolling forward to v1" and a
#            boot-ok for the republished generation (the refused version is
#            never a roll-forward TARGET: it carries no ok).
#          CONTROL: NO roll-forward line at all, and "boot-FAILED v3" — the
#            machine sticks on the refused generation every boot, which is
#            the state the defect leaves behind (its forged ok is what
#            bootlog_last reads).
#
# THE ASYMMETRY: each arm's assertions are the other's failures, on one host
# store, one image, one control-command sequence.  The control is a FIXED
# revision (git cat-file guard) and a cmp guard proves its init.zig DIFFERS
# from the working tree (a control equal to its subject proves nothing).
#
# Env: FX_SIBLINGS/QEMU_BOOT_TIMEOUT/QEMU_KEEP — same contract as
# tests/qemu_svc_limit.sh.
set -u

fail() { echo "qemu-svcrefuse: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-svcrefuse: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
command -v base64 >/dev/null 2>&1 || skip "base64 not found (channel upload)"
command -v git >/dev/null 2>&1    || skip "git not found (pinned control)"
command -v zig >/dev/null 2>&1    || skip "zig not found (build both arms)"
[ -e /dev/kvm ]                   || skip "/dev/kvm absent"
[ -w /dev/kvm ]                   || skip "/dev/kvm not writable"
MKE2FS=""
for _p in mke2fs /sbin/mke2fs /usr/sbin/mke2fs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then MKE2FS="$_p"; break; fi
done
[ -n "$MKE2FS" ] || skip "mke2fs not found (e2fsprogs)"
DEBUGFS=""
for _p in debugfs /sbin/debugfs /usr/sbin/debugfs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then DEBUGFS="$_p"; break; fi
done
[ -n "$DEBUGFS" ] || skip "debugfs not found (e2fsprogs)"
E2FSCK=""
for _p in e2fsck /sbin/e2fsck /usr/sbin/e2fsck; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then E2FSCK="$_p"; break; fi
done
[ -n "$E2FSCK" ] || skip "e2fsck not found (e2fsprogs — journal replay for the raw-disk read)"
CTRL_TOOL=""
if nc -h 2>&1 | grep -q -- '-U.*UNIX domain socket'; then
    CTRL_TOOL=nc
elif command -v python3 >/dev/null 2>&1; then
    CTRL_TOOL=python3
else
    skip "no nc with -U and no python3 — cannot write the virtio chardev socket"
fi

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"

# ─── the PINNED control (a FIXED revision, never HEAD) ────────────────────
# ca9cb06 = the tree immediately before this unit: its activate arm returns
# from the refusal WITHOUT pinning the latch and WITHOUT writing anything to
# .bootlog, which is the pair of defects measured here.
PIN_REV=ca9cb06
git cat-file -e "$PIN_REV^{commit}" 2>/dev/null \
    || skip "pinned control revision $PIN_REV not in this repository (shallow clone?) — refusing to test against an unpinned HEAD"

NSVC_WIDE=70
NSVC_OK=1
GRACE_OK=8000
GRACE_OK2=15000
BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-90}"
# how long the in-guest refusal's re-armed grace window is watched before the
# VM is killed: GRACE_OK2 plus margin.  A vacuous ok (the control) lands at
# the END of that window; the treatment must still show NONE after it.
GRACE_WATCH=25

# ─── pinned kernel ────────────────────────────────────────────────────────
PIN="$REPO/scripts/kernel-pin.txt"
[ -f "$PIN" ] || skip "scripts/kernel-pin.txt missing"
FETCH_OUT=$(sh "$REPO/scripts/fetch-kernel.sh" 2>&1)
FETCH_RC=$?
echo "$FETCH_OUT"
[ "$FETCH_RC" = 0 ] || [ "$FETCH_RC" = 77 ] || fail "fetch-kernel failed (rc=$FETCH_RC)"
[ "$FETCH_RC" = 0 ] || skip "pinned kernel artifact unavailable (offline) — no host-kernel fallback by design"
KERNEL="${FX_KERNEL_CACHE:-$REPO/.kernel-cache}/kernel/vmlinuz"
WANT_SHA=$(sed -n 's/^vmlinuz_sha256 //p' "$PIN")
[ -n "$WANT_SHA" ] || skip "kernel pin file malformed"
[ -r "$KERNEL" ] || skip "fetched vmlinuz missing at $KERNEL"
GOT_SHA=$(sha256sum "$KERNEL" | awk '{print $1}')
[ "$GOT_SHA" = "$WANT_SHA" ] || fail "kernel pin mismatch"

SCRATCH="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$SCRATCH/qemusvcref.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-svcrefuse: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
echo "qemu-svcrefuse: channel writer: $CTRL_TOOL"

# ─── the three configs ────────────────────────────────────────────────────
# gen_cfg FILE HOSTNAME GRACE_MS NSVC — one service per row, argv
# ["fakesvc","ok"] (a heartbeat that starts and stays started), distinct
# names so svc_name_cb's dedupe cannot mask the count.
gen_cfg() { # gen_cfg FILE HOSTNAME GRACE_MS NSVC
    _f="$1" _h="$2" _g="$3" _n="$4"
    {
        printf 'let Probe = < Tcp : Natural | Unix : Text | File : Text >\n'
        printf 'let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,\n                restart : Optional Text, backoffMs : Optional Natural,\n                probe : Optional Probe,\n                env : Optional (List { key : Text, value : Text }) }\n'
        printf 'let User = { name : Text, uid : Natural, groups : List Text }\n'
        printf 'in  { hostname = "%s"\n' "$_h"
        printf '    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]\n'
        printf '    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]\n'
        printf '    , services = ['
        _i=1
        while [ "$_i" -le "$_n" ]; do
            if [ "$_n" = 1 ]; then _nm=heartbeat; else _nm=$(printf 'svc%02d' "$_i"); fi
            [ "$_i" -gt 1 ] && printf ','
            printf '\n        { name = "%s", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",\n            on = "all", restart = Some "always", backoffMs = Some 200,\n            probe = None Probe,\n            env = None (List { key : Text, value : Text }) }' "$_nm"
            _i=$((_i + 1))
        done
        printf ' ]\n'
        printf '    , extraEtc = None (List { path : Text, content : Text })\n'
        printf '    , bootGraceMs = Some %s\n' "$_g"
        printf '    , agentService = None Text\n'
        printf '    }\n'
    } > "$_f"
}
CFG_OK="$WORK/config-ok.dhall"
CFG_OK2="$WORK/config-ok2.dhall"
CFG_WIDE="$WORK/config-svc70.dhall"
gen_cfg "$CFG_OK"  "fixbox"     "$GRACE_OK"  "$NSVC_OK"
gen_cfg "$CFG_OK2" "fixbox-two" "$GRACE_OK2" "$NSVC_OK"
gen_cfg "$CFG_WIDE" "fixbox-wide" 8000       "$NSVC_WIDE"
echo "qemu-svcrefuse: generated 3 configs (ok=$NSVC_OK svc/grace ${GRACE_OK}ms, ok2=$NSVC_OK svc/grace ${GRACE_OK2}ms, wide=$NSVC_WIDE svc)"
[ "$GRACE_OK2" -gt "$((GRACE_WATCH / 2))" ] \
    || fail "the re-arm window ($GRACE_OK2 ms) is too short for the channel sequence — the refusal could land AFTER the verdict"

# ─── freeze the package sources (concurrent-writer shield) ────────────────
freeze_src() {
    mkdir -p "$2"
    ( cd "$1" && find . \
        -not -path "./.git/*"       -not -name ".git" \
        -not -path "./build-tmp/*"  -not -name "build-tmp" \
        -not -path "./zig-out/*"    -not -name "zig-out" \
        -not -path "./zig/zig-out/*" \
        -not -path "./zig/.zig-cache/*" -not -path "./zig/.zig-global/*" \
        -not -path "./node_modules/*" -not -name "node_modules" \
        -not -path "./elm-stuff/*"   -not -name "elm-stuff" \
        -not -path "./dist/*"     -not -name "dist" \
        -not -name "*.o" -not -name "*.a" -not -name "*.so" -not -name "*.com" \
        -not -name "dl-test-*" -not -name ".ape-*" \
        -print0 | cpio -pdm0 "$2" ) >/dev/null 2>&1 \
        || fail "cannot snapshot $1 -> $2"
}
echo "=== qemu-svcrefuse: freezing package sources ==="
SIBS="$(cd "$REPO/.." && pwd)"
[ -f "$SIBS/datalog-dafsa/zig-out/lib/libdatalog.so" ] \
    || skip "libdatalog.so missing at $SIBS/datalog-dafsa/zig-out/lib"
[ -x "$SIBS/dhake/dhake.com" ] || skip "prebuilt dhake.com missing"
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
DLDIR="$SIBS/datalog-dafsa/zig-out/lib"

# ─── build BOTH arms ──────────────────────────────────────────────────────
echo "=== qemu-svcrefuse: building the TREATMENT (working tree) ==="
( cd "$REPO/zig" && zig build install ) > "$WORK/build-treat.log" 2>&1 \
    || { cat "$WORK/build-treat.log"; fail "treatment zig build failed"; }
TREAT_BIN="$REPO/zig/zig-out/bin"
for b in fx-init fx-activate fxctl activate_paths; do
    [ -x "$TREAT_BIN/$b" ] || fail "treatment build produced no $b"
done

echo "=== qemu-svcrefuse: building the CONTROL (pinned $PIN_REV via git archive) ==="
PINROOT="$WORK/pin"
mkdir -p "$PINROOT/fx-init"
git archive "$PIN_REV" | tar -x -C "$PINROOT/fx-init" \
    || skip "git archive $PIN_REV failed"
ln -s "$SIBS/datalog-dafsa" "$PINROOT/datalog-dafsa"
ln -s "$SIBS/dhall-c"       "$PINROOT/dhall-c"
ln -s "$SIBS/fxstore"       "$PINROOT/fxstore"
( cd "$PINROOT/fx-init/zig" && zig build install ) > "$WORK/build-ctrl.log" 2>&1 \
    || { cat "$WORK/build-ctrl.log"; fail "control zig build failed"; }
CTRL_BIN="$PINROOT/fx-init/zig/zig-out/bin"
for b in fx-init fx-activate fxctl activate_paths; do
    [ -x "$CTRL_BIN/$b" ] || fail "control build produced no $b"
done

# ─── the cmp guard: the pinned SOURCE must differ from the working tree ───
cmp -s "$PINROOT/fx-init/zig/src/init.zig" "$REPO/zig/src/init.zig" \
    && fail "cmp guard: pinned init.zig is IDENTICAL to the working tree — the control would not be a pre-fix artifact"

( cd "$REPO" && zig cc -target x86_64-linux-musl -std=gnu11 -O2 -static \
    -o "$WORK/fakesvc" tests/fixtures/fakesvc/fakesvc.c ) \
    || fail "zig cc fakesvc failed"
cp "$SIBS/dhake/dhake.com" "$WORK/dhake.com"
chmod +x "$WORK/dhake.com"
"$WORK/dhake.com" --assimilate || fail "dhake --assimilate failed"
file "$WORK/dhake.com" 2>/dev/null | grep -q 'statically linked' \
    || skip "dhake.com did not assimilate to a static ELF on this host"

# the raw-disk read (journal replay on a COPY: a killed VM can leave jbd2
# transactions committed but uncheckpointed, and debugfs reads raw blocks)
read_store_file() { # read_store_file DISK PATH OUTFILE
    _cp="$1.read"
    cp "$1" "$_cp" 2>/dev/null
    "$E2FSCK" -fy "$_cp" >/dev/null 2>&1
    "$DEBUGFS" -R "cat $2" "$_cp" > "$3" 2>/dev/null
    rm -f "$_cp"
}

# ctrl_session SOCK REQFILE TRANSCRIPT — one connection to the virtio
# chardev, the request file's lines verbatim, NO half-close (qemu_ctrl.sh).
ctrl_session() { # ctrl_session SOCK REQFILE TRANSCRIPT
    _sock=$1 _req=$2 _out=$3
    case "$CTRL_TOOL" in
        nc) timeout 60 nc -w 10 -U "$_sock" < "$_req" > "$_out" 2>&1 ;;
        python3) timeout 60 python3 -c '
import socket, sys, time
sock, req = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.sendall(open(req, "rb").read())
s.settimeout(20)
chunks = []
deadline = time.time() + 20
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

# paced_session SOCK REQFILE TRANSCRIPT [GAP] — ctrl_session, but the request
# file's lines are sent ONE AT A TIME with a gap between them (qemu_shell.sh's
# paced writer).  THE GAP IS LOAD-BEARING: a single BURST can arrive in ONE
# read(2) and the handler then walks that whole buffer in one pass, consuming
# the lines that belong to the SHELL it just forked (MEASURED on fx-init's
# qemu_operator_journal.sh boot-5 arm: a burst produced "OK shell pid N" then
# one "ERR unknown command" per shell line, and the direct exec never ran).
# The shell owns the port until it exits; the parent skips it via its latch.
paced_session() { # paced_session SOCK REQFILE TRANSCRIPT [GAP]
    _sock=$1 _req=$2 _out=$3 _gap=${4:-2}
    if [ "$CTRL_TOOL" = "nc" ]; then
        { while IFS= read -r _l || [ -n "$_l" ]; do
              [ -n "$_l" ] || continue
              printf '%s\n' "$_l"
              sleep "$_gap"
          done < "$_req"; } | timeout 240 nc -w 20 -U "$_sock" > "$_out" 2>&1
    else
        cat > "$WORK/paced.py" <<'PYEOF'
import socket, sys, time
sock, req, out = sys.argv[1], sys.argv[2], sys.argv[3]
gap = float(sys.argv[4]) if len(sys.argv) > 4 else 2.0
lines = [l for l in open(req, "rb").read().split(b"\n") if l.strip()]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.settimeout(3)
chunks = []
def drain(t):
    end = time.time() + t
    while time.time() < end:
        try:
            b = s.recv(4096)
        except socket.timeout:
            return
        if not b:
            return
        chunks.append(b)
        end = time.time() + 1.0
for l in lines:
    s.sendall(l + b"\n")
    drain(gap)
drain(20)
open(out, "wb").write(b"".join(chunks))
PYEOF
        timeout 240 python3 "$WORK/paced.py" "$_sock" "$_req" "$_out" "$_gap" > /dev/null 2>&1
    fi
}

# ─── ONE arm: provision, ONE channel boot + ONE reboot, assertions ────────
run_arm() { # run_arm TAG BINDIR MODE(treat|ctrl)
    TAG=$1 BINDIR=$2 MODE=$3
    STORE="$WORK/$TAG/store"
    ROOT="$WORK/$TAG/root"
    DISK="$WORK/$TAG/disk.img"
    SOCK="$WORK/$TAG/chardev.sock"
    mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp"

    echo "--- arm $TAG ($MODE): provisioning at v1 ---"
    PATHS=$(LD_LIBRARY_PATH="$DLDIR" "$BINDIR/activate_paths" \
        --store "$STORE" --package-set "$PKGSET" \
        dhake fx-init fxctl fx-activate fake-service datalog-dafsa dhall-c fxstore) \
        || fail "$TAG: activate_paths failed"
    echo "$PATHS" | while IFS= read -r pd; do
        mkdir -p "$STORE/$pd" || exit 1
        case "$pd" in
            *-fx-init)        cp "$BINDIR/fx-init"     "$STORE/$pd/fx-init"; chmod 755 "$STORE/$pd/fx-init" ;;
            *-fxctl)          cp "$BINDIR/fxctl"       "$STORE/$pd/fxctl";   chmod 755 "$STORE/$pd/fxctl" ;;
            *-fx-activate)    cp "$BINDIR/fx-activate" "$STORE/$pd/fx-activate"; chmod 755 "$STORE/$pd/fx-activate" ;;
            *-fake-service)   cp "$WORK/fakesvc"       "$STORE/$pd/fakesvc"; chmod 755 "$STORE/$pd/fakesvc" ;;
            *-dhake)          cp "$WORK/dhake.com"     "$STORE/$pd/dhake.com"; chmod 755 "$STORE/$pd/dhake.com" ;;
            *)                : > "$STORE/$pd/.provisioned-by-qemu-svc-refuse" ;;
        esac
    done
    FXD=$(ls -d "$STORE"/*-fx-init | head -1)
    [ -x "$FXD/fx-init" ] || fail "$TAG: fx-init was not staged into the store closure"
    RDINIT="/fx/store/$(basename "$FXD")/fx-init"

    OUT=$(LD_LIBRARY_PATH="$DLDIR" "$BINDIR/fx-activate" --store "$STORE" \
        --package-set "$PKGSET" --config "$CFG_OK" 2>&1) \
        || fail "$TAG: activate the healthy v1 config failed: $OUT"
    V1=$(echo "$OUT" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$V1" ] || fail "$TAG: cannot parse version from: $OUT"
    echo "$TAG: healthy config activated as v$V1 (CURRENT)"

    sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/$TAG/img.cpio.gz" -p "$PKGSET" \
        || fail "$TAG: mkinitramfs failed"
    qemu-img create -q "$DISK" 512M || fail "$TAG: qemu-img create failed"
    "$MKE2FS" -q -t ext4 -J size=4 "$DISK" >/dev/null 2>&1 \
        || fail "$TAG: mke2fs -t ext4 (journaled) failed"

    # boot 1's request files: put + activate, one config each
    {
        echo 'put /run/fx/config-ok2.dhall'
        base64 -w 76 "$CFG_OK2"
        echo '.'
        echo 'activate /run/fx/config-ok2.dhall'
    } > "$WORK/$TAG/req-v2.txt"
    {
        echo 'put /run/fx/config-wide.dhall'
        base64 -w 76 "$CFG_WIDE"
        echo '.'
        echo 'activate /run/fx/config-wide.dhall'
    } > "$WORK/$TAG/req-v3.txt"

    CON="$WORK/$TAG/console1.log"
    : > "$CON"
    echo "--- arm $TAG: boot 1 (channel boot; seed at v$V1, then activate v2 and the refused v3 IN-GUEST) ---"
    rm -f "$SOCK"
    qemu-system-x86_64 \
        -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
        -kernel "$KERNEL" -initrd "$WORK/$TAG/img.cpio.gz" \
        -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
        -nographic -no-reboot -monitor none -serial file:"$CON" \
        -drive file="$DISK",format=raw,if=virtio \
        -chardev socket,id=fxctl0,path="$SOCK",server=on,wait=off \
        -device virtio-serial-pci -device virtserialport,chardev=fxctl0,name=fxctl0 \
        >"$WORK/$TAG/qemu1.out" 2>&1 &
    QPID=$!

    # wait for the v1 verdict AND the control channel, then drive the two
    # activations — all inside v1's own grace would be ideal, but v2's
    # re-arm is what opens the window the refusal must land in, and that
    # window is GRACE_OK2 ms long, so the sequence has room by construction.
    _i=0
    while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
        if grep -q "fx-init: boot-ok v$V1" "$CON"; then break; fi
        if grep -q 'fx-init: boot-FAILED v\|fx-init: no generation to boot' "$CON"; then
            tail -40 "$CON"; kill "$QPID" 2>/dev/null; fail "$TAG: boot 1 did not boot v$V1 ok"
        fi
        kill -0 "$QPID" 2>/dev/null || break
        sleep 0.5
        _i=$((_i + 1))
    done
    grep -q "fx-init: boot-ok v$V1" "$CON" \
        || { tail -40 "$CON"; kill "$QPID" 2>/dev/null; fail "$TAG: want boot-ok v$V1 on boot 1"; }
    _i=0
    while [ "$_i" -lt 120 ]; do
        grep -q 'fx-init: virtio control up' "$CON" && break
        [ -S "$SOCK" ] && break
        sleep 0.5
        _i=$((_i + 1))
    done

    # ── THE PREDICATE'S NEGATIVE PIN (the runtime-record closure) ────────
    # This boot's kernel command line carries NO fx.bootnonce= (it is not
    # passed below, and that is the regime this arm measures — the guard
    # asserts it rather than assuming it).  A DIRECT exec of fx-activate on
    # such a boot must leave <store>/.operator UNCHANGED: the self-record
    # predicate is FALSE without a boot nonce, because a row has to be
    # attributable to the boot it happened in and a self-recorded row may
    # NEVER wear the "none" placeholder.
    #   The exec'd config is uploaded FIRST (the same `put` the channel arm
    # uses), then /bin/fx-activate is run INSIDE the M4 `shell` — PID1 never
    # sees it — and the publish it makes is asserted, so the reading below
    # cannot be a vacuous "the exec never ran".
    if grep -q 'fx.bootnonce=' "$CON" || grep -q 'fx-init: boot nonce' "$CON"; then
        fail "$TAG: this boot LATCHED a boot nonce — the negative pin needs a NONCE-LESS boot (its -append carries no fx.bootnonce=)"
    fi
    echo "--- arm $TAG: NONCE-LESS direct exec over the M4 shell ---"
    # session A — the upload (a `put`: a file transfer, not a request)
    {
        echo 'put /run/fx/config-direct.dhall'
        base64 -w 76 "$CFG_OK2"
        echo '.'
    } > "$WORK/$TAG/req-nonnonce-put.txt"
    ctrl_session "$SOCK" "$WORK/$TAG/req-nonnonce-put.txt" "$WORK/$TAG/put-nononce.log"
    grep -q 'OK put [0-9][0-9]* bytes' "$WORK/$TAG/put-nononce.log" \
        || { cat "$WORK/$TAG/put-nononce.log"; kill "$QPID" 2>/dev/null; fail "$TAG: the config upload never landed on the channel"; }
    # session B — the DIRECT EXEC, PACED
    {
        echo 'shell'
        echo '/bin/fx-activate --store /fx/disk/store --package-set /usr/fx/package-set.dhall --config /run/fx/config-direct.dhall'
        echo 'echo DIRECT-RC=$?'
        echo 'echo DONE-NONONCE'
        echo 'exit'
    } > "$WORK/$TAG/req-nononce-shell.txt"
    paced_session "$SOCK" "$WORK/$TAG/req-nononce-shell.txt" "$WORK/$TAG/shell-nononce.log" 2
    echo "--- arm $TAG no-nonce shell transcript ---"; cat "$WORK/$TAG/shell-nononce.log"; echo "---"
    grep -q 'OK shell pid [0-9][0-9]*' "$WORK/$TAG/shell-nononce.log" \
        || { cat "$WORK/$TAG/shell-nononce.log"; kill "$QPID" 2>/dev/null; fail "$TAG: the in-guest shell never spawned ('OK shell pid N' missing)"; }
    _i=0
    while [ "$_i" -lt 60 ]; do
        grep -q 'activated [0-9a-f]* as version' "$WORK/$TAG/shell-nononce.log" && break
        sleep 0.5
        _i=$((_i + 1))
    done
    VD_NONONCE=$(sed -n 's/.*activated [0-9a-f]* as version \([0-9][0-9]*\).*/\1/p' "$WORK/$TAG/shell-nononce.log" | head -1)
    [ -n "$VD_NONONCE" ] \
        || { cat "$WORK/$TAG/shell-nononce.log"; kill "$QPID" 2>/dev/null; fail "$TAG: the nonce-less DIRECT exec never published — the negative pin would be vacuous (it must reach the publish step and record NOTHING there)"; }
    [ "$VD_NONONCE" -gt "$V1" ] \
        || { kill "$QPID" 2>/dev/null; fail "$TAG: the nonce-less direct exec's v$VD_NONONCE is not above v$V1"; }
    echo "$TAG: the nonce-less direct exec published v$VD_NONONCE — .operator is read back off the disk at the end of this boot"

    CTRL1="$WORK/$TAG/ctrl-v2.log"
    ctrl_session "$SOCK" "$WORK/$TAG/req-v2.txt" "$CTRL1"
    echo "--- arm $TAG ctrl (activate v2) ---"; cat "$CTRL1"; echo "---"
    V2=$(sed -n 's/^activated version \([0-9][0-9]*\)$/\1/p' "$CTRL1" | head -1)
    [ -n "$V2" ] \
        || { cat "$CTRL1"; kill "$QPID" 2>/dev/null; fail "$TAG: no 'activated version N' line for the healthy v2 activation"; }
    [ "$V2" -gt "$V1" ] || { kill "$QPID" 2>/dev/null; fail "$TAG: v$V2 is not above v$V1 (the in-guest activate did not ratchet)"; }
    sed -n "/^activated version/,\$p" "$CTRL1" | grep -q '^OK$' \
        || { cat "$CTRL1"; kill "$QPID" 2>/dev/null; fail "$TAG: no OK after the v2 activation"; }
    echo "$TAG: v2 activated IN-GUEST (grace window re-armed, ${GRACE_OK2}ms)"

    CTRL2="$WORK/$TAG/ctrl-v3.log"
    ctrl_session "$SOCK" "$WORK/$TAG/req-v3.txt" "$CTRL2"
    echo "--- arm $TAG ctrl (activate the over-wide config) ---"; cat "$CTRL2"; echo "---"
    V3=$(sed -n 's/^ERR activated version \([0-9][0-9]*\) but REFUSED.*/\1/p' "$CTRL2" | head -1)
    [ -n "$V3" ] \
        || { cat "$CTRL2"; kill "$QPID" 2>/dev/null; fail "$TAG: the over-wide activation was not REFUSED with 'ERR activated version N but REFUSED' — the channel response is the arm's own honesty line"; }
    [ "$V3" -gt "$V2" ] || { kill "$QPID" 2>/dev/null; fail "$TAG: refused v$V3 is not above v$V2"; }
    grep -q "fx-init: refusing service table: service 'svc" "$CON" \
        || { tail -30 "$CON"; kill "$QPID" 2>/dev/null; fail "$TAG: no in-guest refusal line on the console (read_store_facts must say it LOUDLY)"; }
    grep -qF " is #65 of the declared set; the supervision poll window holds 64 (6 svc rows past it skipped) — configuration refused" "$CON" \
        || { kill "$QPID" 2>/dev/null; fail "$TAG: the refusal does not state ordinal #65, window 64 and 6 skipped rows exactly"; }

    # ── the grace window the refusal landed in: watch it expire ──
    echo "--- arm $TAG: watching ${GRACE_WATCH}s of the re-armed window for a vacuous verdict ---"
    _i=0
    while [ "$_i" -lt $((GRACE_WATCH * 2)) ]; do
        grep -q "fx-init: boot-ok v$V3" "$CON" && break
        kill -0 "$QPID" 2>/dev/null || break
        sleep 0.5
        _i=$((_i + 1))
    done

    if [ "$MODE" = treat ]; then
        grep -q "fx-init: boot-ok v$V3" "$CON" \
            && { tail -30 "$CON"; kill "$QPID" 2>/dev/null; fail "$TAG: VACUOUS boot-ok v$V3 accepted — the refusal left the decision UNPINNED and judged an empty service table"; }
        echo "$TAG: no boot-ok v$V3 after the full re-armed window — the latch is pinned (the defect is closed)"
    else
        grep -q "fx-init: boot-ok v$V3" "$CON" \
            || { tail -40 "$CON"; kill "$QPID" 2>/dev/null; fail "$TAG (control): the pinned pre-fix revision did NOT emit the vacuous boot-ok v$V3 — the control is not pre-fix (pin or fixture broken)"; }
        echo "$TAG: the pinned revision latched the VACUOUS boot-ok v$V3 (the fail-before, measured)"
    fi
    # quiesce, then kill: the records must be ON THE DISK
    _q=0 _prev=""
    while [ "$_q" -lt $((BOOT_TIMEOUT * 2)) ]; do
        _cur=$(sha256sum "$DISK" 2>/dev/null | awk '{print $1}')
        if [ -n "$_cur" ] && [ "$_cur" = "$_prev" ]; then break; fi
        _prev=$_cur
        sleep 0.5
        _q=$((_q + 1))
    done
    kill "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null

    # THE NEGATIVE PIN'S MEASUREMENT: two CHANNEL interventions happened in
    # this boot (the v2 activate and the refused v3), so .operator must hold
    # EXACTLY TWO rows — the nonce-less DIRECT exec added NONE.  Two ways to
    # pass this by accident are closed: the exec's own config path must
    # appear on NO row, and no row may carry more than one row's worth of
    # epoch (the file is read back with the same replay+debugfs path the
    # journal gate uses).
    read_store_file "$DISK" /store/.operator "$WORK/$TAG/operator1.txt"
    echo "--- arm $TAG disk .operator (boot 1) ---"
    cat "$WORK/$TAG/operator1.txt" 2>/dev/null; echo "---"
    _nop=$(grep -c '^[0-9]' "$WORK/$TAG/operator1.txt" 2>/dev/null || true)
    [ "${_nop:-0}" = "2" ] \
        || fail "$TAG: .operator holds ${_nop:-0} data row(s) after boot 1 — want EXACTLY 2 (the two CHANNEL interventions): a NONCE-LESS direct exec must self-record NOTHING (the runtime-record predicate is false without fx.bootnonce=)"
    grep -q 'config-direct.dhall' "$WORK/$TAG/operator1.txt" 2>/dev/null \
        && { cat "$WORK/$TAG/operator1.txt"; kill "$QPID" 2>/dev/null; fail "$TAG: .operator carries a row naming the nonce-less DIRECT exec's config — the predicate let a nonce-less self-record through"; }
    true

    read_store_file "$DISK" /store/.bootlog "$WORK/$TAG/bootlog1.txt"
    echo "--- arm $TAG disk .bootlog (boot 1) ---"
    sed -n '1,40p' "$WORK/$TAG/bootlog1.txt"
    echo "---"
    grep -q "^$V3 in-progress " "$WORK/$TAG/bootlog1.txt" \
        && _ip=1 || _ip=0
    grep -q "^$V3 failed " "$WORK/$TAG/bootlog1.txt" \
        && _fa=1 || _fa=0
    if [ "$MODE" = treat ]; then
        [ "$_ip" = 1 ] \
            || fail "$TAG: the DISK .bootlog carries no '$V3 in-progress' line — the refused activation left no marker for the activated version"
        [ "$_fa" = 1 ] \
            || fail "$TAG: the DISK .bootlog carries no '$V3 failed' verdict — the refusal wrote no honest verdict"
        # ...and the ip comes FIRST (the activated window is open before the
        # verdict): the LAST two data lines are exactly that pair
        grep '^[0-9]' "$WORK/$TAG/bootlog1.txt" | tail -2 > "$WORK/$TAG/tail2.txt"
        head -1 "$WORK/$TAG/tail2.txt" | grep -q "^$V3 in-progress " \
            || fail "$TAG: the last two .bootlog data lines are not '<v$V3> in-progress' then '<v$V3> failed': $(cat "$WORK/$TAG/tail2.txt")"
        tail -1 "$WORK/$TAG/tail2.txt" | grep -q "^$V3 failed " \
            || fail "$TAG: the last .bootlog data line is not the refused version's verdict: $(cat "$WORK/$TAG/tail2.txt")"
        echo "$TAG: disk .bootlog ends with the activated window's marker then the honest '$V3 failed' verdict"
    else
        [ "$_ip" = 0 ] \
            || fail "$TAG (control): the pinned revision DID write a '$V3 in-progress' marker — the control is not pre-fix"
        grep -q "^$V3 ok " "$WORK/$TAG/bootlog1.txt" \
            || fail "$TAG (control): the pinned revision wrote no '$V3 ok' line, so the vacuous verdict was not recorded — control broken"
        echo "$TAG: the pinned revision wrote the vacuous '$V3 ok' and NO marker (the disk record the fix adds)"
    fi

    # ── boot 2: the roll-forward decision reads bootlog_last ──
    CON2="$WORK/$TAG/console2.log"
    : > "$CON2"
    echo "--- arm $TAG: boot 2 (no session) ---"
    qemu-system-x86_64 \
        -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
        -kernel "$KERNEL" -initrd "$WORK/$TAG/img.cpio.gz" \
        -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
        -nographic -no-reboot -monitor none -serial file:"$CON2" \
        -drive file="$DISK",format=raw,if=virtio \
        >"$WORK/$TAG/qemu2.out" 2>&1 &
    QPID=$!
    _i=0
    while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
        if grep -q 'fx-init: boot-ok v\|fx-init: boot-FAILED v\|fx-init: no generation to boot' "$CON2"; then
            break
        fi
        kill -0 "$QPID" 2>/dev/null || break
        sleep 0.5
        _i=$((_i + 1))
    done
    if [ "$MODE" = treat ]; then
        grep -q "fx-init: stale failed for v$V3; rolling forward to v$V1" "$CON2" \
            || { tail -40 "$CON2"; kill "$QPID" 2>/dev/null; fail "$TAG: boot 2 did not roll FORWARD from the refused v$V3 to v$V1 — the honest failed verdict did not steer decide_boot_version"; }
        grep -q 'fx-init: boot-ok v' "$CON2" \
            || { tail -40 "$CON2"; kill "$QPID" 2>/dev/null; fail "$TAG: boot 2 rolled forward but never booted ok"; }
        echo "$TAG: boot 2 rolled FORWARD off the refused generation (stale failed -> the newest ok below) and booted ok"
    else
        grep -q 'fx-init: stale ' "$CON2" \
            && { tail -30 "$CON2"; kill "$QPID" 2>/dev/null; fail "$TAG (control): a roll-forward line appeared at the pinned revision — the control is not pre-fix"; }
        grep -q "fx-init: boot-FAILED v$V3" "$CON2" \
            || { tail -40 "$CON2"; kill "$QPID" 2>/dev/null; fail "$TAG (control): boot 2 did not re-fail on v$V3 — the pinned revision's forged ok should have kept the broken generation CURRENT"; }
        echo "$TAG: boot 2 re-boots the refused v$V3 and FAILS (the forged ok kept it current — the state the defect leaves)"
    fi
    _q=0 _prev=""
    while [ "$_q" -lt $((BOOT_TIMEOUT * 2)) ]; do
        _cur=$(sha256sum "$DISK" 2>/dev/null | awk '{print $1}')
        if [ -n "$_cur" ] && [ "$_cur" = "$_prev" ]; then break; fi
        _prev=$_cur
        sleep 0.5
        _q=$((_q + 1))
    done
    kill "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null
}

run_arm treat "$TREAT_BIN" treat
run_arm ctrl  "$CTRL_BIN"  ctrl

echo "qemu-svcrefuse: PASS (treatment: the in-guest refusal of a 70-service config left '$V3 in-progress'+'failed' on the disk and NO boot-ok for it, then boot 2 rolled forward; control at $PIN_REV: the SAME command sequence latched a VACUOUS boot-ok, wrote no marker, and boot 2 re-failed on it)"
exit 0
