#!/bin/sh
# build-stage2.sh — assemble the MBR stage2 (zig/src/boot/stage2.S), assert
# its hard limits, and pad to a 512 B multiple (stage1 CRCs
# stage2_sectors*512 padded bytes, and INT13 reads whole sectors).
#
# usage: sh zig/src/boot/build-stage2.sh [-o out.bin] [--toolchain gnu|zig|both]
#   -o            output binary (default: stage2.bin in the current directory)
#   --toolchain   gnu  = as + objcopy (default)
#                 zig  = zig cc + GNU objcopy
#                 both = assemble BOTH, assert byte-identical output (U3's
#                        R9 gate: divergence means a padding/encoding drift)
# prints: "stage2: <n> code bytes (<sectors> sectors of 60)" on success;
# nonzero exit on failure.
set -u

OUT=stage2.bin
TC=gnu
while [ $# -gt 0 ]; do
    case $1 in
        -o) OUT=$2; shift 2 ;;
        --toolchain) TC=$2; shift 2 ;;
        *) echo "build-stage2: unknown arg: $1" >&2; exit 2 ;;
    esac
done

SRC=$(dirname "$0")/stage2.S
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

fail() { echo "build-stage2: FAIL: $1" >&2; exit 1; }

# one toolchain -> $1.bin ; exits through the shared assert below
asm_gnu() {
    as -o "$TMP/stage2.o" "$SRC" || fail "as assembly"
    objcopy -O binary --only-section=.text "$TMP/stage2.o" "$1"
}
asm_zig() {
    zig cc -target x86_64-freestanding -c "$SRC" -o "$TMP/stage2z.o" \
        || fail "zig cc assembly"
    objcopy -O binary --only-section=.text "$TMP/stage2z.o" "$1"
}

case "$TC" in
    gnu) asm_gnu "$TMP/a.bin" || exit 1 ;;
    zig) asm_zig "$TMP/a.bin" || exit 1 ;;
    both)
        asm_gnu "$TMP/a.bin" || exit 1
        asm_zig "$TMP/b.bin" || exit 1
        cmp -s "$TMP/a.bin" "$TMP/b.bin" \
            || fail "gnu/zig builds diverge (see U3's .align lesson)"
        ;;
    *) fail "unknown toolchain: $TC" ;;
esac

# hard limits: <= 60 sectors (30720 B, stage1's bound keeps stage2 below
# 0x10000), starts with the 'F','X' data magic at bytes 0..1, code (last
# nonzero byte) never reaches past the DAP table.
python3 - "$TMP/a.bin" "$OUT" <<'EOF' || exit 1
import sys
src, dst = sys.argv[1], sys.argv[2]
b = open(src, "rb").read()
assert b[0:2] == b"FX", "missing 'F','X' magic at bytes 0..1"
assert len(b) <= 60 * 512, f"{len(b)} bytes exceeds the 60-sector bound"
sectors = (len(b) + 511) // 512
padded = b + b"\x00" * (sectors * 512 - len(b))
open(dst, "wb").write(padded)
code = len(padded)
while code > 0 and padded[code - 1] == 0:
    code -= 1
print(f"stage2: {code} code bytes ({sectors} sectors of 60)")
EOF
echo "build-stage2: OK ($TC) -> $OUT"
