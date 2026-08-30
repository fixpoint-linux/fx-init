#!/bin/sh
# config_diff.sh — regression harness for the Zig config walker
# (zig/src/config_check.zig) over the whole corpus (zig/corpus/*.dhall);
# fails on ANY difference in stdout, stderr, or exit code against the
# pinned golden files (zig/golden/config/).
#
# Golden provenance: this was a LIVE differential against the C oracle
# (zig/config_dump.c + src/config.c + the vendored dhall-c 13) — the last
# pre-deletion live run (2026-08-29, C oracle still present) passed 26/26
# byte-identical, and the goldens were then captured from the Zig side,
# i.e. golden == the C oracle's verified behavior.  `--pin` re-captures
# goldens from the Zig side (for corpus changes); it is NOT a C oracle
# rebuild — the C oracle no longer exists in this repo.
set -e
cd "$(dirname "$0")/.."
GOLDEN=zig/golden/config
PIN=0
[ "${1:-}" = "--pin" ] && PIN=1

echo "== building Zig port =="
( cd zig && zig build -Doptimize=ReleaseSafe )
CHECK=zig/zig-out/bin/config_check

mkdir -p "$GOLDEN"

pass=0; fail=0
for f in zig/corpus/*.dhall; do
    name=$(basename "$f")
    check_rc=0

    "$CHECK" "$f" >"/tmp/check.$name.out" 2>"/tmp/check.$name.err" || check_rc=$?

    if [ "$PIN" = 1 ]; then
        cp "/tmp/check.$name.out" "$GOLDEN/$name.out"
        cp "/tmp/check.$name.err" "$GOLDEN/$name.err"
        echo "$check_rc" > "$GOLDEN/$name.rc"
        echo "PIN $name (rc=$check_rc)"
        pass=$((pass + 1))
        continue
    fi

    ok=1
    diff -u "$GOLDEN/$name.out" "/tmp/check.$name.out" >/tmp/diff.out 2>&1 || ok=0
    diff -u "$GOLDEN/$name.err" "/tmp/check.$name.err" >/tmp/diff.err 2>&1 || ok=0
    [ "$check_rc" = "$(cat "$GOLDEN/$name.rc")" ] || ok=0

    if [ "$ok" = 1 ]; then
        pass=$((pass + 1))
        echo "PASS $name (rc=$check_rc)"
    else
        fail=$((fail + 1))
        echo "FAIL $name (golden rc=$(cat "$GOLDEN/$name.rc"), check rc=$check_rc)"
        sed 's/^/    out: /' /tmp/diff.out
        sed 's/^/    err: /' /tmp/diff.err
    fi
done

echo "config_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
