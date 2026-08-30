#!/bin/sh
# log_probe_diff.sh — UNIT 3 regression harness: the Zig log + probe ports
# (zig/src/log.zig + zig/src/probe.zig) against pinned goldens
# (zig/golden/log_probe/).
#
# The one-process driver (zig/log_probe_live.c, built by zig build) reruns
# the identical scripted emit/grep/search/rotate sequence the C oracle was
# byte-verified against, dumps the log + __postings__ relations sorted at
# every checkpoint, rebuilds the probe fixture tree (the old
# tests/probe_test.c bytes), refreshes, and compares every dump, grep/
# search collect buffer, and rc against the goldens.  The absolute
# log_test.c / probe_test.c assertion replays (counts, tuple columns,
# rotation arithmetic) run as inline CHECKs inside the driver.
#
# Golden provenance: this was a LIVE one-process C-vs-Zig differential —
# the last pre-deletion run (2026-08-29, C oracle still present) passed
# 346 checks / 0 failed (plus the C log_test 122 + probe_test 28 contract
# sanity), and the goldens were then captured from the Zig side, i.e.
# golden == the C oracle's verified behavior.  `--pin` re-captures goldens
# from the Zig side (not a C oracle rebuild — the C oracle is gone).
set -e
cd "$(dirname "$0")/.."
GOLDEN=zig/golden/log_probe
PIN=0
[ "${1:-}" = "--pin" ] && PIN=1

echo "== building Zig port + live driver =="
( cd zig && zig build -Doptimize=ReleaseSafe )
LIVE=zig/zig-out/bin/log_probe_live

mkdir -p "$GOLDEN"

pass=0; fail=0

echo "== live log+probe regression vs goldens =="
mode=check
[ "$PIN" = 1 ] && mode=pin
if "$LIVE" "$mode" "$GOLDEN" > /tmp/log_probe_live.out 2>&1; then
    pass=$((pass + 1))
    n=$(tail -1 /tmp/log_probe_live.out)
    if [ "$PIN" = 1 ]; then
        echo "PIN log+probe goldens ($n)"
    else
        echo "PASS live log+probe regression ($n)"
    fi
    grep -c "    OK " /tmp/log_probe_live.out | sed 's/^/    golden+assertion groups OK: /'
else
    fail=$((fail + 1))
    echo "FAIL live log+probe regression"
    sed 's/^/    /' /tmp/log_probe_live.out
fi

echo "log_probe_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
