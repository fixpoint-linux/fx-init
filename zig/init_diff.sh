#!/bin/sh
# init_diff.sh — unit-6 differential harness for src/fx-init.c vs its Zig port
# (zig/src/init.zig).  L1 in-sandbox smoke diff (no cosmocc, no bwrap, no
# fxstore binary): it builds a fixture store via the ZIG fx-activate (unit 5)
# + the activate_paths helper, installs a zig-cc-built fakesvc at its svc_bin
# target and a FAKE dhake (cats its -f arg to stdout, exit 0 or FAKE_DHAKE_EXIT),
# then boots each binary HOST-side with FX_INIT_FORCE=1 and byte-compares a
# NORMALIZED transcript (fxctl status + q service_runtime + q boot_status +
# grep heartbeat + grep 'let GEN' + .bootlog; epochs/pids/restarts/store-path
# sed-normalized).
#
# The store is activated into $WORK/pre (so the buildfile bakes the HOST root
# $WORK/pre) then MOVED to $WORK/store before boot: run_dhake must reloc-rewrite
# $WORK/pre -> $WORK/store, so `grep 'let GEN'` pins the fx_reloc wiring (the
# rewritten GEN line, not the activation-time root).
#
# The two sides run SEQUENTIALLY against the SAME store path (fresh per side):
# dl_open holds a process-lifetime exclusive lock, and the per-package
# derivation hash is store-root-dependent, so the genhash is comparable only
# when both sides activate into the same root.
set -u
cd "$(dirname "$0")/.."

CORPUS=zig/corpus/init
PKGSET=zig/corpus/activate/package-set.dhall
ROOTS="dhake fx-init fxctl fx-activate fakesvc"

ENGINE="vendor/datalog-dafsa/src/intern.c vendor/datalog-dafsa/src/termstore.c vendor/datalog-dafsa/src/relation.c vendor/datalog-dafsa/src/vrelation.c vendor/datalog-dafsa/src/tupleset.c vendor/datalog-dafsa/src/parser.c vendor/datalog-dafsa/src/compiler.c vendor/datalog-dafsa/src/vm.c vendor/datalog-dafsa/src/snapshot.c vendor/datalog-dafsa/src/regexwalk.c vendor/datalog-dafsa/src/permindex.c vendor/datalog-dafsa/src/util.c vendor/datalog-dafsa/src/dl.c vendor/datalog-dafsa/src/iter.c vendor/datalog-dafsa/src/magic.c vendor/datalog-dafsa/src/topdown.c vendor/datalog-dafsa/src/analyze.c vendor/datalog-dafsa/src/schema.c vendor/datalog-dafsa/src/typecheck.c vendor/datalog-dafsa/src/json.c vendor/datalog-dafsa/src/txnwal.c vendor/datalog-dafsa/src/index.c"
DAFSA="vendor/dafsa/dafsa.c vendor/dafsa/dafsa_state.c vendor/dafsa/dafsa_core.c vendor/dafsa/dafsa_persist.c vendor/dafsa/dafsa_view.c vendor/dafsa/dafsa_crc32.c vendor/dafsa/dafsa_wal.c vendor/dafsa/dafsa_build.c vendor/dafsa/dafsa_rank.c vendor/dafsa/dafsa_view_rank.c"
FXSTORE="vendor/fxstore/store.c vendor/fxstore/closure.c vendor/fxstore/build.c vendor/fxstore/packageset.c"
INC="-I src -I vendor/fxstore -I vendor/datalog-dafsa/src -I vendor/datalog-dafsa/vendor -I vendor/dafsa -I vendor/dhall-c/src"
# -DPATH_MAX: fx-init.c uses PATH_MAX but does not include <limits.h>; glibc
# only exposes it transitively under cosmocc (tests/build_fxinit.sh), so the
# zig-cc oracle pins the Linux value 4096.
DEF='-DFXSTORE_STAGE3_PATH="/fx/store/share/stage3" -DPATH_MAX=4096'
GC="-ffunction-sections -fdata-sections -Wl,--gc-sections"

echo "== building C oracle (fx-init) + C fxctl + fakesvc + fake dhake =="
zig cc -std=gnu11 -O2 $GC $DEF $INC -o zig/zig-out/init_c \
    src/fx-init.c src/fx_supervise.c src/fx_reloc.c src/fx_probe.c src/fx_log.c \
    $FXSTORE $ENGINE $DAFSA
zig cc -std=gnu11 -O2 -o zig/zig-out/init_fxctl src/fxctl.c
zig cc -std=gnu11 -O2 -o zig/zig-out/init_fakesvc tests/fixtures/fakesvc/fakesvc.c
zig cc -std=gnu11 -O2 -o zig/zig-out/init_dhake zig/dhake_smoke.c

echo "== building Zig port + activate helpers =="
( cd zig && zig build -Doptimize=ReleaseSafe )

INIT_C=zig/zig-out/init_c
INIT_Z=zig/zig-out/bin/fx-init
FXCTL=zig/zig-out/init_fxctl
FAKESVC=zig/zig-out/init_fakesvc
DHAKE=zig/zig-out/init_dhake
PATHS=zig/zig-out/activate_paths
ACT_Z=zig/zig-out/bin/fx-activate

WORK="$(mktemp -d -t init_diff.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
PRE="$WORK/pre"
STORE="$WORK/store"
RUN="$WORK/run"

fail() { echo "init_diff: FAIL: $*" >&2; exit 1; }

# wait_status RUN — poll fxctl status until boot_status reaches ok/failed.
wait_status() {
    run=$1
    i=1
    while [ "$i" -le 100 ]; do
        out=$(FX_RUN="$run" "$FXCTL" status 2>/dev/null) || { sleep 0.2; i=$((i+1)); continue; }
        bs=$(echo "$out" | grep -A1 '^boot_status:' | tail -n1 | sed 's/^ *//')
        case "$bs" in
            *ok|*failed) echo "$out" > "$WORK/waitstatus.out"; return 0;;
        esac
        sleep 0.2
        i=$((i+1))
    done
    return 1
}

# normalize — epochs/pids/restarts/store-path out of a transcript.
normalize() {
    sed -e "s|$WORK|WORK|g" \
        -e 's/[0-9]\{10\}/EPOCH/g' \
        -e 's/\t[0-9][0-9]*\t/\tPID\t/g' \
        -e 's/\t[0-9][0-9]*$/\tN/'
}

# run_side SIDE BIN CFG DHAKE_EXIT GREPTERM — fresh store, boot, capture
# the (normalized) transcript.
run_side() {
    side=$1 bin=$2 cfg=$3 dhexit=$4 grepterm=$5

    rm -rf "$PRE" "$STORE" "$RUN"
    mkdir -p "$PRE"

    rels=$("$PATHS" --store "$PRE" --package-set "$PKGSET" $ROOTS) \
        || fail "activate_paths failed ($side)"
    for d in $rels; do
        mkdir -p "$PRE/$d" && echo built > "$PRE/$d/payload"
    done

    "$ACT_Z" --store "$PRE" --package-set "$PKGSET" --config "$CORPUS/$cfg" \
        >"$WORK/$side.act.out" 2>"$WORK/$side.act.err" \
        || fail "fx-activate failed ($side): $(tail -1 "$WORK/$side.act.err")"

    # install the compiled fixtures at their svc_bin / dhake targets.  The
    # target FILE does not exist yet, so `cp src dir/*-x/file` would not glob;
    # resolve the content-addressed dir first, then copy into it.
    set -- "$PRE"/*-fakesvc
    fdir=$1
    [ -d "$fdir" ] || fail "fakesvc install failed ($side) — no *-fakesvc dir?"
    cp "$FAKESVC" "$fdir/fakesvc"
    set -- "$PRE"/*-dhake
    ddir=$1
    [ -d "$ddir" ] || fail "dhake install failed ($side) — no *-dhake dir?"
    cp "$DHAKE" "$ddir/dhake.com"
    mv "$PRE" "$STORE"

    mkdir -p "$RUN"
    FX_INIT_FORCE=1 FAKE_DHAKE_EXIT="$dhexit" "$bin" \
        --store "$STORE" --run-dir "$RUN" --grace-ms 1500 --probe-interval-s 100000 \
        >"$WORK/$side.boot.out" 2>&1 &
    BPID=$!

    wait_status "$RUN" || {
        echo "--- $side boot.out ---" >&2
        sed 's/^/    /' "$WORK/$side.boot.out" >&2
        fail "boot_status never reached ok/failed ($side)"
    }

    FX_RUN="$RUN" "$FXCTL" status            | normalize >"$WORK/$side.status" 2>&1
    FX_RUN="$RUN" "$FXCTL" q service_runtime | normalize >"$WORK/$side.sr" 2>&1
    FX_RUN="$RUN" "$FXCTL" grep "$grepterm"  | head -1 | normalize >"$WORK/$side.grep" 2>&1
    FX_RUN="$RUN" "$FXCTL" grep 'let GEN'    | head -1 | normalize >"$WORK/$side.gen" 2>&1

    FX_RUN="$RUN" "$FXCTL" shutdown >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$BPID" 2>/dev/null || break
        sleep 0.3
    done
    kill "$BPID" 2>/dev/null
    wait "$BPID" 2>/dev/null

    normalize < "$STORE/.bootlog" > "$WORK/$side.bootlog"
    [ -s "$WORK/$side.bootlog" ] || fail ".bootlog empty after boot ($side)"
}

pass=0; fail=0

run_case() {
    name=$1; cfg=$2; dhexit=$3; grepterm=$4

    run_side c "$INIT_C" "$cfg" "$dhexit" "$grepterm"
    run_side z "$INIT_Z" "$cfg" "$dhexit" "$grepterm"

    ok=1; why=""
    for f in status sr grep gen bootlog; do
        if ! diff -u "$WORK/c.$f" "$WORK/z.$f" >"$WORK/d.$f" 2>&1; then
            ok=0; why="$why $f"
        fi
    done

    if [ "$ok" = 1 ]; then
        pass=$((pass + 1))
        echo "PASS $name"
    else
        fail=$((fail + 1))
        echo "FAIL $name ($why)"
        for f in status sr grep gen bootlog; do
            [ -s "$WORK/d.$f" ] && sed 's/^/    /' "$WORK/d.$f"
        done
    fi
}

# good boot: heartbeat reaches started, boot -> ok at grace-end
run_case good          good.dhall    0 heartbeat
# crasher: fakesvc exit 7 restarts (backoff), boot pinned failed via reap
run_case crasher       crasher.dhall 0 "fakesvc exit"
# dhake-fail: fake dhake exits 3, boot pinned failed
run_case dhake-fail    good.dhall    3 heartbeat

# ── stop/start via fxctl (control-socket supervision path) ────────────────
echo "== stop/start case =="
run_side c "$INIT_C" good.dhall 0 heartbeat
FX_RUN="$RUN" "$FXCTL" stop heartbeat >/dev/null 2>&1
i=1
while [ "$i" -le 50 ]; do
    sr=$(FX_RUN="$RUN" "$FXCTL" q service_runtime 2>/dev/null)
    echo "$sr" | grep -q '^heartbeat.*stopped' && break
    sleep 0.2; i=$((i+1))
done
echo "$sr" | normalize > "$WORK/c.stop"
FX_RUN="$RUN" "$FXCTL" start heartbeat >/dev/null 2>&1
i=1
while [ "$i" -le 50 ]; do
    sr=$(FX_RUN="$RUN" "$FXCTL" q service_runtime 2>/dev/null)
    echo "$sr" | grep -q '^heartbeat.*started' && break
    sleep 0.2; i=$((i+1))
done
echo "$sr" | normalize > "$WORK/c.start"
FX_RUN="$RUN" "$FXCTL" shutdown >/dev/null 2>&1
sleep 1

run_side z "$INIT_Z" good.dhall 0 heartbeat
FX_RUN="$RUN" "$FXCTL" stop heartbeat >/dev/null 2>&1
i=1
while [ "$i" -le 50 ]; do
    sr=$(FX_RUN="$RUN" "$FXCTL" q service_runtime 2>/dev/null)
    echo "$sr" | grep -q '^heartbeat.*stopped' && break
    sleep 0.2; i=$((i+1))
done
echo "$sr" | normalize > "$WORK/z.stop"
FX_RUN="$RUN" "$FXCTL" start heartbeat >/dev/null 2>&1
i=1
while [ "$i" -le 50 ]; do
    sr=$(FX_RUN="$RUN" "$FXCTL" q service_runtime 2>/dev/null)
    echo "$sr" | grep -q '^heartbeat.*started' && break
    sleep 0.2; i=$((i+1))
done
echo "$sr" | normalize > "$WORK/z.start"
FX_RUN="$RUN" "$FXCTL" shutdown >/dev/null 2>&1
sleep 1

if diff -u "$WORK/c.stop" "$WORK/z.stop" >"$WORK/d.stop" 2>&1 \
   && diff -u "$WORK/c.start" "$WORK/z.start" >"$WORK/d.start" 2>&1; then
    pass=$((pass + 1))
    echo "PASS stop/start"
else
    fail=$((fail + 1))
    echo "FAIL stop/start"
    [ -s "$WORK/d.stop" ]  && sed 's/^/    /' "$WORK/d.stop"
    [ -s "$WORK/d.start" ] && sed 's/^/    /' "$WORK/d.start"
fi

echo "init_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
