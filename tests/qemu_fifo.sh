#!/bin/sh
# tests/qemu_fifo.sh — the IN-GUEST control channel: a FIFO PAIR in /run/fx
# (control.in client->PID1, control.out PID1->client) so fxctl works INSIDE
# the guest, no sockets (the pinned kernel has CONFIG_NET unset — socket(2)
# is ENOSYS there, MEASURED), leaving the virtio port's single consumer as
# the external operator.
#
# SHAPE (qemu_shell.sh's skeleton, cloned): ONE boot of config-good with the
# virtio control port attached, then ONE paced shell session over the port:
#   phase 1  "shell"                  -> the protocol line "OK shell pid N"
#   phase 2  OPAQUE: IN-GUEST `fxctl --fifo q generation_current` (the fifo
#            round trip — its data row must equal the version the HOST
#            activated: live-PID1-DB proof, not a canned string) and
#            `fxctl --fifo status`, both rc-echoed INSIDE the guest, framed
#            by the DONE-7331 sentinel + exit
#   phase 3  after the exit, "status" over the virtio protocol — the port
#            still answers after the fifo dispatched: PID1's main loop
#            survived the third input fd.
# BELTS: the console must carry BOTH "fx-init: fifo control up" AND
# "fx-init: virtio control up (/dev/vport" (the fifo must not disturb the
# port — qemu_ctrl.sh's pinned line).
#
# TIMEOUTS AT EVERY LAYER (a PID1 bug hangs the whole guest, so a hang must
# be a FAILURE, never a hung run): the boot verdict loop is bounded
# (BOOT_TIMEOUT*2 x 0.5s — no verdict line => FAIL); the paced session runs
# under timeout(1) 45; every channel write is timeout-bounded; fxctl itself
# can never hang by construction (O_NONBLOCK opens, a single <=PIPE_BUF
# write, PollSource's 5s poll budget); QEMU is killed by the EXIT trap even
# on a fail() exit, so no run can leak a live guest.
#
# FAILING BASELINE (pre-change, MEASURED on the pristine tree): in-guest
# fxctl has no --fifo and no sockets on this kernel, so
# `fxctl --fifo q generation_current` prints
#   "fxctl: connect /run/fx/control.sock: Function not implemented"
# with FXRC=1 — the asymmetry proof for this test (fails before, passes
# after).
#
# Env: FXSTORE/FX_ACTIVATE/FX_INIT_BIN/FX_SIBLINGS/QEMU_BOOT_TIMEOUT/
#      QEMU_KEEP — same contract as tests/qemu_ctrl.sh / qemu_shell.sh.
set -u

fail() { echo "qemu-fifo: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-fifo: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
command -v python3 >/dev/null 2>&1 || skip "python3 not found (the paced session driver)"
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
WORK="$(mktemp -d "$SCRATCH/qemufifo.XXXXXX")" || fail mktemp
SOCK="$WORK/chardev.sock"
QPID=""
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-fifo: scratch kept at $WORK"' EXIT
else
    trap '[ -n "$QPID" ] && kill "$QPID" 2>/dev/null; rm -rf "$WORK"' EXIT
fi
STORE="$WORK/store"
ROOT="$WORK/root"
DISK="$WORK/disk.img"
mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp"

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
echo "=== qemu-fifo: freezing package sources (concurrent-writer shield) ==="
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
    echo "=== qemu-fifo: toolchain-free provisioning ==="
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
            *)                : > "$STORE/$pd/.provisioned-by-qemu-fifo" ;;
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

echo "=== qemu-fifo: activating good config (store $STORE) ==="
OUT_GOOD=$(activate "$STORE" "$CFG_GOOD") || fail "activate good failed: $OUT_GOOD"
V_GOOD=$(echo "$OUT_GOOD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$V_GOOD" ] || fail "cannot parse good version from: $OUT_GOOD"
echo "$OUT_GOOD"

echo "=== qemu-fifo: building the ONE initramfs (ramfs CURRENT = v$V_GOOD) ==="
sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/img.cpio.gz" -p "$PKGSET" \
    || fail "mkinitramfs failed"
qemu-img create -q "$DISK" 512M || fail "qemu-img create failed"
# journaled ext4 BEFORE the first boot (qemu_ctrl.sh's measured rationale: a
# NOJOURNAL disk left torn by the harness kill dies on the next boot's first
# inode allocation — the guest's busybox mkfs.ext2 cannot add a journal).
"$MKE2FS" -q -t ext4 -J size=4 "$DISK" >/dev/null 2>&1 \
    || fail "mke2fs -t ext4 (journaled) failed — install e2fsprogs"

FXD=$(ls -d "$STORE"/*-fx-init | head -1)
RDINIT="/fx/store/$(basename "$FXD")/fx-init"

echo "=== qemu-fifo: boot — then the in-guest fxctl --fifo session ==="
: > "$WORK/console.log"
rm -f "$SOCK"
timeout $((BOOT_TIMEOUT * 4)) qemu-system-x86_64 \
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
    || { tail -40 "$WORK/console.log"; fail "boot: want boot-ok v$V_GOOD (no verdict = a hung guest is a FAILED guest)"; }
_i=0
while [ ! -S "$SOCK" ] && [ "$_i" -lt 60 ]; do sleep 0.5; _i=$((_i + 1)); done
[ -S "$SOCK" ] || fail "chardev socket never appeared"

# ── the paced shell session (qemu_shell.sh's driver): 'shell' spawns the
# guest shell ON the port; the OPAQUE window runs the IN-GUEST fxctl over
# the FIFO PAIR (rc echoed inside the guest); the sentinel closes the window;
# 'status' then proves the virtio protocol SURVIVED the fifo traffic.
{
    echo 'shell'
    echo 'echo FXQ-BEGIN'
    echo 'fxctl --fifo q generation_current; _qrc=$?'
    echo 'echo FXQ-END'
    echo 'echo FXRC=$_qrc'
    echo 'fxctl --fifo status; echo SRC=$?'
    echo 'echo DONE-7331'
    echo 'exit'
    echo 'status'
} > "$WORK/req1.txt"
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
echo "--- fifo session transcript ---"
timeout 45 python3 "$WORK/paced.py" "$SOCK" "$WORK/req1.txt" 1.0 > "$WORK/fifo.log" 2>&1
cat "$WORK/fifo.log"; echo "--------------------------------"

# ── the fifo round trip: `fxctl --fifo q generation_current` must have
# printed EXACTLY the version the HOST activated (the live PID1's runtime DB
# answered, not a canned string).  ash prints its PS1 ('fx# ') on the same
# line as output (no tty — see qemu_shell.sh), so the row is matched with a
# non-digit prefix stripped, inside the FXQ-BEGIN/END frame.
VQ=$(sed -n '/FXQ-BEGIN/,/FXQ-END/p' "$WORK/fifo.log" \
    | sed -n 's/^[^0-9]*\([0-9][0-9]*\)$/\1/p' | head -1)
[ -n "$VQ" ] \
    || { cat "$WORK/fifo.log"; fail "fifo q: no version row between FXQ-BEGIN/FXQ-END (the in-guest fxctl did not answer)"; }
[ "$VQ" = "$V_GOOD" ] \
    || { cat "$WORK/fifo.log"; fail "fifo q: row v$VQ != host-activated v$V_GOOD (not the live DB's answer)"; }
grep -q 'FXRC=0' "$WORK/fifo.log" \
    || { cat "$WORK/fifo.log"; fail "fifo q: FXRC != 0 (fxctl --fifo exited non-zero)"; }
# `fxctl --fifo status`: the section header + rc 0 — the status grammar rides
# the fifo unchanged.
grep -q 'generation_current:' "$WORK/fifo.log" \
    || { cat "$WORK/fifo.log"; fail "fifo status: no generation_current table"; }
grep -q 'SRC=0' "$WORK/fifo.log" \
    || { cat "$WORK/fifo.log"; fail "fifo status: SRC != 0 (fxctl --fifo status exited non-zero)"; }
# the sentinel closed the opaque window
grep -q 'DONE-7331' "$WORK/fifo.log" \
    || { cat "$WORK/fifo.log"; fail "no DONE-7331 sentinel"; }
# phase 3: AFTER the exit, the virtio protocol must answer again — PID1's
# main loop survived the fifo dispatches (the third input fd neither wedged
# nor silenced the port).
sed -n '/DONE-7331/,$p' "$WORK/fifo.log" | grep -q 'generation_current:' \
    || { cat "$WORK/fifo.log"; fail "post-exit status: no generation_current table (the protocol did not come back)"; }
tail -3 "$WORK/fifo.log" | grep -q '^OK$' \
    || { cat "$WORK/fifo.log"; fail "post-exit status: no OK"; }

# ── console belts: BOTH channels came up — the fifo exists AND it did not
# disturb the virtio port (qemu_ctrl.sh's pinned line).
grep -q 'fx-init: fifo control up (.*/control.in + .*/control.out)' "$WORK/console.log" \
    || { tail -40 "$WORK/console.log"; fail "console: no 'fx-init: fifo control up' line"; }
grep -q 'fx-init: virtio control up (/dev/vport' "$WORK/console.log" \
    || { tail -40 "$WORK/console.log"; fail "console: no virtio control up line (the fifo disturbed the port?)"; }

kill "$QPID" 2>/dev/null
wait "$QPID" 2>/dev/null
QPID=""
echo "qemu-fifo: PASS (in-guest fxctl --fifo answered v$V_GOOD from the live PID1 over /run/fx/control.in+out; status rode the fifo; the virtio protocol survived)"
exit 0
