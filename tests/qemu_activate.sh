#!/bin/sh
# tests/qemu_activate.sh — M4 ITEM: IN-GUEST ACTIVATE.  A NEW config.dhall
# reaches a RUNNING guest over the virtio-serial control channel
# (`put /run/fx/config-alt.dhall` + base64 lines + `.`), the guest
# activates it IN-GUEST (`activate /run/fx/config-alt.dhall` forks
# /bin/fx-activate with the IMAGE-SHIPPED /usr/fx/package-set.dhall and the
# SRC-FREE fallback — the source trees do not exist in the guest), and the
# new service is RUNNING with its output in the log DB.  Not merely rc=0:
# the activated version is one the HOST never created.
#
# ONE image + ONE shared 512M disk + THREE boots (the qemu_ctrl.sh shape):
#
#   host side: ONE store; activate config-alt FIRST (v_alt), then
#          config-good (v_good) on top.  ONE initramfs, CURRENT=v_good,
#          built with mkinitramfs -p (ships /usr/fx/package-set.dhall, the
#          frozen-absolute pkgset whose src paths point at the HOST's
#          frozen trees — ABSENT in the guest, exactly the src-free case).
#   boot 1 (channel): the guest seeds the disk at v_good and boots it ok.
#          With QEMU STILL RUNNING: put config-alt.dhall over the channel,
#          activate it IN-GUEST -> "activated version V_ACT" with
#          V_ACT > v_good.  v_good was the highest version the host ever
#          created, so V_ACT's only possible writer is the guest's own
#          fx-activate.  Then the PROOF the activation TOOK EFFECT:
#            q service_runtime -> a row for "second" (the NEW service)
#            grep heartbeat   -> lines from BOTH heartbeat AND second
#          (a service that did not exist in the booted generation is
#          RUNNING and its output is in the log DB).  Then quiescence-kill.
#   boot 2 (SAME image, no session): disk CURRENT v_act > ramfs v_good ->
#          no adopt -> boots v_act -> boot-ok v_act.  THE PERSISTENCE
#          PROOF: the guest-activated generation is the boot source.
#   boot 3 (SAME image): boot-ok v_act again (idempotent re-boot) + the
#          disk sha changes (bootlog append).
#
# NEGATIVE CONTROL (detector can fail): a put of config-bad-exit-alt (the
# crasher variant) + activate -> v_act2; a boot-2-style reboot then shows
# boot-FAILED v_act2 — the harness's own detector fails loudly when the
# guest activates a broken config.  Run with QEMU_ACT_NEGATE=1 to verify
# the harness EXITS 1 on an inverted expectation.
#
# Channel: same virtio-serial + nc -U contract as qemu_ctrl.sh (no -N: the
# half-close drops the chardev before the guest's response write).
#
# Env: FXSTORE/FX_ACTIVATE/FX_INIT_BIN/FX_SIBLINGS/QEMU_BOOT_TIMEOUT/
#      QEMU_KEEP/QEMU_ACT_NEGATE — same contract as qemu_ctrl.sh.
set -u

fail() { echo "qemu-activate: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-activate: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
command -v base64 >/dev/null 2>&1 || skip "base64 not found (channel upload)"
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

SCRATCH="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$SCRATCH/qemuact.XXXXXX")" || fail mktemp
SOCK="$WORK/chardev.sock"
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-activate: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
STORE="$WORK/store"
ROOT="$WORK/root"
DISK="$WORK/disk.img"
mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp"

CTRL_TOOL=""
if nc -h 2>&1 | grep -q -- '-U.*UNIX domain socket'; then
    CTRL_TOOL=nc
elif command -v python3 >/dev/null 2>&1; then
    CTRL_TOOL=python3
else
    skip "no nc with -U and no python3 — cannot write the virtio chardev socket"
fi
echo "qemu-activate: channel writer: $CTRL_TOOL"

# ctrl_session SOCK REQFILE TRANSCRIPT — send the request file's lines over
# the chardev socket in ONE connection (NO half-close; see qemu_ctrl.sh),
# capture the answers.  The file's lines carry the put framing verbatim.
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
# NO shutdown(SHUT_WR): the guest writes responses on the same connection
# and a half-close makes qemu drop the chardev before they are written.
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

# ─── freeze the package sources (concurrent-writer shield; qemu_ctrl.sh) ──
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
echo "=== qemu-activate: freezing package sources (concurrent-writer shield) ==="
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

# ─── config-alt: config-good PLUS one extra service ("second") ────────────
# fake-service is already in the closure and /bin/fakesvc already exists in
# the running root (the v_good materialization), so the new service can
# exec without a reboot — the plan's honest v1 scope.  The CLOSURE is
# unchanged (same 5 packages) but the SERVICES differ, so the genhash
# differs: a genuinely NEW config, not a re-activation.
# The hostname is ALSO different ("fixbox-alt", 10 bytes, vs config-good's
# "fixbox", 6 bytes — fx-activate writes cfg.hostname VERBATIM, no trailing
# newline): the F1 hot-apply observable.  A `put`+`activate` must land the
# new /etc/hostname on the RUNNING root, which the probe's file relation
# (/etc/hostname size+mtime) and the fresh dhake log lines both see.
cat > "$WORK/config-alt.dhall" <<'EOF'
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox-alt"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        , { name = "second", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 5000
    }
EOF
# the crasher variant for the NEGATIVE control (heartbeat + crasher-second)
sed -e 's/{ name = "second", argv = \[ "fakesvc", "ok" \]/{ name = "second", argv = [ "fakesvc", "exit", "7" ]/' \
    "$WORK/config-alt.dhall" > "$WORK/config-bad-alt.dhall"
grep -q '"fakesvc", "exit", "7"' "$WORK/config-bad-alt.dhall" \
    || fail "crasher variant rewrite produced no exit-7 second service"

# ─── provisioning (toolchain-free path; qemu_ctrl.sh shape) ───────────────
FXS="${FXSTORE:-}"
FXA="${FX_ACTIVATE:-}"
if [ -z "$FXS" ] || [ -z "$FXA" ]; then
    echo "=== qemu-activate: toolchain-free provisioning ==="
    command -v zig >/dev/null 2>&1 || skip "zig not found (build the zig port or set FXSTORE+FX_ACTIVATE)"
    export FX_SIBLINGS="${FX_SIBLINGS:-$SIBS}"
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
            *)                : > "$STORE/$pd/.provisioned-by-qemu-activate" ;;
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

activate() { # activate STORE CFG -> "activated <hash> as version <N>"
    LD_LIBRARY_PATH="$DLDIR" "$FXA" --store "$1" \
        --package-set "$PKGSET" --config "$2" 2>&1
}

# ─── ONE store: config-alt FIRST, then config-good on top ─────────────────
# (v_alt published BELOW v_good; the image boots v_good.  The GUEST's
# in-guest activation of config-alt must land ABOVE v_good — and since the
# host activated v_alt BEFORE v_good, the guest's version is a THIRD one
# the host never created: the only writer can be the guest.)
echo "=== qemu-activate: activating config-alt FIRST (v_alt), then config-good (v_good) ==="
OUT_ALT=$(activate "$STORE" "$WORK/config-alt.dhall") || fail "activate alt failed: $OUT_ALT"
V_ALT=$(echo "$OUT_ALT" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_ALT" ] || fail "cannot parse alt version from: $OUT_ALT"
echo "$OUT_ALT"

OUT_GOOD=$(activate "$STORE" "$CFG_GOOD") || fail "activate good failed: $OUT_GOOD"
V_GOOD=$(echo "$OUT_GOOD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_GOOD" ] || fail "cannot parse good version from: $OUT_GOOD"
echo "$OUT_GOOD"
[ "$V_GOOD" -gt "$V_ALT" ] || fail "good v$V_GOOD not above alt v$V_ALT (the guest must land above BOTH)"

# ─── ONE image (CURRENT=v_good) + ONE shared disk, JOURNALED ext4 ─────────
echo "=== qemu-activate: building the ONE initramfs (ramfs CURRENT = v$V_GOOD; -p ships /usr/fx/package-set.dhall) ==="
sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/img.cpio.gz" -p "$PKGSET" \
    || fail "mkinitramfs failed"
qemu-img create -q "$DISK" 512M || fail "qemu-img create failed"
"$MKE2FS" -q -t ext4 -J size=4 "$DISK" >/dev/null 2>&1 \
    || fail "mke2fs -t ext4 (journaled) failed — install e2fsprogs"

FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

disk_sha() { sha256sum "$DISK" | awk '{print $1}'; }
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

run_boot() { # run_boot CONSOLE WITH_SESSION
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

# the boot-1 channel sessions' request files.  TWO sessions: put+activate
# first, then (after the main loop has iterated) the PROOF queries — the
# guest starts newly-activated services on its NEXT main-loop pass, so a
# q/grep in the same channel burst would race the start (MEASURED: the
# first run's q service_runtime showed only heartbeat).
{
    echo 'put /run/fx/config-alt.dhall'
    base64 -w 76 "$WORK/config-alt.dhall"
    echo '.'
    echo 'activate /run/fx/config-alt.dhall'
} > "$WORK/req1.txt"
{
    echo 'q service_runtime'
    echo 'grep heartbeat'
} > "$WORK/req2.txt"
# req3 — the F1 HOT-APPLY proof: force a probe refresh, read the /etc/hostname
# row (file relation: path, size, mode, uid, gid, mtime), and grep the dhake
# actions the hot-apply ran.  BOOT's own run_dhake already logged dhake lines
# for v_good (hostname 6 bytes); the in-guest activate's re-run must show
# /etc/hostname copied AGAIN with the NEW size (10) — a fresh row that could
# only come from materializing config-alt on the RUNNING root.
{
    echo 'probe'
    echo 'q file'
    echo 'grep hostname'
} > "$WORK/req3.txt"

echo "=== boot 1: channel boot — seed the disk at v$V_GOOD, then put+activate config-alt IN-GUEST ==="
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
# wait for the socket to exist (the chardev is server=on,wait=off)
_i=0
while [ ! -S "$SOCK" ] && [ "$_i" -lt 60 ]; do sleep 0.5; _i=$((_i + 1)); done
[ -S "$SOCK" ] || { kill "$QPID" 2>/dev/null; fail "boot 1: chardev socket never appeared"; }
ctrl_session "$SOCK" "$WORK/req1.txt" "$CTRL_TRANSCRIPT"
echo "--- ctrl transcript ---"; cat "$CTRL_TRANSCRIPT"; echo "-----------------------"

# put: opened (OK), then terminated with the byte-count line
grep -q '^OK$' "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "put/activate: no OK in transcript"; }
PUT_BYTES=$(wc -c < "$WORK/config-alt.dhall" | tr -d ' ')
grep -q "^OK put $PUT_BYTES bytes\$" "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "put: no 'OK put $PUT_BYTES bytes' line"; }

# activate: "activated version V_ACT" then OK; V_ACT > v_good (the host
# never created a version above v_good — the only writer is the guest)
V_ACT=$(sed -n 's/^activated version \([0-9][0-9]*\)$/\1/p' "$CTRL_TRANSCRIPT" | head -1)
[ -n "$V_ACT" ] \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "activate: no 'activated version N' line in transcript"; }
[ "$V_ACT" -gt "$V_GOOD" ] \
    || { kill "$QPID" 2>/dev/null; fail "activate: v$V_ACT not above v$V_GOOD (the host never created one — the guest must)"; }
sed -n "/^activated version/,\$p" "$CTRL_TRANSCRIPT" | grep -q '^OK$' \
    || { kill "$QPID" 2>/dev/null; fail "activate: no OK after the activated line"; }

# ── the PROOF session: the NEW service must now be RUNNING ──────────────
# (the guest's main loop starts newly-activated services on its next pass —
# up to ~1s; poll the runtime table until 'second' appears or time out)
_i=0; SECOND_SEEN=0
while [ "$_i" -lt 20 ]; do
    CTRL_TRANSCRIPT="$WORK/ctrl2.log"
    ctrl_session "$SOCK" "$WORK/req2.txt" "$CTRL_TRANSCRIPT"
    if grep -q 'second' "$CTRL_TRANSCRIPT"; then SECOND_SEEN=1; break; fi
    sleep 1
    _i=$((_i + 1))
done
echo "--- ctrl2 transcript ---"; cat "$WORK/ctrl2.log"; echo "-----------------------"
[ "$SECOND_SEEN" = "1" ] \
    || { cat "$WORK/ctrl2.log"; kill "$QPID" 2>/dev/null; fail "q service_runtime: no 'second' row (the new service is not running)"; }
grep -q 'heartbeat from heartbeat' "$WORK/ctrl2.log" \
    || { cat "$WORK/ctrl2.log"; kill "$QPID" 2>/dev/null; fail "grep: no 'heartbeat from heartbeat' line"; }
grep -q 'heartbeat from second' "$WORK/ctrl2.log" \
    || { cat "$WORK/ctrl2.log"; kill "$QPID" 2>/dev/null; fail "grep: no 'heartbeat from second' line (the new service's output is not in the log DB)"; }

# ── the F1 HOT-APPLY proof: the new /etc CONTENT is on the RUNNING root ──
# (not merely rc=0 — the /etc/hostname ROW must change: config-good wrote
# "fixbox" (6 bytes) at BOOT, config-alt is "fixbox-alt" (10 bytes).  The
# probe command forces fx_probe_refresh, so q file reads the file the
# hot-apply rewrote, and grep hostname shows the fresh dhake Copy of the
# new etc file — both could only exist if run_dhake re-materialized the
# activated generation on the live root.)
CTRL_TRANSCRIPT="$WORK/ctrl3.log"
ctrl_session "$SOCK" "$WORK/req3.txt" "$CTRL_TRANSCRIPT"
echo "--- ctrl3 transcript (hot-apply proof) ---"; cat "$CTRL_TRANSCRIPT"; echo "-----------------------------------------"
# q file row: "/etc/hostname<TAB>10<TAB>33188<TAB>0<TAB>0<TAB>mtime" — the
# SIZE column is the honest observable (config-good's would be 6).
FILE_ROW=$(grep '^/etc/hostname' "$CTRL_TRANSCRIPT" | head -1)
[ -n "$FILE_ROW" ] \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "q file: no /etc/hostname row (the file probe saw nothing)"; }
FILE_SIZE=$(echo "$FILE_ROW" | awk -F'\t' '{print $2}')
[ "$FILE_SIZE" = "10" ] \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "q file: /etc/hostname size is $FILE_SIZE, want 10 ('fixbox-alt' hot-applied; 6 = the boot's 'fixbox' still there — the activate did NOT re-materialize /etc)"; }
# dhake's own action echo for the new etc file (run_dhake pipes the child's
# stdout into the log DB as svc=dhake): "cp <store>/...-system-generation/etc/hostname /etc/hostname"
grep -q 'cp.*-system-generation/etc/hostname /etc/hostname' "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "grep hostname: no dhake Copy of etc/hostname (the hot-apply did not run)"; }
grep -q 'chmod 0644 /etc/hostname' "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill "$QPID" 2>/dev/null; fail "grep hostname: no dhake chmod on /etc/hostname (the hot-apply did not run)"; }

# negative-control hook: invert one assertion to prove the detector can fail
if [ "${QEMU_ACT_NEGATE:-0}" = "1" ]; then
    kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
    fail "NEGATIVE CONTROL: expected NO 'heartbeat from second' (QEMU_ACT_NEGATE=1)"
fi

# ── quiescence kill: the activation's writes must be ON THE DISK ─────────
wait_disk_quiet
kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
SHA1B=$(disk_sha)
[ "$SHA1" != "$SHA1B" ] \
    || fail "boot 1: disk.img unchanged after the ctrl session (the in-guest activation did not write)"

echo "=== boot 2: SAME image, no session — the guest-activated v$V_ACT must boot ok ==="
run_boot "$WORK/console2.log" 0
grep -q 'fx-init: disk store mounted (current v'"$V_ACT"')' "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: disk current is not v$V_ACT (the in-guest activation did not persist)"; }
grep -q "fx-init: boot-ok v$V_ACT" "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: want boot-ok v$V_ACT (persistence)"; }
SHA2=$(disk_sha)
[ "$SHA1B" != "$SHA2" ] || fail "boot 2: disk.img unchanged"

echo "=== boot 3: SAME image — idempotent re-boot of the same CURRENT v$V_ACT ==="
run_boot "$WORK/console3.log" 0
grep -q "fx-init: boot-ok v$V_ACT" "$WORK/console3.log" \
    || { tail -40 "$WORK/console3.log"; fail "boot 3: want boot-ok v$V_ACT again (idempotence)"; }
SHA3=$(disk_sha)
[ "$SHA2" != "$SHA3" ] || fail "boot 3: disk.img unchanged (bootlog append missing)"

echo "qemu-activate: PASS (host built v$V_ALT,v$V_GOOD; guest put+activated config-alt to v$V_ACT in-guest; 'second' is running with output in the log DB; boots 2-3 boot v$V_ACT)"
exit 0
