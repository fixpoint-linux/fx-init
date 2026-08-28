#!/bin/sh
# log_probe_diff.sh — UNIT 3 differential harness: src/fx_log.c + src/fx_probe.c
# vs their Zig ports (zig/src/log.zig + zig/src/probe.zig).
#
# The one-process live driver (zig/log_probe_live.c, built by zig build) is
# the gate: it runs an identical scripted emit/grep/search/rotate sequence on
# C-fx_log and Zig-log in two throwaway DBs, and C/Zig fx_probe_refresh on
# two DBs over the SAME tests/probe_test.c fixture tree (same process => same
# statvfs/uname/environ/sysconf), dumping every relation at string level
# (sorted, syms resolved) and asserting byte-identity, plus replays of the
# log_test.c and probe_test.c assertions against the Zig side.
#
# Additionally, if cosmocc exists, the original C unit tests are rebuilt and
# run as a sanity gate on the C contract itself.
set -e
cd "$(dirname "$0")/.."

echo "== building Zig port + live driver =="
( cd zig && zig build -Doptimize=ReleaseSafe )
LIVE=zig/zig-out/bin/log_probe_live

pass=0; fail=0

echo "== live one-process differential =="
if "$LIVE" > /tmp/log_probe_live.out 2>&1; then
    pass=$((pass + 1))
    n=$(tail -1 /tmp/log_probe_live.out)
    echo "PASS live log+probe differential ($n)"
    grep -c "OK " /tmp/log_probe_live.out | sed 's/^/    byte-identity+assertion groups OK: /'
else
    fail=$((fail + 1))
    echo "FAIL live log+probe differential"
    sed 's/^/    /' /tmp/log_probe_live.out
fi

# ── C contract sanity: the original unit tests (cosmocc only) ─────────────
if command -v cosmocc >/dev/null 2>&1; then
    echo "== C contract sanity (tests/log_test.c + tests/probe_test.c) =="
    if sh tests/build_log.sh >/dev/null 2>&1 && ./build-tmp/log_test > /tmp/log_test.out 2>&1; then
        pass=$((pass + 1))
        echo "PASS C log_test ($(tail -1 /tmp/log_test.out))"
    else
        fail=$((fail + 1))
        echo "FAIL C log_test"
        sed 's/^/    /' /tmp/log_test.out 2>/dev/null
    fi
    if sh tests/build_probe.sh >/dev/null 2>&1 && ./build-tmp/probe_test > /tmp/probe_test.out 2>&1; then
        pass=$((pass + 1))
        echo "PASS C probe_test ($(tail -1 /tmp/probe_test.out))"
    else
        fail=$((fail + 1))
        echo "FAIL C probe_test"
        sed 's/^/    /' /tmp/probe_test.out 2>/dev/null
    fi
else
    echo "NOTE cosmocc not found — skipping C unit-test rebuild (probe_test.c"
    echo "     assertions are replayed against the Zig side inside the driver)"
fi

echo "log_probe_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
