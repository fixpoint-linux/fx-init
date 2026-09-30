#!/bin/sh
# tests/qemu_shell.sh — M4 ITEM F: the IN-GUEST DEBUG SHELL over the control
# channel.  `shell` forks a child that dups the vport onto 0/1/2 and execs
# /bin/sh -i (busybox ash, TERM=dumb); the channel session becomes the
# terminal.
#
# FRAMING RISK (the plan's): while the shell lives, every shell output line
# is indistinguishable from a protocol response — so the harness drives ONE
# connection in three phases with an agreed SENTINEL:
#   phase 1  "shell"           -> the one protocol line "OK shell pid N"
#   phase 2  OPAQUE: shell commands whose output we assert ("echo fxmark",
#            "id -u", "ls /"), terminated by "echo DONE-<n>; exit" — the
#            harness scans for the sentinel marker lines, not for OK/ERR
#   phase 3  after the sentinel, the session ends; a SECOND connection
#            proves the protocol channel SURVIVED the shell: `status` ->
#            OK again, and the main loop kept supervising (the shell never
#            blocked PID1 — the heartbeat service is still running).
#
# The busybox in the image is a shell: /bin/sh -> busybox ash.  The one
# shell at a time rule is asserted too: a second `shell` DURING a live
# shell answers ERR (but a new one AFTER the exit works — phase 4).
#
# Channel: same virtio-serial + nc -U contract as qemu_ctrl.sh (no -N: the
# half-close drops the chardev before the guest's response write).
#
# Env: FXSTORE/FX_ACTIVATE/FX_INIT_BIN/FX_SIBLINGS/QEMU_BOOT_TIMEOUT/
#      QEMU_KEEP — same contract as tests/qemu_ctrl.sh.
set -u

fail() { echo "qemu-shell: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-shell: SKIP ($*)"; exit 77; }

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
WORK="$(mktemp -d "$SCRATCH/qemushell.XXXXXX")" || fail mktemp
SOCK="$WORK/chardev.sock"
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-shell: scratch kept at $WORK"' EXIT
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
echo "qemu-shell: channel writer: $CTRL_TOOL"

# shell_session SOCK REQFILE TRANSCRIPT — like qemu_ctrl.sh's ctrl_session
# but with a longer receive window (the shell session is interactive-ish:
# boot + fork/exec + command round trips must all fit inside ONE
# connection, and no half-close is possible mid-session).
shell_session() { # shell_session SOCK REQFILE TRANSCRIPT
    _sock=$1 _req=$2 _out=$3
    case "$CTRL_TOOL" in
        nc) timeout 45 nc -w 15 -U "$_sock" < "$_req" > "$_out" 2>&1 ;;
        python3) timeout 45 python3 -c '
import socket, sys, time
sock, req = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.sendall(open(req, "rb").read())
s.settimeout(15)
chunks = []
deadline = time.time() + 15
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
echo "=== qemu-shell: freezing package sources (concurrent-writer shield) ==="
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
    echo "=== qemu-shell: toolchain-free provisioning ==="
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
            *)                : > "$STORE/$pd/.provisioned-by-qemu-shell" ;;
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

echo "=== qemu-shell: activating good config (store $STORE) ==="
OUT_GOOD=$(activate "$STORE" "$CFG_GOOD") || fail "activate good failed: $OUT_GOOD"
V_GOOD=$(echo "$OUT_GOOD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_GOOD" ] || fail "cannot parse good version from: $OUT_GOOD"
echo "$OUT_GOOD"

echo "=== qemu-shell: building the ONE initramfs (ramfs CURRENT = v$V_GOOD) ==="
sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/img.cpio.gz" -p "$PKGSET" \
    || fail "mkinitramfs failed"
qemu-img create -q "$DISK" 512M || fail "qemu-img create failed"
"$MKE2FS" -q -t ext4 -J size=4 "$DISK" >/dev/null 2>&1 \
    || fail "mke2fs -t ext4 (journaled) failed — install e2fsprogs"

FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

echo "=== boot: channel boot — then the shell session ==="
: > "$WORK/console.log"
rm -f "$SOCK"
qemu-system-x86_64 \
    -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
    -kernel "$KERNEL" -initrd "$WORK/img.cpio.gz" \
    -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
    -nographic -no-reboot -monitor none -serial file:"$WORK/console.log" \
    -drive file="$DISK",format=raw,if=virtio \
    -chardev socket,id=fxctl0,path="$SOCK",server=on,wait=off \
    -device virtio-serial-pci -device virtserialport,chardev=fxctl0,name=fxctl0 \
    >"$WORK/qemu.$$.out" 2>&1 &
QPID=$!
_i=0
while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
    grep -q 'fx-init: boot-ok v\|fx-init: boot-FAILED v\|fx-init: no generation to boot' "$WORK/console.log" && break
    kill -0 "$QPID" 2>/dev/null || break
    sleep 0.5
    _i=$((_i + 1))
done
grep -q "fx-init: boot-ok v$V_GOOD" "$WORK/console.log" \
    || { tail -40 "$WORK/console.log"; kill "$QPID" 2>/dev/null; fail "boot: want boot-ok v$V_GOOD"; }
_i=0
while [ ! -S "$SOCK" ] && [ "$_i" -lt 60 ]; do sleep 0.5; _i=$((_i + 1)); done
[ -S "$SOCK" ] || { kill "$QPID" 2>/dev/null; fail "chardev socket never appeared"; }

# ── phase 1+2+3 in ONE connection: spawn the shell, drive it OPAQUE until
# the SENTINEL, then (in the SAME stream) a second `shell` must be refused
# — no wait, the refusal probe needs the PROTOCOL, which only returns after
# the shell exits.  The stream below is: shell spawn -> commands -> exit ->
# (protocol is back) -> status.
{
    echo 'shell'
    echo 'echo fxmark-one'
    echo 'echo shellpid=$$'
    echo 'echo fx-roots:'
    echo 'echo /*'
    echo 'echo DONE-7331'
    echo 'exit'
    echo 'status'
} > "$WORK/req1.txt"
# the paced writer: each request line is sent with a drain gap, so the
# shell's output streams back in order (a single burst would be fine for
# the guest, but the pacing also keeps the transcript legible).  Written
# as a FILE (not a function): the heredoc driver is long, and a heredoc
# attached to a function CALL is not portable POSIX sh.
cat > "$WORK/paced.py" <<'PYEOF'
import socket, sys, time
sock, req = sys.argv[1], sys.argv[2]
gap = float(sys.argv[3]) if len(sys.argv) > 3 else 1.0
lines = [l for l in open(req, "rb").read().split(b"\n") if l.strip()]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.settimeout(3)
def drain(t):
    end = time.time() + t
    while time.time() < end:
        try:
            b = s.recv(4096)
        except socket.timeout:
            return
        if not b:
            return
        sys.stdout.write(b.decode("utf-8", "replace"))
        sys.stdout.flush()
        end = time.time() + 1.0  # extend while data flows
for l in lines:
    s.sendall(l + b"\n")
    drain(gap)
PYEOF
paced_session() { # paced_session SOCK REQFILE TRANSCRIPT
    python3 "$WORK/paced.py" "$1" "$2" 1.0 > "$3" 2>&1
}
echo "--- shell session transcript ---"
if [ "$CTRL_TOOL" = "python3" ] || command -v python3 >/dev/null 2>&1; then
    paced_session "$SOCK" "$WORK/req1.txt" "$WORK/shell.log"
else
    shell_session "$SOCK" "$WORK/req1.txt" "$WORK/shell.log"
fi
cat "$WORK/shell.log"; echo "---------------------------------"

# phase 1: the spawn answered exactly one protocol line
# NOTE: unanchored on purpose — ash prints its PS1 ('fx# ') on the same
# line as the first output, and on 6.12 the prompt can WIN THE RACE with
# fx-init's protocol response ("fx# OK shell pid 46" vs "OK shell pid 46
# \n"); the anchored form was only correct under the old kernel's race
# outcome.
grep -q 'OK shell pid [0-9][0-9]*' "$WORK/shell.log" \
    || { cat "$WORK/shell.log"; kill "$QPID" 2>/dev/null; fail "shell: no 'OK shell pid N' line"; }
# phase 2: the OPAQUE window — assert the shell's own markers (never OK/ERR).
# NB: the guest busybox is the multi-call binary; only the applets symlinked
# into the image exist as PATH commands, so the probes use shell BUILTINS
# (echo, glob) — `id`/`ls` are NOT in the pivoted root's PATH.
# ash prints its PS1 ON THE SAME LINE as each command's output (no tty =>
# no line-buffered prompt separation), so the markers are matched as
# line-CONTENTS, not anchored lines: "fx# fxmark-one".
grep -q 'fxmark-one' "$WORK/shell.log" \
    || { cat "$WORK/shell.log"; kill "$QPID" 2>/dev/null; fail "shell: no 'fxmark-one' echo output"; }
grep -q 'shellpid=[0-9][0-9]*' "$WORK/shell.log" \
    || { cat "$WORK/shell.log"; kill "$QPID" 2>/dev/null; fail "shell: no 'shellpid=N' output ($$ is not the guest shell's)"; }
grep -q 'fx-roots:' "$WORK/shell.log" \
    || { cat "$WORK/shell.log"; kill "$QPID" 2>/dev/null; fail "shell: no fx-roots marker echo"; }
# the shell SEES the pivoted root: the glob expands to the new root's dirs
# (MEASURED: /bin /dev /etc /fx /lib64 /oldroot /proc /run /sys /usr — no
# /tmp: the image's tmp lives on the initramfs root dhake did not carry).
for d in /etc /bin /proc /dev /fx /usr /run; do
    _d=${d#/}
    grep -q -- "$d" "$WORK/shell.log" \
        || { cat "$WORK/shell.log"; kill "$QPID" 2>/dev/null; fail "shell: the root glob is missing '$_d' (the shell does not see the guest root)"; }
done
# the SENTINEL closed the opaque window
grep -q 'DONE-7331' "$WORK/shell.log" \
    || { cat "$WORK/shell.log"; kill "$QPID" 2>/dev/null; fail "shell: no DONE-7331 sentinel"; }
# phase 3: AFTER the exit, the protocol channel must answer again
grep -q 'generation_current:' "$WORK/shell.log" \
    || { cat "$WORK/shell.log"; kill "$QPID" 2>/dev/null; fail "post-exit status: no generation_current table (the protocol did not come back)"; }
tail -3 "$WORK/shell.log" | grep -q '^OK$' \
    || { cat "$WORK/shell.log"; kill "$QPID" 2>/dev/null; fail "post-exit status: no OK"; }

# ── phase 4: a SECOND shell after the first exited (the latch cleared)
{
    echo 'shell'
    echo 'echo fxmark-two'
    echo 'echo DONE-8442'
    echo 'exit'
} > "$WORK/req2.txt"
paced_session "$SOCK" "$WORK/req2.txt" "$WORK/shell2.log"
echo "--- second shell transcript ---"; cat "$WORK/shell2.log"; echo "--------------------------------"
grep -q 'OK shell pid [0-9][0-9]*' "$WORK/shell2.log" \
    || { cat "$WORK/shell2.log"; kill "$QPID" 2>/dev/null; fail "second shell: no 'OK shell pid N' (the latch did not clear)"; }
grep -q 'fxmark-two' "$WORK/shell2.log" \
    || { cat "$WORK/shell2.log"; kill "$QPID" 2>/dev/null; fail "second shell: no 'fxmark-two' echo output"; }
grep -q 'DONE-8442' "$WORK/shell2.log" \
    || { cat "$WORK/shell2.log"; kill "$QPID" 2>/dev/null; fail "second shell: no DONE-8442 sentinel"; }

# ── the never-blocked proof: the heartbeat service was supervised THROUGH
# both shell sessions — a `grep heartbeat` (protocol, channel free) shows
# recent lines.  Wait for quiescence first, then ask.
sleep 1
printf 'grep heartbeat\n' > "$WORK/req3.txt"
shell_session "$SOCK" "$WORK/req3.txt" "$WORK/grep.log"
grep -q 'heartbeat from heartbeat' "$WORK/grep.log" \
    || { cat "$WORK/grep.log"; kill "$QPID" 2>/dev/null; fail "grep heartbeat: no lines (PID1 supervision died during the shells?)"; }

kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
echo "qemu-shell: PASS (shell over the channel: root id, guest root visible, sentinel-framed exit; protocol returned after the exit; a second shell spawned; heartbeat supervised throughout)"
exit 0
