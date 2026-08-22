#!/bin/sh
# tests/activate.sh — verify fx-activate (U-B): builds the closure into a tmp
# store, activates config-good, asserts the emitted per-generation Dhakefile
# has the Copy+Chmod / Rm+Symlink corrections and all-phony targets, re-activates
# to the SAME genhash (content-addressed idempotency), and rejects a config
# referencing a package not in the store.
#
# This is a HOST test: it needs a built `fxstore` binary (to build the closure)
# and the `fx-activate` binary under test.  In the rattan sandbox fxstore is not
# built, so this script skips loudly there; the orchestrator runs it on the host.
#
# Env / args:
#   FXSTORE     path to a built fxstore binary    (default: $1)
#   FX_ACTIVATE path to the fx-activate under test (default: $2)
#   DHAKE       optional; fxstore build uses an internal cosmocc recipe (no dhake).
set -u

FXSTORE="${FXSTORE:-${1:-}}"
FX_ACTIVATE="${FX_ACTIVATE:-${2:-}}"

fail() { echo "activate-test: FAIL: $*" >&2; exit 1; }
skip() { echo "activate-test: SKIP ($*)"; exit 77; }

[ -n "$FXSTORE" ]    || skip "FXSTORE not given (in-sandbox has no built fxstore)"
[ -n "$FX_ACTIVATE" ] || skip "FX_ACTIVATE not given"
[ -x "$FXSTORE" ]    || skip "fxstore not executable: $FXSTORE"
[ -x "$FX_ACTIVATE" ] || skip "fx-activate not executable: $FX_ACTIVATE"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"

WORK="$(mktemp -d -t fxactivate.XXXXXX)" || fail "mktemp"
trap 'rm -rf "$WORK"' EXIT
STORE="$WORK/store"

echo "=== activate-test: building closure into $STORE ==="
# Build all five closure roots from this repo's own package set.
( cd "$REPO/m3" && "$FXSTORE" build --store "$STORE" ) || fail "fxstore build failed"

echo "=== activate-test: activate config-good ==="
# fx-activate resolves package src Paths relative to the package-set FILE's dir,
# so point it at the real m3/package-set.dhall + the config by absolute path
# (never copy package-set away from its tree).
OUT=$( "$FX_ACTIVATE" --store "$STORE" \
    --package-set "$REPO/m3/package-set.dhall" \
    --config "$REPO/m3/config-good.dhall" 2>&1 ) || fail "activate failed: $OUT"
echo "$OUT"
# "activated <genhash> as version <v>; buildfile <path>"
GENHASH=$(echo "$OUT" | sed -n 's/^activated \([0-9a-f]*\) as version.*/\1/p')
[ -n "$GENHASH" ] || fail "no genhash in activate output: $OUT"
echo "genhash=$GENHASH"

# locate the generation dir: <store>/<genhash>-system-generation
GENDIR="$STORE/$GENHASH-system-generation"
[ -d "$GENDIR" ] || fail "generation dir not found: $GENDIR"
BF="$GENDIR/Dhakefile.dhall"
[ -f "$BF" ] || fail "no Dhakefile.dhall in generation dir"

echo "=== activate-test: assert buildfile corrections ==="
# (1) /etc files materialized via Copy, not Echo.
grep -q '< Copy' "$BF" || fail "no Copy actions in buildfile"
# (2) every /etc file followed by a Chmod (umask independence).
NCOPY=$(grep -c '< Copy' "$BF")
NCHMOD=$(grep -c '< Chmod' "$BF")
[ "$NCHMOD" -ge "$NCOPY" ] || fail "fewer Chmod ($NCHMOD) than Copy ($NCOPY) — /etc modes depend on umask"
# (3) every Symlink preceded by an Rm<Plain> guard (dhake bare symlink fails EEXIST).
NSYM=$(grep -c '< Symlink' "$BF")
NRM=$(grep -c '< Rm = < Plain' "$BF")
[ "$NRM" -ge "$NSYM" ] || fail "fewer Rm guards ($NRM) than Symlinks ($NSYM) — bare symlink would fail on EEXIST"
# (4) all targets phony (always re-assert; no mtime-incremental skip).
grep -q 'phony = True' "$BF" || fail "no phony=True in buildfile"
if grep -q 'phony = False' "$BF"; then
    fail "found phony=False — all targets must be phony (always re-assert)"
fi

echo "=== activate-test: re-activate idempotency (same genhash) ==="
OUT2=$( "$FX_ACTIVATE" --store "$STORE" \
    --package-set "$REPO/m3/package-set.dhall" \
    --config "$REPO/m3/config-good.dhall" 2>&1 ) || fail "re-activate failed: $OUT2"
GENHASH2=$(echo "$OUT2" | sed -n 's/^activated \([0-9a-f]*\) as version.*/\1/p')
[ "$GENHASH2" = "$GENHASH" ] || fail "re-activate genhash differs: $GENHASH vs $GENHASH2 (not content-addressed idempotent)"

echo "=== activate-test: missing-package rejection ==="
# a config whose only service pkg is "ghost-package" — not in the store.
cat > "$WORK/missing-config.dhall" <<'EOF'
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox"
    , packages = [ "ghost-package" ]
    , users = [] : List { name : Text, uid : Natural, groups : List Text }
    , services = [] : List Service
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = None Natural }
EOF
if "$FX_ACTIVATE" --store "$STORE" \
    --package-set "$REPO/m3/package-set.dhall" \
    --config "$WORK/missing-config.dhall" >/dev/null 2>&1; then
    fail "activate accepted a config with an unbuilt package (should reject)"
fi
echo "missing-package rejected OK"

echo "activate-test: PASS"
