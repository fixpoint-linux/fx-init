#!/bin/sh
# reloc_diff.sh — regression harness for the Zig buildfile store-root
# rewrite (zig/src/reloc_check.zig) over every corpus buildfile
# (zig/corpus-reloc/) × a fixed set of new_store values; fails on ANY
# difference in stdout, stderr, or exit code against the pinned golden
# files (zig/golden/reloc/).
#
# Golden provenance: this was a LIVE differential against the C oracle
# (zig/reloc_dump.c + src/fx_reloc.c) — the last pre-deletion live run
# (2026-08-29, C oracle still present) passed 104/104 byte-identical, and
# the goldens were then captured from the Zig side, i.e. golden == the C
# oracle's verified behavior.  `--pin` re-captures goldens from the Zig
# side (for corpus changes); it is NOT a C oracle rebuild — the C oracle
# no longer exists in this repo.
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
GOLDEN=zig/golden/reloc
PIN=0
[ "${1:-}" = "--pin" ] && PIN=1

echo "== building Zig port =="
( cd zig && zig build -Doptimize=ReleaseSafe )
CHECK=zig/zig-out/bin/reloc_check

mkdir -p "$GOLDEN"

# new_store sweep: grow, shrink, equal-ish, empty, single-char
NEW_STORES="/fx/store /tmp/s /a ''"

pass=0; fail=0
for f in zig/corpus-reloc/*.dhall; do
    name=$(basename "$f")
    for ns in $NEW_STORES; do
        # eval so the quoted empty string stays one (empty) arg
        eval "set -- $ns"
        case "$1" in
            /fx/store) lbl=fx-store ;;
            /tmp/s) lbl=tmp-s ;;
            /a) lbl=a ;;
            "") lbl=empty ;;
            *) lbl=other ;;
        esac
        gname="$name.__$lbl"
        check_rc=0

        "$CHECK" "$f" "$1" >"/tmp/reloc_check.$name.out" 2>"/tmp/reloc_check.$name.err" || check_rc=$?

        if [ "$PIN" = 1 ]; then
            cp "/tmp/reloc_check.$name.out" "$GOLDEN/$gname.out"
            cp "/tmp/reloc_check.$name.err" "$GOLDEN/$gname.err"
            echo "$check_rc" > "$GOLDEN/$gname.rc"
            echo "PIN $name ns='$1' (rc=$check_rc)"
            pass=$((pass + 1))
            continue
        fi

        ok=1
        diff -u "$GOLDEN/$gname.out" "/tmp/reloc_check.$name.out" >"/tmp/reloc.d.out" 2>&1 || ok=0
        diff -u "$GOLDEN/$gname.err" "/tmp/reloc_check.$name.err" >"/tmp/reloc.d.err" 2>&1 || ok=0
        [ "$check_rc" = "$(cat "$GOLDEN/$gname.rc")" ] || ok=0

        if [ "$ok" = 1 ]; then
            pass=$((pass + 1))
            echo "PASS $name ns='$1' (rc=$check_rc)"
        else
            fail=$((fail + 1))
            echo "FAIL $name ns='$1' (golden rc=$(cat "$GOLDEN/$gname.rc"), check rc=$check_rc)"
            sed 's/^/    out: /' /tmp/reloc.d.out
            sed 's/^/    err: /' /tmp/reloc.d.err
        fi
    done
done

echo "reloc_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
