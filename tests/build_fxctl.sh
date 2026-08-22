#!/bin/sh
# Build fxctl (U-D) — pure-POSIX control/query client, no external deps.
cd /workspace/fx-init
mkdir -p build-tmp
INC="-I src"
echo "[fxctl] compiling..."
cosmocc -std=c11 -O2 -g -Wall -Wextra $INC -o build-tmp/fxctl src/fxctl.c 2>build-tmp/fxctl.err
echo "[fxctl] exit=$?  (errors in build-tmp/fxctl.err)"
