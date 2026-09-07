#!/bin/sh
# tests/prov_e2e.sh — the U10 cross-repo provenance E2E (fx-init + fxstore
# + fx-core), on top of the M4 boot harness precedent (tests/fxinit_boot.sh).
#
# Proves the whole Lens-2 provenance stack end-to-end over a REAL bwrap boot:
#   1. build the m3 fixture closure into a temp store (fxstore build)
#   2. BEFORE any boot: fxstore what/why answer from the store db —
#        what /bin/fakesvc    -> origin <hash>-fake-service, package
#                                fake-service, generation <gen_good>
#        what /etc/hostname   -> generation-relative origin, package unknown
#        what /etc/nonexistent-> rc 1 'unmanaged'
#        why fake-service     -> store dir + provides /bin/fakesvc
#      (and on the build-only store, before activation: what -> rc 1)
#   3. boot config-good in a bwrap chroot -> ok; `fxstore verify` runs INSIDE
#      a minimal chroot with the rootfs at / and the store at /fx/store —
#      the relocated-boot view, i.e. exactly what an in-system verify sees —
#      -> verify OK: the materialized /etc files and /bin symlinks match the
#      install facts (kinds, modes, link targets, content hashes)
#   4. tamper three ways (content / missing / retargeted symlink) -> verify
#      exits 1 with exactly 3 drifts: hash / missing / link_target
#   5. fx-activate config-bad-exit -> v_bad: what /etc/hostname now answers
#      the FAILED activation's genhash (current view pre-roll-forward);
#      --as-of v_good still answers gen_good (snapshot timeline intact)
#   6. boot v_bad -> failed; boot again -> roll-forward to the newest ok
#      generation (snapshot-complete fx_store_rollback + re-publish).  All
#      post-roll-forward asserts run strictly AFTER the re-publish (the
#      read-semantics caveat: dl_query/dl_iter read the PINNED snapshot
#      until fx_store_rollback publishes — never assert against the live
#      WAL mid-rollback):
#        what /etc/hostname -> gen_good again, NOT gen_bad
#        what /bin/fakesvc  -> package fake-service, gen_good
#        why fake-service   -> provides /bin/fakesvc
#        what --as-of v_bad /etc/hostname -> gen_bad (history kept)
#      verify in the chroot -> OK again: the roll-forward boot re-materialized
#      v_good's generation and healed the tamper
#   7. optional: the fx-core fx-what/fx-why coreutils cross-checked when
#      their binaries are reachable (loud NOTE otherwise — never a fake pass)
#
# Asserts are exit-code + substring only — NO golden output is pinned.
#
# This is a HOST test like fxinit_boot.sh: bwrap cannot nest inside the
# rattan sandbox (no userns), so it SKIPS LOUDLY (77) there.  The sibling
# repos must be checked out next to this one (../fxstore for the CLI +
# palisade stage3; ../fx-core optional for step 7).
#
# Env:
#   FXSTORE          built fxstore binary
#                    (default ../fxstore/zig-out/bin/fxstore)
#   FX_ACTIVATE      fx-activate under test (default: the store-built one)
#   FX_INIT_BIN      fx-init under test     (default: the store-built one)
#   FX_CORE_BIN      dir with fx-what/fx-why (default ../fx-core/zig-out/bin;
#                    FX_CORE_BIN= disables step 7)
#   BWRAP            bwrap path (default: bwrap from PATH)
#   FXSTORE_STAGE3   palisade stage3 for the fixture build
#                    (default: the fxstore repo's vendor/palisade/bin/stage3)
#   FX_SIBLINGS      dir with the datalog-dafsa/dhall-c/fxstore checkouts the
#                    m3 zig recipes read as siblings (default: repo's parent)
#   (zig must be on PATH — the m3 fixture builds the Zig port)
#
# Standalone invocation (the fx-init dhake target `prov-e2e` runs this):
#   sh tests/prov_e2e.sh
set -u

FXSTORE="${FXSTORE:-}"
FX_ACTIVATE="${FX_ACTIVATE:-}"
FX_INIT_BIN="${FX_INIT_BIN:-}"
FX_CORE_BIN="${FX_CORE_BIN:-}"
BWRAP="${BWRAP:-bwrap}"
FXSTORE_STAGE3="${FXSTORE_STAGE3:-}"

fail() {
    echo "prov-e2e: FAIL: $*" >&2
    if [ -n "${WORK:-}" ] && [ -f "$WORK/boot.out" ]; then
        echo "---- $WORK/boot.out (tail) ----" >&2
        tail -n 40 "$WORK/boot.out" >&2
    fi
    exit 1
}
skip() { echo "prov-e2e: SKIP ($*)"; exit 77; }

command -v "$BWRAP" >/dev/null 2>&1 || skip "bwrap not found ($BWRAP) — cannot chroot (rattan sandbox has no userns)"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
SIB="$(cd "$REPO/.." && pwd)"

# bwrap must actually be able to sandbox here (userns etc.)
if ! "$BWRAP" --unshare-all --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp \
        -- /bin/sh -c 'exit 0' >/dev/null 2>&1; then
    skip "bwrap cannot sandbox on this host (userns blocked?)"
fi

[ -n "$FXSTORE" ] || FXSTORE="$SIB/fxstore/zig-out/bin/fxstore"
[ -x "$FXSTORE" ] || skip "fxstore not executable: $FXSTORE (build the fxstore repo, or set FXSTORE)"
FXSTORE_DIR="$(cd "$(dirname "$FXSTORE")" && pwd)"
[ -n "$FXSTORE_STAGE3" ] || FXSTORE_STAGE3="$FXSTORE_DIR/../../vendor/palisade/bin/stage3"
[ -x "$FXSTORE_STAGE3" ] || skip "palisade stage3 not executable: $FXSTORE_STAGE3 (build it in the fxstore repo, or set FXSTORE_STAGE3)"
command -v cosmocc >/dev/null 2>&1 || skip "cosmocc not found — cannot build the m3 fixture closure"
COSMOBIN="$(dirname "$(command -v cosmocc)")"

[ -n "$FX_CORE_BIN" ] || FX_CORE_BIN="$SIB/fx-core/zig-out/bin"

# The m3 fx-init/fx-activate/fxctl recipes run `zig build` with the sibling
# checkouts modeled as fxstore DEPS (datalog-dafsa, dhall-c, fxstore
# packages in m3/package-set.dhall) — dhall-c/fxstore come from the deps'
# store outputs; the engine .so still comes from the live sibling checkout
# (its own zig build is broken at HEAD), so FX_SIBLINGS is required.
export FX_SIBLINGS="$SIB"
command -v zig >/dev/null 2>&1 || skip "zig not found — the m3 fixture builds the Zig port"

# libdatalog.so dir baked into the fxstore RUNPATH (bound at the same
# absolute path inside the verify chroot so the loader resolves it)
if command -v readelf >/dev/null 2>&1; then
    DLIBDIR=$(readelf -d "$FXSTORE" | sed -n 's/.*Library runpath: \[\(.*\)\].*/\1/p' | head -1)
fi
[ -n "${DLIBDIR:-}" ] || DLIBDIR="$SIB/datalog-dafsa/zig-out/lib"
[ -f "$DLIBDIR/libdatalog.so" ] || fail "libdatalog.so not found at $DLIBDIR (fxstore RUNPATH)"

# Scratch dir: the fixture build copies the repo per package and the zig
# builds write caches (~2-3G peak).  When the default tmp is a small tmpfs
# (Arch /tmp), relocate LOUDLY to a disk-backed cache dir instead of dying
# on Disk quota.  Stale prove2e.* leftovers from killed runs are removed.
SCRATCH="${TMPDIR:-/tmp}"
FSTYPE=$(stat -f -c %T "$SCRATCH" 2>/dev/null || echo unknown)
AVAIL_KB=$(df -Pk "$SCRATCH" 2>/dev/null | awk 'NR==2 {print $4}')
if [ "$FSTYPE" = "tmpfs" ] && [ -n "${AVAIL_KB:-}" ] && [ "$AVAIL_KB" -lt 3000000 ]; then
    SCRATCH="${XDG_CACHE_HOME:-$HOME/.cache}/prov-e2e"
    mkdir -p "$SCRATCH" || fail "cannot create scratch dir $SCRATCH"
    echo "prov-e2e: NOTE: ${TMPDIR:-/tmp} is a small tmpfs (<3G free) — scratch moved to"
    echo "prov-e2e: NOTE: $SCRATCH (the fixture build needs ~2-3G)"
fi
rm -rf "$SCRATCH"/prove2e.?????? 2>/dev/null   # stale killed-run leftovers
WORK="$(mktemp -d "$SCRATCH/prove2e.XXXXXX")" || fail "mktemp in $SCRATCH"
trap 'rm -rf "$WORK"' EXIT
STORE="$WORK/store"
ROOT="$WORK/root"
mkdir -p "$STORE" "$ROOT/run/fx"

echo "=== prov-e2e [1]: build the m3 fixture closure into $STORE ==="
# fxstore's recipe sandbox does `--ro-bind /bin /bin` after `--ro-bind / /`,
# which bwrap refuses when /bin is a symlink (merged-usr hosts like Arch);
# fxstore itself treats that as a host-env condition (its own sandbox e2e
# LOUD-skips there).  Detected here, the fixture build runs with a PATH that
# hides bwrap from fxstore's startup probe, so fxstore takes its OWN
# sanctioned loud NON-HERMETIC fallback (plain exec in the workdir; recipes
# still resolve sh/cp/mv/... via $WORK/path and cosmocc via $COSMOBIN).
# The build sandbox is not what this e2e exercises.
BIN_LINK=$( (readlink /bin 2>/dev/null || echo /bin) )
if [ "$BIN_LINK" = "/bin" ]; then
    ( cd "$REPO/m3" && FXSTORE_STAGE3="$FXSTORE_STAGE3" "$FXSTORE" build --store "$STORE" ) \
        >"$WORK/build.out" 2>&1 \
        || fail "fxstore build failed: $(tail -n 5 "$WORK/build.out")"
else
    echo "prov-e2e: NOTE: merged-usr host (/bin -> $BIN_LINK): fxstore's bwrap"
    echo "prov-e2e: NOTE: sandbox cannot bind /bin; fixture build runs via fxstore's"
    echo "prov-e2e: NOTE: LOUD NON-HERMETIC fallback (PATH hides bwrap from its probe)"
    mkdir -p "$WORK/path"
    for t in sh cp ln rm mv cat mkdir file zig; do
        ln -sf "$(command -v "$t")" "$WORK/path/$t" 2>/dev/null || \
            fail "merged-usr fallback needs '$t' on PATH"
    done
    ( cd "$REPO/m3" && FXSTORE_STAGE3="$FXSTORE_STAGE3" \
        PATH="$COSMOBIN:$WORK/path" "$FXSTORE" build --store "$STORE" ) \
        >"$WORK/build.out" 2>&1 \
        || fail "fxstore build (non-hermetic) failed: $(tail -n 5 "$WORK/build.out")"
fi

# locate the store-built APEs (content-addressed dirs)
if [ -n "$FX_ACTIVATE" ]; then
    [ -x "$FX_ACTIVATE" ] || skip "FX_ACTIVATE not executable: $FX_ACTIVATE"
else
    FX_ACTIVATE=$(ls "$STORE"/*-fx-activate/fx-activate 2>/dev/null | head -1)
    [ -n "$FX_ACTIVATE" ] || fail "fx-activate not found in store ($STORE/*-fx-activate/fx-activate)"
fi
if [ -n "$FX_INIT_BIN" ]; then
    [ -x "$FX_INIT_BIN" ] || skip "FX_INIT_BIN not executable: $FX_INIT_BIN"
    cp "$FX_INIT_BIN" "$STORE/.fx-init-under-test"
    FXINIT_BIN="$STORE/.fx-init-under-test"
    FXINIT_CHROOT="/fx/store/.fx-init-under-test"
else
    FXINIT_BIN=$(ls "$STORE"/*-fx-init/fx-init 2>/dev/null | head -1)
    [ -n "$FXINIT_BIN" ] || fail "fx-init not found in store ($STORE/*-fx-init/fx-init)"
    FXINIT_CHROOT="/fx/store/$(basename "$(dirname "$FXINIT_BIN")")/fx-init"
fi
FXCTL_BIN=$(ls "$STORE"/*-fxctl/fxctl 2>/dev/null | head -1)
[ -n "$FXCTL_BIN" ] || fail "fxctl not found in store ($STORE/*-fxctl/fxctl)"

# ─── fxstore provenance readers (host-side; --store points the db + origins) ─
prov_out=""; prov_rc=0
prov() { prov_out=$( "$FXSTORE" "$@" 2>&1 ); prov_rc=$?; }

# assert_last RC DESC [!]PATTERN...  — '!' prefixes a must-NOT-contain
assert_last() {
    want_rc=$1; desc=$2; shift 2
    [ "$prov_rc" -eq "$want_rc" ] || fail "$desc: rc=$prov_rc want $want_rc — $prov_out"
    for pat in "$@"; do
        case "$pat" in
        !*) echo "$prov_out" | grep -qF -- "${pat#!}" \
                && fail "$desc: output must not contain '${pat#!}' — $prov_out" ;;
        *)  echo "$prov_out" | grep -qF -- "$pat" \
                || fail "$desc: output lacks '$pat' — $prov_out" ;;
        esac
    done
    echo "  ok: $desc"
}

# ─── fx-activate (host-side, like fxinit_boot.sh) ────────────────────────────
# echoes "activated <genhash> as version <v>"; sets ACT_GEN/ACT_VER.
activate() {
    cfg="$1"
    out=$( LD_LIBRARY_PATH="$DLIBDIR" "$FX_ACTIVATE" --store "$STORE" \
        --package-set "$REPO/m3/package-set.dhall" \
        --config "$cfg" 2>&1 ) || fail "activate $cfg failed: $out"
    ACT_GEN=$(echo "$out" | sed -n 's/^activated \([0-9a-f][0-9a-f]*\) as version.*/\1/p')
    ACT_VER=$(echo "$out" | sed -n 's/^activated [0-9a-f][0-9a-f]* as version \([0-9][0-9]*\).*/\1/p')
    [ -n "$ACT_GEN" ] && [ -n "$ACT_VER" ] || fail "cannot parse activate output: $out"
    echo "$out"
}

# ─── bwrap boot (fxinit_boot.sh precedent) ───────────────────────────────────
fxctl() { FX_RUN="$ROOT/run/fx" LD_LIBRARY_PATH="$DLIBDIR" "$FXCTL_BIN" "$@"; }

boot_run() {
    rm -rf "$ROOT/etc" "$ROOT/bin" "$ROOT/run/fx"/* 2>/dev/null
    mkdir -p "$ROOT/etc" "$ROOT/bin" "$ROOT/run/fx" "$ROOT/tmp"
    # the store-built fx-init is the ZIG port: its RUNPATH is CWD-relative
    # (../datalog-dafsa/zig-out/lib), useless inside the chroot — bind the
    # libdatalog dir at its real host path and force it via LD_LIBRARY_PATH.
    "$BWRAP" \
        --bind "$ROOT" / \
        --bind "$STORE" /fx/store \
        --ro-bind "$DLIBDIR" "$DLIBDIR" \
        --ro-bind /bin/sh /bin/sh \
        --ro-bind /usr /usr --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
        --dev /dev --proc /proc --ro-bind /sys /sys \
        --clearenv --setenv FX_INIT_FORCE 1 --setenv PATH /bin:/usr/bin \
        --setenv LD_LIBRARY_PATH "$DLIBDIR" \
        -- "$FXINIT_CHROOT" --store /fx/store --run-dir /run/fx \
        >"$WORK/boot.out" 2>&1 &
    BPID=$!
    sleep 1
}

boot_stop() {
    fxctl shutdown 2>/dev/null
    for i in 1 2 3 4 5; do
        kill -0 "$BPID" 2>/dev/null || break
        sleep 1
    done
    kill "$BPID" 2>/dev/null
    wait "$BPID" 2>/dev/null
}

wait_status() {
    for i in $(seq 1 60); do
        out=$(fxctl status 2>/dev/null) || { sleep 0.5; continue; }
        bs=$(st_bs "$out")
        case "$bs" in
            *ok|*failed) echo "$out"; return 0;;
        esac
        sleep 0.5
    done
    fail "boot_status never reached ok/failed in 30s (boot log: $(tail -n 5 "$WORK/boot.out"))"
}

st_bs()  { echo "$1" | grep -A1 '^boot_status:'        | tail -n1 | sed 's/^ *//'; }
st_gen() { echo "$1" | grep -A1 '^generation_current:' | tail -n1 | sed 's/^ *//'; }

# ─── verify inside the relocated-boot chroot ─────────────────────────────────
# $ROOT at /, $STORE at /fx/store (the paths the BOOT's rewritten buildfile
# used), fxstore + its libdatalog RUNPATH at their real host paths, /usr +
# /lib64 only for the ELF interpreter/libc.  NO /bin/sh bind and no /proc:
# the unmanaged scan must see exactly what the boot materialized.  bwrap's
# /bin/sh bind in boot_run leaves the dest FILE on disk in $ROOT/bin — a
# harness artifact, not fx materialization — so it is removed before the
# scan.  Sets VOUT/VRC.
verify_chroot() {
    rm -f "$ROOT/bin/sh"
    VOUT=$( "$BWRAP" \
        --bind "$ROOT" / \
        --bind "$STORE" /fx/store \
        --ro-bind "$FXSTORE" /fxstore \
        --ro-bind "$DLIBDIR" "$DLIBDIR" \
        --ro-bind /usr /usr --ro-bind /lib64 /lib64 \
        --dev /dev --clearenv \
        -- /fxstore verify --store /fx/store / 2>&1 )
    VRC=$?
}

# assert_verify RC DESC [!]<target>: <kind>: substring...
assert_verify() {
    want_rc=$1; desc=$2; shift 2
    [ "$VRC" -eq "$want_rc" ] || fail "$desc: verify rc=$VRC want $want_rc — $VOUT"
    for pat in "$@"; do
        case "$pat" in
        !*) echo "$VOUT" | grep -qF -- "${pat#!}" \
                && fail "$desc: verify output must not contain '${pat#!}' — $VOUT" ;;
        *)  echo "$VOUT" | grep -qF -- "$pat" \
                || fail "$desc: verify output lacks '$pat' — $VOUT" ;;
        esac
    done
    echo "  ok: $desc"
}

echo "=== prov-e2e [2]: build-only store has no install facts yet ==="
prov what --store "$STORE" /bin/fakesvc
assert_last 1 "what /bin/fakesvc before activation is unmanaged" \
    "is unmanaged (no install fact as-of version"

echo "=== prov-e2e [3]: activate config-good -> v_good; what/why answer ==="
activate "$REPO/m3/config-good.dhall" >/dev/null
GEN_GOOD=$ACT_GEN; V_GOOD=$ACT_VER
echo "  v_good=$V_GOOD gen_good=$GEN_GOOD"

prov what --store "$STORE" /bin/fakesvc
assert_last 0 "what /bin/fakesvc (bin symlink fact)" \
    "/bin/fakesvc" "-fake-service" "package fake-service" \
    "generation $GEN_GOOD" "pulled by root 'fake-service'"

prov what --store "$STORE" /etc/hostname
assert_last 0 "what /etc/hostname (etc copy fact, generation-relative origin)" \
    "/etc/hostname" "${GEN_GOOD}-system-generation/etc/hostname" \
    "package unknown"

prov what --store "$STORE" /etc/prov-e2e-nonexistent
assert_last 1 "what /etc/prov-e2e-nonexistent is unmanaged" "is unmanaged"

prov why --store "$STORE" fake-service
assert_last 0 "why fake-service (provides /bin/fakesvc)" \
    "package fake-service" "-fake-service" "/bin/fakesvc"

prov why --store "$STORE" prov-e2e-no-such-pkg
assert_last 1 "why prov-e2e-no-such-pkg has no provides fact" "no provides fact"

echo "=== prov-e2e [4]: boot config-good -> ok; verify the materialized rootfs ==="
boot_run
st=$(wait_status)
st_bs "$st" | grep -q 'ok' || { echo "$st"; boot_stop; fail "good boot did not reach ok"; }
boot_stop
verify_chroot
assert_verify 0 "verify clean after good boot" "verify OK"

echo "=== prov-e2e [5]: tamper 3 ways -> verify reports hash/missing/link_target ==="
echo "tampered by prov-e2e" > "$ROOT/etc/hostname" || fail "cannot tamper /etc/hostname"
rm -f "$ROOT/etc/passwd"                    || fail "cannot remove /etc/passwd"
rm -f "$ROOT/bin/fakesvc"                   || fail "cannot remove /bin/fakesvc"
ln -s /bin/sh "$ROOT/bin/fakesvc"           || fail "cannot retarget /bin/fakesvc"
verify_chroot
assert_verify 1 "verify flags exactly the 3 tamper drifts" \
    ": 3 drift(s)" \
    "/etc/hostname: hash:" \
    "/etc/passwd: missing:" \
    "/bin/fakesvc: link_target:" \
    "!verify OK"

echo "=== prov-e2e [6]: activate config-bad-exit -> v_bad; current view flips ==="
activate "$REPO/m3/config-bad-exit.dhall" >/dev/null
GEN_BAD=$ACT_GEN; V_BAD=$ACT_VER
echo "  v_bad=$V_BAD gen_bad=$GEN_BAD"

prov what --store "$STORE" /etc/hostname
assert_last 0 "what /etc/hostname at v_bad shows the failed activation's genhash" \
    "${GEN_BAD}-system-generation/etc/hostname" "!${GEN_GOOD}"

prov what --store "$STORE" --as-of "$V_GOOD" /etc/hostname
assert_last 0 "what --as-of v_good still shows gen_good (timeline intact)" \
    "${GEN_GOOD}-system-generation/etc/hostname"

echo "=== prov-e2e [7]: boot v_bad -> failed ==="
boot_run
st=$(wait_status)
st_bs "$st" | grep -q 'failed' || { echo "$st"; boot_stop; fail "crasher boot did not reach failed"; }
V2GEN=$(st_gen "$st" | grep -o '[0-9][0-9]*' | head -1)
boot_stop
echo "  failed boot at generation $V2GEN (v_bad)"

echo "=== prov-e2e [8]: boot again -> roll-forward; prov facts == v_good's set ==="
# All asserts below run AFTER the roll-forward boot completed — i.e. after
# fx_store_rollback re-published the converged state (the U4 read-semantics
# finding: dl_query readers see the PINNED snapshot until that publish).
boot_run
st=$(wait_status)
st_bs "$st" | grep -q 'ok' || { echo "$st"; boot_stop; fail "roll-forward did not reach ok"; }
V_RF=$(st_gen "$st" | grep -o '[0-9][0-9]*' | head -1)
[ "$V_RF" -gt "$V_BAD" ] || { echo "v_rf=$V_RF v_bad=$V_BAD"; boot_stop; \
    fail "roll-forward version not monotonic (v_rf > v_bad)"; }
boot_stop
echo "  roll-forward OK (v_rf=$V_RF > v_bad=$V_BAD)"

prov what --store "$STORE" /etc/hostname
assert_last 0 "ROLL-FORWARD: what /etc/hostname is gen_good again (not gen_bad)" \
    "${GEN_GOOD}-system-generation/etc/hostname" "!${GEN_BAD}"

prov what --store "$STORE" /bin/fakesvc
assert_last 0 "ROLL-FORWARD: what /bin/fakesvc (package + gen_good)" \
    "package fake-service" "generation $GEN_GOOD"

prov why --store "$STORE" fake-service
assert_last 0 "ROLL-FORWARD: why fake-service still provides /bin/fakesvc" \
    "/bin/fakesvc"

prov what --store "$STORE" --as-of "$V_BAD" /etc/hostname
assert_last 0 "what --as-of v_bad keeps the failed generation's facts (history)" \
    "${GEN_BAD}-system-generation/etc/hostname"

verify_chroot
assert_verify 0 "verify clean after roll-forward re-materialization (tamper healed)" \
    "verify OK"

echo "=== prov-e2e [9]: fx-core fx-what/fx-why coreutils (same engine, other repo) ==="
if [ -n "$FX_CORE_BIN" ] && [ -x "$FX_CORE_BIN/fx-what" ] && [ -x "$FX_CORE_BIN/fx-why" ]; then
    cout=$(LD_LIBRARY_PATH="$DLIBDIR" "$FX_CORE_BIN/fx-what" /bin/fakesvc --store "$STORE" 2>&1)
    crc=$?
    [ "$crc" -eq 0 ] && echo "$cout" | grep -qF "package fake-service" \
        || fail "fx-core fx-what /bin/fakesvc: rc=$crc — $cout"
    cout=$(LD_LIBRARY_PATH="$DLIBDIR" "$FX_CORE_BIN/fx-why" fake-service --store "$STORE" 2>&1)
    crc=$?
    [ "$crc" -eq 0 ] && echo "$cout" | grep -qF "/bin/fakesvc" \
        || fail "fx-core fx-why fake-service: rc=$crc — $cout"
    echo "  ok: fx-core fx-what/fx-why agree"
else
    echo "prov-e2e: NOTE: fx-core fx-what/fx-why not reachable at ${FX_CORE_BIN:-<disabled>}"
    echo "prov-e2e: NOTE: — cross-coreutils check SKIPPED (fxstore CLI answers above)"
fi

echo "prov-e2e: PASS"
