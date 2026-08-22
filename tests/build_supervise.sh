#!/bin/sh
# tests/build_supervise.sh — build the fx_supervise unit test (supervise_test).
# Links supervise_test.c + src/fx_supervise.c only — the helpers are pure (no
# store DB, no fxstore, no dhall-c, no dafsa).  fx_sock_ready uses real
# AF_INET/AF_UNIX sockets (the test creates listening sockets).
set -e
cd "$(dirname "$0")/.."
mkdir -p build-tmp
cosmocc -std=c11 -O2 -g -Wall -Wextra -I src -o build-tmp/supervise_test \
    tests/supervise_test.c src/fx_supervise.c
echo "supervise_test built"
