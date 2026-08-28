#!/bin/sh
# activate_diff.sh — unit-5 differential harness: run the Zig port of
# fx-activate (zig-out/bin/fx-activate) against the C oracle built from the
# UNMODIFIED src/fx-activate.c + src/config.c on every corpus case; fail on
# ANY difference in stdout, stderr, exit code, the store FACTS (10 M4
# relations + versions, dumped by zig/activate_facts.c), or the emitted
# generation dir (Dhakefile.dhall + etc/*).
#
# Fully in-sandbox: needs only zig (no cosmocc, no fxstore binary).  The
# harness pre-creates each closure store dir (via zig/activate_paths.c, the
# compute_paths twin) with a dummy payload so it counts as BUILT —
# fx-activate only stats dir-ness (fx-activate.c:545).
#
# The two sides run SEQUENTIALLY against ONE shared store path per case
# (fresh per side): the per-package derivation hash embeds each dep's FULL
# store path (fxstore.h "each direct dep's FULL store path"), so it is
# store-root-dependent for dep-ful packages — the C oracle and the port must
# hash against the same root for the genhash to be comparable.  dl_open holds
# a process-lifetime exclusive lock: every store touch is sequential.
#
# The generation epoch (time(2)) is sed-normalized in the facts dump — the
# two sides run seconds apart.  CORPUS CONSTRAINT: every config has >= 1 user
# with >= 1 group — the C oracle's groups CSV (fx-activate.c:805) and empty
# passwd/group content (fx-activate.c:578-582) read UNINITIALIZED malloc when
# nothing was written, i.e. C-side UB the port must not mirror.
set -u
cd "$(dirname "$0")/.."

CORPUS=zig/corpus/activate
ROOTS="dhake fx-init fxctl fx-activate fakesvc"
OBJ=build-tmp/activate-obj

ENGINE="vendor/datalog-dafsa/src/intern.c vendor/datalog-dafsa/src/termstore.c vendor/datalog-dafsa/src/relation.c vendor/datalog-dafsa/src/vrelation.c vendor/datalog-dafsa/src/tupleset.c vendor/datalog-dafsa/src/parser.c vendor/datalog-dafsa/src/compiler.c vendor/datalog-dafsa/src/vm.c vendor/datalog-dafsa/src/snapshot.c vendor/datalog-dafsa/src/regexwalk.c vendor/datalog-dafsa/src/permindex.c vendor/datalog-dafsa/src/util.c vendor/datalog-dafsa/src/dl.c vendor/datalog-dafsa/src/iter.c vendor/datalog-dafsa/src/magic.c vendor/datalog-dafsa/src/topdown.c vendor/datalog-dafsa/src/analyze.c vendor/datalog-dafsa/src/schema.c vendor/datalog-dafsa/src/typecheck.c vendor/datalog-dafsa/src/json.c vendor/datalog-dafsa/src/txnwal.c vendor/datalog-dafsa/src/index.c"
DAFSA="vendor/dafsa/dafsa.c vendor/dafsa/dafsa_state.c vendor/dafsa/dafsa_core.c vendor/dafsa/dafsa_persist.c vendor/dafsa/dafsa_view.c vendor/dafsa/dafsa_crc32.c vendor/dafsa/dafsa_wal.c vendor/dafsa/dafsa_build.c vendor/dafsa/dafsa_rank.c vendor/dafsa/dafsa_view_rank.c"
FXSTORE="vendor/fxstore/packageset.c vendor/fxstore/derivation.c vendor/fxstore/closure.c vendor/fxstore/store.c vendor/fxstore/build.c"
DHALLC="vendor/dhall-c/src/arena.c vendor/dhall-c/src/lexer.c vendor/dhall-c/src/parser.c vendor/dhall-c/src/ast.c vendor/dhall-c/src/normalize.c vendor/dhall-c/src/typecheck.c vendor/dhall-c/src/builtins.c vendor/dhall-c/src/serialize.c vendor/dhall-c/src/import.c vendor/dhall-c/src/bignum.c vendor/dhall-c/src/sha256.c vendor/dhall-c/src/ssrf.c vendor/dhall-c/src/http.c"
INC="-I src -I vendor/fxstore -I vendor/datalog-dafsa/src -I vendor/datalog-dafsa/vendor -I vendor/dafsa -I vendor/dhall-c/src"
DEF='-DFXSTORE_STAGE3_PATH="/fx/store/share/stage3"'

echo "== building C oracle + helpers (zig cc) =="
mkdir -p "$OBJ"
# one static core archive, three consumers (oracle, paths twin, facts dump)
for f in $FXSTORE $ENGINE $DAFSA $DHALLC; do
    zig cc -std=gnu11 -O2 $DEF $INC -c "$f" -o "$OBJ/$(echo "$f" | tr / _).o"
done
ar rcs build-tmp/libfxcore.a "$OBJ"/*.o
zig cc -std=gnu11 -O2 $DEF $INC -o zig/zig-out/activate_c \
    src/config.c src/fx-activate.c build-tmp/libfxcore.a
zig cc -std=gnu11 -O2 $DEF $INC -o zig/zig-out/activate_paths \
    zig/activate_paths.c build-tmp/libfxcore.a
zig cc -std=gnu11 -O2 $DEF $INC -o zig/zig-out/activate_facts \
    zig/activate_facts.c build-tmp/libfxcore.a
echo "C oracle built"

echo "== building Zig port =="
( cd zig && zig build -Doptimize=ReleaseSafe )
ACT_C=zig/zig-out/activate_c
ACT_Z=zig/zig-out/bin/fx-activate
PATHS=zig/zig-out/activate_paths
FACTS=zig/zig-out/activate_facts

WORK="$(mktemp -d -t activate_diff.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# run_side SIDE BIN CFG NRUNS STORE — fresh shared store, pre-build closure
# dirs, run the activator NRUNS times (idempotency case), dump facts.
run_side() {
    side=$1 bin=$2 cfg=$3 nruns=$4 store=$5
    rm -rf "$store" "$store.build"

    rels=$("$PATHS" --store "$store" --package-set "$CORPUS/package-set.dhall" $ROOTS) || {
        echo "activate_diff: activate_paths failed for $side" >&2; return 1; }
    for d in $rels; do
        mkdir -p "$store/$d" && echo built > "$store/$d/payload"
    done

    i=1
    while [ "$i" -le "$nruns" ]; do
        rc=0
        "$bin" --store "$store" --package-set "$CORPUS/package-set.dhall" \
            --config "$CORPUS/$cfg" >"$WORK/$side.$i.out" 2>"$WORK/$side.$i.err" || rc=$?
        echo "$rc" > "$WORK/$side.$i.rc"
        i=$((i + 1))
    done

    "$FACTS" --store "$store" 2>"$WORK/$side.facts.err" \
        | sed -E 's/ [0-9]{10}$/ E/' > "$WORK/$side.facts"

    # genhash + generation dir (last run's stdout)
    sed -n 's/^activated \([0-9a-f]\{64\}\) as version.*/\1/p' \
        "$WORK/$side.$nruns.out" > "$WORK/$side.genhash"
    if [ -s "$WORK/$side.genhash" ]; then
        genhash=$(cat "$WORK/$side.genhash")
        cp -r "$store/$genhash-system-generation" "$WORK/$side.gen"
    else
        : > "$WORK/$side.genhash.empty"
    fi
}

pass=0; fail=0
run_case() {
    name=$1; cfg=$2; nruns=$3
    store="$WORK/store"
    run_side c "$ACT_C" "$cfg" "$nruns" "$store"
    run_side z "$ACT_Z" "$cfg" "$nruns" "$store"

    ok=1; why=""
    i=1
    while [ "$i" -le "$nruns" ]; do
        diff -u "$WORK/c.$i.out" "$WORK/z.$i.out" >"$WORK/d.out" 2>&1 || { ok=0; why="$why out[$i]"; }
        diff -u "$WORK/c.$i.err" "$WORK/z.$i.err" >"$WORK/d.err" 2>&1 || { ok=0; why="$why err[$i]"; }
        [ "$(cat "$WORK/c.$i.rc")" = "$(cat "$WORK/z.$i.rc")" ] || { ok=0; why="$why rc[$i]"; }
        i=$((i + 1))
    done
    diff -u "$WORK/c.facts" "$WORK/z.facts" >"$WORK/d.facts" 2>&1 || { ok=0; why="$why facts"; }
    # genhash: equal across sides, and stable across re-runs (idempotency)
    if [ -f "$WORK/c.genhash.empty" ] || [ -f "$WORK/z.genhash.empty" ]; then
        [ -f "$WORK/c.genhash.empty" ] && [ -f "$WORK/z.genhash.empty" ] || { ok=0; why="$why genhash-presence"; }
    else
        cmp -s "$WORK/c.genhash" "$WORK/z.genhash" || { ok=0; why="$why genhash"; }
        if [ "$nruns" -ge 2 ]; then
            h1=$(sed -n 1p "$WORK/c.genhash"); hlast=$(sed -n '$p' "$WORK/c.genhash")
            [ "$h1" = "$hlast" ] || { ok=0; why="$why idempotency"; }
        fi
        diff -r "$WORK/c.gen" "$WORK/z.gen" >"$WORK/d.gen" 2>&1 || { ok=0; why="$why gendir"; }
    fi

    if [ "$ok" = 1 ]; then
        pass=$((pass + 1))
        echo "PASS $name (rc=$(cat "$WORK/c.$nruns.rc"), runs=$nruns)"
    else
        fail=$((fail + 1))
        echo "FAIL $name ($why)"
        for d in "$WORK"/d.out "$WORK"/d.err "$WORK"/d.facts "$WORK"/d.gen; do
            [ -s "$d" ] && sed 's/^/    /' "$d"
        done
    fi
}

# name                    config                     runs
run_case full            full.dhall                 1
run_case empty-svc       empty-svc.dhall            1
run_case svc-no-closure  svc-not-in-closure.dhall   1
run_case missing-pkg     missing-pkg.dhall          1
run_case bad-on          bad-on.dhall               1
run_case parse-err       parse-err.dhall            1
run_case missing-field   missing-field.dhall        1
run_case idempotency     full.dhall                 2

echo "activate_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
