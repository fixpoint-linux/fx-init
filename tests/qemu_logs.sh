#!/bin/sh
# tests/qemu_logs.sh — M4 ITEM D: the SECOND virtserialport as a
# guest->host LOG STREAM.  A second virtserialport is attached whose
# chardev is a HOST FILE; fx-init opens it O_WRONLY|O_NONBLOCK
# (setup_virtio_log) and every log_line call mirrors one
# "ts svc lvl msg" line to it.  The assertion: KNOWN log lines appear
# HOST-SIDE with NO grep request ever sent over the control channel —
# logs flow out continuously instead of being polled over the request
# channel.
#
#   boot 1 (TWO virtserialports): port 1 = the control channel (socket,
#          qemu_ctrl.sh contract); port 2 = the log stream (chardev
#          file:log port).  The guest boots config-good, boots ok, and
#          the harness then:
#            1. asserts the HOST FILE already carries known boot-time log
#               lines ("entered main loop", heartbeat "started (pid N)")
#               BEFORE any channel request is made — the stream is
#               push, not poll;
#            2. runs `restart heartbeat` over the CONTROL channel and
#               asserts the log file then carries the stop/start lines
#               the command caused — proving live log_line taps reach
#               the host file as they happen;
#            3. asserts NO grep/search was sent (the transcript contains
#               no grep output — the only requests are status/restart).
#
# INERTNESS belt: boots 2 runs with NO second port — the setup gate
# (find_vport_nth skip=1) finds nothing, the boot proceeds, and the
# harness asserts boot-ok + "virtio control up" (the FIRST port's
# listener) with no log-stream line on the console.  A guest with one
# port must not so much as warn.
#
# Channel: same virtio-serial + nc -U contract as qemu_ctrl.sh (no -N: the
# half-close drops the chardev before the guest's response write).
#
# Env: FXSTORE/FX_ACTIVATE/FX_INIT_BIN/FX_SIBLINGS/QEMU_BOOT_TIMEOUT/
#      QEMU_KEEP — same contract as tests/qemu_ctrl.sh.
set -u

fail() { echo "qemu-logs: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-logs: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
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

SCRATCH="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$SCRATCH/qemulog.XXXXXX")" || fail mktemp
SOCK="$WORK/chardev.sock"
LOGPORT="$WORK/guest.log"
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-logs: scratch kept at $WORK"' EXIT
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
echo "qemu-logs: channel writer: $CTRL_TOOL"

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
echo "=== qemu-logs: freezing package sources (concurrent-writer shield) ==="
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

# ─── provisioning (toolchain-free path; qemu_ctrl.sh shape) ───────────────
FXS="${FXSTORE:-}"
FXA="${FX_ACTIVATE:-}"
if [ -z "$FXS" ] || [ -z "$FXA" ]; then
    echo "=== qemu-logs: toolchain-free provisioning ==="
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
            *)                : > "$STORE/$pd/.provisioned-by-qemu-logs" ;;
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

echo "=== qemu-logs: activating good config (store $STORE) ==="
OUT_GOOD=$(activate "$STORE" "$CFG_GOOD") || fail "activate good failed: $OUT_GOOD"
V_GOOD=$(echo "$OUT_GOOD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_GOOD" ] || fail "cannot parse good version from: $OUT_GOOD"
echo "$OUT_GOOD"

echo "=== qemu-logs: building the ONE initramfs (ramfs CURRENT = v$V_GOOD) ==="
sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/img.cpio.gz" -p "$PKGSET" \
    || fail "mkinitramfs failed"
qemu-img create -q "$DISK" 512M || fail "qemu-img create failed"
"$MKE2FS" -q -t ext4 -J size=4 "$DISK" >/dev/null 2>&1 \
    || fail "mke2fs -t ext4 (journaled) failed — install e2fsprogs"

FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

# run_boot CONSOLE WITH_LOGPORT — boot the ONE image on $DISK.  Port 1
# (the control channel) is attached in EVERY boot; port 2 (the log
# stream, chardev file:) only in the WITH_LOGPORT=1 boots — the inertness
# belt runs without it.
run_boot() {
    _con=$1 _logport=$2
    : > "$_con"
    rm -f "$SOCK"
    : > "$LOGPORT"
    _extra=""
    if [ "$_logport" = "1" ]; then
        _extra="-chardev file,id=fxlog0,path=$LOGPORT \
        -device virtserialport,chardev=fxlog0,name=fxlog0"
    fi
    # shellcheck disable=SC2086
    qemu-system-x86_64 \
        -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
        -kernel "$KERNEL" -initrd "$WORK/img.cpio.gz" \
        -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
        -nographic -no-reboot -monitor none -serial file:"$_con" \
        -drive file="$DISK",format=raw,if=virtio \
        -chardev socket,id=fxctl0,path="$SOCK",server=on,wait=off \
        -device virtio-serial-pci \
        -device virtserialport,chardev=fxctl0,name=fxctl0 \
        $_extra \
        >"$WORK/qemu.$$.out" 2>&1 &
    QPID=$!
    _i=0
    while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
        if grep -q 'fx-init: boot-ok v\|fx-init: boot-FAILED v\|fx-init: no generation to boot' "$_con"; then
            return 0
        fi
        kill -0 "$QPID" 2>/dev/null || return 0
        sleep 0.5
        _i=$((_i + 1))
    done
    return 0
}

kill_qemu() {
    kill "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null
}

echo "=== boot 1: TWO ports — the log stream must carry boot-time lines with NO channel request ==="
run_boot "$WORK/console1.log" 1
grep -q "fx-init: boot-ok v$V_GOOD" "$WORK/console1.log" \
    || { tail -40 "$WORK/console1.log"; kill_qemu; fail "boot 1: want boot-ok v$V_GOOD"; }
grep -q 'fx-init: virtio log up (/dev/vport' "$WORK/console1.log" \
    || { tail -40 "$WORK/console1.log"; kill_qemu; fail "boot 1: no 'virtio log up' console line (the second port was not opened)"; }

# THE PUSH PROOF: known log lines in the HOST file BEFORE any request.
# "entered main loop" is emitted by fx-init itself (log_line, before
# main_loop), "started (pid N)" by the heartbeat service start — both
# land in the log DB AND (this item) on the log port.  No grep was sent:
# nothing has touched $SOCK yet.
_i=0
while [ "$_i" -lt 20 ]; do
    grep -q 'fx-init info entered main loop' "$LOGPORT" && break
    sleep 0.5
    _i=$((_i + 1))
done
grep -q 'fx-init info entered main loop' "$LOGPORT" \
    || { kill_qemu; fail "log port: no 'fx-init info entered main loop' line host-side (the push stream did not flow)"; }
grep -q 'heartbeat info started (pid ' "$LOGPORT" \
    || { kill_qemu; fail "log port: no 'heartbeat info started (pid N)' line host-side"; }
echo "--- log port head (pre-request) ---"; head -8 "$LOGPORT"; echo "-----------------------------------"

# ── the LIVE tap: a control-channel command whose side effects must show
# up on the log port as they happen.  `restart heartbeat` stops the service
# (SIGTERM) — MEASURED on this config: the TERM death logs "stopping
# (SIGTERM)" + "exited (fail); not restarting" (fakesvc dies to the TERM
# and the stop arm's explicit-stop path does not relaunch it), so the LIVE
# proof is those two lines arriving in the HOST file, not a new pid.
sleep 1
printf 'restart heartbeat\n' > "$WORK/req1.txt"
CTRL_TRANSCRIPT="$WORK/ctrl.log"
ctrl_session "$SOCK" "$WORK/req1.txt" "$CTRL_TRANSCRIPT"
echo "--- ctrl transcript ---"; cat "$CTRL_TRANSCRIPT"; echo "-----------------------"
grep -q '^OK$' "$CTRL_TRANSCRIPT" \
    || { cat "$CTRL_TRANSCRIPT"; kill_qemu; fail "restart heartbeat: no OK in transcript"; }
# NO grep/search request was sent — the transcript above IS the proof; belt:
# it contains no tab-separated grep rows.
grep -q "$(printf '\t')" "$CTRL_TRANSCRIPT" \
    && { cat "$CTRL_TRANSCRIPT"; kill_qemu; fail "transcript unexpectedly contains grep-style rows"; }
_i=0
while [ "$_i" -lt 20 ] && ! grep -q 'heartbeat info stopping (SIGTERM)' "$LOGPORT"; do
    sleep 0.5
    _i=$((_i + 1))
done
grep -q 'heartbeat info stopping (SIGTERM)' "$LOGPORT" \
    || { kill_qemu; fail "log port: the restart's 'stopping (SIGTERM)' line never appeared (the live tap does not flow)"; }
grep -q 'heartbeat error exited' "$LOGPORT" \
    || { kill_qemu; fail "log port: no 'exited (...)' line for the restart"; }
echo "--- log port tail (post-restart) ---"; tail -5 "$LOGPORT"; echo "-------------------------------------"
kill_qemu

echo "=== boot 2: ONE port (no log port) — the gate must be INERT ==="
run_boot "$WORK/console2.log" 0
grep -q "fx-init: boot-ok v$V_GOOD" "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: want boot-ok v$V_GOOD without the log port"; }
grep -q 'fx-init: virtio control up (/dev/vport' "$WORK/console2.log" \
    || { tail -40 "$WORK/console2.log"; fail "boot 2: no virtio control up line (the FIRST port must be untouched)"; }
grep -q 'fx-init: virtio log up' "$WORK/console2.log" \
    && { tail -40 "$WORK/console2.log"; fail "boot 2: 'virtio log up' line WITHOUT a second port?!"; }
grep -q 'warning: virtio log' "$WORK/console2.log" \
    && { tail -40 "$WORK/console2.log"; fail "boot 2: a virtio-log WARNING appeared without a second port (the gate is not inert)"; }
kill_qemu

echo "qemu-logs: PASS (boot-time + live log lines reached the host file over the second vport with NO grep sent; one-port boot inert)"
exit 0
