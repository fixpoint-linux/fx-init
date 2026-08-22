#!/bin/sh
# tests/build_unit.sh — build the in-sandbox unit tests (config walker; later
# log/probe).  No fxstore build, no bwrap — just cosmocc compiles + runs.
set -e
cd "$(dirname "$0")/.."
mkdir -p build-tmp
DHALLC="vendor/dhall-c/src/arena.c vendor/dhall-c/src/lexer.c vendor/dhall-c/src/parser.c vendor/dhall-c/src/ast.c vendor/dhall-c/src/normalize.c vendor/dhall-c/src/typecheck.c vendor/dhall-c/src/builtins.c vendor/dhall-c/src/serialize.c vendor/dhall-c/src/import.c vendor/dhall-c/src/bignum.c vendor/dhall-c/src/sha256.c vendor/dhall-c/src/ssrf.c vendor/dhall-c/src/http.c"
INC="-I src -I vendor/fxstore -I vendor/dhall-c/src"
cosmocc -std=c11 -O2 -g -Wall -Wextra $INC -o build-tmp/config_test \
    tests/config_test.c src/config.c $DHALLC
echo "config_test built"
