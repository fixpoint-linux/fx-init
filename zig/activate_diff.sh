#!/bin/sh
# activate_diff.sh — unit-5 regression harness: the Zig port of fx-activate
# (zig-out/bin/fx-activate) over every corpus case, compared against pinned
# goldens (zig/golden/activate/): stdout, stderr, exit code, the store FACTS
# (10 M4 relations + versions, dumped by zig/activate_facts.c), the
# generation hash, and the emitted generation dir (Dhakefile.dhall + etc/*,
# as a normalized manifest).
#
# Golden provenance: this was a LIVE differential against the C oracle
# (src/fx-activate.c + src/config.c, since removed) — the last pre-deletion
# live run (2026-08-29, C oracle still present) passed 8/8 identical on
# every stream, the facts, the genhash, and the full generation trees; the
# goldens were then captured from the Zig side, i.e. golden == the C
# oracle's verified behavior.  `--pin` re-captures goldens from the Zig
# side (NOT a C oracle rebuild — the C oracle is gone).
#
# Fully in-sandbox: needs only zig (no cosmocc, no fxstore binary).  The
# harness pre-creates each closure store dir (via zig/activate_paths.c, the
# compute_paths twin) with a dummy payload so it counts as BUILT —
# fx-activate only stats dir-ness (fx-activate.c:545 in the C oracle era).
#
# One shared store path per case (fresh per run): the per-package derivation
# hash embeds each dep's FULL store path (fxstore.h "each direct dep's FULL
# store path"), so the genhash is store-root-dependent — the store root is
# a mktemp dir, so golden comparisons NORMALIZE $WORK -> WORK and the
# 64-hex genhash -> H (idempotency across re-runs is still asserted on the
# RAW hash within a single run).  The generation epoch is normalized to E
# in stdout and facts.  dl_open holds a process-lifetime exclusive lock:
# every store touch is sequential.
#
# CORPUS CONSTRAINT (from the C-oracle era): every config has >= 1 user
# with >= 1 group — the C oracle's groups CSV read UNINITIALIZED malloc
# when nothing was written, i.e. C-side UB the port must not mirror.
set -u
cd "$(dirname "$0")/.."

CORPUS=zig/corpus/activate
ROOTS="dhake fx-init fxctl fx-activate fakesvc"
OBJ=build-tmp/activate-obj
GOLDEN=zig/golden/activate
PIN=0
[ "${1:-}" = "--pin" ] && PIN=1

ENGINE="vendor/datalog-dafsa/src/intern.c vendor/datalog-dafsa/src/termstore.c vendor/datalog-dafsa/src/relation.c vendor/datalog-dafsa/src/vrelation.c vendor/datalog-dafsa/src/tupleset.c vendor/datalog-dafsa/src/parser.c vendor/datalog-dafsa/src/compiler.c vendor/datalog-dafsa/src/vm.c vendor/datalog-dafsa/src/snapshot.c vendor/datalog-dafsa/src/regexwalk.c vendor/datalog-dafsa/src/permindex.c vendor/datalog-dafsa/src/util.c vendor/datalog-dafsa/src/dl.c vendor/datalog-dafsa/src/iter.c vendor/datalog-dafsa/src/magic.c vendor/datalog-dafsa/src/topdown.c vendor/datalog-dafsa/src/analyze.c vendor/datalog-dafsa/src/schema.c vendor/datalog-dafsa/src/typecheck.c vendor/datalog-dafsa/src/json.c vendor/datalog-dafsa/src/txnwal.c vendor/datalog-dafsa/src/index.c"
DAFSA="vendor/dafsa/dafsa.c vendor/dafsa/dafsa_state.c vendor/dafsa/dafsa_core.c vendor/dafsa/dafsa_persist.c vendor/dafsa/dafsa_view.c vendor/dafsa/dafsa_crc32.c vendor/dafsa/dafsa_wal.c vendor/dafsa/dafsa_build.c vendor/dafsa/dafsa_rank.c vendor/dafsa/dafsa_view_rank.c"
FXSTORE="vendor/fxstore/packageset.c vendor/fxstore/derivation.c vendor/fxstore/closure.c vendor/fxstore/store.c vendor/fxstore/build.c"
DHALLC="vendor/dhall-c/src/arena.c vendor/dhall-c/src/lexer.c vendor/dhall-c/src/parser.c vendor/dhall-c/src/ast.c vendor/dhall-c/src/normalize.c vendor/dhall-c/src/typecheck.c vendor/dhall-c/src/builtins.c vendor/dhall-c/src/serialize.c vendor/dhall-c/src/import.c vendor/dhall-c/src/bignum.c vendor/dhall-c/src/sha256.c vendor/dhall-c/src/ssrf.c vendor/dhall-c/src/http.c"
INC="-I vendor/fxstore -I vendor/datalog-dafsa/src -I vendor/datalog-dafsa/vendor -I vendor/dafsa -I vendor/dhall-c/src"
DEF='-DFXSTORE_STAGE3_PATH="/fx/store/share/stage3"'

echo "== building activate helpers (vendor C only: paths twin + facts dump) =="
mkdir -p "$OBJ"
# one static core archive, two consumers (paths twin, facts dump)
for f in $FXSTORE $ENGINE $DAFSA $DHALLC; do
    zig cc -std=gnu11 -O2 $DEF $INC -c "$f" -o "$OBJ/$(echo "$f" | tr / _).o"
done
ar rcs build-tmp/libfxcore.a "$OBJ"/*.o
zig cc -std=gnu11 -O2 $DEF $INC -o zig/zig-out/activate_paths \
    zig/activate_paths.c build-tmp/libfxcore.a
zig cc -std=gnu11 -O2 $DEF $INC -o zig/zig-out/activate_facts \
    zig/activate_facts.c build-tmp/libfxcore.a
echo "helpers built"

echo "== building Zig port =="
( cd zig && zig build -Doptimize=ReleaseSafe )
ACT_Z=zig/zig-out/bin/fx-activate
PATHS=zig/zig-out/activate_paths
FACTS=zig/zig-out/activate_facts

mkdir -p "$GOLDEN"

WORK="$(mktemp -d -t activate_diff.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
STORE="$WORK/store"

# normalize — golden comparisons ignore the mktemp store root, the epoch,
# and the (store-root-derived) 64-hex genhash.
normalize() {
    sed -e "s|$WORK|WORK|g" \
        -e 's/[0-9a-f]\{64\}/H/g' \
        -e 's/ [0-9]\{10\}$/ E/'
}

# run_side CFG NRUNS — fresh store, pre-build closure dirs, run the
# activator NRUNS times (idempotency case), dump facts; every artifact is
# normalized in place.
run_side() {
    cfg=$1 nruns=$2

    rm -rf "$STORE"
    rels=$("$PATHS" --store "$STORE" --package-set "$CORPUS/package-set.dhall" $ROOTS) || {
        echo "activate_diff: activate_paths failed" >&2; return 1; }
    for d in $rels; do
        mkdir -p "$STORE/$d" && echo built > "$STORE/$d/payload"
    done

    i=1
    while [ "$i" -le "$nruns" ]; do
        rc=0
        "$ACT_Z" --store "$STORE" --package-set "$CORPUS/package-set.dhall" \
            --config "$CORPUS/$cfg" >"$WORK/run.$i.out" 2>"$WORK/run.$i.err" || rc=$?
        normalize < "$WORK/run.$i.out" > "$WORK/n.$i.out"
        normalize < "$WORK/run.$i.err" > "$WORK/n.$i.err"
        echo "$rc" > "$WORK/n.$i.rc"
        i=$((i + 1))
    done

    "$FACTS" --store "$STORE" 2>"$WORK/facts.err" \
        | sed -E 's/ [0-9]{10}$/ E/' | sed -e "s|$WORK|WORK|g" -e 's/[0-9a-f]\{64\}/H/g' \
        > "$WORK/n.facts"
    normalize < "$WORK/facts.err" > "$WORK/n.facts.err"

    # genhash + generation dir (last run's stdout), normalized for goldens;
    # the RAW hash is kept for the within-run idempotency check
    sed -n 's/^activated \([0-9a-f]\{64\}\) as version.*/\1/p' \
        "$WORK/run.$nruns.out" > "$WORK/raw.genhash"
    normalize < "$WORK/raw.genhash" > "$WORK/n.genhash"
    if [ -s "$WORK/raw.genhash" ]; then
        genhash=$(cat "$WORK/raw.genhash")
        ( cd "$STORE" && find "$genhash-system-generation" -type f | sort ) > "$WORK/raw.gen.list"
        : > "$WORK/n.gen.manifest"
        while read -r f <&3; do
            rf=$(echo "$f" | sed "s/[0-9a-f]\{64\}/H/g")
            h=$(normalize < "$STORE/$f" | sha256sum | cut -d' ' -f1)
            echo "$rf $h" >> "$WORK/n.gen.manifest"
        done 3< "$WORK/raw.gen.list"
        echo "$STORE/$genhash-system-generation" > "$WORK/gendir.path"
    else
        : > "$WORK/n.genhash.empty"
    fi
}

pass=0; fail=0

# check_one NAME EXT — compare/golden one artifact.  EXT like "run1.out"
# maps to the work file n.1.out (run_side writes per-run artifacts as
# n.<i>.<kind>).
check_one() {
    name=$1 ext=$2
    wf=$(echo "$ext" | sed 's/^run\([0-9]*\)\./\1./')
    g="$GOLDEN/$name.$ext"
    if [ "$PIN" = 1 ]; then
        cp "$WORK/n.$wf" "$g" || { echo "    pin failed [$ext]"; return 1; }
        return 0
    fi
    if [ "$ext" = "gen.manifest" ] || [ "$ext" = "genhash.empty" ] || [ "$ext" = "genhash" ] || [ "$ext" = "facts.err" ]; then
        cmp -s "$g" "$WORK/n.$wf" && return 0
    else
        diff -u "$g" "$WORK/n.$wf" > "/tmp/act.d.$ext" 2>&1 && return 0
    fi
    echo "    diff [$ext]:"
    sed 's/^/      /' "/tmp/act.d.$ext" 2>/dev/null | head -15
    return 1
}

run_case() {
    name=$1; cfg=$2; nruns=$3
    run_side "$cfg" "$nruns" || { fail=$((fail + 1)); echo "FAIL $name (run_side)"; return; }

    ok=1
    i=1
    while [ "$i" -le "$nruns" ]; do
        check_one "$name" "run$i.out" || ok=0
        check_one "$name" "run$i.err" || ok=0
        check_one "$name" "run$i.rc"  || ok=0
        i=$((i + 1))
    done
    check_one "$name" "facts" || ok=0
    check_one "$name" "facts.err" || ok=0
    if [ -f "$WORK/n.genhash.empty" ]; then
        if [ "$PIN" = 1 ]; then : > "$GOLDEN/$name.genhash.empty";
        elif [ ! -f "$GOLDEN/$name.genhash.empty" ]; then
            ok=0; echo "    diff [genhash-presence]: golden expects a generation"
        fi
    else
        check_one "$name" "genhash" || { ok=0; }
        check_one "$name" "gen.manifest" || ok=0
        # idempotency: RAW genhash stable across re-runs within this run
        if [ "$nruns" -ge 2 ]; then
            h1=$(sed -n 1p "$WORK/raw.genhash"); hlast=$(sed -n '$p' "$WORK/raw.genhash")
            [ "$h1" = "$hlast" ] || { ok=0; echo "    diff [idempotency]"; }
        fi
    fi

    if [ "$ok" = 1 ]; then
        pass=$((pass + 1))
        if [ "$PIN" = 1 ]; then
            echo "PIN $name (rc=$(cat "$WORK/n.$nruns.rc"), runs=$nruns)"
        else
            echo "PASS $name (rc=$(cat "$WORK/n.$nruns.rc"), runs=$nruns)"
        fi
    else
        fail=$((fail + 1))
        echo "FAIL $name"
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
