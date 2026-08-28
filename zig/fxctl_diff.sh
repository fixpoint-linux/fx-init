#!/bin/sh
# fxctl_diff.sh — differential harness for src/fxctl.c vs its Zig port
# (zig/src/fxctl.zig).  Two parts:
#
#   1. REQUEST-LINE DIFF: the C oracle (zig/fxctl_dump.c — a labeled verbatim
#      copy of the request builder + usage, which live INLINE in fxctl.c's
#      main()) and the Zig twin (zig/src/fxctl_check.zig) sweep a corpus of
#      argv vectors; stdout+stderr+rc must be byte-identical.
#   2. LIVE CLIENT DIFF: the UNMODIFIED C client (built from src/fxctl.c)
#      vs the Zig client (zig/zig-out/bin/fxctl), both exec'd against a fake
#      fx-init AF_UNIX server (zig/fxctl_live.c): request echoed back / data
#      + OK / ERR variants / close-without-reply / not-running / no-args.
#      This pins the REAL C main()'s request bytes and the response
#      streaming end-to-end, covering any drift between the oracle copy and
#      fxctl.c.
#
# Builds all binaries first (oracle+client+driver: zig cc gnu11; port: zig
# build), like the other *_diff.sh harnesses.
set -e
cd "$(dirname "$0")/.."

echo "== building C oracle + C client + live driver =="
zig cc -std=gnu11 -O2 -Wall -Wextra -o zig/zig-out/fxctl_dump zig/fxctl_dump.c
zig cc -std=gnu11 -O2 -Wall -Wextra -o zig/zig-out/fxctl_c src/fxctl.c
zig cc -std=gnu11 -O2 -Wall -Wextra -o zig/zig-out/fxctl_live zig/fxctl_live.c
echo "fxctl_dump / fxctl_c / fxctl_live built"

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

# ── part 2: live client diff — real C binary vs Zig binary, fake server ──
echo "== live client diff (C vs Zig vs fake fx-init server) =="
if "$LIVE" zig/zig-out/fxctl_c zig/zig-out/bin/fxctl >"/tmp/fxctl_live.out" 2>&1; then
    pass=$((pass + 1))
    echo "PASS live client diff (real C client vs Zig client, 13 cases)"
    sed 's/^/    /' "/tmp/fxctl_live.out"
else
    fail=$((fail + 1))
    echo "FAIL live client diff"
    sed 's/^/    /' "/tmp/fxctl_live.out"
fi

echo "fxctl_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
