// supervise_check.zig — CLI twin of the C oracle zig/supervise_dump.c:
// drives the Zig port (supervise.zig) over the SAME deterministic sweep and
// prints one line per case in the SAME format, so supervise_diff.sh can
// byte-diff stdout+rc against the oracle.  fx_sock_ready is NOT swept here
// (live I/O; exercised separately against real sockets by supervise_diff.sh).
const std = @import("std");
const sup = @import("supervise");

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    // ── fx_backoff_sleep_ms: cur x base ───────────────────────────────────
    const curs = [_]u32{
        0,       1,    500,  1000,  1500,  29999, 30000, 30001,
        0xFFFFFFFF, // wrap-around top
    };
    const bases = [_]u32{ 0, 1, 999, 1000, 29999, 30000 };
    for (curs) |cu| {
        for (bases) |base| {
            try out.print("sleep({d},{d})={d}\n", .{ cu, base, sup.fx_backoff_sleep_ms(cu, base) });
        }
    }

    // ── fx_backoff_next: boundary set + u32 overflow (15000000*2 wraps) ──
    const sleeps = [_]u32{
        0, 1, 2, 999, 1000, 14999, 15000, 15001, 20000, 29999, 30000,
        30001, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
    };
    for (sleeps) |s| {
        try out.print("next({d})={d}\n", .{ s, sup.fx_backoff_next(s) });
    }

    // ── fx_backoff_should_reset: 60s boundary ─────────────────────────────
    const stables = [_]u32{ 0, 1, 59998, 59999, 60000, 60001, 120000, 0xFFFFFFFF };
    for (stables) |st| {
        try out.print("reset({d})={d}\n", .{ st, sup.fx_backoff_should_reset(st) });
    }

    // ── fx_boot_deadline_ms: incl u64 overflow (start near 2^64) ─────────
    const starts = [_]u64{
        0, 1, 999, 100000, 1500,
        0xFFFFFFFFFFFFFFF8, 0xFFFFFFFFFFFFFFFF, // wrap starts
    };
    const graces = [_]u32{ 0, 1, 500, 1500, 5000, 30000, 60000, 0xFFFFFFFF };
    for (starts) |st| {
        for (graces) |g| {
            try out.print("deadline({d},{d})={d}\n", .{ st, g, sup.fx_boot_deadline_ms(st, g) });
        }
    }

    // ── fx_boot_grace_expired: at/past deadline + both-max wrap ──────────
    const pairs = [_][2]u64{
        .{ 0, 0 },          .{ 0, 1 },                 .{ 1, 1 },
        .{ 1499, 1500 },    .{ 1500, 1500 },           .{ 2000, 1500 },
        .{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF },
        .{ 0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF },
    };
    for (pairs) |pr| {
        try out.print("expired({d},{d})={d}\n", .{ pr[0], pr[1], sup.fx_boot_grace_expired(pr[0], pr[1]) });
    }
    try out.flush();
}
