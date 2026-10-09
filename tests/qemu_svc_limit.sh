#!/bin/sh
# tests/qemu_svc_limit.sh — THE SERVICE-TABLE BOUND proof: a configuration
# with more services than main_loop's poll window ([2+1+1+SVC_MAX] fds)
# used to load silently (svc_name_cb grew 16->32->64->128 with NO cap) so
# service pipes beyond the window were never polled — their stdout never
# drained, so the service could block forever on a full pipe.  The defect
# class: a bound that is right in the small and silently inert beyond a
# limit.  It is now LOUD: svc_name_cb refuses a configuration with more
# than SVC_MAX=64 distinct services, naming the first offender, its
# ORDINAL, the window, and the skipped-row count; the boot then fails
# with its own boot-FAILED verdict (no services from a refused config
# run), and the in-guest ctrl activate/rollback arms answer ERR for an
# over-wide config.
#
# WHAT THIS LANE DOES (ONE boot per arm, ONE generated config):
#   gen 70 healthy services (svc01..svc70, fakesvc ok) -> activate -> v$V;
#   treatment arm (working tree): the console MUST carry the exact refusal
#     ("service 'svcNN' is #65 of the declared set; the supervision poll
#     window holds 64 (6 svc rows past it skipped) — configuration
#     refused"), MUST NOT claim "no generation to boot" (the generation
#     exists; the CONFIG is refused — read_store_facts returns -2 and main
#     says the truthful thing), MUST end boot-FAILED v$V with NO boot-ok,
#     and the recovery journal on disk MUST exist with ZERO data lines
#     (a refused boot is not a recovery; crosses qemu_recovery_count.sh).
#   control arm (PINNED revision, git archive + zig build — never HEAD):
#     the SAME config MUST boot-ok v$V with NO refusal line — proving the
#     config is valid and bootable, and that the ONLY behavioral
#     difference at 70 services is the new refusal.  This is also the
#     honest demonstration of the defect's SILENCE: the pre-fix starvation
#     (pipes 65+ unpolled) is NOT observable in a short boot — the pipes
#     take minutes to fill — which is exactly why the bound must refuse
#     loudly instead of degrading quietly.
#
# The asymmetry: the treatment's refusal assertions are the control's
# failures (and vice versa for boot-ok) — fail-before/pass-after in ONE
# run, against a FIXED revision with a cat-file guard and a cmp proving
# the pinned source differs from the working tree.
#
# Env: FX_SIBLINGS/QEMU_BOOT_TIMEOUT/QEMU_KEEP — same contract as
# tests/qemu_guardrail.sh.
set -u

fail() { echo "qemu-svclimit: FAIL: $*" >&2; exit 1; }
skip() { echo "qemu-svclimit: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v cpio >/dev/null 2>&1    || skip "cpio not found"
command -v gzip >/dev/null 2>&1    || skip "gzip not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v timeout >/dev/null 2>&1 || skip "timeout(1) not found"
command -v qemu-img >/dev/null 2>&1 || skip "qemu-img not found (disk store)"
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

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"

# ─── the PINNED control (a FIXED revision, never HEAD) ────────────────────
# 9b20161 = the tree immediately before the service bound; its svc_name_cb
# grows unbounded, so a 70-service config loads and boots (silently wide).
PIN_REV=9b201610782ecca40184e015028a6f254885b4b7
git cat-file -e "$PIN_REV^{commit}" 2>/dev/null \
    || skip "pinned control revision $PIN_REV not in this repository (shallow clone?) — refusing to test against an unpinned HEAD"

NSVC=70
BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-90}"

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
WORK="$(mktemp -d "$SCRATCH/qemusvc.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "qemu-svclimit: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi

# ─── generate the over-wide config (70 healthy services) ──────────────────
# fakesvc "ok": prints a heartbeat every 500ms forever — every service
# starts, stays started, and reaches the boot-ok verdict.  The names are
# distinct so svc_name_cb's dedupe cannot mask the count; the FIRST
# offender's ordinal (#65), the window (64) and the skipped rows (70-64=6,
# offender included) are deterministic whatever the enumeration order.
CFG_WIDE="$WORK/config-svc70.dhall"
{
    printf 'let Probe = < Tcp : Natural | Unix : Text | File : Text >\n'
    printf 'let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,\n                restart : Optional Text, backoffMs : Optional Natural,\n                probe : Optional Probe,\n                env : Optional (List { key : Text, value : Text }) }\n'
    printf 'let User = { name : Text, uid : Natural, groups : List Text }\n'
    printf 'in  { hostname = "fixbox"\n'
    printf '    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]\n'
    printf '    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]\n'
    printf '    , services = ['
    _i=1
    while [ "$_i" -le "$NSVC" ]; do
        _nm=$(printf 'svc%02d' "$_i")
        [ "$_i" -gt 1 ] && printf ','
        printf '\n        { name = "%s", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",\n            on = "all", restart = Some "always", backoffMs = Some 200,\n            probe = None Probe,\n            env = None (List { key : Text, value : Text }) }' "$_nm"
        _i=$((_i + 1))
    done
    printf ' ]\n'
    printf '    , extraEtc = None (List { path : Text, content : Text })\n'
    printf '    , bootGraceMs = Some 8000\n'
    printf '    }\n'
} > "$CFG_WIDE"
echo "qemu-svclimit: generated $CFG_WIDE ($NSVC services)"

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
echo "=== qemu-svclimit: freezing package sources ==="
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
echo "=== qemu-svclimit: building the TREATMENT (working tree) ==="
( cd "$REPO/zig" && zig build install ) > "$WORK/build-treat.log" 2>&1 \
    || { cat "$WORK/build-treat.log"; fail "treatment zig build failed"; }
TREAT_BIN="$REPO/zig/zig-out/bin"
for b in fx-init fx-activate fxctl activate_paths; do
    [ -x "$TREAT_BIN/$b" ] || fail "treatment build produced no $b"
done

echo "=== qemu-svclimit: building the CONTROL (pinned $PIN_REV via git archive) ==="
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

read_journal() { # read_journal DISK OUTFILE — replay the journal on a COPY, then cat
    # (see the comment at the boot loop: a killed VM can leave jbd2
    # transactions committed but uncheckpointed; e2fsck -fy replays exactly
    # what the next mount would see)
    _cp="$1.read"
    cp "$1" "$_cp" 2>/dev/null
    "$E2FSCK" -fy "$_cp" >/dev/null 2>&1
    "$DEBUGFS" -R "cat /store/.recovery" "$_cp" > "$2" 2>/dev/null
    rm -f "$_cp"
}
j_lines() {
    _n=$(grep -c '^[0-9]' "$1" 2>/dev/null)
    echo "${_n:-0}"
}

# ─── ONE arm: provision, ONE boot, assertions ─────────────────────────────
# run_arm TAG BINDIR MODE(treat|ctrl)
run_arm() {
    TAG=$1 BINDIR=$2 MODE=$3
    STORE="$WORK/$TAG/store"
    ROOT="$WORK/$TAG/root"
    DISK="$WORK/$TAG/disk.img"
    mkdir -p "$STORE" "$ROOT/run/fx" "$ROOT/etc" "$ROOT/bin" "$ROOT/tmp"

    echo "--- arm $TAG ($MODE): provisioning ---"
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
            *)                : > "$STORE/$pd/.provisioned-by-qemu-svclimit" ;;
        esac
    done
    FXD=$(ls -d "$STORE"/*-fx-init | head -1)
    [ -x "$FXD/fx-init" ] || fail "$TAG: fx-init was not staged into the store closure"
    RDINIT="/fx/store/$(basename "$FXD")/fx-init"

    OUT=$(LD_LIBRARY_PATH="$DLDIR" "$BINDIR/fx-activate" --store "$STORE" \
        --package-set "$PKGSET" --config "$CFG_WIDE" 2>&1) \
        || fail "$TAG: activate $NSVC-service config failed: $OUT"
    V=$(echo "$OUT" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$V" ] || fail "$TAG: cannot parse version from: $OUT"
    echo "$TAG: $NSVC-service config activated as v$V"

    sh "$REPO/tests/mkinitramfs.sh" -s "$STORE" -r "$ROOT" -k "$KERNEL" -o "$WORK/$TAG/img.cpio.gz" -p "$PKGSET" \
        || fail "$TAG: mkinitramfs failed"
    qemu-img create -q "$DISK" 512M || fail "$TAG: qemu-img create failed"
    "$MKE2FS" -q -t ext4 -J size=4 "$DISK" >/dev/null 2>&1 \
        || fail "$TAG: mke2fs -t ext4 (journaled) failed"

    CON="$WORK/$TAG/console.log"
    : > "$CON"
    echo "--- arm $TAG: ONE boot ---"
    qemu-system-x86_64 \
        -machine q35 -accel kvm -cpu host -m 2048 -smp 1 \
        -kernel "$KERNEL" -initrd "$WORK/$TAG/img.cpio.gz" \
        -append "console=ttyS0,115200 rdinit=$RDINIT fx.store=/fx/store panic=-1 oops=panic" \
        -nographic -no-reboot -monitor none -serial file:"$CON" \
        -drive file="$DISK",format=raw,if=virtio \
        >"$WORK/$TAG/qemu.out" 2>&1 &
    QPID=$!
    _i=0
    while [ "$_i" -lt $((BOOT_TIMEOUT * 2)) ]; do
        if grep -q 'fx-init: boot-ok v\|fx-init: boot-FAILED v\|fx-init: no generation to boot' "$CON"; then
            break
        fi
        kill -0 "$QPID" 2>/dev/null || break
        sleep 0.5
        _i=$((_i + 1))
    done
    # A refused boot is SHORT-LIVED and ext4 jbd2 may leave the last
    # transactions COMMITTED-but-not-CHECKPOINTED (the data lives only in
    # the on-disk journal area): debugfs reads raw blocks without replaying,
    # so a freshly created file can read as absent even though the next
    # MOUNT would see it.  read_journal below replays the journal on a
    # COPY (e2fsck -fy) before reading — the semantics a real reader
    # (the next boot, a mounted image) gets.  MEASURED: without replay the
    # cross-item journal assert below fails on a fresh file; with it the
    # read is deterministic regardless of guest lifetime.
    # quiesce before the kill (in-flight writes land before death)
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

    echo "--- arm $TAG console (tail) ---"; tail -12 "$CON"; echo "---"

    if [ "$MODE" = treat ]; then
        grep -q "fx-init: refusing service table: service 'svc" "$CON" \
            || fail "$TAG: no refusal line naming the service"
        grep -qF " is #65 of the declared set; the supervision poll window holds 64 (6 svc rows past it skipped) — configuration refused" "$CON" \
            || fail "$TAG: the refusal does not state ordinal #65, window 64 and 6 skipped rows exactly"
        grep -q "fx-init: boot-FAILED v$V" "$CON" \
            || fail "$TAG: no boot-FAILED v$V (a refused config must fail its boot)"
        grep -q "fx-init: boot-ok v" "$CON" \
            && fail "$TAG: a boot-ok verdict for a REFUSED configuration?!"
        grep -q 'fx-init: no generation to boot' "$CON" \
            && fail "$TAG: 'no generation to boot' printed for a refused CONFIG (the generation exists — the -2 distinction is broken)"
        # cross-item: a refused boot is NOT a recovery — the journal exists
        # (decide_boot_version ran before the refusal) with ZERO data lines
        read_journal "$DISK" "$WORK/$TAG/j.txt"
        grep -q 'fx-init recovery journal' "$WORK/$TAG/j.txt" 2>/dev/null \
            || fail "$TAG: the recovery journal header is missing after a refused boot"
        _n=$(j_lines "$WORK/$TAG/j.txt")
        [ "$_n" = 0 ] || fail "$TAG: a refused boot appended $_n journal line(s) — a refusal is not a recovery"
    else
        grep -q "fx-init: boot-ok v$V" "$CON" \
            || fail "$TAG (control): the SAME config must boot-ok at the pinned revision — the config is valid; the refusal is the only difference"
        grep -q "fx-init: refusing service table" "$CON" \
            && fail "$TAG (control): a refusal line at pinned $PIN_REV — the control is not pre-fix (pin or probe broken)"
        echo "control: no refusal line, boot-ok v$V — the pre-fix silence (the unbounded table loads; pipes 65+ are simply never polled)"
    fi
}

run_arm treat "$TREAT_BIN" treat
run_arm ctrl  "$CTRL_BIN"  ctrl

echo "qemu-svclimit: PASS (treatment refused the 70-service config by name with ordinal/window/rows, boot-FAILED, no 'no generation' lie, journal untouched; control at $PIN_REV booted the SAME config ok with no refusal — fail-before/pass-after against a pinned revision)"
exit 0
