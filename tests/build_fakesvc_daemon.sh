#!/bin/sh
# Build the fakesvc_daemon fixture (daemonizing-service + pid1 probe) standalone,
# for a quick compile check.  The m3 closure build (via package-set.dhall's
# fake-service-daemon package) is what tests/fxinit_pid1.sh actually relies on;
# this script just verifies the fixture itself compiles with cosmocc.
cd "$(dirname "$0")/.." || exit 1
mkdir -p build-tmp
echo "[fakesvc_daemon] compiling..."
cosmocc -std=c11 -O2 -g -Wall -Wextra -o build-tmp/fakesvc_daemon \
    tests/fixtures/fakesvc_daemon/fakesvc_daemon.c 2>build-tmp/fakesvc_daemon.err
echo "[fakesvc_daemon] exit=$?  (errors in build-tmp/fakesvc_daemon.err)"
