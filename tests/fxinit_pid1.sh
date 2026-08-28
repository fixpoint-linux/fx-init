#!/bin/sh
# tests/fxinit_pid1.sh — the M4 GENUINE-PID1 boot harness (bwrap + unshare -pfU).
#
# Exercises fx-init running as the REAL init of its PID namespace (getpid()==1),
# with NO FX_INIT_FORCE override — proving the PID1 guard passes for the right
# reason.  It:
#   1. builds the closure + activates m3/config-pid1.dhall -> v1
#   2. boots inside a bwrap fs namespace, then a nested `unshare --user
#      --map-root-user --pid --fork --mount-proc` so fx-init is the namespace's
#      PID 1 (bwrap keeps PID1 for itself as its reaper, so the nested unshare
#      is the ONLY way to get a real inner PID1); asserts boot-ok + clean
#      shutdown
#   3. asserts fx-init is genuinely PID1: pid1probe reports /proc/1/comm ==
#      "fx-init" inside the namespace, and the guard passed WITHOUT
#      FX_INIT_FORCE (which it can only do when getpid()==1)
#   4. orphan adoption + reap: the `daemon` service double-forks a grandchild
#      that outlives its tracked direct child; the orphan must be adopted by
#      fx-init (its observed PPid == 1) and REAPED when it exits (a watchdog
#      grandchild inspects /proc after it exits -> "reaped", not "zombie")
#   5. guard: fx-init without FX_INIT_FORCE and NOT PID1 still refuses
#
# HOST test: bwrap + a nested user/PID namespace cannot be created inside the
# rattan sandbox (no userns), so this SKIPS LOUDLY there.  The orchestrator
# runs it on the host.
#
# Env:
#   FXSTORE     path to a built fxstore binary  (REQUIRED)
#   FX_ACTIVATE path to the fx-activate under test (REQUIRED)
#   FX_INIT_BIN path to the fx-init under test (default: the store-built C
#               fx-init; pass the Zig port or a custom C build to diff)
#   BWRAP       path to bwrap (default: bwrap from PATH)
set -u

FXSTORE="${FXSTORE:-}"
FX_ACTIVATE="${FX_ACTIVATE:-}"
FX_INIT_BIN="${FX_INIT_BIN:-}"
BWRAP="${BWRAP:-bwrap}"

fail() { echo "fxinit-pid1: FAIL: $*" >&2; exit 1; }
skip() { echo "fxinit-pid1: SKIP ($*)"; exit 77; }

command -v "$BWRAP"    >/dev/null 2>&1 || skip "bwrap not found ($BWRAP) — cannot chroot (rattan sandbox has no userns)"
command -v unshare     >/dev/null 2>&1 || skip "unshare not found — cannot create a nested PID namespace"
[ -n "$FXSTORE" ]     || skip "FXSTORE not given"
[ -n "$FX_ACTIVATE" ] || skip "FX_ACTIVATE not given"
[ -x "$FXSTORE" ]     || skip "fxstore not executable: $FXSTORE"
[ -x "$FX_ACTIVATE" ] || skip "fx-activate not executable: $FX_ACTIVATE"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"

WORK="$(mktemp -d -t fxinitpid1.XXXXXX)" || fail "mktemp"
trap 'rm -rf "$WORK"' EXIT
STORE="$WORK/store"
ROOT="$WORK/root"
mkdir -p "$STORE" "$ROOT/run/fx"

echo "=== fxinit-pid1: building closure into $STORE ==="
( cd "$REPO/m3" && "$FXSTORE" build --store "$STORE" ) || fail "fxstore build failed"

# locate the built fx-init + fxctl APEs in the store (content-addressed dirs).
# FX_INIT_BIN (optional) overrides the fx-init under test (e.g. the Zig port):
# copied into the store so the chroot boot can exec it at a chroot-visible
# path, and the host-side guard step execs it directly.
if [ -n "$FX_INIT_BIN" ]; then
    [ -x "$FX_INIT_BIN" ] || skip "FX_INIT_BIN not executable: $FX_INIT_BIN"
    cp "$FX_INIT_BIN" "$STORE/.fx-init-under-test"
    FXINIT_BIN="$STORE/.fx-init-under-test"
    FXINIT_CHROOT="/fx/store/.fx-init-under-test"
else
    FXINIT_BIN=$(ls "$STORE"/*-fx-init/fx-init 2>/dev/null | head -1)
    [ -n "$FXINIT_BIN" ] || fail "fx-init not found in store ($STORE/*-fx-init/fx-init)"
    # path to fx-init AS SEEN inside the chroot (only /=$ROOT and /fx/store=
    # $STORE are bound; the host path does not exist there).  fxctl runs
    # host-side.
    FXINIT_CHROOT="/fx/store/$(basename "$(dirname "$FXINIT_BIN")")/fx-init"
fi
FXCTL_BIN=$(ls "$STORE"/*-fxctl/fxctl 2>/dev/null | head -1)
[ -n "$FXCTL_BIN" ] || fail "fxctl not found in store ($STORE/*-fxctl/fxctl)"

# fxctl helper: connect to the chroot's control socket from the host.
fxctl() { FX_RUN="$ROOT/run/fx" "$FXCTL_BIN" "$@"; }

activate() {
    # $1 = config path (absolute); same as fxinit_boot.sh.
    cfg="$1"
    out=$( "$FX_ACTIVATE" --store "$STORE" \
        --package-set "$REPO/m3/package-set.dhall" \
        --config "$cfg" 2>&1 ) || fail "activate $cfg failed: $out"
    echo "$out"
}

# bwrap_fs runs bwrap with the fs/mount namespace args shared by the userns
# probe and the real boot, exec'ing the given inner command as $@ (after the
# bwrap `--` separator).  PATH is exported; no FX_INIT_FORCE is set.
bwrap_fs() {
    "$BWRAP" \
        --bind "$ROOT" / \
        --bind "$STORE" /fx/store \
        --ro-bind /bin/sh /bin/sh \
        --ro-bind /usr /usr --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
        --dev /dev \
        --proc /proc \
        --ro-bind /sys /sys \
        --clearenv --setenv PATH /bin:/usr/bin \
        -- "$@"
}

boot_run() {
    # start fx-init as the GENUINE PID1 of a nested PID namespace, in the
    # background.  Caller polls fxctl.  NO FX_INIT_FORCE: the PID1 guard must
    # pass because getpid()==1 (bwrap itself holds PID1 in ITS namespace, so we
    # nest a user+PID namespace via unshare to make fx-init PID 1).
    rm -rf "$ROOT/etc" "$ROOT/bin" "$ROOT/run/fx"/* 2>/dev/null
    mkdir -p "$ROOT/etc" "$ROOT/bin" "$ROOT/run/fx" "$ROOT/tmp"
    bwrap_fs unshare --user --map-root-user --pid --fork --mount-proc \
        -- "$FXINIT_CHROOT" --store /fx/store --run-dir /run/fx \
        >"$WORK/boot.out" 2>&1 &
    BPID=$!
    # give fx-init ~1s to bring up the control socket
    sleep 1
}

boot_stop() {
    # clean shutdown via fxctl, then ensure the whole bwrap+unshare stack is
    # gone.  bwrap only exits after its child (unshare) exits, which only exits
    # after fx-init (the nested PID1) exits — so waiting on $BPID (bwrap) covers
    # the extra unshare layer.
    fxctl shutdown 2>/dev/null
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$BPID" 2>/dev/null || break
        sleep 1
    done
    kill "$BPID" 2>/dev/null
    wait "$BPID" 2>/dev/null
}

wait_status() {
    # poll fxctl status until the boot DECISION is made (ok/failed), up to 30s.
    for i in $(seq 1 60); do
        out=$(fxctl status 2>/dev/null) || { sleep 0.5; continue; }
        bs=$(st_bs "$out")
        case "$bs" in
            *ok|*failed) echo "$out"; return 0;;
        esac
        sleep 0.5
    done
    fail "boot_status never reached ok/failed in 30s"
}

bootlog_has() {
    # $1 version $2 status — grep the durable marker.
    grep -q "^$1 $2 " "$STORE/.bootlog" 2>/dev/null
}

# fxctl status section extractors (mirror fxinit_boot.sh).
st_bs()  { echo "$1" | grep -A1 '^boot_status:'         | tail -n1 | sed 's/^ *//'; }
st_gen() { echo "$1" | grep -A1 '^generation_current:'  | tail -n1 | sed 's/^ *//'; }
st_sr()  { echo "$1" | sed -n '/^service_runtime:/,$p'  | tail -n +2; }

# ─── Step 0: probe that a nested user+PID namespace can be created ───────────
# Some hosts allow bwrap (userns) but block nested userns/PID namespaces; that
# must SKIP (not FAIL) since the genuine-PID1 test is impossible there.
echo "=== fxinit-pid1 [0]: probe nested user+pid namespace ==="
bwrap_fs unshare --user --map-root-user --pid --fork --mount-proc -- /bin/sh -c true 2>/dev/null \
    || skip "nested unshare --user --pid --mount-proc unavailable (userns blocked) — cannot run genuine-PID1 test"
echo "nested user+pid namespace OK"

# ─── Step 1: genuine-PID1 good boot ───────────────────────────────────────────
echo "=== fxinit-pid1 [1]: genuine-PID1 good boot (config-pid1, no FX_INIT_FORCE) ==="
activate "$REPO/m3/config-pid1.dhall" >/dev/null
boot_run
st=$(wait_status)
st_bs "$st" | grep -q 'ok' || { echo "$st"; boot_stop; fail "genuine-PID1 boot did not reach ok"; }
st_sr "$st" | grep '^heartbeat' | grep -q 'started' || { echo "$st"; boot_stop; fail "heartbeat not started"; }

# ─── Step 2: prove fx-init is genuinely PID1 ──────────────────────────────────
# pid1probe (running inside the namespace) reports /proc/1/comm; it must be
# fx-init.  The process image holding PID1 in a genuine-PID1 boot is fx-init's
# own — its cosmocc APE comm is an ape-loader temp name (e.g. ".ape-1.10"), NOT
# the exact string "fx-init", so we assert the OPPOSITE: PID1's comm must not be
# any namespace-scaffolding process (bwrap / unshare / sh), which is what would
# hold PID1 if fx-init were NOT the real init.  Combined with the fact that
# boot_ok above happened WITHOUT FX_INIT_FORCE (boot_run never sets it) AND step
# [5] proves non-PID1+no-force refuses, this proves the guard passed because
# getpid()==1 — the genuine-PID1 path.
echo "=== fxinit-pid1 [2]: assert fx-init is PID1 ==="
PROC1COMM=$(fxctl grep proc1comm | sed -n 's/.*proc1comm=\(.*\)/\1/p' | head -1)
[ -n "$PROC1COMM" ] || { fxctl grep proc1comm; boot_stop; fail "pid1probe did not report /proc/1/comm"; }
case "$PROC1COMM" in
    bwrap|unshare|sh)
        boot_stop; fail "PID1 is '$PROC1COMM' (scaffolding), not fx-init — fx-init is NOT the real init";;
    *) echo "PID1 identity OK (proc1comm=$PROC1COMM is fx-init's process; guard passed without FX_INIT_FORCE)";;
esac
V1=$(st_gen "$st" | grep -o '[0-9][0-9]*' | head -1)

# ─── Step 3: orphan adoption + reap ───────────────────────────────────────────
echo "=== fxinit-pid1 [3]: orphan adoption + reap ==="
# The daemon service double-forked a grandchild which recorded "<pid> <ppid>"
# to /run/fx/daemon.pid at t~0.  The ppid is the process that adopted the
# orphan: it must be 1 (fx-init/PID1).
for i in $(seq 1 40); do [ -f "$ROOT/run/fx/daemon.pid" ] && break; sleep 0.25; done
[ -f "$ROOT/run/fx/daemon.pid" ] \
    || { cat "$WORK/boot.out" 2>/dev/null; boot_stop; fail "daemon.pid never appeared (daemon grandchild did not start)"; }
DPID=$(awk '{print $1}' "$ROOT/run/fx/daemon.pid")
DPPPID=$(awk '{print $2}' "$ROOT/run/fx/daemon.pid")
echo "daemon grandchild pid=$DPID adopted-ppid=$DPPPID"
[ "$DPPPID" = "1" ] || { boot_stop; fail "orphan grandchild reparented to ppid=$DPPPID (expected 1 = fx-init/PID1)"; }

# Watchdog verdict: after the grandchild exits, fx-init (PID1) must reap it.
# The watchdog (same namespace) inspects /proc/<pid> post-exit: gone -> reaped
# (no zombie); state 'Z' -> zombie leak (fail).
for i in $(seq 1 60); do
    [ -f "$ROOT/run/fx/daemon.report" ] && break
    sleep 0.5
done
[ -f "$ROOT/run/fx/daemon.report" ] \
    || { cat "$WORK/boot.out" 2>/dev/null; boot_stop; fail "daemon.report never appeared (watchdog did not finish)"; }
DVERDICT=$(cat "$ROOT/run/fx/daemon.report")
echo "orphan reap verdict: $DVERDICT"
[ "$DVERDICT" = "reaped" ] || { boot_stop; fail "orphan grandchild was NOT reaped by fx-init (verdict=$DVERDICT)"; }

# ─── Step 4: clean shutdown ───────────────────────────────────────────────────
echo "=== fxinit-pid1 [4]: clean shutdown ==="
boot_stop
bootlog_has "$V1" ok || fail ".bootlog missing (v$V1, ok)"
echo "shutdown OK"

# ─── Step 5: non-PID1 guard ───────────────────────────────────────────────────
echo "=== fxinit-pid1 [5]: non-PID1 guard (fx-init refuses without FX_INIT_FORCE / PID1) ==="
unset FX_INIT_FORCE
if "$FXINIT_BIN" --store "$STORE" --run-dir "$WORK/noguard" >/dev/null 2>&1; then
    fail "fx-init ran without FX_INIT_FORCE and not PID1 (should refuse)"
fi
echo "guard OK (fx-init refuses without FX_INIT_FORCE)"

echo "fxinit-pid1: PASS"
