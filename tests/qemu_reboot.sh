#!/bin/sh
# tests/qemu_reboot.sh — S3: THE SOFT REBOOT GATE.  A `reboot` over the ctrl
# channel must actually RE-ENTER THE BOOT PATH, and this gate believes it only
# if it sees THE SECOND BOOT.
#
# THE VERB UNDER TEST (init.zig `reboot <reason>`, S3): admits through
# operator_journal.admit (the verdict latch, an open shell, and
# REBOOT_SAME_VERSION_MAX consecutive same-from-version reboots), records ONE
# `.operator` row, REPLIES, and only then lets main() run do_soft_reboot()
# (teardown -> wipe_run_state -> syncfs_store -> execve /proc/self/exe).
#
# WHAT IS ASSERTED, IN TWO CLASSES, AND WHY THE SPLIT IS THE GATE:
#   'record'  (the reply + the durable row) — the operator saw an answer and a
#             row landed.  BLIND to whether the machine came back.
#   'boot'    (the SECOND BOOT) — two "boot start store", two "boot nonce N"
#             with the SAME nonce, the pivot-not-attempted line ONLY in the
#             second one, a second "boot-ok v<V>" for the generation that was
#             current, two (in-progress, ok) pairs in .bootlog, and the
#             "soft reboot: re-entering" line with NO "soft reboot FAILED".
#   'hold'    facts that must hold in every arm (not how the fix is detected).
#
# THE ASYMMETRY, THREE ARMS, ONE SCRIPT:
#   treat   (the working tree):            record PASS, boot PASS.
#   noexec  (MUT-NOEXEC: the SAME tree with `const rc = reexec_self();`
#            replaced by `const rc: c_int = -1;` — admit, record, reply, SKIP
#            the execve):                   record PASS, boot FAIL.
#           THIS IS THE POINT OF THE GATE.  A gate that passes on MUT-NOEXEC is
#           testing the logger, not the re-entry; this one fails it loudly.
#   ctrl    (PINNED pre-fix c0aa45b, the tree BEFORE this landing, where the
#            arm does not exist and answers "ERR unknown command"):
#                                            record FAIL, boot FAIL.
#           The SAME script must observe exactly ONE "boot start store" and no
#           second pair — the fail-before direction.
#
# THE FIRST BOOT CANNOT PRODUCE THE PIVOT LINE: on an initramfs boot the root
# fstype IS rootfs, so the pivot RUNS and "pivot not attempted" is ABSENT
# (tests/qemu_boot_pivot.sh asserts that absence).  On the re-entry the root is
# tmpfs, so the line appears exactly once — which is why this gate asserts
# ONE, positioned AFTER the first verdict, and not the plan's "second pair".
#
# WHAT THIS GATE DOES NOT PROVE: that the machine performed a HARD reboot.  It
# did not and cannot — no firmware, no device re-init, no kernel restart (see
# do_soft_reboot's own comment).  Under qemu -no-reboot a real reboot(2) would
# make qemu EXIT; here qemu stays alive and the second boot happens in-guest.
#
# Env: QEMU_BOOT_TIMEOUT / QEMU_KEEP / TMPDIR (this host: TMPDIR=/home/jaye/tmp
# — /tmp is over quota) — same contract as tests/qemu_operator_journal.sh.
set -u

fail() { echo "qemu-reboot: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-reboot: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
command -v git >/dev/null 2>&1    || skip "git not found (pinned control)"
command -v zig >/dev/null 2>&1    || skip "zig not found (build all three arms)"
command -v sed >/dev/null 2>&1    || skip "sed not found (MUT-NOEXEC)"
[ -e /dev/kvm ]                   || skip "/dev/kvm absent"
[ -w /dev/kvm ]                   || skip "/dev/kvm not writable"
# mke2fs / debugfs / e2fsck live in /sbin,/usr/sbin (not on a user PATH)
MKE2FS=""
for _p in mke2fs /sbin/mke2fs /usr/sbin/mke2fs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then MKE2FS="$_p"; break; fi
done
[ -n "$MKE2FS" ] || skip "mke2fs not found (e2fsprogs — disk store)"
DEBUGFS=""
for _p in debugfs /sbin/debugfs /usr/sbin/debugfs; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then DEBUGFS="$_p"; break; fi
done
[ -n "$DEBUGFS" ] || skip "debugfs not found (the host-side plain read of the journal)"
E2FSCK=""
for _p in e2fsck /sbin/e2fsck /usr/sbin/e2fsck; do
    if command -v "$_p" >/dev/null 2>&1 || [ -x "$_p" ]; then E2FSCK="$_p"; break; fi
done
[ -n "$E2FSCK" ] || skip "e2fsck not found (journal replay for the raw-disk read)"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"

# ─── the PINNED control (a FIXED revision, never HEAD) ────────────────────
# c0aa45b = the tree immediately before this landing: it carries S1's
# vocabulary and the whole ctrl surface, and has NO `reboot` arm — so the SAME
# script sends `reboot <reason>` and the guest answers "ERR unknown command"
# with no second boot.  That is the pre-fix artifact this lane needs.
PIN_REV=c0aa45b34685d10560b75b352a2b40a6fb90c25e
git cat-file -e "$PIN_REV^{commit}" 2>/dev/null \
    || skip "pinned control revision $PIN_REV not in this repository (shallow clone?) — refusing to test against an unpinned HEAD"

CFG_GOOD="$REPO/m3/config-good.dhall"
[ -f "$CFG_GOOD" ] || skip "m3/config-good.dhall missing"
BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-90}"
REASON="s3-gate"

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
WORK="$(mktemp -d "$SCRATCH/qemureboot.XXXXXX")" || fail mktemp
SOCK="$WORK/chardev.sock"
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-reboot: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi

# ─── host writer for the channel (qemu_ctrl.sh contract) ─────────────────
CTRL_TOOL=""
if nc -h 2>&1 | grep -q -- '-U.*UNIX domain socket'; then
    CTRL_TOOL=nc
elif command -v python3 >/dev/null 2>&1; then
    CTRL_TOOL=python3
else
    skip "no nc with -U and no python3 — cannot write the virtio chardev socket"
fi
echo "qemu-reboot: channel writer: $CTRL_TOOL"

# ctrl_session SOCK REQFILE TRANSCRIPT — send the request file's lines over the
# chardev socket in ONE connection, NO half-close (MEASURED: -N makes qemu tear
# the chardev down before the guest's response write, silently dropping it).
ctrl_session() { # ctrl_session SOCK REQFILE TRANSCRIPT
    _sock=$1 _req=$2 _out=$3
    case "$CTRL_TOOL" in
        nc) timeout 60 nc -w 20 -U "$_sock" < "$_req" > "$_out" 2>&1 ;;
        python3) timeout 60 python3 -c '
import socket, sys, time
sock, req = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.sendall(open(req, "rb").read())
# NO shutdown(SHUT_WR): the guest writes its responses on the same connection
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

# ─── freeze the package sources (qemu_operator_journal.sh's shield, verbatim) ─
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
echo "=== qemu-reboot: freezing package sources (concurrent-writer shield) ==="
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

# ─── build the THREE ARMS ────────────────────────────────────────────────
echo "=== qemu-reboot: building the TREATMENT (working tree) ==="
( cd "$REPO/zig" && zig build install ) > "$WORK/build-treat.log" 2>&1 \
    || { tail -40 "$WORK/build-treat.log"; fail "treatment zig build failed"; }
TREAT_BIN="$REPO/zig/zig-out/bin"
for b in fx-init fx-activate fxctl activate_paths; do
    [ -x "$TREAT_BIN/$b" ] || fail "treatment build produced no $b"
done

echo "=== qemu-reboot: building the CONTROL (pinned $PIN_REV via git archive) ==="
PINROOT="$WORK/pin"
mkdir -p "$PINROOT/fx-init"
git archive "$PIN_REV" | tar -x -C "$PINROOT/fx-init" \
    || skip "git archive $PIN_REV failed"
cmp -s "$PINROOT/fx-init/zig/src/init.zig" "$REPO/zig/src/init.zig" \
    && fail "cmp guard: pinned init.zig is IDENTICAL to the working tree — the control would not be a pre-fix artifact (pin wrong or the S3 wiring missing)"
ln -s "$SIBS/datalog-dafsa" "$PINROOT/datalog-dafsa"
ln -s "$SIBS/dhall-c"       "$PINROOT/dhall-c"
ln -s "$SIBS/fxstore"       "$PINROOT/fxstore"
( cd "$PINROOT/fx-init/zig" && zig build install ) > "$WORK/build-ctrl.log" 2>&1 \
    || { tail -40 "$WORK/build-ctrl.log"; fail "control zig build failed"; }
CTRL_BIN="$PINROOT/fx-init/zig/zig-out/bin"
[ -x "$CTRL_BIN/fx-init" ] || fail "control build produced no fx-init"

echo "=== qemu-reboot: building MUT-NOEXEC (the SAME tree, the execve SKIPPED) ==="
cp -a "$WORK/frozen/fx-init" "$WORK/mut-fx-init" || fail "cannot copy the frozen tree for the mutant"
MUT_SRC="$WORK/mut-fx-init/zig/src/init.zig"
sed -e 's|const rc = reexec_self();|const rc: c_int = -1; // MUT-NOEXEC: the execve is SKIPPED|' \
    "$MUT_SRC" > "$WORK/mut-init.zig" || fail "sed failed on the mutant source"
mv "$WORK/mut-init.zig" "$MUT_SRC" || fail "cannot install the mutant source"
[ "$(grep -c 'MUT-NOEXEC' "$MUT_SRC")" = "1" ] \
    || fail "MUT-NOEXEC did not apply exactly once — the call site in do_soft_reboot MOVED; fix the sed (never weaken the mutation)"
# build.zig resolves the siblings at ../../<name> — relative to the MUTANT's
# parent ($WORK), since the mutant lives at $WORK/mut-fx-init.  They point at
# the LIVE siblings (read-only), exactly like the pinned control arm: the
# frozen copies are for the package-set/store closure, and freeze_src drops
# *.so — a mutant linked against those would fail to build, not to test.
ln -s "$SIBS/datalog-dafsa" "$WORK/datalog-dafsa"
ln -s "$SIBS/dhall-c"       "$WORK/dhall-c"
ln -s "$SIBS/fxstore"       "$WORK/fxstore"
( cd "$WORK/mut-fx-init/zig" && zig build install ) > "$WORK/build-mut.log" 2>&1 \
    || { tail -40 "$WORK/build-mut.log"; fail "mutant zig build failed"; }
MUT_BIN="$WORK/mut-fx-init/zig/zig-out/bin"
[ -x "$MUT_BIN/fx-init" ] || fail "mutant build produced no fx-init"
cmp -s "$MUT_BIN/fx-init" "$TREAT_BIN/fx-init" \
    && fail "the MUT-NOEXEC binary is IDENTICAL to the treatment — the mutation did not reach the build"

# ─── the fixture (shared by all arms) ────────────────────────────────────
( cd "$REPO" && zig cc -target x86_64-linux-musl -std=gnu11 -O2 -static \
    -o "$WORK/fakesvc" tests/fixtures/fakesvc/fakesvc.c ) \
    || fail "zig cc fakesvc failed"
cp "$SIBS/dhake/dhake.com" "$WORK/dhake.com"
chmod +x "$WORK/dhake.com"
"$WORK/dhake.com" --assimilate || fail "dhake --assimilate failed"
file "$WORK/dhake.com" 2>/dev/null | grep -q 'statically linked' \
    || skip "dhake.com did not assimilate to a static ELF on this host"

# ─── record readers (the host-side PLAIN FILE READ of the artifact) ──────
# The killed VM can leave jbd2 transactions committed-but-not-checkpointed:
# replay the journal on a COPY first (e2fsck -fy) — the view the next mount
# gets — then read the raw fs with debugfs.  Same technique, same reason, as
# tests/qemu_operator_journal.sh.
read_journal() { # read_journal DISK OUTFILE MEMBER
    _disk=$1 _out=$2 _member=$3
    _cp="$_disk.read"
    cp "$_disk" "$_cp" 2>/dev/null
    "$E2FSCK" -fy "$_cp" >/dev/null 2>&1
    "$DEBUGFS" -R "cat /store/$_member" "$_cp" > "$_out" 2>/dev/null
    rm -f "$_cp"
}
cnt() { # cnt PATTERN FILE — occurrences of a fixed string (0 when absent)
    _n=$(grep -c -F -- "$1" "$2" 2>/dev/null)
    echo "${_n:-0}"
}
n_reboot_rows() { # data rows whose action is `reboot`
    awk '$1 ~ /^[0-9]+$/ && $2 == "reboot" { n++ } END { print n + 0 }' "$1" 2>/dev/null
}
op_field() { # op_field FIELD FILE — FIELD of the FIRST reboot data row
    awk -v f="$1" '$1 ~ /^[0-9]+$/ && $2 == "reboot" { print $f; exit }' "$2" 2>/dev/null
}

# ─── ONE arm: build the store, boot, drive the channel, assert ────────────
# run_arm TAG MODE BINDIR
TOTAL_FAIL=0
run_arm() {
    TAG=$1 MODE=$2 BINDIR=$3
    STORE="$WORK/$TAG/store"
    ROOT="$WORK/$TAG/root"
    DISK="$WORK/$TAG/disk.img"
    CON="$WORK/$TAG/console.log"
    TRANS="$WORK/$TAG/ctrl.log"
    mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp" "$WORK/$TAG"

    echo "--- arm $TAG ($MODE): provisioning the store closure at $STORE ---"
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
            *)                : > "$STORE/$pd/.provisioned-by-qemu-reboot" ;;
        esac
    done
    FXD=$(ls -d "$STORE"/*-fx-init | head -1)
    [ -x "$FXD/fx-init" ] || fail "$TAG: fx-init was not staged into the store closure"
    RDINIT="/fx/store/$(basename "$FXD")/fx-init"

    # ONE activation: the generation that is CURRENT when the reboot is asked
    # is the one the re-entry must decide on and boot again.
    OUT_GOOD=$(LD_LIBRARY_PATH="$DLDIR" "$BINDIR/fx-activate" --store "$STORE" \
        --package-set "$PKGSET" --config "$CFG_GOOD" 2>&1) \
        || fail "$TAG: activate failed: $OUT_GOOD"
    V_CUR=$(echo "$OUT_GOOD" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$V_CUR" ] || fail "$TAG: cannot parse the version from: $OUT_GOOD"
    echo "$TAG: v_cur=$V_CUR"

    sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" \
        -o "$WORK/$TAG/img.cpio.gz" -p "$PKGSET" \
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

    NONCE="dead5e0b0000000$(printf '%s' "$TAG" | cksum | awk '{print $1 % 10}')"
    echo "--- arm $TAG: boot (channel up, nonce $NONCE) ---"
    : > "$CON"
    rm -f "$SOCK"
    qemu-system-x86_64 \
        -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
        -kernel "$KERNEL" -initrd "$WORK/$TAG/img.cpio.gz" \
        -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store fx.bootnonce=$NONCE panic=-1 oops=panic" \
        -nographic -no-reboot -monitor none -serial file:"$CON" \
        -drive file="$DISK",format=raw,if=virtio \
        -chardev socket,id=fxctl0,path="$SOCK",server=on,wait=off \
        -device virtio-serial-pci -device virtserialport,chardev=fxctl0,name=fxctl0 \
        >"$WORK/$TAG/qemu.out" 2>&1 &
    QPID=$!
    _i=0
    while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
        grep -q 'fx-init: boot-ok v\|fx-init: boot-FAILED v\|fx-init: no generation to boot' "$CON" && break
        kill -0 "$QPID" 2>/dev/null || break
        sleep 0.5
        _i=$((_i + 1))
    done
    kill -0 "$QPID" 2>/dev/null || fail "$TAG: the guest died before the first verdict (qemu.out: $(tail -3 "$WORK/$TAG/qemu.out" 2>/dev/null))"

    # THE SESSION: a READ (status, so the transcript proves the channel is the
    # live one) then THE REBOOT.  One burst is right here: both commands are
    # newline-delimited and neither forks a child that takes the port (unlike
    # `shell`), so the handler walks the whole buffer and the reboot's reply is
    # flushed before main_loop ever returns.
    printf 'status\nreboot %s\n' "$REASON" > "$WORK/$TAG/req.txt"
    ctrl_session "$SOCK" "$WORK/$TAG/req.txt" "$TRANS"
    echo "--- arm $TAG: ctrl transcript ---"; cat "$TRANS"; echo "--------------------------------"

    # Wait (bounded) for the SECOND boot; an arm that never re-enters simply
    # runs out the clock and the 'boot' assertions below fail on the count.
    # 30s: the treatment arm's re-entry lands in seconds (MEASURED), so this is
    # ~10x the observed latency and not a tailored budget.
    _i=0
    while [ "$_i" -lt 60 ]; do
        [ "$(cnt 'fx-init: boot-ok v' "$CON")" -ge 2 ] && break
        kill -0 "$QPID" 2>/dev/null || break
        sleep 0.5
        _i=$((_i + 1))
    done
    wait_disk_quiet
    kill "$QPID" 2>/dev/null
    wait "$QPID" 2>/dev/null

    read_journal "$DISK" "$WORK/$TAG/op.txt" ".operator"
    read_journal "$DISK" "$WORK/$TAG/bootlog.txt" ".bootlog"
    if [ "${QEMU_KEEP:-0}" = "1" ]; then
        echo "--- arm $TAG: .operator data rows ---"; grep '^[0-9]' "$WORK/$TAG/op.txt" 2>/dev/null
        echo "--- arm $TAG: .bootlog ---";           grep '^[0-9]' "$WORK/$TAG/bootlog.txt" 2>/dev/null
    fi

    # ── the measured facts, each as an exit code ──────────────────────────
    N_START=$(cnt 'fx-init: boot start store' "$CON")
    N_NONCE=$(cnt "fx-init: boot nonce $NONCE" "$CON")
    N_BOK=$(cnt "fx-init: boot-ok v$V_CUR" "$CON")
    N_PIVOT=$(cnt '— pivot not attempted' "$CON")
    N_SOFT=$(cnt 'fx-init: soft reboot: re-entering the boot path' "$CON")
    N_NFAIL=$(cnt 'fx-init: soft reboot FAILED' "$CON")
    N_SHUT=$(cnt ' shutdown ' "$WORK/$TAG/bootlog.txt")
    L_BOK=$(grep -n -F "fx-init: boot-ok v" "$CON" | head -1 | cut -d: -f1)
    L_PIV=$(grep -n -F -- '— pivot not attempted' "$CON" | head -1 | cut -d: -f1)
    N_OKREPLY=$(grep -c '^OK$' "$TRANS" 2>/dev/null); N_OKREPLY=${N_OKREPLY:-0}
    N_REFUSED=$(cnt 'reboot refused:' "$TRANS")
    LAST_LINE=$(tail -1 "$TRANS" 2>/dev/null)
    N_RR=$(n_reboot_rows "$WORK/$TAG/op.txt")
    OP_OUT=$(op_field 4 "$WORK/$TAG/op.txt")
    OP_FROM=$(op_field 5 "$WORK/$TAG/op.txt")
    OP_TO=$(op_field 6 "$WORK/$TAG/op.txt")
    OP_NONCE=$(op_field 7 "$WORK/$TAG/op.txt")
    OP_ARG=$(op_field 3 "$WORK/$TAG/op.txt")
    N_BL_IP=$(grep -c "^$V_CUR in-progress [0-9][0-9]* $NONCE\$" "$WORK/$TAG/bootlog.txt" 2>/dev/null)
    N_BL_OK=$(grep -c "^$V_CUR ok [0-9][0-9]* $NONCE\$" "$WORK/$TAG/bootlog.txt" 2>/dev/null)
    N_BL_IP=${N_BL_IP:-0}; N_BL_OK=${N_BL_OK:-0}

    echo "--- arm $TAG: measured ---"
    echo "  console: boot-start=$N_START nonce=$N_NONCE boot-ok(v$V_CUR)=$N_BOK pivot-skip=$N_PIVOT soft=$N_SOFT exec-FAILED=$N_NFAIL"
    echo "  channel: OKs=$N_OKREPLY refusals=$N_REFUSED last='$LAST_LINE'"
    echo "  record:  reboot-rows=$N_RR outcome='$OP_OUT' from='$OP_FROM' to='$OP_TO' arg='$OP_ARG' nonce='$OP_NONCE'"
    echo "  bootlog: (v$V_CUR,in-progress)=$N_BL_IP (v$V_CUR,ok)=$N_BL_OK shutdown-lines=$N_SHUT"

    # ── the assertions ───────────────────────────────────────────────────
    # chk CLASS DESC RC.  CLASS: hold | record | boot.  What a pass MEANS is
    # the arm's, and the asymmetry is the bookkeeping:
    #   hold   — must hold in EVERY arm (it is not how the fix is detected)
    #   record — PASS in treat AND in MUT-NOEXEC; FAIL in the pre-fix control
    #   boot   — PASS in treat ONLY: the re-entry itself
    chk() {
        _cls=$1 _d=$2 _rc=$3
        if [ "$_cls" = "hold" ]; then
            if [ "$_rc" = "0" ]; then echo "  hold  $_d"; return; fi
            TOTAL_FAIL=$((TOTAL_FAIL + 1)); echo "  FAIL  $_d (a fact that must hold in EVERY arm)"; return
        fi
        case "$MODE" in
            treat)
                if [ "$_rc" = "0" ]; then echo "  PASS  $_d"
                else TOTAL_FAIL=$((TOTAL_FAIL + 1)); echo "  FAIL  $_d"; fi ;;
            noexec)
                if [ "$_cls" = "record" ]; then
                    if [ "$_rc" = "0" ]; then echo "  PASS  [blind] $_d"
                    else TOTAL_FAIL=$((TOTAL_FAIL + 1)); echo "  FAIL  [blind] $_d — MUT-NOEXEC MUST still record and answer"; fi
                else
                    if [ "$_rc" != "0" ]; then echo "  ok    [second boot] failed as required: $_d"
                    else TOTAL_FAIL=$((TOTAL_FAIL + 1)); echo "  FAIL  [second boot] $_d — MUT-NOEXEC PASSED a re-entry assertion: THE GATE IS TESTING THE LOGGER"; fi
                fi ;;
            ctrl)
                if [ "$_rc" != "0" ]; then echo "  ok    [pre-fix] failed as required: $_d"
                else TOTAL_FAIL=$((TOTAL_FAIL + 1)); echo "  FAIL  [pre-fix] $_d — the pinned arm PASSED this: pin or probe broken"; fi ;;
        esac
    }
    eq() { [ "$1" = "$2" ]; }

    # ── hold: the channel is the LIVE one and the machine survives the reply
    chk hold "a verdict for the generation that was current exists (boot-ok v$V_CUR)" \
        "$([ "$N_BOK" -ge 1 ]; echo $?)"
    chk hold "the guest did not shut down: no 'shutdown' line in .bootlog" \
        "$(eq "$N_SHUT" 0; echo $?)"

    # ── record: the reply and the durable row (BLIND to the re-entry)
    chk record "the channel answered the reboot: a SECOND '^OK$' after status" \
        "$(eq "$N_OKREPLY" 2; echo $?)"
    chk record "the reboot reply is the LAST line of the transcript (it landed BEFORE the channel closed)" \
        "$(eq "$LAST_LINE" "OK"; echo $?)"
    chk record ".operator carries EXACTLY ONE reboot row" \
        "$(eq "$N_RR" 1; echo $?)"
    chk record "the reboot row's outcome is the ADMISSION token 'ok'" \
        "$(eq "$OP_OUT" "ok"; echo $?)"
    chk record "the reboot row's from-version is the CURRENT at request (v$V_CUR)" \
        "$(eq "$OP_FROM" "$V_CUR"; echo $?)"
    chk record "the reboot row moves NO generation (to = '-')" \
        "$(eq "$OP_TO" "-"; echo $?)"
    chk record "the reboot row carries the requester's reason token ('$REASON')" \
        "$(eq "$OP_ARG" "$REASON"; echo $?)"
    chk record "the reboot row carries THIS boot's nonce ($NONCE)" \
        "$(eq "$OP_NONCE" "$NONCE"; echo $?)"

    # ── boot: THE SECOND BOOT (the re-entry), never satisfied by a logger
    chk boot "main() ran TWICE: exactly two 'fx-init: boot start store' lines (got $N_START)" \
        "$(eq "$N_START" 2; echo $?)"
    chk boot "a NEW PID1 LIFETIME under the SAME nonce: two 'boot nonce $NONCE' lines (got $N_NONCE)" \
        "$(eq "$N_NONCE" 2; echo $?)"
    chk boot "the second incarnation could not re-pivot (root is tmpfs now): 'pivot not attempted' appears exactly once (got $N_PIVOT)" \
        "$(eq "$N_PIVOT" 1; echo $?)"
    chk boot "that pivot line belongs to the SECOND boot (it comes after the first verdict)" \
        "$([ -n "$L_PIV" ] && [ -n "$L_BOK" ] && [ "$L_PIV" -gt "$L_BOK" ]; echo $?)"
    chk boot "the boot decision RAN AGAIN and booted the SAME current generation: two 'boot-ok v$V_CUR' (got $N_BOK)" \
        "$(eq "$N_BOK" 2; echo $?)"
    chk boot ".bootlog gained a SECOND (v$V_CUR, in-progress) under this nonce (got $N_BL_IP)" \
        "$(eq "$N_BL_IP" 2; echo $?)"
    chk boot ".bootlog gained a SECOND (v$V_CUR, ok) verdict under this nonce (got $N_BL_OK)" \
        "$(eq "$N_BL_OK" 2; echo $?)"
    chk record "the guarded path was taken: ONE 'soft reboot: re-entering the boot path' line (got $N_SOFT)" \
        "$(eq "$N_SOFT" 1; echo $?)"
    chk boot "the execve SUCCEEDED: the re-entry line is there and NO 'soft reboot FAILED' line (re-entering=$N_SOFT failed=$N_NFAIL)" \
        "$([ "$N_NFAIL" = 0 ] && [ "$N_SOFT" = 1 ]; echo $?)"
}

run_arm treat  treat  "$TREAT_BIN"
run_arm noexec noexec "$MUT_BIN"
run_arm ctrl   ctrl   "$CTRL_BIN"

[ "$TOTAL_FAIL" = 0 ] || fail "$TOTAL_FAIL assertion(s) violated across the three arms (see above)"
echo "qemu-reboot: PASS (treatment: one 'reboot $REASON' over the ctrl channel was ADMITTED, recorded in .operator and answered, and the machine RE-ENTERED the boot path — a second 'boot start', a second 'boot nonce' with the SAME nonce, a second boot-ok v$V_CUR and a second bootlog pair, with the pivot line only in the re-entry. MUT-NOEXEC: the same reply and the same row, and NO second boot — the gate is blind on the record and sensitive only to the re-entry. pre-fix c0aa45b: 'ERR unknown command', no row, one boot)"
exit 0
