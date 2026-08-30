#!/bin/sh
# fxctl_diff.sh — regression harness for the fxctl port (zig/src/fxctl.zig).
# Two parts:
#
#   1. REQUEST-LINE DIFF (still live): the self-contained fixture oracle
#      (zig/fxctl_dump.c — a labeled verbatim copy of the request builder +
#      usage, which live INLINE in fxctl.c's main()) and the Zig twin
#      (zig/src/fxctl_check.zig) sweep a corpus of argv vectors; stdout+
#      stderr+rc must be byte-identical.  fxctl_dump.c is harness fixture C
#      under zig/, NOT the removed C oracle — it needs nothing from src/.
#   2. LIVE CLIENT CONTRACT vs goldens: the client (zig/zig-out/bin/fxctl)
#      is exec'd against a fake fx-init AF_UNIX server (zig/fxctl_live.c):
#      request echoed back / data + OK / ERR variants / close-without-reply
#      / not-running / no-args; stdout+stderr+rc must match the pinned
#      goldens (zig/golden/fxctl-live/).
#
# Golden provenance (part 2): pinned ONCE from the REAL C client
# (src/fxctl.c, since removed) with `--pin` after the last pre-deletion
# live C-vs-Zig client diff passed 13/13 byte-identical (2026-08-29) — the
# goldens are the C client's verified behavior, including its request
# bytes end-to-end.  `--pin` re-pins from a client binary you name; it can
# no longer rebuild the C oracle (it is gone from this repo).
set -e
cd "$(dirname "$0")/.."
GOLDEN=zig/golden/fxctl-live
PIN=0
PINBIN=""
if [ "${1:-}" = "--pin" ]; then
    PIN=1
    PINBIN="${2:-}"
    [ -n "$PINBIN" ] || { echo "usage: fxctl_diff.sh --pin <client-binary>" >&2; exit 2; }
    [ -x "$PINBIN" ] || { echo "fxctl_diff: pin client not executable: $PINBIN" >&2; exit 2; }
fi

echo "== building fixture oracle (fxctl_dump) + live driver =="
zig cc -std=gnu11 -O2 -Wall -Wextra -o zig/zig-out/fxctl_dump zig/fxctl_dump.c
zig cc -std=gnu11 -O2 -Wall -Wextra -o zig/zig-out/fxctl_live zig/fxctl_live.c
echo "fxctl_dump / fxctl_live built"

echo "== building Zig port =="
( cd zig && zig build -Doptimize=ReleaseSafe )
DUMP=zig/zig-out/fxctl_dump
CHECK=zig/zig-out/bin/fxctl_check
LIVE=zig/zig-out/fxctl_live

pass=0; fail=0

# ── part 1: request-line corpus sweep, byte-identical stdout+stderr+rc ────
run() {
    dump_rc=0; check_rc=0
    "$DUMP" "$@" >"/tmp/fxctl_dump.out" 2>"/tmp/fxctl_dump.err" || dump_rc=$?
    "$CHECK" "$@" >"/tmp/fxctl_check.out" 2>"/tmp/fxctl_check.err" || check_rc=$?
    ok=1
    cmp -s "/tmp/fxctl_dump.out" "/tmp/fxctl_check.out" || ok=0
    cmp -s "/tmp/fxctl_dump.err" "/tmp/fxctl_check.err" || ok=0
    [ "$dump_rc" = "$check_rc" ] || ok=0
    if [ "$ok" = 1 ]; then
        pass=$((pass + 1))
        echo "PASS req: $*"
    else
        fail=$((fail + 1))
        echo "FAIL req: $* (dump rc=$dump_rc, check rc=$check_rc)"
        diff -u "/tmp/fxctl_dump.out" "/tmp/fxctl_check.out" | sed 's/^/    out: /'
        diff -u "/tmp/fxctl_dump.err" "/tmp/fxctl_check.err" | sed 's/^/    err: /'
    fi
}

run status
run probe
run shutdown
run q users alice
run q users "" "a b" 'c"d'
run q rel "has space" 'has"quote'
run start web
run stop web
run restart api-gateway
run start
run activate "my config.dhall"
run rollback 17
run grep "err.*timeout"
run search "term one" "term-two"
run search "$(printf 'a\tb')" plain
run ""
run status extra junk args here
run # no subcommand: usage, rc 2
LONG=$(head -c 5000 /dev/zero | tr '\0' 'x')
run q users "$LONG"
run status "$LONG" "$LONG"

# ── part 2: live client contract — client binary vs pinned goldens ────────
mkdir -p "$GOLDEN"
if [ "$PIN" = 1 ]; then
    echo "== pinning live client contract from $PINBIN =="
    if "$LIVE" pin "$PINBIN" "$GOLDEN" >"/tmp/fxctl_live.out" 2>&1; then
        pass=$((pass + 1))
        echo "PIN live client contract ($(grep -c '    PIN ' /tmp/fxctl_live.out) cases)"
        sed 's/^/    /' /tmp/fxctl_live.out
    else
        fail=$((fail + 1))
        echo "FAIL live client pin"
        sed 's/^/    /' /tmp/fxctl_live.out
    fi
else
    echo "== live client contract (zig fxctl vs C-pinned goldens) =="
    if "$LIVE" check zig/zig-out/bin/fxctl "$GOLDEN" >"/tmp/fxctl_live.out" 2>&1; then
        pass=$((pass + 1))
        echo "PASS live client contract (zig fxctl vs C-pinned goldens, 13 cases)"
        sed 's/^/    /' "/tmp/fxctl_live.out"
    else
        fail=$((fail + 1))
        echo "FAIL live client contract"
        sed 's/^/    /' /tmp/fxctl_live.out
    fi
fi

echo "fxctl_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
