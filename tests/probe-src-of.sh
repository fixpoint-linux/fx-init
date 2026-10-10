#!/bin/sh
# probe-src-of.sh — THE ASYMMETRY GATE for src_of(deriv_hash, src_hash, name),
# the fact fx-activate now commits beside its store/srcstore pair in
# commitClosureMeta (activate.zig).
#
# WHAT A CONSUMER NEEDS (todo.md §3, the fx-harness oracle's refusal): after a
# package is REBUILT, one name has TWO live srcstore rows and nothing says
# which source the RUNNING generation was folded from.  With src_of, a reader
# holding the generation's own provides row ("<hash>-<pkg>") resolves the
# exact src_hash with no guessing.
#
# THE ARMS (same fixture recipe as fx-harness tests/test_osier_share.sh A4:
# toolchain-free activate_paths provisioning + real host-side fx-activate,
# twice, with the source mutated between — one name, two live srcstore rows):
#   ARM A  fail-before, WRITER side: OLD fx-activate (pinned INIT_REV) +
#          NEW fxstore -> src_of rows never land -> the consumer CANNOT
#          attribute -> resolution is empty -> exit 1.
#   ARM B  fail-before, READER side: NEW fx-activate + OLD fxstore (pinned
#          FXSTORE_REV, predates RELATION_SCHEMAS.src_of) -> 'fxstore facts
#          src_of' is a LOUD unknown-relation error -> exit 1.
#   ARM C  pass-after: NEW fx-activate + NEW fxstore ->
#            (c1) as-of V2 the consumer resolves EXACTLY the v2 src_hash;
#            (c2) as-of V1 (the OLD snapshot, same store) it resolves the
#                 v1 src_hash — version-bound: an older snapshot keeps its
#                 own claim and gains no retroactive one;
#            (c3) the row prints as <64hex>\t<64hex>\t<name> — three SYMBOL
#                 columns (a wrong sym-vs-raw classification would print an
#                 integer), the schema-table risk;
#            (c4) re-activation is idempotent: V3 still resolves AMB_H2 and
#                 ambig has exactly ONE src_of row as-of V3.
#
# The controls are PINNED REVISIONS (never HEAD): INIT_REV / FXSTORE_REV,
# guarded by git cat-file (a shallow clone says SKIP out loud), and their
# domain is PROVEN with cmp — if the pinned activate.zig equals the working
# one the fail-before arm would compare the code to itself and prove nothing.
#
# Usage: sh probe-src-of.sh [scratch-dir]   (default a fresh mktemp -d)
set -u

fail() { echo "probe-src-of: FAIL: $*" >&2; exit 1; }
skip() { echo "probe-src-of: SKIP ($*)"; exit 77; }

SIBS="$(cd "$(dirname "$0")/../.." && pwd)"
INIT="$SIBS/fx-init"
FXSTORE="$SIBS/fxstore"
DL="$SIBS/datalog-dafsa/zig-out/lib"
[ -f "$DL/libdatalog.so" ] || skip "libdatalog.so missing at $DL"

# ── the PINNED controls (fixed revisions, never HEAD) ────────────────────
INIT_REV=2feedf6     # fx-init @ activate.zig WITHOUT src_of
FXSTORE_REV=c79af4b  # fxstore @ RELATION_SCHEMAS WITHOUT src_of
for r in "$INIT:activate.zig:$INIT_REV" "$FXSTORE:provenance.zig:$FXSTORE_REV"; do
    repo=${r%%:*}; rest=${r#*:}; f=${rest%%:*}; rev=${rest##*:}
    git -C "$repo" cat-file -e "$rev^{commit}" 2>/dev/null \
        || skip "$repo pinned revision $rev unavailable (shallow clone?)"
done
[ -f "$INIT/zig/src/activate.zig" ] || fail "no working activate.zig"

WORK="${1:-$(mktemp -d /tmp/probe-srcof.XXXXXX)}" || fail mktemp
mkdir -p "$WORK"
echo "probe-src-of: scratch $WORK"
BIN="$WORK/bin"
mkdir -p "$BIN"

# ── build all four binaries (old = git archive of the pinned rev) ────────
# The pinned trees must sit DIRECTLY under $SIBS as dot-dirs: fx-init's
# build.zig resolves siblings as ../../dhall-c and ../../datalog-dafsa
# relative to <tree>/zig, so one extra nesting level breaks the imports with
# file_hash FileNotFound (not the real error).
build_init() { # build_init SRCDIR OUTDIR
    ( cd "$1/zig" && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe \
        -p "$2" --cache-dir "$2-cache" ) >"$2.log" 2>&1 \
        || fail "zig build $1 failed: $(tail -3 "$2.log")"
}
build_fs() { # build_fs SRCDIR OUTDIR
    ( cd "$1/zig" && zig build -Doptimize=ReleaseSafe \
        -p "$2" --cache-dir "$2-cache" ) >"$2.log" 2>&1 \
        || fail "zig build $1 failed: $(tail -3 "$2.log")"
}
OLD_INIT_SRC="$SIBS/.probe-pin-init-$INIT_REV"
if [ ! -x "$BIN/old-init/bin/fx-activate" ]; then
    rm -rf "$OLD_INIT_SRC"; mkdir -p "$OLD_INIT_SRC"
    git -C "$INIT" archive "$INIT_REV" | tar -x -C "$OLD_INIT_SRC" \
        || fail "cannot extract fx-init $INIT_REV"
    cmp -s "$OLD_INIT_SRC/zig/src/activate.zig" "$INIT/zig/src/activate.zig" \
        && skip "pinned $INIT_REV activate.zig is IDENTICAL to the working one — ARM A would compare the code to itself"
    build_init "$OLD_INIT_SRC" "$BIN/old-init"
fi
OLD_FS_SRC="$SIBS/.probe-pin-fxstore-$FXSTORE_REV"
if [ ! -x "$BIN/old-fs/bin/fxstore" ]; then
    rm -rf "$OLD_FS_SRC"; mkdir -p "$OLD_FS_SRC"
    git -C "$FXSTORE" archive "$FXSTORE_REV" | tar -x -C "$OLD_FS_SRC" \
        || fail "cannot extract fxstore $FXSTORE_REV"
    cmp -s "$OLD_FS_SRC/zig/src/provenance.zig" "$FXSTORE/zig/src/provenance.zig" \
        && skip "pinned $FXSTORE_REV provenance.zig is IDENTICAL to the working one — ARM B would compare the code to itself"
    build_fs "$OLD_FS_SRC" "$BIN/old-fs"
fi
[ -x "$BIN/new-init/bin/fx-activate" ] || build_init "$INIT" "$BIN/new-init"
[ -x "$BIN/new-fs/bin/fxstore" ] || build_fs "$FXSTORE" "$BIN/new-fs"
for b in "$BIN/old-init/bin/fx-activate" "$BIN/old-init/bin/activate_paths" \
         "$BIN/new-init/bin/fx-activate" "$BIN/new-init/bin/activate_paths" \
         "$BIN/old-fs/bin/fxstore" "$BIN/new-fs/bin/fxstore"; do
    [ -x "$b" ] || fail "missing binary $b"
done
echo "probe-src-of: four binaries built (old/new x fx-init/fxstore)"

# ── the fixture (test_osier_share.sh's shape, ambig only) ────────────────
# provision_fixture INITDIR STORE: build the two-live-srcstore-rows store.
# Prints "V1 V2 AMB_H1 AMB_H2" (the two versions, the two src hashes).
provision_fixture() { # provision_fixture INITDIR STORE
    _ib="$1"; _st="$2"
    _src="$WORK/src-$(basename "$_st")"
    rm -rf "$_src"; mkdir -p "$_src/ambig" "$_src/tool"
    echo "-- the ambiguity fixture's osier module, revision 1" > "$_src/ambig/A.elm"
    i=0; while [ $i -lt 5 ]; do echo "int tool_line_$i = $i;" >> "$_src/tool/tool.c"; i=$((i+1)); done
    _ps="$_st.pkgset.dhall"
    {
        cat <<'EOF'
let Action = < Shell : Text | Copy : { from : Text, to : Text } | Mkdir : Text
             | Rm : Text | Touch : Text | Move : { from : Text, to : Text }
             | Symlink : { from : Text, to : Text } | Chmod : { path : Text, mode : Text }
             | Echo : Text | Env : { key : Text, value : Text } | Run : { argv : List Text } >
let Src = < Path : Text | Fetch : { url : Text, hash : Text } >
let Package = { name : Text, version : Text, src : Src, deps : List Text,
                excludes : List Text, build : { target : Text, recipe : List Action } }
in  { packages = [
EOF
        for _p in dhake fx-init fxctl fx-activate; do
            echo "  { name = \"$_p\", version = \"0\", src = < Path = \"$_src/tool\" >, deps = [] : List Text, excludes = [] : List Text, build = { target = \"$_p\", recipe = [] : List Action } }"
            echo "  ,"
        done
        echo "  { name = \"ambig\", version = \"0\", src = < Path = \"$_src/ambig\" >, deps = [] : List Text, excludes = [] : List Text, build = { target = \"ambig\", recipe = [] : List Action } }"
        echo "  ] }"
    } > "$_ps" || fail "cannot write the package set"
    _cfg="$_st.cfg.dhall"
    cat > "$_cfg" <<EOF
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "probebox"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "ambig" ]
    , users = [ { name = "root", uid = 0, groups = [] : List User } ] : List User
    , services = [ { name = "shsvc", argv = [ "/bin/sh", "-c", "true" ], pkg = None Text, on = "all", restart = Some "always", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text },
                   { name = "ambigd", argv = [ "ambig" ], pkg = Some "ambig", on = "all", restart = Some "always", backoffMs = Some 500, probe = None Probe, env = None (List { key : Text, value : Text }), console = None Text } ] : List Service
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 30000
    , agentService = None Text
    }
EOF
    _prov() { # pre-create the closure dirs for the CURRENT source
        _p=$(LD_LIBRARY_PATH="$DL" "$_ib/bin/activate_paths" --store "$_st" \
            --package-set "$_ps" dhake fx-init fxctl fx-activate ambig) \
            || fail "activate_paths failed: $_p"
        for _pd in $_p; do mkdir -p "$_st/$_pd" || fail "cannot create $_pd"; done
    }
    _activate() { # _activate CFG -> version N on stdout
        _o=$(LD_LIBRARY_PATH="$DL" "$_ib/bin/fx-activate" --store "$_st" \
            --package-set "$_ps" --config "$1" 2>&1) \
            || fail "fx-activate failed: $_o"
        echo "$_o" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1
    }
    _prov
    _v1=$(_activate "$_cfg"); [ -n "$_v1" ] || fail "no version from activation 1"
    cp -r "$_src/ambig" "$_st.ambig-v1" || fail "cannot save the v1 tree"
    echo "-- mutation: revision 2 (a different source, same package name)" >> "$_src/ambig/A.elm"
    _prov
    _v2=$(_activate "$_cfg"); [ -n "$_v2" ] || fail "no version from activation 2"
    # the premise: TWO live srcstore rows for ambig as-of v2
    _rows=$(LD_LIBRARY_PATH="$DL" "$BIN/new-fs/bin/fxstore" facts srcstore --as-of "$_v2" --store "$_st" \
        | awk -F'\t' '$2 == "ambig"')
    _n=$(echo "$_rows" | grep -c .)
    [ "$_n" = 2 ] || fail "premise broken: $_n live srcstore rows for ambig as-of $_v2 (want 2)"
    _h1=$(LD_LIBRARY_PATH="$DL" "$BIN/new-fs/bin/fxstore" facts srcstore --as-of "$_v1" --store "$_st" \
        | awk -F'\t' '$2 == "ambig" {print $1; exit}')
    [ -n "$_h1" ] || fail "no srcstore row for ambig as-of $_v1"
    _h2=$(echo "$_rows" | awk -F'\t' '$1 != h1 {print $1; exit}' h1="$_h1")
    [ -n "$_h2" ] && [ "$_h1" != "$_h2" ] || fail "the two src hashes are not distinct"
    echo "$_v1 $_v2 $_h1 $_h2"
}

# ── the consumer: provides -> <hash> -> src_of -> the exact src_hash ─────
# Prints the src_hash, or "NONE" when the store cannot attribute (no
# provides row / no src_of row).  A query that itself FAILS dies loudly —
# an empty answer must mean "cannot attribute", never a swallowed error
# (that vacuity is how ARM A first "passed": an invalid --as-of).
resolve_src() { # resolve_src FXSTORE STORE ASOF PKG -> src_hash | NONE
    _fs="$1"; _st="$2"; _v="$3"; _pk="$4"
    _prov_out=$(LD_LIBRARY_PATH="$DL" "$_fs" facts provides --as-of "$_v" --store "$_st" 2>&1) \
        || fail "resolve_src: 'facts provides --as-of $_v' failed: $_prov_out"
    _dir=$(echo "$_prov_out" | awk -F'\t' -v p="$_pk" '$1 == p {print $2; exit}')
    [ -n "$_dir" ] || { echo "NONE"; return; }
    _dh=${_dir%%-*}
    _of_out=$(LD_LIBRARY_PATH="$DL" "$_fs" facts src_of --as-of "$_v" --store "$_st" 2>&1) \
        || fail "resolve_src: 'facts src_of --as-of $_v' failed: $_of_out"
    _s=$(echo "$_of_out" | awk -F'\t' -v d="$_dh" -v p="$_pk" '$1 == d && $3 == p {print $2; exit}')
    echo "${_s:-NONE}"
}

# ══ ARM A: OLD writer — the consumer CANNOT attribute (fail-before) ══════
STORE_A="$WORK/store-oldwriter"; mkdir -p "$STORE_A"
set -- $(provision_fixture "$BIN/old-init" "$STORE_A") || fail "fixture A failed"
VA1=$1; VA2=$2; H1=$3; H2=$4
for _v in "$VA1" "$VA2"; do
    case "$_v" in ''|*[!0-9]*) fail "fixture A: version '$_v' is not an integer (fixture plumbing broke)";; esac
done
GOT_A=$(resolve_src "$BIN/new-fs/bin/fxstore" "$STORE_A" "$VA2" ambig)
[ "$GOT_A" = "NONE" ] \
    || fail "ARM A: the OLD writer's store resolved a src_hash ($GOT_A) — src_of predates $INIT_REV?"
echo "probe-src-of: ARM A (old writer, v$VA2): cannot attribute (NONE) — as expected"

# ══ ARM B: OLD reader — 'facts src_of' is a LOUD error (fail-before) ═════
STORE_B="$WORK/store-newwriter"; mkdir -p "$STORE_B"
set -- $(provision_fixture "$BIN/new-init" "$STORE_B") || fail "fixture B failed"
VB1=$1; VB2=$2; HB1=$3; HB2=$4
for _v in "$VB1" "$VB2"; do
    case "$_v" in ''|*[!0-9]*) fail "fixture B: version '$_v' is not an integer (fixture plumbing broke)";; esac
done
if LD_LIBRARY_PATH="$DL" "$BIN/old-fs/bin/fxstore" facts src_of --as-of "$VB2" --store "$STORE_B" >/dev/null 2>"$WORK/armB.err"; then
    fail "ARM B: the OLD fxstore dumped src_of without the schema row — $FXSTORE_REV predates it?"
fi
grep -q "unknown relation 'src_of'" "$WORK/armB.err" \
    || fail "ARM B: old fxstore failed for the wrong reason: $(cat "$WORK/armB.err")"
echo "probe-src-of: ARM B (old reader, v$VB2): 'facts src_of' refuses loud (unknown relation) — as expected"

# ══ ARM C: NEW writer + NEW reader — exact, version-bound, symbolic ═════
# (c1) the CURRENT generation resolves EXACTLY the v2 hash
GOT_C1=$(resolve_src "$BIN/new-fs/bin/fxstore" "$STORE_B" "$VB2" ambig)
[ "$GOT_C1" = "$HB2" ] \
    || fail "ARM C1: as-of $VB2 resolved '${GOT_C1:-<empty>}', want the v2 hash $HB2"
[ "$GOT_C1" != "$HB1" ] || fail "ARM C1: resolved the WRONG (v1) hash"
# (c2) version-boundness: the SAME store's older snapshot resolves its OWN
GOT_C2=$(resolve_src "$BIN/new-fs/bin/fxstore" "$STORE_B" "$VB1" ambig)
[ "$GOT_C2" = "$HB1" ] \
    || fail "ARM C2: as-of $VB1 resolved '${GOT_C2:-<empty>}', want the v1 hash $HB1 (an old snapshot must keep its own claim)"
# (c3) the row is three SYMBOL columns keyed by the DERIV hash: as-of V2
# src_of legitimately holds BOTH pairs for ambig (append-only, like
# srcstore) — the disambiguation is the KEY: exactly one row carries the
# provides dir's hash, its src is the v2 hash, and cols are 64-hex SYMBOLS
# (a raw misclassification would print a decimal integer, not 64 hex chars)
DIR_C=$(LD_LIBRARY_PATH="$DL" "$BIN/new-fs/bin/fxstore" facts provides --as-of "$VB2" --store "$STORE_B" \
    | awk -F'\t' '$1 == "ambig" {print $2; exit}')
DH_C=${DIR_C%%-*}
ROW_C3=$(LD_LIBRARY_PATH="$DL" "$BIN/new-fs/bin/fxstore" facts src_of --as-of "$VB2" --store "$STORE_B" \
    | awk -F'\t' -v d="$DH_C" 'NF == 3 && $1 == d && $3 == "ambig" && $2 ~ /^[0-9a-f]{64}$/ && $1 ~ /^[0-9a-f]{64}$/')
N_C3=$(LD_LIBRARY_PATH="$DL" "$BIN/new-fs/bin/fxstore" facts src_of --as-of "$VB2" --store "$STORE_B" \
    | awk -F'\t' -v d="$DH_C" '$1 == d && $3 == "ambig"' | grep -c .)
[ "$N_C3" = 1 ] && [ -n "$ROW_C3" ] \
    || fail "ARM C3: $N_C3 src_of rows keyed by the provides hash as-of $VB2 (want exactly 1, symbolic)"
echo "$ROW_C3" | awk -F'\t' -v want="$HB2" 'NF != 3 || $2 != want { exit 1 }' \
    || fail "ARM C3: the provides-keyed row's src ($ROW_C3) is not the v2 hash $HB2"
# and the OLD snapshot gains NO retroactive claim: as-of V1, ambig has
# exactly ONE src_of row — the v1 pair — and its deriv hash is NOT the v2
# provides hash (the v2 row must not leak backwards into V1's snapshot)
DIR_C1=$(LD_LIBRARY_PATH="$DL" "$BIN/new-fs/bin/fxstore" facts provides --as-of "$VB1" --store "$STORE_B" \
    | awk -F'\t' '$1 == "ambig" {print $2; exit}')
N_C3b=$(LD_LIBRARY_PATH="$DL" "$BIN/new-fs/bin/fxstore" facts src_of --as-of "$VB1" --store "$STORE_B" \
    | awk -F'\t' '$3 == "ambig"' | grep -c .)
RETRO=$(LD_LIBRARY_PATH="$DL" "$BIN/new-fs/bin/fxstore" facts src_of --as-of "$VB1" --store "$STORE_B" \
    | awk -F'\t' -v d="$DH_C" '$1 == d && $3 == "ambig"' | grep -c .)
[ "$N_C3b" = 1 ] && [ "$RETRO" = 0 ] \
    || fail "ARM C3b: as-of $VB1 ambig has $N_C3b src_of row(s), $RETRO carrying the v2 deriv hash (want 1 row, 0 retroactive)"
echo "probe-src-of: ARM C1/C2/C3: v$VB2 -> $HB2 (not $HB1); v$VB1 -> $HB1; one row per deriv hash; no retroactive claim in v$VB1"

# (c4) idempotent re-activation: the SAME source re-activated adds NO new
# row (DAFSA dedup) — ambig keeps exactly 2 rows total (the v1 pair + the
# v2 pair), exactly 1 keyed by the current deriv hash, still resolving v2's
# hash; and the OLD snapshot is untouched by the re-activation
_o=$(LD_LIBRARY_PATH="$DL" "$BIN/new-init/bin/fx-activate" --store "$STORE_B" \
    --package-set "$STORE_B.pkgset.dhall" --config "$STORE_B.cfg.dhall" 2>&1) \
    || fail "re-activation failed: $_o"
VB3=$(echo "$_o" | sed -n 's/.*as version \([0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$VB3" ] || fail "no version from re-activation"
NROWS=$(LD_LIBRARY_PATH="$DL" "$BIN/new-fs/bin/fxstore" facts src_of --as-of "$VB3" --store "$STORE_B" \
    | awk -F'\t' '$3 == "ambig"' | grep -c .)
NKEYED=$(LD_LIBRARY_PATH="$DL" "$BIN/new-fs/bin/fxstore" facts src_of --as-of "$VB3" --store "$STORE_B" \
    | awk -F'\t' -v d="$DH_C" '$1 == d && $3 == "ambig"' | grep -c .)
[ "$NROWS" = 2 ] && [ "$NKEYED" = 1 ] \
    || fail "ARM C4: re-activation grew src_of for ambig to $NROWS rows / $NKEYED keyed (want 2 / 1 — must be idempotent)"
GOT_C4=$(resolve_src "$BIN/new-fs/bin/fxstore" "$STORE_B" "$VB3" ambig)
[ "$GOT_C4" = "$HB2" ] || fail "ARM C4: as-of $VB3 resolved '$GOT_C4', want $HB2"
# and the OLD snapshot is untouched by the re-activation
GOT_C2b=$(resolve_src "$BIN/new-fs/bin/fxstore" "$STORE_B" "$VB1" ambig)
[ "$GOT_C2b" = "$HB1" ] || fail "ARM C4: re-activation disturbed the v$VB1 snapshot's own claim"
echo "probe-src-of: ARM C4: v$VB3 re-activation idempotent (2 rows, 1 keyed, still $HB2); v$VB1 still $HB1"

echo "probe-src-of: PASS — old writer cannot attribute; old reader refuses loud; new pair resolves exactly, version-bound"
exit 0
