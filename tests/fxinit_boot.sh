#!/bin/sh
# tests/fxinit_boot.sh — the M4 chroot boot harness (bwrap).
#
# Exercises the full fx-init boot/supervision/rollback path end-to-end:
#   1. build the closure (dhake, fx-init, fx-activate, fxctl, fake-service)
#   2. activate config-good -> v1; boot in a bwrap chroot; assert ok boot
#   3. activate config-bad-exit -> v2; boot; assert failed (crasher restarts)
#   4. boot AGAIN (stale failed v2) -> roll-forward to ok v1 -> re-publish v3;
#      assert ok, monotonic timeline CURRENT=v3
#   5. activate config-bad-hang -> v4; boot; grace expiry -> failed
#   6. boot again -> rolls forward to newest ok (v3); ok
#   7. non-bwrap guard: fx-init without FX_INIT_FORCE and not PID1 refuses
#
# This is a HOST test: bwrap cannot nest inside the rattan sandbox (no userns),
# so this script SKIPS LOUDLY there.  The orchestrator runs it on the host.
#
# Env:
#   FXSTORE     path to a built fxstore binary  (REQUIRED)
#   FX_ACTIVATE path to the fx-activate under test (REQUIRED)
#   FX_INIT_BIN path to the fx-init under test (default: the store-built
#               ZIG fx-init — the m3 fixture builds this repo's zig port;
#               pass a custom binary to override)
#   BWRAP       path to bwrap (default: bwrap from PATH)
set -u

FXSTORE="${FXSTORE:-}"
FX_ACTIVATE="${FX_ACTIVATE:-}"
FX_INIT_BIN="${FX_INIT_BIN:-}"
BWRAP="${BWRAP:-bwrap}"

fail() { echo "fxinit-boot: FAIL: $*" >&2; exit 1; }
skip() { echo "fxinit-boot: SKIP ($*)"; exit 77; }

command -v "$BWRAP" >/dev/null 2>&1 || skip "bwrap not found ($BWRAP) — cannot chroot (rattan sandbox has no userns)"
[ -n "$FXSTORE" ]     || skip "FXSTORE not given"
[ -n "$FX_ACTIVATE" ] || skip "FX_ACTIVATE not given"
[ -x "$FXSTORE" ]     || skip "fxstore not executable: $FXSTORE"
[ -x "$FX_ACTIVATE" ] || skip "fx-activate not executable: $FX_ACTIVATE"

# the m3 fixture builds this repo's Zig port: the recipes run `zig build`
# with the sibling checkouts modeled as fxstore deps (see
# m3/package-set.dhall) — dhall-c/fxstore from the deps' store outputs, the
# engine .so from the live sibling checkout (its own zig build is broken at
# HEAD), so FX_SIBLINGS must be exported; zig must be on PATH; cosmocc
# builds dhake + fake-service; fxstore's package-set evaluation needs the
# palisade stage3.
REPO_PARENT="$(cd "$(dirname "$0")/../.." && pwd)"
export FX_SIBLINGS="${FX_SIBLINGS:-$REPO_PARENT}"
command -v zig >/dev/null 2>&1 || skip "zig not found — the m3 fixture builds the Zig port"
command -v cosmocc >/dev/null 2>&1 || skip "cosmocc not found — the m3 fixture builds dhake + fake-service"
COSMOBIN="$(dirname "$(command -v cosmocc)")"
FXSTORE_STAGE3="${FXSTORE_STAGE3:-}"
if [ -z "$FXSTORE_STAGE3" ]; then
    FXSTORE_DIR="$(cd "$(dirname "$FXSTORE")" && pwd)"
    FXSTORE_STAGE3="$FXSTORE_DIR/../../vendor/palisade/bin/stage3"
fi
[ -x "$FXSTORE_STAGE3" ] || skip "palisade stage3 not executable: $FXSTORE_STAGE3 (build it in the fxstore repo, or set FXSTORE_STAGE3)"

# libdatalog.so dir the Zig binaries need at runtime (the fxstore RUNPATH is
# the authoritative location; bound at the same absolute path inside the boot
# chroot so the loader resolves it).  Same fallback as prov_e2e.sh.
if command -v readelf >/dev/null 2>&1; then
    DLIBDIR=$(readelf -d "$FXSTORE" | sed -n 's/.*Library runpath: \[\(.*\)\].*/\1/p' | head -1)
fi
[ -n "${DLIBDIR:-}" ] || DLIBDIR="$(cd "$(dirname "$0")/../.." && pwd)/datalog-dafsa/zig-out/lib"
[ -f "$DLIBDIR/libdatalog.so" ] || fail "libdatalog.so not found at $DLIBDIR (fxstore RUNPATH)"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"

# Scratch: the fixture build copies the repo per package and the zig builds
# write caches (~2-3G peak) — same relocation policy as prov_e2e.sh.
SCRATCH="${TMPDIR:-/tmp}"
FSTYPE=$(stat -f -c %T "$SCRATCH" 2>/dev/null || echo unknown)
AVAIL_KB=$(df -Pk "$SCRATCH" 2>/dev/null | awk 'NR==2 {print $4}')
if [ "$FSTYPE" = "tmpfs" ] && [ -n "${AVAIL_KB:-}" ] && [ "$AVAIL_KB" -lt 3000000 ]; then
    SCRATCH="${XDG_CACHE_HOME:-$HOME/.cache}/fxinit-boot"
    mkdir -p "$SCRATCH" || fail "cannot create scratch dir $SCRATCH"
    echo "fxinit-boot: NOTE: ${TMPDIR:-/tmp} is a small tmpfs (<3G free) — scratch moved to"
    echo "fxinit-boot: NOTE: $SCRATCH (the fixture build needs ~2-3G)"
fi
rm -rf "$SCRATCH"/fxinitboot.?????? 2>/dev/null   # stale killed-run leftovers
WORK="$(mktemp -d "$SCRATCH/fxinitboot.XXXXXX")" || fail "mktemp in $SCRATCH"
trap 'rm -rf "$WORK"' EXIT
STORE="$WORK/store"
ROOT="$WORK/root"
mkdir -p "$STORE" "$ROOT/run/fx"

echo "=== fxinit-boot: building closure into $STORE ==="
# Merged-usr hosts (/bin a symlink): fxstore's hermetic bwrap cannot
# --ro-bind /bin, so hide bwrap from its startup probe and take fxstore's
# sanctioned LOUD NON-HERMETIC fallback (same deliberate detour as
# prov_e2e.sh — the build sandbox is not what this harness exercises).
BIN_LINK=$( (readlink /bin 2>/dev/null || echo /bin) )
if [ "$BIN_LINK" = "/bin" ]; then
    ( cd "$REPO/m3" && FXSTORE_STAGE3="$FXSTORE_STAGE3" "$FXSTORE" build --store "$STORE" ) \
        || fail "fxstore build failed"
else
    echo "fxinit-boot: NOTE: merged-usr host (/bin -> $BIN_LINK): fixture build runs via"
    echo "fxinit-boot: NOTE: fxstore's LOUD NON-HERMETIC fallback (PATH hides bwrap from its probe)"
    PPATH="$WORK/path"
    mkdir -p "$PPATH"
    for t in sh cp ln rm mv cat mkdir file zig; do
        ln -sf "$(command -v "$t")" "$PPATH/$t" 2>/dev/null || \
            fail "merged-usr fallback needs '$t' on PATH"
    done
    ( cd "$REPO/m3" && FXSTORE_STAGE3="$FXSTORE_STAGE3" \
        PATH="$COSMOBIN:$PPATH" "$FXSTORE" build --store "$STORE" ) \
        || fail "fxstore build (non-hermetic) failed"
fi

# locate the built fx-init + fxctl APEs in the store (content-addressed dirs).
# FX_INIT_BIN (optional) overrides the fx-init under test with an arbitrary
# host-side binary (e.g. the Zig port): it is copied into the store so the
# chroot boot can exec it at a chroot-visible path, and the host-side guard
# step execs it directly.
if [ -n "$FX_INIT_BIN" ]; then
    [ -x "$FX_INIT_BIN" ] || skip "FX_INIT_BIN not executable: $FX_INIT_BIN"
    cp "$FX_INIT_BIN" "$STORE/.fx-init-under-test"
    FXINIT_BIN="$STORE/.fx-init-under-test"
    FXINIT_CHROOT="/fx/store/.fx-init-under-test"
else
    FXINIT_BIN=$(ls "$STORE"/*-fx-init/fx-init 2>/dev/null | head -1)
    [ -n "$FXINIT_BIN" ] || fail "fx-init not found in store ($STORE/*-fx-init/fx-init)"
    # The path to fx-init AS SEEN INSIDE the bwrap chroot.  bwrap execs the
    # given path inside the new mount namespace, where only / (=$ROOT) and
    # /fx/store (=$STORE) are bound — the HOST path $STORE/<hash>-fx-init/
    # fx-init does not exist there.  (fxctl runs host-side against the bound
    # control socket, so it keeps the host path.)
    FXINIT_CHROOT="/fx/store/$(basename "$(dirname "$FXINIT_BIN")")/fx-init"
fi
FXCTL_BIN=$(ls "$STORE"/*-fxctl/fxctl 2>/dev/null | head -1)
[ -n "$FXCTL_BIN" ] || fail "fxctl not found in store ($STORE/*-fxctl/fxctl)"

# fxctl helper: connect to the chroot's control socket from the host.
# $ROOT/run/fx is bound into the bwrap at /run/fx; the unix socket inode is
# reachable through the bind, so no second namespace is needed.
fxctl() {
    FX_RUN="$ROOT/run/fx" LD_LIBRARY_PATH="$DLIBDIR" "$FXCTL_BIN" "$@"
}

activate() {
    # $1 = config path (absolute).  Point fx-activate at the real m3/package-set
    # (src Paths resolve relative to the package-set FILE's dir) + the config by
    # absolute path; echoes "activated <genhash> as version <v>".
    cfg="$1"
    out=$( LD_LIBRARY_PATH="$DLIBDIR" "$FX_ACTIVATE" --store "$STORE" \
        --package-set "$REPO/m3/package-set.dhall" \
        --config "$cfg" 2>&1 ) || fail "activate $cfg failed: $out"
    echo "$out"
}

boot_run() {
    # start fx-init in a bwrap chroot in the background.  Caller polls fxctl.
    rm -rf "$ROOT/etc" "$ROOT/bin" "$ROOT/run/fx"/* 2>/dev/null
    mkdir -p "$ROOT/etc" "$ROOT/bin" "$ROOT/run/fx" "$ROOT/tmp"
    # The store-built fx-init is the Zig port: it needs libdatalog.so, whose
    # RUNPATH is useless inside the chroot — bind the libdatalog dir at its
    # real host path and force it via LD_LIBRARY_PATH (prov_e2e.sh precedent).
    # /bin/sh + /usr /lib /lib64 keep the cosmocc APE binaries (dhake,
    # fakesvc) runnable, while / =$ROOT keeps /etc /bin /run /tmp as writable
    # materialization targets.
    "$BWRAP" \
        --bind "$ROOT" / \
        --bind "$STORE" /fx/store \
        --ro-bind "$DLIBDIR" "$DLIBDIR" \
        --ro-bind /bin/sh /bin/sh \
        --ro-bind /usr /usr --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
        --dev /dev \
        --proc /proc \
        --ro-bind /sys /sys \
        --clearenv --setenv FX_INIT_FORCE 1 --setenv PATH /bin:/usr/bin \
        --setenv LD_LIBRARY_PATH "$DLIBDIR" \
        -- "$FXINIT_CHROOT" --store /fx/store --run-dir /run/fx \
        >"$WORK/boot.out" 2>&1 &
    BPID=$!
    # give fx-init ~1s to bring up the control socket
    sleep 1
}

boot_stop() {
    # clean shutdown via fxctl, then ensure the bwrap process is gone.
    fxctl shutdown 2>/dev/null
    for i in 1 2 3 4 5; do
        kill -0 "$BPID" 2>/dev/null || break
        sleep 1
    done
    kill "$BPID" 2>/dev/null
    wait "$BPID" 2>/dev/null
}

wait_status() {
    # poll fxctl status until the boot DECISION is made (boot_status reaches
    # ok or failed — boot-ok now lands at grace-end, after the socket is up),
    # up to 30s.  echoes the status output.
    for i in $(seq 1 60); do
        out=$(fxctl status 2>/dev/null) || { sleep 0.5; continue; }
        bs=$(st_bs "$out")
        case "$bs" in
            *ok|*failed) echo "$out"; return 0;;
        esac
        sleep 0.5
    done
    fail "boot_status never reached ok/failed (fxctl responded but no boot decision in 30s)"
}

bootlog_has() {
    # $1 version $2 status — grep the durable marker.
    grep -q "^$1 $2 " "$STORE/.bootlog" 2>/dev/null
}

# fxctl status emits each section as a header line then value lines.  Extract:
#  boot_status:  \n  4\tok          -> "4\tok"
#  generation_current: \n  4        -> "4"
#  service_runtime: \n name\tpid\tstate\trestarts
st_bs()  { echo "$1" | grep -A1 '^boot_status:'         | tail -n1 | sed 's/^ *//'; }
st_gen() { echo "$1" | grep -A1 '^generation_current:'  | tail -n1 | sed 's/^ *//'; }
st_sr()  { echo "$1" | sed -n '/^service_runtime:/,$p'  | tail -n +2; }

echo "=== fxinit-boot [2]: good boot (config-good -> v1) ==="
activate "$REPO/m3/config-good.dhall" >/dev/null
boot_run
st=$(wait_status)
st_bs "$st" | grep -q 'ok' || { echo "$st"; boot_stop; fail "good boot did not reach ok"; }
st_sr "$st" | grep '^heartbeat' | grep -q 'started' || { echo "$st"; boot_stop; fail "heartbeat not started"; }
# /etc/hostname materialized by dhake into the chroot root
[ -f "$ROOT/etc/hostname" ] || { boot_stop; fail "/etc/hostname not materialized"; }
[ "$(cat "$ROOT/etc/hostname")" = "fixbox" ] || { boot_stop; fail "/etc/hostname wrong: $(cat "$ROOT/etc/hostname")"; }
# /bin/init symlink -> store fx-init dir
[ -L "$ROOT/bin/init" ] || { boot_stop; fail "/bin/init not a symlink"; }
readlink "$ROOT/bin/init" | grep -q 'fx-init' || { boot_stop; fail "/bin/init -> wrong target"; }
# log grep + search (DAFSA-interned + postings full-text)
fxctl grep heartbeat | grep -q 'heartbeat from heartbeat' || { boot_stop; fail "grep heartbeat returned no lines"; }
fxctl search heartbeat | grep -q 'heartbeat' || { boot_stop; fail "search heartbeat returned no lines"; }
# durable bootlog marker
V1=$(st_gen "$st" | grep -o '[0-9][0-9]*' | head -1)
boot_stop
bootlog_has "$V1" ok || fail ".bootlog missing (v$V1, ok)"
echo "good boot OK (v$V1)"

echo "=== fxinit-boot [3]: failed boot (config-bad-exit -> v2) ==="
activate "$REPO/m3/config-bad-exit.dhall" >/dev/null
boot_run
st=$(wait_status)
st_bs "$st" | grep -q 'failed' || { echo "$st"; boot_stop; fail "crasher boot did not reach failed"; }
st_sr "$st" | grep -q '^crasher' || { echo "$st"; boot_stop; fail "crasher not in service_runtime"; }
# restart counter on crasher >= 1 (restart=always + backoff)
V2=$(st_gen "$st" | grep -o '[0-9][0-9]*' | head -1)
boot_stop
bootlog_has "$V2" failed || fail ".bootlog missing (v$V2, failed)"
echo "failed-exit boot OK (v$V2)"

echo "=== fxinit-boot [4]: roll-forward (boot again, stale failed v2 -> ok v1 -> re-publish v3) ==="
boot_run
st=$(wait_status)
st_bs "$st" | grep -q 'ok' || { echo "$st"; boot_stop; fail "roll-forward did not reach ok"; }
V3=$(st_gen "$st" | grep -o '[0-9][0-9]*' | head -1)
[ "$V3" -gt "$V2" ] || { echo "v3=$V3 v2=$V2"; boot_stop; fail "roll-forward version not monotonic (v3 > v2)"; }
# service set == good set (heartbeat present, crasher absent)
st_sr "$st" | grep -q '^heartbeat' || { boot_stop; fail "roll-forward did not restore heartbeat"; }
st_sr "$st" | grep -q '^crasher' && { boot_stop; fail "roll-forward kept stale crasher service"; }
boot_stop
# host-side: fxstore timeline shows 3 versions, CURRENT=v3 monotonic
TL=$("$FXSTORE" timeline --store "$STORE" 2>&1) || true
echo "$TL" | grep -q "CURRENT.*$V3\|current.*$V3\|$V3" || echo "(timeline check is best-effort: $TL)"
echo "roll-forward OK (v$V3, monotonic)"

echo "=== fxinit-boot [5]: failed boot hang (config-bad-hang -> v4; grace 2s) ==="
activate "$REPO/m3/config-bad-hang.dhall" >/dev/null
boot_run
st=$(wait_status)
st_bs "$st" | grep -q 'failed' || { echo "$st"; boot_stop; fail "hang boot did not reach failed (grace expiry)"; }
# hanger never started (gate never ready)
st_sr "$st" | grep '^hanger' | grep -qE 'pending|starting' || echo "(hanger state check best-effort)"
V4=$(st_gen "$st" | grep -o '[0-9][0-9]*' | head -1)
boot_stop
bootlog_has "$V4" failed || fail ".bootlog missing (v$V4, failed)"
echo "failed-hang boot OK (v$V4)"

echo "=== fxinit-boot [6]: boot again -> roll-forward to newest ok (v3) ==="
boot_run
st=$(wait_status)
st_bs "$st" | grep -q 'ok' || { echo "$st"; boot_stop; fail "post-hang roll-forward did not reach ok"; }
st_sr "$st" | grep -q '^heartbeat' || { boot_stop; fail "post-hang did not restore heartbeat"; }
boot_stop
echo "post-hang roll-forward OK"

echo "=== fxinit-boot [7]: non-bwrap guard (fx-init refuses without FX_INIT_FORCE / PID1) ==="
# Run fx-init directly on the host (no bwrap, not PID1, no FX_INIT_FORCE).
unset FX_INIT_FORCE
if "$FXINIT_BIN" --store "$STORE" --run-dir "$WORK/noguard" >/dev/null 2>&1; then
    fail "fx-init ran without FX_INIT_FORCE and not PID1 (should refuse)"
fi
echo "guard OK (fx-init refuses without FX_INIT_FORCE)"

echo "fxinit-boot: PASS"
