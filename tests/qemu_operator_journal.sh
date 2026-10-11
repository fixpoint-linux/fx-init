#!/bin/sh
# tests/qemu_operator_journal.sh — THE OPERATOR JOURNAL proof: operator
# interventions (control-channel activate / rollback / shutdown) were
# recorded ONLY in the runtime datalog (/run/fx/log.db — POST-PIVOT TMPFS,
# dies at every reboot), so the only durable trace of an operator action
# was the ABSENCE of an automatic roll-forward.  This gate pins, BY
# BEHAVIOUR, that every generation-plane intervention leaves a DURABLE row
# in <store>/.operator — read back OFF THE DISK IMAGE with debugfs after
# the machine is gone, the same artifact an in-guest reader would cat.
#
# THE INSTRUMENT UNDER TEST (init.zig, "operator journal" section):
#   * <store>/.operator, an append-only journal beside .bootlog/.recovery,
#     with a HEADER that is the definition (what is recorded, what is NOT,
#     and which intervention paths can never reach the file);
#   * line: <epoch-s> <action> <arg> <outcome> <from|-> <to|-> <boot-nonce|none>
#   * fsync + syncfs per append, BEFORE the reply is flushed — a machine
#     KILLED right after the response still carries the row.
#
# THE ASYMMETRY (fail-before / pass-after), both directions in ONE run:
#   treatment arm (working tree): every .operator assertion must PASS;
#   control arm (PINNED revision 4c5803d, git-archive + zig build — the
#     tree immediately before the journal): the SAME boots must behave
#     identically (same verdicts, same channel responses) while EVERY
#     .operator assertion must FAIL (the pinned tree never writes the
#     file).  A pinned run whose .operator assertions PASS says the pin
#     or the probe is broken, and fails loudly.
#
# THE BOOTS (ONE image + ONE shared 512M disk per arm, qemu_ctrl.sh's
# composition: v_bad published below v_good, ramfs CURRENT = v_good).  NB:
# the ctrl ROLLBACK arm does NOT re-arm the boot decision (only activate
# does — MEASURED in this gate's first run: no verdict line ever follows
# a channel rollback), so the rolled-back-to generation is JUDGED by the
# NEXT boot, exactly as qemu_ctrl.sh's boot 2 does it.
#   boot 1 (channel, nonce A): seed disk at v_good, boot-ok.  Then IN-GUEST
#          over the channel: status (a READ), `activate /nonexistent.dhall`
#          (the executor fails -> a FAILED intervention is still recorded),
#          `rollback 9999` (the store REFUSES -> recorded), `rollback v_bad`
#          (ok -> recorded), status again (a READ).  QEMU is then KILLED —
#          the machine dies, not powers off: the rows must already be on
#          the disk.  DISK: 3 data lines, all nonce A; the two status
#          commands append nothing — the effects are DISTINGUISHED BY
#          TOKEN, not by count alone.
#   boot 2 (NO channel, nonce B): boots the rolled-back-to v_ctrl; the
#          crasher fails in grace -> boot-FAILED v_ctrl.  No intervention
#          happened: DISK still 3 lines, nonce B on NONE of them — the
#          rows survived a machine death AND a fresh boot that judged the
#          recorded generation.
#   boot 3 (channel, nonce C): stale (v_ctrl, failed) -> AUTOMATIC
#          roll-forward to v_good (boot-ok v_roll; the .recovery journal
#          gains its line — the semantics this change must NOT move).
#          Then: status (READ), `rollback 9998` (refused, nonce C),
#          `shutdown` (ok, nonce C) — the machine powers itself off.
#          DISK: 5 lines; the earlier file is byte-identical underneath
#          (durability across a SECOND machine death and re-mount).
#   boot 4 (NO channel, nonce D): ordinary boot-ok, NO intervention.
#          DISK: STILL 5 lines; nonce D appears on NO line (an ordinary
#          boot appends NOTHING) and .recovery is still exactly 1.
#
# NONCE BINDING: every boot passes its own fx.bootnonce= on the kernel
# command line; the rows carry the boot's latched token (asserted per
# line), so an appended forged line cannot wear a nonce its boot was never
# issued — the same discipline .bootlog/.recovery already have.
#
# The journals are read from the HOST off the raw disk with debugfs
# (journal-replayed copy first — e2fsck -fy — the view the next mount
# gets; see read_journal below).
#
# Env: FXSTORE/FX_ACTIVATE/FX_INIT_BIN/FX_SIBLINGS/QEMU_BOOT_TIMEOUT/
#      QEMU_KEEP — same contract as tests/qemu_guardrail.sh.
set -u

fail() { echo "qemu-operator: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-operator: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
command -v base64 >/dev/null 2>&1 || skip "base64 not found"
command -v git >/dev/null 2>&1    || skip "git not found (pinned control)"
command -v zig >/dev/null 2>&1    || skip "zig not found (build both arms)"
[ -e /dev/kvm ]                   || skip "/dev/kvm absent"
[ -w /dev/kvm ]                   || skip "/dev/kvm not writable"
# mke2fs + debugfs + e2fsck live in /sbin,/usr/sbin (not on a user PATH)
MKE2FS=""
for _p in mke2fs /sbin/mke2fs /usr/sbin/mke2fs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then MKE2FS="$_p"; break; fi
done
[ -n "$MKE2FS" ] || skip "mke2fs not found (e2fsprogs — disk store)"
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
# 4c5803d = the tree immediately before the operator journal; it has the
# recovery journal and the full ctrl-arm behaviour (so the boots and the
# channel responses are identical) and LACKS .operator — exactly the
# pre-fix artifact this lane needs.
PIN_REV=4c5803d93c79361078c5f5b3349e5fe931c88f11
git cat-file -e "$PIN_REV^{commit}" 2>/dev/null \
    || skip "pinned control revision $PIN_REV not in this repository (shallow clone?) — refusing to test against an unpinned HEAD"

CFG_GOOD="$REPO/m3/config-good.dhall"
CFG_BAD="$REPO/m3/config-bad-exit.dhall"
[ -f "$CFG_GOOD" ] || skip "m3/config-good.dhall missing"
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
WORK="$(mktemp -d "$SCRATCH/qemuopj.XXXXXX")" || fail mktemp
SOCK="$WORK/chardev.sock"
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-operator: scratch kept at $WORK"' EXIT
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
echo "qemu-operator: channel writer: $CTRL_TOOL"

# One session carries up to five commands including an in-guest fx-activate
# (package-set load + failure), so the recovery-count timeouts, not the
# single-command ctrl ones.
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
echo "=== qemu-operator: freezing package sources (concurrent-writer shield) ==="
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
echo "=== qemu-operator: building the TREATMENT (working tree) ==="
( cd "$REPO/zig" && zig build install ) > "$WORK/build-treat.log" 2>&1 \
    || { cat "$WORK/build-treat.log"; fail "treatment zig build failed"; }
TREAT_BIN="$REPO/zig/zig-out/bin"
for b in fx-init fx-activate fxctl activate_paths; do
    [ -x "$TREAT_BIN/$b" ] || fail "treatment build produced no $b"
done

echo "=== qemu-operator: building the CONTROL (pinned $PIN_REV via git archive) ==="
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
# The killed VM can leave jbd2 transactions COMMITTED-but-not-CHECKPOINTED:
# debugfs reads raw blocks without replaying, so a freshly written file
# could read as absent even though the next MOUNT would see it.  Replay the
# journal on a COPY first (e2fsck -fy) — exactly the view the next boot
# gets; the read is then deterministic regardless of how the guest died.
read_journal() { # read_journal DISK OUTFILE MEMBER — replayed copy, then cat
    _disk=$1 _out=$2 _member=$3
    _cp="$_disk.read"
    cp "$_disk" "$_cp" 2>/dev/null
    "$E2FSCK" -fy "$_cp" >/dev/null 2>&1
    "$DEBUGFS" -R "cat /store/$_member" "$_cp" > "$_out" 2>/dev/null
    rm -f "$_cp"
}
read_operator() { read_journal "$1" "$2" ".operator"; }
read_recovery()  { read_journal "$1" "$2" ".recovery"; }
j_lines() { # j_lines FILE -> number of DATA lines (digit-initial)
    _n=$(grep -c '^[0-9]' "$1" 2>/dev/null)
    echo "${_n:-0}"
}
j_field() { # j_field FILE LINENO FIELD — LINENO counts DATA lines only
    awk -v n="$2" -v f="$3" '$0 ~ /^[0-9]/ { c++; if (c == n) { print $f; exit } }' "$1" 2>/dev/null
}

# ─── ONE arm: provision + 3 boots + assertions ─────────────────────────────
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
            *)                : > "$STORE/$pd/.provisioned-by-qemu-operator" ;;
        esac
    done
    FXD=$(ls -d "$STORE"/*-fx-init | head -1)
    [ -x "$FXD/fx-init" ] || fail "$TAG: fx-init was not staged into the store closure"
    RDINIT="/fx/store/$(basename "$FXD")/fx-init"

    # bad FIRST, good on top: v_bad stays published BELOW v_good in the
    # same db (fx_store_rollback's target); ramfs CURRENT = v_good.
    OUT_BAD=$(LD_LIBRARY_PATH="$DLDIR" "$BINDIR/fx-activate" --store "$STORE" \
        --package-set "$PKGSET" --config "$CFG_BAD" 2>&1) \
        || fail "$TAG: activate bad failed: $OUT_BAD"
    V_BAD=$(echo "$OUT_BAD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$V_BAD" ] || fail "$TAG: cannot parse bad version from: $OUT_BAD"
    OUT_GOOD=$(LD_LIBRARY_PATH="$DLDIR" "$BINDIR/fx-activate" --store "$STORE" \
        --package-set "$PKGSET" --config "$CFG_GOOD" 2>&1) \
        || fail "$TAG: activate good failed: $OUT_GOOD"
    V_GOOD=$(echo "$OUT_GOOD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$V_GOOD" ] || fail "$TAG: cannot parse good version from: $OUT_GOOD"
    [ "$V_GOOD" -gt "$V_BAD" ] || fail "$TAG: good v$V_GOOD not above bad v$V_BAD"
    echo "$TAG: v_bad=$V_BAD v_good=$V_GOOD"

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
    wait_qemu_gone() {
        _i=0
        while [ "$_i" -lt 120 ]; do
            kill -0 "$QPID" 2>/dev/null || return 0
            sleep 0.5
            _i=$((_i + 1))
        done
        return 1
    }

    NONCE1="dead4f2a00000001"
    NONCE2="dead4f2a00000002"
    NONCE3="dead4f2a00000003"
    NONCE4="dead4f2a00000004"

    # run_boot CONSOLE CHANNEL NONCE — the ONE image on $DISK, a per-boot
    # fx.bootnonce= so every journal row is attributable to its boot.
    run_boot() {
        _con=$1 _chan=$2 _nonce=$3
        : > "$_con"
        rm -f "$SOCK"
        qemu-system-x86_64 \
            -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
            -kernel "$KERNEL" -initrd "$WORK/$TAG/img.cpio.gz" \
            -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store fx.bootnonce=$_nonce panic=-1 oops=panic" \
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

    # jassert DESC RC — a .operator assertion: in treat mode it must pass;
    # in ctrl mode it must FAIL (the pinned tree never writes the journal).
    jassert() {
        _d=$1 _rc=$2
        if [ "$MODE" = treat ]; then
            if [ "$_rc" != 0 ]; then
                echo "--- journal dump on failure ($TAG) ---"
                cat "$WORK/$TAG"/op*.txt 2>/dev/null
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
    # with no journal ("file absent vs absent" compares equal): in treat
    # mode identical to jassert; in ctrl mode it is NOT a discriminator
    # and is ignored (counted neither way).
    jzassert() {
        if [ "$MODE" = treat ]; then
            jassert "$1" "$2"
        else
            echo "ctrl: vacuous-on-absence assertion not counted: $1"
        fi
    }

    # ── boot 1: seed + three interventions, then the machine is KILLED ────
    echo "=== arm $TAG boot 1: seed at v$V_GOOD (nonce $NONCE1), drive 3 interventions + 2 reads in-guest ==="
    run_boot "$WORK/$TAG/console1.log" 1 "$NONCE1"
    grep -q 'fx-init: disk store mounted (current v'"$V_GOOD"')' "$WORK/$TAG/console1.log" \
        || { tail -40 "$WORK/$TAG/console1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: no disk-store line (seed)"; }
    grep -q "fx-init: boot-ok v$V_GOOD" "$WORK/$TAG/console1.log" \
        || { tail -40 "$WORK/$TAG/console1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: want boot-ok v$V_GOOD"; }
    grep -q "fx-init: boot nonce $NONCE1" "$WORK/$TAG/console1.log" \
        || { tail -40 "$WORK/$TAG/console1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: the nonce was never latched (no 'boot nonce' console line)"; }
    _i=0
    while [ ! -S "$SOCK" ] && [ "$_i" -lt 60 ]; do sleep 0.5; _i=$((_i + 1)); done
    [ -S "$SOCK" ] || { kill "$QPID" 2>/dev/null; fail "$TAG boot 1: chardev socket never appeared"; }
    {
        echo 'status'
        echo 'activate /nonexistent.dhall'
        echo 'rollback 9999'
        echo "rollback $V_BAD"
        echo 'status'
    } > "$WORK/$TAG/req1.txt"
    ctrl_session "$SOCK" "$WORK/$TAG/req1.txt" "$WORK/$TAG/ctrl1.log"
    echo "--- arm $TAG boot-1 ctrl transcript ---"; cat "$WORK/$TAG/ctrl1.log"; echo "---"
    # the READS must answer (normal paths unchanged by the journal)
    [ "$(grep -c 'boot_status:' "$WORK/$TAG/ctrl1.log")" = "2" ] \
        || { cat "$WORK/$TAG/ctrl1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: expected two status tables (one per read)"; }
    grep -q '^ERR activate failed (rc ' "$WORK/$TAG/ctrl1.log" \
        || { cat "$WORK/$TAG/ctrl1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: the failed activate did not answer ERR activate failed"; }
    grep -q '^ERR ' "$WORK/$TAG/ctrl1.log" \
        || { cat "$WORK/$TAG/ctrl1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: no ERR for the refused rollback 9999"; }
    V_CTRL=$(sed -n "s/^rolled back to version $V_BAD (current \([0-9][0-9]*\))$/\1/p" "$WORK/$TAG/ctrl1.log" | head -1)
    [ -n "$V_CTRL" ] \
        || { cat "$WORK/$TAG/ctrl1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: no 'rolled back to version $V_BAD (current N)' line"; }
    [ "$V_CTRL" -gt "$V_GOOD" ] || { kill "$QPID" 2>/dev/null; fail "$TAG boot 1: v$V_CTRL not above v$V_GOOD"; }
    sed -n "/^rolled back to version/,\$p" "$WORK/$TAG/ctrl1.log" | grep -q '^OK$' \
        || { cat "$WORK/$TAG/ctrl1.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 1: no OK after the rollback line"; }
    # NO verdict wait here: the ctrl ROLLBACK arm does not re-arm the boot
    # decision (MEASURED — that is the activate arm's re-arm), so nothing
    # judges v_ctrl until boot 2 boots it.  The rows are already durable
    # (operator_append fsyncs before the reply); quiesce and kill.
    wait_disk_quiet
    kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null

    read_operator "$DISK" "$WORK/$TAG/op1.txt"
    # the header IS the definition: it must NAME what it records, what it
    # refuses to record, and the paths it can NEVER see
    _rc=0
    grep -q 'fx-init operator journal' "$WORK/$TAG/op1.txt" 2>/dev/null || _rc=1
    grep -q 'NOT recorded' "$WORK/$TAG/op1.txt" 2>/dev/null || _rc=1
    grep -q 'fxstore rollback' "$WORK/$TAG/op1.txt" 2>/dev/null || _rc=1
    jassert "boot 1: journal header with the definition must exist on disk" "$_rc"
    _n=$(j_lines "$WORK/$TAG/op1.txt")
    [ "$_n" = 3 ]; jassert "boot 1: exactly THREE data lines (3 interventions; the two status READS append nothing) (got $_n)" "$?"
    # line 1: the FAILED activation — recorded with the executor's rc, and
    # "-" for a to-version that a failed executor never confirmed
    _f=$(j_field "$WORK/$TAG/op1.txt" 1 2); [ "$_f" = activate ]; jassert "boot 1: line 1 action=activate (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op1.txt" 1 3); [ "$_f" = /nonexistent.dhall ]; jassert "boot 1: line 1 arg verbatim (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op1.txt" 1 4); case "$_f" in failed:[0-9-]*) _rc=0 ;; *) _rc=1 ;; esac
    jassert "boot 1: line 1 outcome=failed:<rc> (got '$_f')" "$_rc"
    _f=$(j_field "$WORK/$TAG/op1.txt" 1 5); [ "$_f" = "$V_GOOD" ]; jassert "boot 1: line 1 from=v$V_GOOD (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op1.txt" 1 6); [ "$_f" = "-" ]; jassert "boot 1: line 1 to='-' (got '$_f')" "$?"
    # line 2: the REFUSED rollback — an intervention that did not take
    # effect, still recorded (the activation-refusal gap this file closes)
    _f=$(j_field "$WORK/$TAG/op1.txt" 2 2); [ "$_f" = rollback ]; jassert "boot 1: line 2 action=rollback (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op1.txt" 2 3); [ "$_f" = 9999 ]; jassert "boot 1: line 2 arg=9999 (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op1.txt" 2 4); [ "$_f" = refused ]; jassert "boot 1: line 2 outcome=refused (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op1.txt" 2 6); [ "$_f" = "-" ]; jassert "boot 1: line 2 to='-' — nothing landed (got '$_f')" "$?"
    # line 3: the OK rollback — from/to attribute the move
    _f=$(j_field "$WORK/$TAG/op1.txt" 3 4); [ "$_f" = ok ]; jassert "boot 1: line 3 outcome=ok (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op1.txt" 3 5); [ "$_f" = "$V_GOOD" ]; jassert "boot 1: line 3 from=v$V_GOOD (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op1.txt" 3 6); [ "$_f" = "$V_CTRL" ]; jassert "boot 1: line 3 to=v$V_CTRL (got '$_f')" "$?"
    # every row of THIS boot carries THIS boot's nonce
    _i=1; _rc=0
    while [ "$_i" -le 3 ]; do
        _f=$(j_field "$WORK/$TAG/op1.txt" "$_i" 7)
        [ "$_f" = "$NONCE1" ] || _rc=1
        _i=$((_i + 1))
    done
    jassert "boot 1: all 3 rows carry boot 1's nonce $NONCE1" "$_rc"
    # .recovery must NOT have moved: operator actions are never recorded there
    if [ "$MODE" = treat ]; then
        read_recovery "$DISK" "$WORK/$TAG/rec1.txt"
        _n=$(j_lines "$WORK/$TAG/rec1.txt")
        [ "$_n" = 0 ] || fail "$TAG boot 1: .recovery gained $_n line(s) — operator actions must NEVER write .recovery"
    fi

    # ── boot 2: the rolled-back-to generation is JUDGED by a fresh boot
    # (the rollback arm does not re-arm; see boot 1).  NO intervention
    # happens in this boot — the rows must be untouched and unattributed.
    echo "=== arm $TAG boot 2: boots the rolled-back-to v$V_CTRL (nonce $NONCE2), crasher fails in grace ==="
    run_boot "$WORK/$TAG/console2.log" 0 "$NONCE2"
    grep -q 'fx-init: disk store mounted (current v'"$V_CTRL"')' "$WORK/$TAG/console2.log" \
        || { tail -40 "$WORK/$TAG/console2.log"; fail "$TAG boot 2: disk current is not v$V_CTRL (the in-guest rollback did not persist)"; }
    grep -q "fx-init: boot-FAILED v$V_CTRL" "$WORK/$TAG/console2.log" \
        || { tail -40 "$WORK/$TAG/console2.log"; fail "$TAG boot 2: want boot-FAILED v$V_CTRL (the crasher must fail in grace)"; }

    read_operator "$DISK" "$WORK/$TAG/op2.txt"
    _n=$(j_lines "$WORK/$TAG/op2.txt")
    [ "$_n" = 3 ]; jassert "boot 2: STILL three data lines after a machine death and a fresh boot (got $_n)" "$?"
    grep -q "$NONCE2" "$WORK/$TAG/op2.txt" \
        && { echo "--- nonce $NONCE2 found in a no-intervention boot's journal ---"; fail "$TAG boot 2: nonce $NONCE2 appears — a boot that intervened NOTHING must append NOTHING"; }
    if [ "$MODE" = treat ]; then
        read_recovery "$DISK" "$WORK/$TAG/rec2.txt"
        _n=$(j_lines "$WORK/$TAG/rec2.txt")
        [ "$_n" = 0 ] || fail "$TAG boot 2: .recovery gained $_n line(s) — no AUTOMATIC roll-forward happened yet"
    fi

    # ── boot 3: AUTOMATIC roll-forward (.recovery moves, .operator does
    # not), then 1 refused rollback + shutdown — the machine powers OFF ──
    echo "=== arm $TAG boot 3: roll-forward to v$V_GOOD (nonce $NONCE3), then refused rollback + shutdown ==="
    run_boot "$WORK/$TAG/console3.log" 1 "$NONCE3"
    grep -q "fx-init: stale failed for v$V_CTRL; rolling forward to v$V_GOOD" "$WORK/$TAG/console3.log" \
        || { tail -40 "$WORK/$TAG/console3.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 3: no roll-forward line"; }
    V_ROLL=$(sed -n 's/.*fx-init: boot-ok v\([0-9][0-9]*\).*/\1/p' "$WORK/$TAG/console3.log" | head -1)
    [ -n "$V_ROLL" ] || { tail -40 "$WORK/$TAG/console3.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 3: no boot-ok verdict"; }
    [ "$V_ROLL" -gt "$V_CTRL" ] || { kill "$QPID" 2>/dev/null; fail "$TAG boot 3: v$V_ROLL not above v$V_CTRL"; }
    _i=0
    while [ ! -S "$SOCK" ] && [ "$_i" -lt 60 ]; do sleep 0.5; _i=$((_i + 1)); done
    [ -S "$SOCK" ] || { kill "$QPID" 2>/dev/null; fail "$TAG boot 3: chardev socket never appeared"; }
    {
        echo 'status'
        echo 'rollback 9998'
        echo 'shutdown'
    } > "$WORK/$TAG/req3.txt"
    ctrl_session "$SOCK" "$WORK/$TAG/req3.txt" "$WORK/$TAG/ctrl3.log"
    echo "--- arm $TAG boot-3 ctrl transcript ---"; cat "$WORK/$TAG/ctrl3.log"; echo "---"
    grep -q 'boot_status:' "$WORK/$TAG/ctrl3.log" \
        || { cat "$WORK/$TAG/ctrl3.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 3: no status table in transcript"; }
    grep -q '^ERR ' "$WORK/$TAG/ctrl3.log" \
        || { cat "$WORK/$TAG/ctrl3.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 3: no ERR for the refused rollback 9998"; }
    sed -n '/^ERR /,$p' "$WORK/$TAG/ctrl3.log" | grep -q '^OK$' \
        || { cat "$WORK/$TAG/ctrl3.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 3: no OK for the shutdown"; }
    # the shutdown powers the machine off: PID1 exits, panic=-1 + -no-reboot
    # make QEMU exit.  Belt: it must not need the harness's kill.
    wait_qemu_gone \
        || { tail -30 "$WORK/$TAG/console3.log"; kill "$QPID" 2>/dev/null; fail "$TAG boot 3: QEMU never exited after the shutdown"; }
    wait "$QPID" 2>/dev/null

    read_operator "$DISK" "$WORK/$TAG/op3.txt"
    _n=$(j_lines "$WORK/$TAG/op3.txt")
    [ "$_n" = 5 ]; jassert "boot 3: FIVE data lines total — 2 new (refused rollback + shutdown), the status READ appended nothing (got $_n)" "$?"
    # durability across a SECOND machine death and re-mount: op3 is exactly
    # op1 + the two new rows — compare the PREFIX
    _t3=$(wc -l < "$WORK/$TAG/op3.txt" 2>/dev/null)
    head -n $((_t3 - 2)) "$WORK/$TAG/op3.txt" > "$WORK/$TAG/op3head.txt" 2>/dev/null
    cmp -s "$WORK/$TAG/op1.txt" "$WORK/$TAG/op3head.txt"
    jzassert "boot 3: boot 1's file is byte-identical (header + 3 rows) after two machine deaths and re-mounts" "$?"
    _f=$(j_field "$WORK/$TAG/op3.txt" 4 4); [ "$_f" = refused ]; jassert "boot 3: line 4 outcome=refused (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op3.txt" 4 5); [ "$_f" = "$V_ROLL" ]; jassert "boot 3: line 4 from=v$V_ROLL (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op3.txt" 5 2); [ "$_f" = shutdown ]; jassert "boot 3: line 5 action=shutdown (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op3.txt" 5 3); [ "$_f" = "-" ]; jassert "boot 3: line 5 arg='-' (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op3.txt" 5 4); [ "$_f" = ok ]; jassert "boot 3: line 5 outcome=ok (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op3.txt" 5 5); [ "$_f" = "$V_ROLL" ]; jassert "boot 3: line 5 from=v$V_ROLL (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op3.txt" 5 6); [ "$_f" = "-" ]; jassert "boot 3: line 5 to='-' — a shutdown moves no generation (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op3.txt" 4 7); [ "$_f" = "$NONCE3" ]; jassert "boot 3: line 4 nonce=$NONCE3 (got '$_f')" "$?"
    _f=$(j_field "$WORK/$TAG/op3.txt" 5 7); [ "$_f" = "$NONCE3" ]; jassert "boot 3: line 5 nonce=$NONCE3 (got '$_f')" "$?"
    # the two journals carry the two sides of the same boot: .recovery the
    # AUTOMATIC roll-forward, .operator the OPERATOR's actions — and never
    # each other's (the semantics this change must NOT move)
    if [ "$MODE" = treat ]; then
        read_recovery "$DISK" "$WORK/$TAG/rec3.txt"
        _n=$(j_lines "$WORK/$TAG/rec3.txt")
        [ "$_n" = 1 ] || fail "$TAG boot 3: .recovery has $_n line(s) after boot 3's roll-forward (want exactly 1)"
        _f=$(j_field "$WORK/$TAG/rec3.txt" 1 2)
        [ "$_f" = "$V_ROLL" ] || fail "$TAG boot 3: .recovery line 1 published=v$_f, want the roll-forward v$V_ROLL"
    fi

    # ── boot 4: an ORDINARY boot (nonce D, NO channel, NO intervention) ───
    echo "=== arm $TAG boot 4: ordinary boot (nonce $NONCE4) — no intervention, nothing new ==="
    run_boot "$WORK/$TAG/console4.log" 0 "$NONCE4"
    grep -q "fx-init: boot-ok v$V_ROLL" "$WORK/$TAG/console4.log" \
        || { tail -40 "$WORK/$TAG/console4.log"; fail "$TAG boot 4: want boot-ok v$V_ROLL (ordinary re-boot)"; }

    read_operator "$DISK" "$WORK/$TAG/op4.txt"
    _n=$(j_lines "$WORK/$TAG/op4.txt")
    [ "$_n" = 5 ]; jassert "boot 4: STILL five lines after an ordinary boot (got $_n)" "$?"
    grep -q "$NONCE4" "$WORK/$TAG/op4.txt" \
        && { echo "--- nonce $NONCE4 found in an ordinary boot's journal ---"; fail "$TAG boot 4: nonce $NONCE4 appears — an ordinary boot must append NOTHING"; }
    [ -s "$WORK/$TAG/op4.txt" ]; jassert "boot 4: the journal file is still readable on disk" "$?"
    if [ "$MODE" = treat ]; then
        read_recovery "$DISK" "$WORK/$TAG/rec4.txt"
        _n=$(j_lines "$WORK/$TAG/rec4.txt")
        [ "$_n" = 1 ] || fail "$TAG boot 4: .recovery gained $_n line(s) on an ordinary boot (want still 1)"
    fi

    if [ "$MODE" = ctrl ]; then
        [ "$JPASS" = 0 ] || fail "control arm: $JPASS journal assertion(s) PASSED on pinned $PIN_REV — the control is not pre-fix (pin or probe broken)"
        [ "$JFAIL" -ge 1 ] || fail "control arm: no journal assertion ran — probe is broken"
    fi
    echo "--- arm $TAG ($MODE) done: journal data lines final=$(j_lines "$WORK/$TAG/op4.txt" 2>/dev/null || echo 0) ctrl-failures-noted=$JFAIL ---"
}

run_arm treat "$TREAT_BIN" treat
run_arm ctrl  "$CTRL_BIN"  ctrl

echo "qemu-operator: PASS (treatment: 3 rows after boot 1 — a FAILED activate, a REFUSED rollback and an OK one, all nonce-bound; the two status READS appended nothing; the rows survived the machine being killed AND a fresh boot that judged the recorded generation; boot 3's roll-forward boot added its refused-rollback and shutdown rows under its own nonce, byte-identical underneath; boot 4's ordinary boot appended nothing and .recovery counted only the AUTOMATIC roll-forward. control $PIN_REV: same boots, every journal assertion failed as expected)"
exit 0
