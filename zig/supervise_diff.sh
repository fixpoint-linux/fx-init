#!/bin/sh
# supervise_diff.sh — regression harness for the Zig supervision port
# (zig/src/supervise.zig).  Two parts:
#
#   1. PURE-MATH SWEEP vs goldens: the Zig twin (zig/src/supervise_check.zig)
#      sweeps fx_backoff_sleep_ms / fx_backoff_next / fx_backoff_should_reset
#      / fx_boot_deadline_ms / fx_boot_grace_expired over a deterministic
#      boundary+overflow grid; stdout+stderr+rc must be byte-identical to
#      the pinned goldens (zig/golden/supervise/sweep.*).  fx_sock_ready is
#      NOT part of the sweep (live I/O, part 2).
#   2. LIVE SOCKET CONTRACT: zig/supervise_live.c drives the Zig
#      fx_sock_ready against real listening AF_INET 127.0.0.1 + AF_UNIX
#      sockets and asserts the absolute 1/0 contract in every deterministic
#      state (see that file's header for the expectation table).
#
# Golden provenance: part 1 was a LIVE byte-diff against the C oracle
# (zig/supervise_dump.c + src/fx_supervise.c) — the last pre-deletion live
# run (2026-08-29, C oracle still present) was byte-identical over the full
# 141-case grid, and the goldens were then captured from the Zig side,
# i.e. golden == the C oracle's verified behavior.  `--pin` re-captures
# the sweep goldens from the Zig side; it is NOT a C oracle rebuild — the
# C oracle no longer exists in this repo.
set -e
cd "$(dirname "$0")/.."
GOLDEN=zig/golden/supervise
PIN=0
[ "${1:-}" = "--pin" ] && PIN=1

echo "== building Zig port =="
( cd zig && zig build -Doptimize=ReleaseSafe )
CHECK=zig/zig-out/bin/supervise_check

mkdir -p "$GOLDEN"

pass=0; fail=0

# ── part 1: pure-math sweep, byte-identical to the goldens ────────────────
sweep_rc=0
"$CHECK" >"/tmp/supervise_check.out" 2>"/tmp/supervise_check.err" || sweep_rc=$?

if [ "$PIN" = 1 ]; then
    cp "/tmp/supervise_check.out" "$GOLDEN/sweep.out"
    cp "/tmp/supervise_check.err" "$GOLDEN/sweep.err"
    echo "$sweep_rc" > "$GOLDEN/sweep.rc"
    echo "PIN pure-math sweep ($(wc -l < /tmp/supervise_check.out) cases, rc=$sweep_rc)"
    pass=$((pass + 1))
else
    ok=1
    cmp -s "$GOLDEN/sweep.out" "/tmp/supervise_check.out" || ok=0
    cmp -s "$GOLDEN/sweep.err" "/tmp/supervise_check.err" || ok=0
    [ "$sweep_rc" = "$(cat "$GOLDEN/sweep.rc")" ] || ok=0

    if [ "$ok" = 1 ]; then
        pass=$((pass + 1))
        echo "PASS pure-math sweep ($(wc -l < /tmp/supervise_check.out) cases, rc=$sweep_rc)"
    else
        fail=$((fail + 1))
        echo "FAIL pure-math sweep (golden rc=$(cat "$GOLDEN/sweep.rc"), check rc=$sweep_rc)"
        diff -u "$GOLDEN/sweep.out" "/tmp/supervise_check.out" | sed 's/^/    out: /'
    fi
fi

# ── part 2: live fx_sock_ready — absolute contract on real sockets ────────
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
    -o "$LIVE" zig/supervise_live.c /tmp/supervise_extern.o -lc
if "$LIVE" >"/tmp/supervise_live.out" 2>&1; then
    pass=$((pass + 1))
    echo "PASS live fx_sock_ready (absolute contract on real TCP+UNIX sockets)"
    sed 's/^/    /' "/tmp/supervise_live.out"
else
    fail=$((fail + 1))
    echo "FAIL live fx_sock_ready"
    sed 's/^/    /' "/tmp/supervise_live.out"
fi

echo "supervise_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
