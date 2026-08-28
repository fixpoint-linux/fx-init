#!/bin/sh
# config_diff.sh — differential harness: run the Zig port (config_check)
# against the C oracle (config_dump) on every corpus file; fail on ANY
# difference in stdout, stderr, or exit code.  (The dafsa/dhall-c *_diff.sh
# pattern.)
#
# Builds both binaries first:
#   - oracle: zig cc (gnu11; -std=c11 hides POSIX strdup) config_dump.c +
#     src/config.c + the vendored dhall-c 13 C files
#   - port:   zig build -Doptimize=ReleaseSafe
set -e
DUMP_RC=0; CHECK_RC=0
cd "$(dirname "$0")/.."

echo "== building C oracle =="
DHALLC="vendor/dhall-c/src/arena.c vendor/dhall-c/src/lexer.c \
vendor/dhall-c/src/parser.c vendor/dhall-c/src/ast.c \
vendor/dhall-c/src/normalize.c vendor/dhall-c/src/typecheck.c \
vendor/dhall-c/src/builtins.c vendor/dhall-c/src/serialize.c \
vendor/dhall-c/src/import.c vendor/dhall-c/src/bignum.c \
vendor/dhall-c/src/sha256.c vendor/dhall-c/src/ssrf.c \
vendor/dhall-c/src/http.c"
zig cc -std=gnu11 -O2 -Wall -Wextra \
    -I src -I vendor/fxstore -I vendor/dhall-c/src \
    -o zig/zig-out/config_dump zig/config_dump.c src/config.c $DHALLC
echo "config_dump built"

echo "== building Zig port =="
( cd zig && zig build -Doptimize=ReleaseSafe )
CHECK=zig/zig-out/bin/config_check
DUMP=zig/zig-out/config_dump

pass=0; fail=0
for f in zig/corpus/*.dhall; do
    name=$(basename "$f")
    dump_rc=0; check_rc=0

    "$DUMP" "$f" >"/tmp/dump.$name.out" 2>"/tmp/dump.$name.err" || dump_rc=$?
    "$CHECK" "$f" >"/tmp/check.$name.out" 2>"/tmp/check.$name.err" || check_rc=$?


    ok=1
    diff -u "/tmp/dump.$name.out" "/tmp/check.$name.out" >/tmp/diff.out 2>&1 || ok=0
    diff -u "/tmp/dump.$name.err" "/tmp/check.$name.err" >/tmp/diff.err 2>&1 || ok=0
    [ "$dump_rc" = "$check_rc" ] || ok=0

    if [ "$ok" = 1 ]; then
        pass=$((pass + 1))
        echo "PASS $name (rc=$dump_rc)"
    else
        fail=$((fail + 1))
        echo "FAIL $name (dump rc=$dump_rc, check rc=$check_rc)"
        sed 's/^/    out: /' /tmp/diff.out
        sed 's/^/    err: /' /tmp/diff.err
    fi
done

echo "config_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
