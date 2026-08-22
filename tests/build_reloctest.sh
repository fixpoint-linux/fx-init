#!/bin/sh
# tests/build_reloctest.sh — build the fx_reloc unit test (reloctest).
# Links reloctest.c + src/fx_reloc.c only — the rewrite is a pure string
# transform with no store DB, no fxstore, no dhall-c, no bwrap dependency.
set -e
cd "$(dirname "$0")/.."
mkdir -p build-tmp
cosmocc -std=c11 -O2 -g -Wall -Wextra -I src -o build-tmp/reloctest \
    tests/reloctest.c src/fx_reloc.c
echo "reloctest built"
