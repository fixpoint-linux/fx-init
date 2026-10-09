#!/bin/sh
# tests/qemu_recovery_count.sh — THE RECOVERY COUNTER proof: the substrate
# now COUNTS automatic roll-forwards in a plain file, <store>/.recovery,
# readable from the running system (or the raw disk) with a plain file
# read — NOT through the runtime DB, which PID1 holds under a
# process-lifetime exclusive lock.
#
# THE INSTRUMENT UNDER TEST (init.zig, "recovery journal" section):
#   * an append-only JOURNAL, not a bare number — one data line per
#     AUTOMATIC roll-forward: "<epoch-s> <published> <from> <genhash>".
#     The count is the number of data lines; identical genhashes across
#     lines = the same fault coming back (what a count alone cannot show).
#   * the HEADER in the file IS the definition (what counts, what does
#     NOT: operator rollbacks / activations / ordinary boots / refused
#     recoveries), so the reader never needs init.zig;
#   * the append lands inside decide_boot_version AFTER the rollback
#     commits and BEFORE read_store_facts/the first service fork — every
#     failure mode of the recovered boot runs AFTER the increment is
#     durable.  A counter written at boot-ok would read 0 on a machine
#     whose every recovery re-fails; this lane's boots 2+3 FAILED and the
#     counter still moved — the timing proof, by behaviour.
#
# THE ASYMMETRY (fail-before / pass-after), both directions in ONE run:
#   treatment arm (working tree): every journal assertion must PASS;
#   control arm (PINNED revision, git-archive + zig build — never HEAD):
#     the SAME boots must behave identically (seed, roll-forwards,
#     give-up, ctrl rollback — the pinned tree has the guardrail) while
#     EVERY journal assertion must FAIL (the pinned tree never writes
#     .recovery).  If any journal assertion passes on the control, the
#     probe is broken and says so loudly.
#
# THE OSCILLATION (qemu_guardrail.sh's recipe, 4 boots, ONE shared disk):
#   boot 1 (channel): seed at v_flap (flapper's first run is GOOD); upload
#          + activate bad IN-GUEST -> v_bad fails inside the re-armed
#          grace window.  JOURNAL: header present, ZERO data lines — an
#          ordinary good boot and an in-guest FAILURE both append NOTHING.
#   boot 2: stale (v_bad, failed) -> roll forward to v_flap (recovery #1)
#          -> republished content re-breaks (marker survived) ->
#          boot-FAILED v_roll1.  JOURNAL: exactly ONE line:
#          published=v_roll1 from=v_bad genhash=<flapper content>.
#   boot 3: roll forward AGAIN (recovery #2) -> boot-FAILED v_roll2.
#          JOURNAL: exactly TWO lines; line 2 published=v_roll2
#          from=v_roll1, genhash IDENTICAL to line 1 — the recurrence is
#          VISIBLE in the file (N=2 distinguished from 1 by exact counts
#          at every step; a counter stuck at 1 or 0 fails this lane).
#   boot 4 (channel): the guardrail REFUSES (give-up; no roll-forward,
#          current frozen at v_roll2) and a DELIBERATE ctrl `rollback
#          v_flap` is answered OK.  JOURNAL: STILL exactly TWO lines — a
#          refused recovery and an operator rollback both append NOTHING
#          (the definition, pinned by behaviour, not by comment).
#
# BELT: the journal's genhash must EQUAL the genhash the guardrail's own
# measurement line derived on the console (init.zig computes both from the
# store's as-of-resolved generation relation — cross-instrument proof).
#
# The journal is read from the HOST off the raw disk with debugfs
# (plain file read of <store>/.recovery at /store/.recovery in the image)
# after each boot's disk quiescence — the same artifact an in-guest
# reader would cat.
#
# Env: FXSTORE/FX_ACTIVATE/FX_INIT_BIN/FX_SIBLINGS/QEMU_BOOT_TIMEOUT/
#      QEMU_KEEP — same contract as tests/qemu_guardrail.sh.
set -u

fail() { echo "qemu-recovery: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-recovery: SKIP ($*)"; exit 77; }

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
# mke2fs + debugfs live in /sbin,/usr/sbin (not on a user PATH)
MKE2FS=""
for _p in mke2fs /sbin/mke2fs /usr/sbin/mke2fs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then MKE2FS="$_p"; break; fi
done
[ -n "$MKE2FS" ] || skip "mke2fs not found (e2fsprogs)"
DEBUGFS=""
for _p in debugfs /sbin/debugfs /usr/sbin/debugfs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then DEBUGFS="$_p"; break; fi
done
[ -n "$DEBUGFS" ] || skip "debugfs not found (e2fsprogs — the host-side plain read of the journal)"
E2FSCK=""
for _p in e2fsck /sbin/e2fsck /usr/sbin/e2fsck; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then E2FSCK="$_p"; break; fi
done
[ -n "$E2FSCK" ] || skip "e2fsck not found (e2fsprogs — journal replay for the raw-disk read)"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"

# ─── the PINNED control (a FIXED revision, never HEAD) ────────────────────
# 9b20161 = the tree immediately before the recovery journal; it HAS the
# guardrail (2feedf6) so the oscillation boots behave identically, and it
# LACKS the journal — exactly the pre-fix artifact this lane needs.
PIN_REV=9b201610782ecca40184e015028a6f254885b4b7
git cat-file -e "$PIN_REV^{commit}" 2>/dev/null \
    || skip "pinned control revision $PIN_REV not in this repository (shallow clone?) — refusing to test against an unpinned HEAD"

CFG_FLAP="$REPO/m3/config-flapper.dhall"
CFG_BAD="$REPO/m3/config-bad-exit.dhall"
[ -f "$CFG_FLAP" ] || skip "m3/config-flapper.dhall missing"
[ -f "$CFG_BAD" ] || skip "m3/config-bad-exit.dhall missing"
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
WORK="$(mktemp -d "$SCRATCH/qemurec.XXXXXX")" || fail mktemp
SOCK="$WORK/chardev.sock"
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-recovery: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
mkdir -p "$WORK"

# ─── host writer for the channel (qemu_ctrl.sh contract) ─────────────────
CTRL_TOOL=""
if nc -h 2>&1 | grep -q -- '-U.*UNIX domain socket'; then
    CTRL_TOOL=nc
elif command -v python3 >/dev/null 2>&1; then
    CTRL_TOOL=python3
else
    skip "no nc with -U and no python3 — cannot write the virtio chardev socket"
fi
echo "qemu-recovery: channel writer: $CTRL_TOOL"

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

# ─── freeze the package sources (qemu_boot_rollback.sh's shield, verbatim) ─
freeze_src() { # freeze_src SRC DST
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
echo "=== qemu-recovery: freezing package sources (concurrent-writer shield) ==="
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
echo "=== qemu-recovery: building the TREATMENT (working tree) ==="
( cd "$REPO/zig" && zig build install ) > "$WORK/build-treat.log" 2>&1 \
    || { cat "$WORK/build-treat.log"; fail "treatment zig build failed"; }
TREAT_BIN="$REPO/zig/zig-out/bin"
for b in fx-init fx-activate fxctl activate_paths; do
    [ -x "$TREAT_BIN/$b" ] || fail "treatment build produced no $b"
done

echo "=== qemu-recovery: building the CONTROL (pinned $PIN_REV via git archive) ==="
PINROOT="$WORK/pin"
mkdir -p "$PINROOT/fx-init"
git archive "$PIN_REV" | tar -x -C "$PINROOT/fx-init" \
    || skip "git archive $PIN_REV failed"
# build.zig resolves siblings at ../../<name> — symlink the live siblings
# next to the archived tree (read-only use; same siblings the treatment
# build links against).
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
    && fail "cmp guard: pinned init.zig is IDENTICAL to the working tree — the control would not be a pre-fix artifact (pin wrong or fix missing)"

# the fixture is shared by both arms
( cd "$REPO" && zig cc -target x86_64-linux-musl -std=gnu11 -O2 -static \
    -o "$WORK/fakesvc" tests/fixtures/fakesvc/fakesvc.c ) \
    || fail "zig cc fakesvc failed"
cp "$SIBS/dhake/dhake.com" "$WORK/dhake.com"
chmod +x "$WORK/dhake.com"
"$WORK/dhake.com" --assimilate || fail "dhake --assimilate failed"
file "$WORK/dhake.com" 2>/dev/null | grep -q 'statically linked' \
    || skip "dhake.com did not assimilate to a static ELF on this host"

# ─── journal readers (the host-side PLAIN FILE READ of the artifact) ──────
# The killed VM can leave jbd2 transactions COMMITTED-but-not-CHECKPOINTED
# (the data lives only in the on-disk journal area): debugfs reads raw
# blocks without replaying, so a freshly created file could read as absent
# even though the next MOUNT would see it.  Replay the journal on a COPY
# first (e2fsck -fy) — exactly the view the next boot gets; the read is
# then deterministic regardless of how long the guest lived.
read_journal() { # read_journal DISK OUTFILE — replayed copy, then cat /store/.recovery
    _cp="$1.read"
    cp "$1" "$_cp" 2>/dev/null
    "$E2FSCK" -fy "$_cp" >/dev/null 2>&1
    "$DEBUGFS" -R "cat /store/.recovery" "$_cp" > "$2" 2>/dev/null
    rm -f "$_cp"
}
j_lines() { # j_lines FILE -> number of DATA lines (digit-initial)
    _n=$(grep -c '^[0-9]' "$1" 2>/dev/null)
    echo "${_n:-0}"
}
j_field() { # j_field FILE LINENO FIELD — LINENO counts DATA lines only
    awk -v n="$2" -v f="$3" '$0 ~ /^[0-9]/ { c++; if (c == n) { print $f; exit } }' "$1" 2>/dev/null
}

# ─── ONE arm: provision + 4 boots + assertions ────────────────────────────
# run_arm TAG BINDIR MODE(treat|ctrl)
run_arm() {
    TAG=$1 BINDIR=$2 MODE=$3
    STORE="$WORK/$TAG/store"
    ROOT="$WORK/$TAG/root"
    DISK="$WORK/$TAG/disk.img"
    mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp"
    JPASS=0; JFAIL=0

    echo "--- arm $TAG ($MODE): provisioning the store closure ---"
    PATHS=$(LD_LIBRARY_PATH="$DLDIR" "$BINDIR/activate_paths" \
        --store "$STORE" --package-set "$PKGSET" \
        dhake fx-init fxctl fx-activate fake-service datalog-dafsa dhall-c fxstore) \
        || fail "$TAG: activate_paths failed"
    [ -n "$PATHS" ] || fail "$TAG: activate_paths printed no closure"
    echo "$PATHS" | while IFS= read -r pd; do
        mkdir -p "$STORE/$pd" || exit 1
        case "$pd" in
            *-fx-init)        cp "$BINDIR/fx-init"     "$STORE/$pd/fx-init"; chmod 755 "$STORE/$pd/fx-init" ;;
            *-fxctl)          cp "$BINDIR/fxctl"       "$STORE/$pd/fxctl";   chmod 755 "$STORE/$pd/fxctl" ;;
            *-fx-activate)    cp "$BINDIR/fx-activate" "$STORE/$pd/fx-activate"; chmod 755 "$STORE/$pd/fx-activate" ;;
            *-fake-service)   cp "$WORK/fakesvc"       "$STORE/$pd/fakesvc"; chmod 755 "$STORE/$pd/fakesvc" ;;
            *-dhake)          cp "$WORK/dhake.com"     "$STORE/$pd/dhake.com"; chmod 755 "$STORE/$pd/dhake.com" ;;
            *)                : > "$STORE/$pd/.provisioned-by-qemu-recovery" ;;
        esac
    done
    FXD=$(ls -d "$STORE"/*-fx-init | head -1)
    [ -x "$FXD/fx-init" ] || fail "$TAG: fx-init was not staged into the store closure"
    RDINIT="/fx/store/$(basename "$FXD")/fx-init"

    OUT_FLAP=$(LD_LIBRARY_PATH="$DLDIR" "$BINDIR/fx-activate" --store "$STORE" \
        --package-set "$PKGSET" --config "$CFG_FLAP" 2>&1) \
        || fail "$TAG: activate flapper failed: $OUT_FLAP"
    V_FLAP=$(echo "$OUT_FLAP" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$V_FLAP" ] || fail "$TAG: cannot parse flapper version from: $OUT_FLAP"
    echo "$TAG: flapper activated as v$V_FLAP"

    sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/$TAG/img.cpio.gz" -p "$PKGSET" \
        || fail "$TAG: mkinitramfs failed"
    qemu-img create -q "$DISK" 512M || fail "$TAG: qemu-img create failed"
    "$MKE2FS" -q -t ext4 -J size=4 "$DISK" >/dev/null 2>&1 \
        || fail "$TAG: mke2fs -t ext4 (journaled) failed"

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

    run_boot() {
        _con=$1 _chan=$2
        : > "$_con"
        rm -f "$SOCK"
        qemu-system-x86_64 \
            -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
            -kernel "$KERNEL" -initrd "$WORK/$TAG/img.cpio.gz" \
            -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
            -nographic -no-reboot -monitor none -serial file:"$_con" \
            -drive file="$DISK",format=raw,if=virtio \
            -chardev socket,id=fxctl0,path="$SOCK",server=on,wait=off \
            -device virtio-serial-pci -device virtserialport,chardev=fxctl0,name=fxctl0 \
            >"$WORK/$TAG/qemu.$$.out" 2>&1 &
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
            return 0   # the ctrl session owns the kill
        fi
        wait_disk_quiet
        kill "$QPID" 2>/dev/null
        wait "$QPID" 2>/dev/null
        return 0
    }

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

    # jassert DESC RC — a JOURNAL assertion: in treat mode it must pass; in
    # ctrl mode it must FAIL (the pinned tree never writes the journal).
    jassert() {
        _d=$1 _rc=$2
        if [ "$MODE" = treat ]; then
            if [ "$_rc" != 0 ]; then
                echo "--- journal dump on failure ($TAG) ---"
                cat "$WORK/$TAG"/j*.txt 2>/dev/null
                echo "---"
                fail "$TAG: $_d"
            fi
        else
            if [ "$_rc" = 0 ]; then
                JPASS=$((JPASS + 1)); echo "ctrl: journal assertion UNEXPECTEDLY passed: $_d"
            else
                JFAIL=$((JFAIL + 1)); echo "ctrl: journal assertion failed as expected: $_d"
            fi
        fi
    }

    # jzassert DESC RC — a journal assertion that is VACUOUS on a machine
    # with no journal ("zero data lines" is trivially true when the file is
    # absent): in treat mode identical to jassert; in ctrl mode it is NOT a
    # discriminator and is ignored (counted neither way).
    jzassert() {
        if [ "$MODE" = treat ]; then
            jassert "$1" "$2"
        else
            echo "ctrl: vacuous-on-absence assertion not counted: $1"
        fi
    }

    echo "=== arm $TAG boot 1: seed at v$V_FLAP (good boot), then in-guest activate of the bad config ==="
    run_boot "$WORK/$TAG/console1.log" 1
    grep -q 'fx-init: disk store mounted (current v'"$V_FLAP"')' "$WORK/$TAG/console1.log" \
        || { tail -40 "$WORK/$TAG/console1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: no disk-store line (seed)"; }
    grep -q "fx-init: boot-ok v$V_FLAP" "$WORK/$TAG/console1.log" \
        || { tail -40 "$WORK/$TAG/console1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: want boot-ok v$V_FLAP"; }
    _i=0
    while [ ! -S "$SOCK" ] && [ "$_i" -lt 60 ]; do sleep 0.5; _i=$((_i + 1)); done
    [ -S "$SOCK" ] || { kill "$QPID" 2>/dev/null; fail "$TAG boot 1: chardev socket never appeared"; }
    {
        echo 'put /etc/bad.dhall'
        base64 -w 76 "$CFG_BAD"
        echo '.'
        echo 'activate /etc/bad.dhall'
    } > "$WORK/$TAG/req1.txt"
    ctrl_session "$SOCK" "$WORK/$TAG/req1.txt" "$WORK/$TAG/ctrl1.log"
    grep -q '^OK$' "$WORK/$TAG/ctrl1.log" \
        || { cat "$WORK/$TAG/ctrl1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: put/activate: no OK in transcript"; }
    V_BAD=$(sed -n 's/^activated version \([0-9][0-9]*\)$/\1/p' "$WORK/$TAG/ctrl1.log" | head -1)
    [ -n "$V_BAD" ] || { cat "$WORK/$TAG/ctrl1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: no activated version line"; }
    [ "$V_BAD" -gt "$V_FLAP" ] || { kill "$QPID" 2>/dev/null; fail "$TAG boot 1: v$V_BAD not above v$V_FLAP"; }
    wait_console "$WORK/$TAG/console1.log" "fx-init: boot-FAILED v$V_BAD" \
        || { tail -40 "$WORK/$TAG/console1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: v$V_BAD never failed its re-armed grace window"; }
    wait_disk_quiet
    kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null

    read_journal "$DISK" "$WORK/$TAG/j1.txt"
    # the header IS the definition: present on disk, naming what counts and
    # what does not — from the machine's FIRST (good) boot on
    _rc=0
    grep -q 'fx-init recovery journal' "$WORK/$TAG/j1.txt" 2>/dev/null || _rc=1
    grep -q 'AUTOMATIC roll-forward' "$WORK/$TAG/j1.txt" 2>/dev/null || _rc=1
    grep -q 'NOT counted' "$WORK/$TAG/j1.txt" 2>/dev/null || _rc=1
    jassert "boot 1: journal header with the definition must exist on disk" "$_rc"
    _n=$(j_lines "$WORK/$TAG/j1.txt")
    [ "$_n" = 0 ]; jzassert "boot 1: ZERO data lines after an ordinary good boot + one in-guest failure (got $_n)" "$?"

    echo "=== arm $TAG boot 2: recovery #1 (roll forward to v$V_FLAP), re-break -> boot-FAILED ==="
    run_boot "$WORK/$TAG/console2.log" 0
    grep -q "fx-init: stale failed for v$V_BAD; rolling forward to v$V_FLAP" "$WORK/$TAG/console2.log" \
        || { tail -40 "$WORK/$TAG/console2.log"; fail "$TAG boot 2: no roll-forward line"; }
    V_ROLL1=$(sed -n 's/.*fx-init: boot-FAILED v\([0-9][0-9]*\).*/\1/p' "$WORK/$TAG/console2.log" | head -1)
    [ -n "$V_ROLL1" ] || { tail -40 "$WORK/$TAG/console2.log"; fail "$TAG boot 2: no boot-FAILED verdict (recovered content must re-break)"; }
    [ "$V_ROLL1" -gt "$V_BAD" ] || fail "$TAG boot 2: v$V_ROLL1 not above v$V_BAD"

    read_journal "$DISK" "$WORK/$TAG/j2.txt"
    _n=$(j_lines "$WORK/$TAG/j2.txt")
    [ "$_n" = 1 ]; jassert "boot 2: exactly ONE data line after recovery #1 (got $_n)" "$?"
    _f=$(j_field "$WORK/$TAG/j2.txt" 1 2)
    [ "$_f" = "$V_ROLL1" ]; jassert "boot 2: line 1 published=v$V_ROLL1 (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/j2.txt" 1 3)
    [ "$_f" = "$V_BAD" ]; jassert "boot 2: line 1 from=v$V_BAD (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/j2.txt" 1 1)
    case "$_f" in ''|*[!0-9]*) _rc=1 ;; *) _rc=0 ;; esac
    jassert "boot 2: line 1 epoch is numeric (got '$_f')" "$_rc"

    echo "=== arm $TAG boot 3: recovery #2 (roll forward AGAIN), second re-break ==="
    run_boot "$WORK/$TAG/console3.log" 0
    grep -q "fx-init: stale failed for v$V_ROLL1; rolling forward to v$V_FLAP" "$WORK/$TAG/console3.log" \
        || { tail -40 "$WORK/$TAG/console3.log"; fail "$TAG boot 3: no roll-forward line"; }
    V_ROLL2=$(sed -n 's/.*fx-init: boot-FAILED v\([0-9][0-9]*\).*/\1/p' "$WORK/$TAG/console3.log" | head -1)
    [ -n "$V_ROLL2" ] || { tail -40 "$WORK/$TAG/console3.log"; fail "$TAG boot 3: no boot-FAILED verdict"; }
    [ "$V_ROLL2" -gt "$V_ROLL1" ] || fail "$TAG boot 3: v$V_ROLL2 not above v$V_ROLL1"

    read_journal "$DISK" "$WORK/$TAG/j3.txt"
    _n=$(j_lines "$WORK/$TAG/j3.txt")
    [ "$_n" = 2 ]; jassert "boot 3: exactly TWO data lines after recovery #2 — N=2 distinguished from 1 (got $_n)" "$?"
    _f=$(j_field "$WORK/$TAG/j3.txt" 2 2)
    [ "$_f" = "$V_ROLL2" ]; jassert "boot 3: line 2 published=v$V_ROLL2 (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/j3.txt" 2 3)
    [ "$_f" = "$V_ROLL1" ]; jassert "boot 3: line 2 from=v$V_ROLL1 (got '$_f')" "$?"
    _g1=$(j_field "$WORK/$TAG/j3.txt" 1 4)
    _g2=$(j_field "$WORK/$TAG/j3.txt" 2 4)
    [ -n "$_g1" ] && [ "$_g1" = "$_g2" ]; jassert "boot 3: line 2 genhash IDENTICAL to line 1 — the recurrence is visible in the file ('$_g1' vs '$_g2')" "$?"

    echo "=== arm $TAG boot 4: the guardrail REFUSES + a DELIBERATE ctrl rollback — neither appends ==="
    run_boot "$WORK/$TAG/console4.log" 1
    grep -q 'fx-init: recovery gave up' "$WORK/$TAG/console4.log" \
        || { tail -40 "$WORK/$TAG/console4.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 4: no give-up line"; }
    grep -q 'rolling forward' "$WORK/$TAG/console4.log" \
        && { kill "$QPID" 2>/dev/null; fail "$TAG boot 4: a roll-forward happened (guardrail broken at this binary?)"; }
    _i=0
    while [ ! -S "$SOCK" ] && [ "$_i" -lt 60 ]; do sleep 0.5; _i=$((_i + 1)); done
    [ -S "$SOCK" ] || { kill "$QPID" 2>/dev/null; fail "$TAG boot 4: chardev socket never appeared"; }
    echo "rollback $V_FLAP" > "$WORK/$TAG/req4.txt"
    ctrl_session "$SOCK" "$WORK/$TAG/req4.txt" "$WORK/$TAG/ctrl4.log"
    echo "--- arm $TAG boot-4 ctrl transcript ---"; cat "$WORK/$TAG/ctrl4.log"; echo "---"
    grep -q '^rolled back to version '"$V_FLAP" "$WORK/$TAG/ctrl4.log" \
        || { cat "$WORK/$TAG/ctrl4.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 4: the deliberate rollback was not performed"; }
    grep -q '^OK$' "$WORK/$TAG/ctrl4.log" \
        || { cat "$WORK/$TAG/ctrl4.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 4: no OK for the deliberate rollback"; }
    wait_disk_quiet
    kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null

    read_journal "$DISK" "$WORK/$TAG/j4.txt"
    _n=$(j_lines "$WORK/$TAG/j4.txt")
    [ "$_n" = 2 ]; jassert "boot 4: STILL exactly TWO lines after a refused recovery AND a deliberate operator rollback (got $_n)" "$?"

    # BELT (treat only): the journal's genhash == the guardrail's own
    # console measurement line genhash (both derive from the store's as-of
    # generation relation; a mismatch means two instruments disagree).
    if [ "$MODE" = treat ]; then
        GH_CONS=$(sed -n "s/.*recovery to v$V_FLAP content genhash=\([0-9a-f]*\).*/\1/p" "$WORK/$TAG/console2.log" | head -1)
        GH_J=$(j_field "$WORK/$TAG/j3.txt" 1 4)
        [ -n "$GH_CONS" ] || fail "$TAG belt: no genhash on boot 2's console measurement line"
        [ "$GH_CONS" = "$GH_J" ] \
            || fail "$TAG belt: journal genhash '$GH_J' != console measurement genhash '$GH_CONS'"
    fi

    if [ "$MODE" = ctrl ]; then
        [ "$JPASS" = 0 ] || fail "control arm: $JPASS journal assertion(s) PASSED on pinned $PIN_REV — the control is not pre-fix (pin or probe broken)"
        [ "$JFAIL" -ge 1 ] || fail "control arm: no journal assertion ran — probe is broken"
    fi
    echo "--- arm $TAG ($MODE) done: journal data lines final=$(j_lines "$WORK/$TAG/j4.txt") ctrl-failures-noted=$JFAIL ---"
}

run_arm treat "$TREAT_BIN" treat
run_arm ctrl  "$CTRL_BIN"  ctrl

echo "qemu-recovery: PASS (treatment: journal counted exactly 1 then 2 roll-forwards with an IDENTICAL genhash — the recurrence visible; header carried the definition from boot 1; the refused recovery and the deliberate operator rollback appended NOTHING; journal genhash == the console measurement's. control $PIN_REV: same boots, every journal assertion failed as expected)"
exit 0
