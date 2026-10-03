#!/bin/sh
# build-stage1.sh — assemble the MBR stage1 (zig/src/boot/stage1.S) and assert
# its hard limits. Used by the fx-image builder (U2) and the boot harnesses.
#
# usage: sh zig/src/boot/build-stage1.sh [-o out.bin] [--toolchain gnu|zig]
#   -o          output binary (default: stage1.bin in the current directory)
#   --toolchain gnu = as + objcopy (default)
#                 zig = zig cc + zig objcopy, GNU objcopy fallback
# prints: "stage1: <n> code bytes (of 446)" on success; nonzero exit on failure.
set -u

OUT=stage1.bin
TC=gnu
while [ $# -gt 0 ]; do
    case $1 in
        -o) OUT=$2; shift 2 ;;
        --toolchain) TC=$2; shift 2 ;;
        *) echo "build-stage1: unknown arg: $1" >&2; exit 2 ;;
    esac
done

SRC=$(dirname "$0")/stage1.S
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
OBJ="$TMP/stage1.o"

fail() { echo "build-stage1: FAIL: $1" >&2; exit 1; }

if [ "$TC" = gnu ]; then
    as -o "$OBJ" "$SRC" || fail "as assembly"
else
    zig cc -target x86_64-freestanding -c "$SRC" -o "$OBJ" || fail "zig cc assembly"
fi
# stage1 imports nothing; an undefined symbol means a typo'd constant that
# silently assembles as 0 (the #define-vs-gas trap), so fail the build on it.
nm -u "$OBJ" | grep -q . && fail "undefined symbols: $(nm -u "$OBJ" | tr '\n' ' ')"
objcopy -O binary --only-section=.text "$OBJ" "$OUT" || fail "objcopy"

# hard limits: 512 bytes total, 55 AA at 510, zero partition table,
# code (nonzero bytes) must not reach into the table area at all.
[ "$(wc -c < "$OUT")" -eq 512 ] || fail "output is $(wc -c < "$OUT") bytes, not 512"
python3 - "$OUT" <<'EOF' || exit 1
import sys
b = open(sys.argv[1], "rb").read()
assert len(b) == 512, "size"
assert b[510:512] == b"\x55\xaa", "signature"
assert b[446:510] == b"\x00" * 64, "partition table area not zero"
code = 446
while code > 0 and b[code - 1] == 0:
    code -= 1
print(f"stage1: {code} code bytes (of 446)")
EOF
echo "build-stage1: OK ($TC) -> $OUT"
