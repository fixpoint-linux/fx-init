#!/bin/sh
# reloc_diff.sh — differential harness: run the Zig port (reloc_check)
# against the C oracle (reloc_dump) on every corpus buildfile × a fixed set
# of new_store values; fail on ANY difference in stdout, stderr, or exit
# code.  (The dafsa/dhall-c *_diff.sh pattern, like config_diff.sh.)
#
# Builds both binaries first:
#   - oracle: zig cc (gnu11) zig/reloc_dump.c + src/fx_reloc.c
#   - port:   zig build -Doptimize=ReleaseSafe
#
# Corpus (zig/corpus-reloc/): all 8 reloctest.c cases (basic, no-marker,
# GEN-with-no-slash, unterminated, escaped-quote, root-"/" verbatim, multi)
# + edge cases: empty text, marker without quote, GEN at EOF (no trailing
# newline), equal-length rewrite, new_store longer/shorter (grow+shrink),
# embedded \\ and \" escapes, escaped quote before the closing quote,
# empty new_store, root-as-substring (no false rewrite), adjacent
# occurrences, marker twice (first wins), single-char root, 50-occurrence
# stress, CRLF text, no-occurrence body.
set -e
cd "$(dirname "$0")/.."

echo "== building C oracle =="
zig cc -std=gnu11 -O2 -Wall -Wextra \
    -I src -o zig/zig-out/reloc_dump zig/reloc_dump.c src/fx_reloc.c
echo "reloc_dump built"

echo "== building Zig port =="
( cd zig && zig build -Doptimize=ReleaseSafe )
DUMP=zig/zig-out/reloc_dump
CHECK=zig/zig-out/bin/reloc_check

# new_store sweep: grow, shrink, equal-ish, empty, single-char
NEW_STORES="/fx/store /tmp/s /a ''"

pass=0; fail=0
for f in zig/corpus-reloc/*.dhall; do
    name=$(basename "$f")
    for ns in $NEW_STORES; do
        # eval so the quoted empty string stays one (empty) arg
        eval "set -- $ns"
        dump_rc=0; check_rc=0

        "$DUMP" "$f" "$1" >"/tmp/reloc_dump.$name.out" 2>"/tmp/reloc_dump.$name.err" || dump_rc=$?
        "$CHECK" "$f" "$1" >"/tmp/reloc_check.$name.out" 2>"/tmp/reloc_check.$name.err" || check_rc=$?

        ok=1
        cmp -s "/tmp/reloc_dump.$name.out" "/tmp/reloc_check.$name.out" || ok=0
        cmp -s "/tmp/reloc_dump.$name.err" "/tmp/reloc_check.$name.err" || ok=0
        [ "$dump_rc" = "$check_rc" ] || ok=0

        if [ "$ok" = 1 ]; then
            pass=$((pass + 1))
            echo "PASS $name ns='$1' (rc=$dump_rc)"
        else
            fail=$((fail + 1))
            echo "FAIL $name ns='$1' (dump rc=$dump_rc, check rc=$check_rc)"
            diff -u "/tmp/reloc_dump.$name.out" "/tmp/reloc_check.$name.out" | sed 's/^/    out: /'
            diff -u "/tmp/reloc_dump.$name.err" "/tmp/reloc_check.$name.err" | sed 's/^/    err: /'
        fi
    done
done

echo "reloc_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
