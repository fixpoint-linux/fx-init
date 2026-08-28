// supervise.zig — faithful Zig port of src/fx_supervise.c: the pure
// supervision helpers extracted from the fx-init supervisor (fx-init.c).
//
//   fx_sock_ready        — on=sock:tcp/unix readiness gate AND Tcp/Unix probe
//   fx_backoff_*         — restart backoff (sleep / next / 60s-stable reset)
//   fx_boot_deadline_ms  — boot grace deadline (ms-precision, no /1000 truncation)
//   fx_boot_grace_expired
//
// Constants FX_BACKOFF_CAP_MS=30000 / FX_BACKOFF_STABLE_MS=60000 are copied
// verbatim from fx_supervise.h.  fx_sock_ready keeps the C connect contract:
// AF_INET 127.0.0.1:<decimal port> with a 250ms SO_SNDTIMEO, or AF_UNIX at
// the given path; NULL/empty arg short-circuits to 0 before any socket() —
// the socket syscalls go through the same libc externs the sibling dhall-c
// zig core uses (std.posix has no socket/connect in 0.16).
const std = @import("std");

pub const FX_BACKOFF_CAP_MS: u32 = 30000; // doubling cap (30s)
pub const FX_BACKOFF_STABLE_MS: u32 = 60000; // reset to base after 60s ST_STARTED

// ─── on=sock: readiness gate + Tcp/Unix probe ─────────────────────────────
// libc declarations (not exposed by std.posix in 0.16; same pattern as the
// dhall-c zig core's http.zig).

const AF_INET: c_int = 2;
const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const SOL_SOCKET: c_int = 1;
const SO_SNDTIMEO: c_int = 21; // Linux

const Timeval = extern struct { tv_sec: i64, tv_usec: i64 };

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const std.c.sockaddr, len: c_uint) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;

const SockaddrIn = extern struct {
    family: u16, // sa_family_t
    port: u16, // network byte order
    addr: u32, // network byte order
    zero: [8]u8 = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
};

const SockaddrUn = extern struct {
    family: u16, // sa_family_t
    path: [108]u8,
};

/// Byte-order helpers (glibc htons/htonl on little-endian = byte swap; both
/// functions are identity on big-endian, mirroring the C macros).
fn htons(v: u16) u16 {
    return if (native_endian == .little) @byteSwap(v) else v;
}
fn htonl(v: u32) u32 {
    return if (native_endian == .little) @byteSwap(v) else v;
}
const native_endian = @import("builtin").target.cpu.arch.endian();

/// Attempt a connect to a local readiness socket.  Returns 1 on success (the
/// socket accepts), 0 on failure (refused/timeout/no listener).  tcp=1 ->
/// AF_INET 127.0.0.1:<arg decimal port>; tcp=0 -> AF_UNIX <arg path>.
/// A NULL or empty arg returns 0 without attempting a connect.
pub fn fx_sock_ready(tcp: bool, arg: ?[]const u8) u8 {
    const a = arg orelse return 0;
    if (a.len == 0) return 0;
    // 250ms connect timeout (defensive): localhost/unix connects return fast
    // (ECONNREFUSED/ENOENT), but a slow endpoint must not hang the poll loop.
    const to = Timeval{ .tv_sec = 0, .tv_usec = 250000 };
    const fd = socket(if (tcp) AF_INET else AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &to, @sizeOf(Timeval));
    var ok: u8 = 0;
    if (tcp) {
        var sa = std.mem.zeroes(SockaddrIn);
        sa.family = AF_INET;
        sa.port = htons(strtoul16_mirror(a));
        sa.addr = htonl(0x7f000001); // 127.0.0.1
        ok = if (connect(fd, @ptrCast(&sa), @sizeOf(SockaddrIn)) == 0) 1 else 0;
    } else {
        var sa = std.mem.zeroes(SockaddrUn);
        sa.family = AF_UNIX;
        // strncpy(a.sun_path, arg, sizeof a.sun_path - 1): copies at most
        // 107 bytes, stops at its own NUL padding (zeroes), no terminator
        // added when the path is exactly sun_path-1 long.
        const n = @min(a.len, sa.path.len - 1);
        @memcpy(sa.path[0..n], a[0..n]);
        ok = if (connect(fd, @ptrCast(&sa), @sizeOf(SockaddrUn)) == 0) 1 else 0;
    }
    _ = close(fd);
    return ok;
}

/// C strtoul(arg, NULL, 10) truncated to uint16_t (the C passes the value
/// straight into htons((uint16_t)...)): optional +/-, leading base-10
/// digits, ERANGE saturation to ULONG_MAX (then the cast keeps the low 16
/// bits), value 0 when there are no digits at all.  Leading whitespace is
/// skipped exactly like strtoul.
fn strtoul16_mirror(v: []const u8) u16 {
    var i: usize = 0;
    var neg = false;
    while (i < v.len and (v[i] == ' ' or (v[i] >= 9 and v[i] <= 13))) i += 1;
    if (i < v.len and (v[i] == '+' or v[i] == '-')) {
        neg = v[i] == '-';
        i += 1;
    }
    var acc: u64 = 0;
    var sat = false;
    while (i < v.len) : (i += 1) {
        const ch = v[i];
        if (ch < '0' or ch > '9') break; // trailing garbage: ignored by strtoul
        const d: u64 = ch - '0';
        if (!sat) {
            const prod = @mulWithOverflow(acc, 10);
            const sum = @addWithOverflow(prod[0], d);
            if (prod[1] != 0 or sum[1] != 0) {
                acc = std.math.maxInt(u64); // ERANGE: saturate
                sat = true;
            } else {
                acc = sum[0];
            }
        }
    }
    if (sat) {
        // ERANGE: glibc strtoul returns ULONG_MAX and skips the sign negation
        return @truncate(std.math.maxInt(u64));
    }
    const val = if (neg) 0 -% acc else acc;
    return @truncate(val);
}

// ─── restart backoff ──────────────────────────────────────────────────────

/// Sleep duration (ms) for the next restart, given the current backoff state.
/// cur=0 => use base; base=0 => 1000; clamped to FX_BACKOFF_CAP_MS.
pub fn fx_backoff_sleep_ms(cur_backoff: u32, base_ms: u32) u32 {
    var bo = if (cur_backoff != 0) cur_backoff else base_ms;
    if (bo == 0) bo = 1000;
    if (bo > FX_BACKOFF_CAP_MS) bo = FX_BACKOFF_CAP_MS;
    return bo;
}

/// New cur_backoff to store after a restart (the slept value doubled, capped).
/// u32 wrapping multiply, then capped; a stuck-zero next (sleep_ms==0)
/// collapses to the cap — both exactly like the C on 32-bit uint math.
pub fn fx_backoff_next(sleep_ms: u32) u32 {
    var n = sleep_ms *% 2;
    if (n > FX_BACKOFF_CAP_MS) n = FX_BACKOFF_CAP_MS;
    if (n == 0) n = FX_BACKOFF_CAP_MS;
    return n;
}

/// 1 if a service that has been ST_STARTED for `stable_ms` should reset its
/// accumulated backoff to base (the design's "reset after 60s stable").
pub fn fx_backoff_should_reset(stable_ms: u32) u8 {
    return if (stable_ms >= FX_BACKOFF_STABLE_MS) 1 else 0;
}

// ─── boot grace deadline (ms-precision) ───────────────────────────────────

/// Absolute ms deadline = start_ms + grace_ms (wrapping u64 add, like the C).
pub fn fx_boot_deadline_ms(start_ms: u64, grace_ms: u32) u64 {
    return start_ms +% grace_ms;
}

/// 1 if `now_ms` has reached/passed the deadline.
pub fn fx_boot_grace_expired(now_ms: u64, deadline_ms: u64) u8 {
    return if (now_ms >= deadline_ms) 1 else 0;
}

// ─── tests (pin the supervise_test.c contract) ────────────────────────────

test "backoff: sleep/next/reset" {
    try std.testing.expectEqual(@as(u32, 1000), fx_backoff_sleep_ms(0, 1000));
    try std.testing.expectEqual(@as(u32, 200), fx_backoff_sleep_ms(0, 200));
    try std.testing.expectEqual(@as(u32, 1000), fx_backoff_sleep_ms(0, 0));
    try std.testing.expectEqual(@as(u32, 4000), fx_backoff_sleep_ms(4000, 1000));
    try std.testing.expectEqual(@as(u32, 30000), fx_backoff_sleep_ms(99999, 1000));
    try std.testing.expectEqual(@as(u32, 30000), fx_backoff_sleep_ms(0, 99999));
    try std.testing.expectEqual(@as(u32, 2000), fx_backoff_next(1000));
    try std.testing.expectEqual(@as(u32, 4000), fx_backoff_next(2000));
    try std.testing.expectEqual(@as(u32, 30000), fx_backoff_next(20000));
    try std.testing.expectEqual(@as(u32, 30000), fx_backoff_next(30000));
    try std.testing.expectEqual(@as(u8, 0), fx_backoff_should_reset(0));
    try std.testing.expectEqual(@as(u8, 0), fx_backoff_should_reset(59999));
    try std.testing.expectEqual(@as(u8, 1), fx_backoff_should_reset(60000));
    try std.testing.expectEqual(@as(u8, 1), fx_backoff_should_reset(120000));
    // crash-restart-stable-reset cycle (base=200)
    var cur: u32 = 0;
    var s = fx_backoff_sleep_ms(cur, 200);
    cur = fx_backoff_next(s);
    try std.testing.expectEqual(@as(u32, 200), s);
    try std.testing.expectEqual(@as(u32, 400), cur);
    s = fx_backoff_sleep_ms(cur, 200);
    cur = fx_backoff_next(s);
    try std.testing.expectEqual(@as(u32, 400), s);
    try std.testing.expectEqual(@as(u32, 800), cur);
    cur = 0;
    try std.testing.expectEqual(@as(u32, 200), fx_backoff_sleep_ms(cur, 200));
}

test "grace: ms-precision deadline" {
    try std.testing.expectEqual(@as(u64, 1500), fx_boot_deadline_ms(0, 1500));
    try std.testing.expectEqual(@as(u64, 500), fx_boot_deadline_ms(0, 500));
    try std.testing.expectEqual(@as(u64, 2000), fx_boot_deadline_ms(0, 2000));
    try std.testing.expectEqual(@as(u64, 30000), fx_boot_deadline_ms(0, 30000));
    try std.testing.expectEqual(@as(u64, 101500), fx_boot_deadline_ms(100000, 1500));
    try std.testing.expectEqual(@as(u8, 0), fx_boot_grace_expired(1499, 1500));
    try std.testing.expectEqual(@as(u8, 1), fx_boot_grace_expired(1500, 1500));
    try std.testing.expectEqual(@as(u8, 1), fx_boot_grace_expired(2000, 1500));
    try std.testing.expectEqual(@as(u8, 1), fx_boot_grace_expired(0, 0));
}

test "sock_ready: pure-input cases (no listener needed)" {
    try std.testing.expectEqual(@as(u8, 0), fx_sock_ready(true, null));
    try std.testing.expectEqual(@as(u8, 0), fx_sock_ready(true, ""));
    try std.testing.expectEqual(@as(u8, 0), fx_sock_ready(false, null));
    try std.testing.expectEqual(@as(u8, 0), fx_sock_ready(false, "/run/fx/does-not-exist-xyz"));
}
