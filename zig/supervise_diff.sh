#!/bin/sh
# supervise_diff.sh — differential harness for src/fx_supervise.c vs its Zig
# port (zig/src/supervise.zig).  Two parts:
#
#   1. PURE-MATH DIFF: the C oracle (zig/supervise_dump.c) and the Zig twin
#      (zig/src/supervise_check.zig) sweep fx_backoff_sleep_ms /
#      fx_backoff_next / fx_backoff_should_reset / fx_boot_deadline_ms /
#      fx_boot_grace_expired over a deterministic boundary+overflow grid;
#      stdout+rc must be byte-identical.  fx_sock_ready is NOT part of the
#      sweep (live I/O).
#   2. LIVE SOCKET TEST: real listening AF_INET 127.0.0.1 + AF_UNIX sockets
#      (the supervise_test.c contract) — the C fx_sock_ready and the Zig
#      fx_sock_ready must return the SAME 1/0 against each state: listening,
#      after close (TCP) / close+unlink (UNIX), NULL/empty/nonexistent args.
#
# Builds both binaries first (oracle: zig cc gnu11; port: zig build).
set -e
cd "$(dirname "$0")/.."

echo "== building C oracle =="
zig cc -std=gnu11 -O2 -Wall -Wextra \
    -I src -o zig/zig-out/supervise_dump zig/supervise_dump.c src/fx_supervise.c
echo "supervise_dump built"

echo "== building Zig port =="
( cd zig && zig build -Doptimize=ReleaseSafe )
DUMP=zig/zig-out/supervise_dump
CHECK=zig/zig-out/bin/supervise_check

pass=0; fail=0

# ── part 1: pure-math sweep, byte-identical stdout+rc ─────────────────────
dump_rc=0; check_rc=0
"$DUMP" >"/tmp/supervise_dump.out" 2>"/tmp/supervise_dump.err" || dump_rc=$?
"$CHECK" >"/tmp/supervise_check.out" 2>"/tmp/supervise_check.err" || check_rc=$?

ok=1
cmp -s "/tmp/supervise_dump.out" "/tmp/supervise_check.out" || ok=0
cmp -s "/tmp/supervise_dump.err" "/tmp/supervise_check.err" || ok=0
[ "$dump_rc" = "$check_rc" ] || ok=0

if [ "$ok" = 1 ]; then
    pass=$((pass + 1))
    echo "PASS pure-math sweep ($(wc -l < /tmp/supervise_dump.out) cases, rc=$dump_rc)"
else
    fail=$((fail + 1))
    echo "FAIL pure-math sweep (dump rc=$dump_rc, check rc=$check_rc)"
    diff -u "/tmp/supervise_dump.out" "/tmp/supervise_check.out" | sed 's/^/    out: /'
fi

# ── part 2: live fx_sock_ready — C and Zig must agree on real sockets ─────
# The Zig side is exported as `zig_fx_sock_ready` through a tiny wrapper
# compiled to an object with zig build-obj, linked into the live driver.
LIVE=/tmp/supervise_live
cat > /tmp/supervise_extern.zig <<'EOF'
const std = @import("std");
const sup = @import("supervise");
export fn zig_fx_sock_ready(tcp: c_int, arg: ?[*:0]const u8) c_int {
    const a: ?[]const u8 = if (arg) |p| std.mem.span(p) else null;
    return @as(c_int, sup.fx_sock_ready(tcp != 0, a));
}
EOF
( cd zig && zig build-obj -Doptimize=ReleaseSafe -lc \
    --dep supervise -Mroot=/tmp/supervise_extern.zig \
    -Msupervise=src/supervise.zig \
    -femit-bin=/tmp/supervise_extern.o )
zig cc -std=gnu11 -O2 -Wall -Wextra \
    -I src -o "$LIVE" zig/supervise_live.c src/fx_supervise.c /tmp/supervise_extern.o -lc
if "$LIVE" >"/tmp/supervise_live.out" 2>&1; then
    pass=$((pass + 1))
    echo "PASS live fx_sock_ready (C-vs-Zig agreement on real TCP+UNIX sockets)"
    sed 's/^/    /' "/tmp/supervise_live.out"
else
    fail=$((fail + 1))
    echo "FAIL live fx_sock_ready"
    sed 's/^/    /' "/tmp/supervise_live.out"
fi

echo "supervise_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
