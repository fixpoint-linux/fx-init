// fxctl.zig — faithful Zig port of src/fxctl.c: the fx-init control/query
// client.  A pure POSIX client linking NOTHING from vendor: it maps the
// subcommands to ONE newline-terminated request line over
// $FX_RUN/control.sock (default /run/fx, FX_SOCKET overrides the full path)
// and streams the response lines to stdout, terminating on `OK` (exit 0) or
// `ERR <msg>` (exit 1).  fxctl never opens a datalog DB directly — all reads
// go through the socket (the actor/sole-writer model: dl_open takes a
// process-lifetime exclusive lock, so direct access would block fx-init).
//
// Fidelity notes (mirrors the C exactly):
//   - requestLine: args joined with single spaces, each arg wrapped in `"`
//     when empty or containing space/tab, NO escaping, capped at
//     LINE_MAX_REQ=4096 (chars past the cap are dropped, like the C's
//     `off < sizeof req - 1` guards); usage + rc 2 with no subcommand.
//   - sockPath: FX_SOCKET (non-empty) > FX_RUN/control.sock > /run/fx,
//     snprintf-truncated to a 512-byte buf.
//   - connectSock: AF_UNIX SOCK_STREAM, SO_RCVTIMEO + SO_SNDTIMEO 5s,
//     sun_path truncated to 107 bytes over a zeroed sockaddr.
//   - readResponse: fgets(8192) line loop — a line longer than 8191 arrives
//     in 8191-char chunks, each printed as its own data line; only the
//     strlen view (up to the first NUL) is matched/printed; a final
//     unterminated chunk still classifies ("OK" + EOF -> rc 0).  EOF/read
//     error before OK/ERR -> "no response (timeout/disconnect)" rc 1.
// The socket syscalls go through the same libc externs the sibling ports
// use (std.posix has no socket/connect in 0.16 — see supervise.zig).
//
// Chardev mode (this port's addition; no C original): `--chardev PATH`
// anywhere in argv, or a non-empty FX_CHARDEV env, selects a bidirectional
// virtio chardev connection (a qemu unix chardev socket or a /dev/vportNpM
// node) opened O_RDWR INSTEAD of the control socket.  The request grammar
// is IDENTICAL — the guest side (init.zig handle_virtio) feeds the same
// lines to handle_request — so requestLine/readResponse are reused
// unchanged.  Two deliberate differences from the socket path:
//   - NO half-close, ever: MEASURED (init.zig handle_virtio), a chardev
//     write-side shutdown makes qemu tear the port down before the guest's
//     response write, silently dropping it — the fd is closed only after
//     readResponse returns.
//   - a plain fd has no SO_RCVTIMEO, so PollSource gates every read with
//     poll(2) under the same 5s budget connectSock sets on the socket; a
//     silent guest cannot wedge the client.
// usage() is deliberately NOT extended: its bytes are pinned by the
// fxctl_diff.sh goldens (zig/golden/fxctl-live) and the fixture oracle
// zig/fxctl_dump.c, neither of which this change may touch.
const std = @import("std");

pub const LINE_MAX_REQ: usize = 4096;

// libc declarations (supervise.zig pattern).
const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const SOL_SOCKET: c_int = 1;
const SO_RCVTIMEO: c_int = 20; // Linux
const SO_SNDTIMEO: c_int = 21; // Linux

const EINTR: c_int = 4;
const ENOENT: c_int = 2;
const EAFNOSUPPORT: c_int = 97;
const ENOTSUP: c_int = 95; // == EOPNOTSUPP on Linux
const EPROTONOSUPPORT: c_int = 93;
const ECONNREFUSED: c_int = 111;
const EAGAIN: c_int = 11;
const ENXIO: c_int = 6;

const Timeval = extern struct { tv_sec: i64, tv_usec: i64 };

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const std.c.sockaddr, len: c_uint) c_int;
extern "c" fn setsockopt(fd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn __errno_location() *c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;

// open(2) for the chardev path, exactly as the guest-facing ports call it
// (init.zig): O_RDWR = 2.  No O_NONBLOCK — a blocking chardev read is fine
// because PollSource only calls it after poll(2) reports data (and the one
// consumer of a non-socket fd needs no socket timeouts).
const O_RDWR: c_int = 2;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;

fn errno() c_int {
    return __errno_location().*;
}

const SockaddrUn = extern struct {
    family: u16, // sa_family_t
    path: [108]u8,
};

/// sock_path() (fxctl.c:36-44): FX_SOCKET wins when set and non-empty,
/// else <FX_RUN|/run/fx>/control.sock snprintf'd (truncated) into `buf`.
pub fn sockPath(buf: []u8, fx_socket: ?[]const u8, fx_run: ?[]const u8) []const u8 {
    if (fx_socket) |s| {
        if (s.len > 0) return s;
    }
    var run: []const u8 = "/run/fx";
    if (fx_run) |r| {
        if (r.len > 0) run = r;
    }
    var off: usize = 0;
    for (run) |ch| {
        if (off < buf.len - 1) {
            buf[off] = ch;
            off += 1;
        }
    }
    for ("/control.sock") |ch| {
        if (off < buf.len - 1) {
            buf[off] = ch;
            off += 1;
        }
    }
    return buf[0..off];
}

/// The request-line builder from fxctl.c main() (fxctl.c:119-134): args
/// joined with single spaces, each quoted when empty / containing space or
/// tab, no escaping, hard-capped at buf.len-1 chars (the C's buf is
/// LINE_MAX_REQ).  Returns the built prefix of `buf`.
pub fn requestLine(buf: []u8, args: []const []const u8) []const u8 {
    var off: usize = 0;
    for (args, 0..) |a, i| {
        if (i > 0) {
            if (off < buf.len - 1) {
                buf[off] = ' ';
                off += 1;
            }
        }
        // quote if it contains spaces or is empty
        const quote = a.len == 0 or std.mem.indexOfAny(u8, a, " \t") != null;
        if (quote and off < buf.len - 1) {
            buf[off] = '"';
            off += 1;
        }
        for (a) |ch| {
            if (off < buf.len - 1) {
                buf[off] = ch;
                off += 1;
            }
        }
        if (quote and off < buf.len - 1) {
            buf[off] = '"';
            off += 1;
        }
    }
    return buf[0..off];
}

/// usage() (fxctl.c:107-114), byte-identical text on stderr.
pub fn usage() void {
    std.debug.print(
        "usage: fxctl <subcommand> [args]\n" ++
            "  status | q <rel> [vals..] | start|stop|restart <svc> | probe\n" ++
            "  activate <config> | rollback <ver> | shutdown\n" ++
            "  grep <regex> | search <term> [term..]\n" ++
            "env: FX_RUN (default /run/fx), FX_SOCKET (override control.sock path)\n",
        .{},
    );
}

/// connect_sock() (fxctl.c:46-64): AF_UNIX stream socket with 5s
/// SO_RCVTIMEO/SO_SNDTIMEO; the path is truncated to 107 bytes over a zeroed
/// sockaddr (the C's `pl >= sizeof a.sun_path` guard).  -1 on any failure
/// (errno left set for the caller's message, like the C).
pub fn connectSock(path: []const u8) c_int {
    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    const to = Timeval{ .tv_sec = 5, .tv_usec = 0 };
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &to, @sizeOf(Timeval));
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &to, @sizeOf(Timeval));
    var a = std.mem.zeroes(SockaddrUn);
    a.family = AF_UNIX;
    const n = @min(path.len, a.path.len - 1);
    @memcpy(a.path[0..n], path[0..n]);
    if (connect(fd, @ptrCast(&a), @sizeOf(SockaddrUn)) < 0) {
        _ = close(fd);
        return -1;
    }
    return fd;
}

/// Chardev transport selection (this port's addition): `--chardev PATH`
/// (a leading-`--` flag, so it is dropped from the request line) or the
/// FX_CHARDEV env (same non-empty rule as FX_SOCKET) picks the chardev
/// transport; null keeps the control-socket path.  The flag wins over the
/// env (FX_CHARDEV is the default, --chardev the explicit override).
pub fn chardevPath(argv: []const []const u8, fx_chardev: ?[]const u8) ?[]const u8 {
    for (argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--chardev")) {
            // bare flag: the next arg is PATH; a trailing bare flag has no
            // path, so chardev mode cannot engage (the token rides as an
            // unknown subcommand, like any other non-flag word).
            if (i + 1 < argv.len) return argv[i + 1];
            return null;
        }
        if (a.len > 10 and std.mem.eql(u8, a[0..10], "--chardev=")) return a[10..];
    }
    if (fx_chardev) |p| {
        if (p.len > 0) return p;
    }
    return null;
}

/// open(2) O_RDWR on the chardev path — the bidirectional connection the
/// plan names (NO half-close: the fd is closed only after readResponse).
/// A real virtio char device (/dev/vportNpM) opens here; a qemu unix
/// chardev SOCKET cannot be open(2)'d (MEASURED on this host: ENXIO), so
/// the miss falls through to the same AF_UNIX connect the control socket
/// uses (its 5s sockopts are harmless alongside PollSource's poll gate —
/// poll returns as soon as data lands).  -1 on failure, errno left set for
/// main's message (the connectSock contract).
pub fn openChardev(path: []const u8) c_int {
    var buf: [512]u8 = undefined;
    const n = @min(path.len, buf.len - 1);
    @memcpy(buf[0..n], path[0..n]);
    buf[n] = 0;
    const fd = open(buf[0..n :0].ptr, O_RDWR);
    if (fd >= 0) return fd;
    if (errno() != ENXIO) return -1;
    return connectSock(path);
}

/// The read(2) source for readResponse over a plain (non-socket) chardev
/// fd: a plain fd has no SO_RCVTIMEO, so poll(2) gates every read under the
/// same 5s budget connectSock sets on the socket.  -1 on timeout/error
/// (readResponse's EOF/error contract; glibc stdio gives up on both).
pub const PollSource = struct {
    fd: c_int,
    timeout_ms: i32 = 5000,

    pub fn read(this: *PollSource, dst: []u8) isize {
        var pfd = [_]std.posix.pollfd{.{
            .fd = this.fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        // std.posix.poll retries EINTR itself; 0 = the budget ran out.  A
        // transport error maps to read -1 (readResponse treats it like the
        // socket path's EAGAIN: no response).
        _ = std.posix.poll(&pfd, this.timeout_ms) catch return -1;
        if (pfd[0].revents == 0) {
            __errno_location().* = EAGAIN; // the SO_RCVTIMEO-equivalent outcome
            return -1;
        }
        return std.c.read(this.fd, dst.ptr, dst.len);
    }
};

/// send_line() (fxctl.c:67-80): the line capped at LINE_MAX_REQ, written
/// whole with EINTR retry, then the single '\n' terminator (EINTR retry on
/// that write only, like the C's do/while).  false on write failure.
pub fn sendLine(fd: c_int, line: []const u8) bool {
    var n = line.len;
    if (n > LINE_MAX_REQ) n = LINE_MAX_REQ;
    var off: usize = 0;
    while (off < n) {
        const w = write(fd, line.ptr + off, n - off);
        if (w < 0) {
            if (errno() == EINTR) continue;
            return false;
        }
        off += @intCast(w);
    }
    var nl: u8 = '\n';
    var w: isize = undefined;
    while (true) {
        w = write(fd, @ptrCast(&nl), 1);
        if (w >= 0) break;
        if (errno() != EINTR) break;
    }
    return w >= 0;
}

/// Per-line classification in read_response (fxctl.c:93-99): exactly "OK"
/// terminates OK; "ERR" followed by end/space/tab terminates ERR (so
/// "ERRSUFFIX" is a data line); everything else — including the empty line —
/// is a data line.
pub const LineKind = enum { ok, err, data };

pub fn classifyLine(line: []const u8) LineKind {
    if (std.mem.eql(u8, line, "OK")) return .ok;
    if (line.len >= 3 and std.mem.eql(u8, line[0..3], "ERR") and
        (line.len == 3 or line[3] == ' ' or line[3] == '\t')) return .err;
    return .data;
}

/// The read(2) source for readResponse: >0 bytes filled, 0 = EOF, <0 =
/// error (SO_RCVTIMEO EAGAIN included) — glibc stdio gives up on all of
/// these, it does not retry EINTR.
pub const FdSource = struct {
    fd: c_int,
    pub fn read(this: *FdSource, dst: []u8) isize {
        // std.c.read (libc read(2)); a container-level `extern fn read`
        // would be ambiguous with this method name.
        return std.c.read(this.fd, dst.ptr, dst.len);
    }
};

/// read_response() (fxctl.c:84-105) over a generic source (ctx: *T with
/// `fn read(*T, []u8) isize`, C read-style).  Streams data lines to `out`,
/// returns 0 on OK, 1 on ERR (message to stderr), -1 on transport error.
/// Closes nothing — the fd lifecycle stays with the caller's FdSource
/// (the C's fclose(fdopen(fd)) closes the fd; main() is its only user).
pub fn readResponse(ctx: anytype, out: *std.Io.Writer) i32 {
    var rc: i32 = -1;
    var lr = LineReader{};
    var buf: [8192]u8 = undefined;
    while (fgetsLine(ctx, &lr, &buf)) |raw| {
        // The C works on the strlen view: only bytes up to the first NUL
        // exist; the newline is stripped only when it is the LAST strlen
        // char (an embedded NUL hides a trailing '\n' from strlen).
        var line: []const u8 = std.mem.sliceTo(raw, 0);
        if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        switch (classifyLine(line)) {
            .ok => {
                rc = 0;
                break;
            },
            .err => {
                std.debug.print("{s}\n", .{line});
                rc = 1;
                break;
            },
            .data => out.print("{s}\n", .{line}) catch {}, // puts(): ignored on error
        }
    }
    return rc;
}

/// fgets(line, 8192, r) mirror: stdio-style internal buffer with pushback
/// (glibc reads 4096-byte blocks; the block size is not observable), serving
/// dst up to the FIRST '\n' inclusive, or 8191 bytes, or EOF/error.  null
/// only when NO bytes were available (the C's fgets -> NULL loop exit); a
/// partial chunk with no newline is returned as-is (the C treats it as a
/// line, and the line's remainder arrives in the next call).
const LineReader = struct {
    ibuf: [4096]u8 = undefined,
    fill: usize = 0,
    pos: usize = 0,
};

fn fgetsLine(ctx: anytype, lr: *LineReader, dst: *[8192]u8) ?[]const u8 {
    var n: usize = 0;
    while (n < dst.len - 1) {
        if (lr.pos >= lr.fill) {
            const got = ctx.read(lr.ibuf[0..]);
            if (got <= 0) break; // EOF or error: glibc fgets gives up
            lr.pos = 0;
            lr.fill = @intCast(got);
        }
        const avail = lr.fill - lr.pos;
        const room = dst.len - 1 - n;
        const take = @min(avail, room);
        const seg = lr.ibuf[lr.pos..][0..take];
        if (std.mem.indexOfScalar(u8, seg, '\n')) |i| {
            @memcpy(dst[n..][0 .. i + 1], seg[0 .. i + 1]);
            n += i + 1;
            lr.pos += i + 1;
            break;
        }
        @memcpy(dst[n..][0..take], seg);
        n += take;
        lr.pos += take;
    }
    if (n == 0) return null;
    dst[n] = 0; // fgets NUL-terminates; readResponse works on the strlen view
    return dst[0..n];
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [16384]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_w.interface;

    if (args.len < 2) {
        usage();
        std.process.exit(2);
    }

    var req: [LINE_MAX_REQ]u8 = undefined;

    // chardev mode: --chardev PATH / --chardev=PATH / FX_CHARDEV selects the
    // bidirectional virtio chardev transport instead of the control socket.
    // The flag pair is STRIPPED from argv before requestLine so the request
    // line is byte-identical to the socket path's (the guest grammar is the
    // socket's); usage()/rc 2 still fire first when there is no subcommand.
    const chardev = chardevPath(args[1..], env("FX_CHARDEV"));
    var argv_req: []const []const u8 = args[1..];
    if (chardev != null) {
        const al = init.arena.allocator();
        const compact = try al.alloc([]const u8, args.len - 1);
        var keep: usize = 0;
        var skip_next = false;
        for (args[1..]) |a| {
            if (skip_next) {
                skip_next = false; // the bare flag's PATH operand
                continue;
            }
            if (std.mem.eql(u8, a, "--chardev")) {
                skip_next = true;
                continue;
            }
            if (a.len > 10 and std.mem.eql(u8, a[0..10], "--chardev=")) continue;
            compact[keep] = a;
            keep += 1;
        }
        argv_req = compact[0..keep];
    }
    const line = requestLine(&req, argv_req);

    var fd: c_int = -1;
    if (chardev) |cp| {
        fd = openChardev(cp);
        if (fd < 0) {
            const e = errno();
            if (e == ENOENT) {
                std.debug.print("fxctl: chardev not present ({s})\n", .{cp});
            } else {
                std.debug.print("fxctl: open {s}: {s}\n", .{ cp, std.mem.span(strerror(e)) });
            }
            std.process.exit(1);
        }
    } else {
        var pbuf: [512]u8 = undefined;
        const path = sockPath(&pbuf, env("FX_SOCKET"), env("FX_RUN"));

        fd = connectSock(path);
        if (fd < 0) {
            const e = errno();
            if (e == ENOENT or e == ECONNREFUSED) {
                std.debug.print("fxctl: fx-init not running ({s})\n", .{path});
            } else if (e == EAFNOSUPPORT or e == ENOTSUP or e == EPROTONOSUPPORT) {
                std.debug.print(
                    "fxctl: cannot connect to {s}: Unix-domain sockets are not " ++
                        "supported on this platform (browser wasm) — fx-init's PID1 " ++
                        "control.sock is not running here\n",
                    .{path},
                );
            } else {
                std.debug.print("fxctl: connect {s}: {s}\n", .{ path, std.mem.span(strerror(e)) });
            }
            std.process.exit(1);
        }
    }
    if (!sendLine(fd, line)) {
        const e = errno();
        std.debug.print("fxctl: send failed: {s}\n", .{std.mem.span(strerror(e))});
        _ = close(fd);
        std.process.exit(1);
    }
    // The read source mirrors the transport: the socket's SO_RCVTIMEO does
    // the timing; a plain chardev fd has no such option, so PollSource
    // gates each read with poll(2) under the same 5s budget.
    const rc = if (chardev != null) blk: {
        var src = PollSource{ .fd = fd };
        break :blk readResponse(&src, out);
    } else blk: {
        var src = FdSource{ .fd = fd };
        break :blk readResponse(&src, out);
    };
    // NO half-close on the chardev path: the fd closes only HERE, after the
    // responses (MEASURED: an earlier write-side shutdown makes qemu tear
    // the chardev down before the guest's response write).  The socket path
    // is the C's fclose(fdopen(fd)) on every exit — same point.
    _ = close(fd);
    out.flush() catch {};
    if (rc < 0) {
        std.debug.print("fxctl: no response (timeout/disconnect)\n", .{});
        std.process.exit(1);
    }
    std.process.exit(@intCast(rc));
}

fn env(name: [:0]const u8) ?[]const u8 {
    // extern getenv: the same libc lookup the C uses (std.posix.getenv
    // varies by target; the extern is unconditional).
    const v = getenv(name.ptr) orelse return null;
    return std.mem.span(v);
}
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

// ─── tests (pin the fxctl.c contract) ──────────────────────────────────────

test "requestLine: join + quoting" {
    var buf: [LINE_MAX_REQ]u8 = undefined;
    const eq = struct {
        fn f(b: []u8, want: []const u8, args: []const []const u8) !void {
            const line = requestLine(b, args);
            try std.testing.expectEqualStrings(want, line);
        }
    }.f;
    try eq(&buf, "status", &.{"status"});
    try eq(&buf, "q users alice", &.{ "q", "users", "alice" });
    try eq(&buf, "q users \"\"", &.{ "q", "users", "" });
    try eq(&buf, "q users \"a b\"", &.{ "q", "users", "a b" });
    try eq(&buf, "search \"a\tb\"", &.{ "search", "a\tb" });
    try eq(&buf, "a \"b c\" \"\" \"d\t\"", &.{ "a", "b c", "", "d\t" });
    try eq(&buf, "x\"y", &.{"x\"y"}); // quotes pass through unescaped
    try eq(&buf, "start \"\"", &.{ "start", "" }); // trailing empty arg still quoted
    try eq(&buf, "\"\"", &.{""}); // lone empty arg is still quoted
}

test "requestLine: cap at buf.len-1 (LINE_MAX_REQ=4096)" {
    var buf: [LINE_MAX_REQ]u8 = undefined;
    const long = "y" ++ "x" ** 5000;
    const args = [_][]const u8{ "status", long };
    const line = requestLine(&buf, &args);
    try std.testing.expectEqual(@as(usize, LINE_MAX_REQ - 1), line.len);
    try std.testing.expectStringStartsWith(line, "status ");
    // single huge arg: capped to exactly 4095 chars
    const line2 = requestLine(&buf, &.{long});
    try std.testing.expectEqual(@as(usize, LINE_MAX_REQ - 1), line2.len);
    try std.testing.expectEqual(@as(u8, 'x'), line2[line2.len - 1]);
    // small-cap variant of the same guard (no 4k literals needed): 8-byte
    // buf -> at most 7 chars; the space / quote guards each drop silently
    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("sta tus", requestLine(&tiny, &.{ "sta", "tus" }));
    try std.testing.expectEqualStrings("status!", requestLine(&tiny, &.{"status!"}));
    try std.testing.expectEqualStrings("status!", requestLine(&tiny, &.{"status!!"}));
    // cap lands mid-arg: 7 chars kept, the closing quote dropped
    try std.testing.expectEqualStrings("a \"b c\"", requestLine(&tiny, &.{ "a", "b c" }));
}

test "chardevPath: --chardev flag / = form / FX_CHARDEV precedence" {
    const none: ?[]const u8 = null;
    // no flag, no env -> socket mode
    try std.testing.expect(chardevPath(&.{"status"}, null) == null);
    try std.testing.expect(chardevPath(&.{"status"}, none) == null);
    try std.testing.expect(chardevPath(&.{"status"}, "") == null);
    // bare flag eats the NEXT arg as PATH, anywhere in argv
    try std.testing.expectEqualStrings("/dev/vport0p1", chardevPath(&.{ "--chardev", "/dev/vport0p1" }, null).?);
    try std.testing.expectEqualStrings("/dev/vport0p1", chardevPath(&.{ "status", "--chardev", "/dev/vport0p1" }, null).?);
    try std.testing.expectEqualStrings("p", chardevPath(&.{ "--chardev", "p", "status" }, null).?);
    // = form
    try std.testing.expectEqualStrings("/tmp/s.sock", chardevPath(&.{ "--chardev=/tmp/s.sock", "status" }, null).?);
    // flag beats env
    try std.testing.expectEqualStrings("/dev/flag", chardevPath(&.{ "--chardev", "/dev/flag" }, "/dev/env").?);
    try std.testing.expectEqualStrings("/dev/env", chardevPath(&.{"status"}, "/dev/env").?);
    // lookalikes are NOT the flag
    try std.testing.expect(chardevPath(&.{ "--chardevx", "p" }, null) == null);
    try std.testing.expect(chardevPath(&.{ "--chardev2=p" }, null) == null);
    // single-char = form
    try std.testing.expectEqualStrings("p", chardevPath(&.{"--chardev=p"}, null).?);
    // trailing bare flag (no operand) cannot engage chardev mode
    try std.testing.expect(chardevPath(&.{"--chardev"}, null) == null);
    // empty = form selects nothing itself; the env still applies
    try std.testing.expectEqualStrings("/dev/env", chardevPath(&.{"--chardev="}, "/dev/env").?);
    try std.testing.expect(chardevPath(&.{"--chardev="}, null) == null);
}

test "openChardev: errno shaped like connectSock; a real node opens O_RDWR" {
    try std.testing.expect(openChardev("/nonexistent/fxctl-chardev-test") < 0);
    try std.testing.expectEqual(@as(c_int, 2), errno()); // ENOENT, not a stale errno
    // ENXIO fallback shape is live-probed in the harness smoke; the unit
    // contract here is only: a real rw node OPENS.
    const fd = openChardev("/dev/null");
    try std.testing.expect(fd >= 0);
    _ = close(fd);
}

test "PollSource: poll-gated read over a pipe (data, EOF, timeout)" {
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.pipe(&fds));
    var src = PollSource{ .fd = fds[0], .timeout_ms = 250 };

    // nothing to read: the poll budget runs out -> -1 with EAGAIN set (the
    // SO_RCVTIMEO-equivalent the plan names)
    var dst: [16]u8 = undefined;
    try std.testing.expectEqual(@as(isize, -1), src.read(&dst));
    try std.testing.expectEqual(@as(c_int, EAGAIN), errno());

    // data arrives: the read returns exactly the payload
    try std.testing.expectEqual(@as(usize, 4), @as(usize, @intCast(std.c.write(fds[1], "OK\n\n", 4))));
    try std.testing.expectEqual(@as(isize, 4), src.read(&dst));
    try std.testing.expectEqualStrings("OK\n\n", dst[0..4]);

    // peer closes: poll reports HUP -> read 0 = EOF (readResponse rc -1)
    _ = std.c.close(fds[1]);
    try std.testing.expectEqual(@as(isize, 0), src.read(&dst));
    _ = std.c.close(fds[0]);
}

test "sockPath: env precedence + snprintf truncation" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("/run/fx/control.sock", sockPath(&buf, null, null));
    try std.testing.expectEqualStrings("/run/fx/control.sock", sockPath(&buf, "", null));
    try std.testing.expectEqualStrings("/run/fx/control.sock", sockPath(&buf, "", ""));
    try std.testing.expectEqualStrings("/custom/control.sock", sockPath(&buf, "", "/custom"));
    try std.testing.expectEqualStrings("/abs/ctl", sockPath(&buf, "/abs/ctl", "/custom"));
    try std.testing.expectEqualStrings("/abs/ctl", sockPath(&buf, "/abs/ctl", null));
    // snprintf truncation: 600-char FX_RUN -> 511 chars kept
    const long = "r" ++ "u" ** 600;
    const p = sockPath(&buf, null, long);
    try std.testing.expectEqual(@as(usize, 511), p.len);
    try std.testing.expectStringStartsWith(p, "ru");
}

test "classifyLine: OK / ERR / data" {
    try std.testing.expectEqual(LineKind.ok, classifyLine("OK"));
    try std.testing.expectEqual(LineKind.err, classifyLine("ERR"));
    try std.testing.expectEqual(LineKind.err, classifyLine("ERR boom"));
    try std.testing.expectEqual(LineKind.err, classifyLine("ERR\tboom"));
    try std.testing.expectEqual(LineKind.data, classifyLine("ERROR")); // no space/tab after ERR
    try std.testing.expectEqual(LineKind.data, classifyLine("ERRx"));
    try std.testing.expectEqual(LineKind.data, classifyLine("OK ")); // strcmp != "OK"
    try std.testing.expectEqual(LineKind.data, classifyLine("ok"));
    try std.testing.expectEqual(LineKind.data, classifyLine(""));
    try std.testing.expectEqual(LineKind.data, classifyLine("gen 7"));
}

// in-memory read(2) source for readResponse tests
const MemSource = struct {
    data: []const u8,
    pos: usize = 0,
    pub fn read(this: *MemSource, dst: []u8) isize {
        const n = @min(dst.len, this.data.len - this.pos);
        @memcpy(dst[0..n], this.data[this.pos..][0..n]);
        this.pos += n;
        return @intCast(n);
    }
};

test "readResponse: data lines then OK (rc 0)" {
    var mem = MemSource{ .data = "alpha\nbeta\ngamma\nOK\n" };
    var wbuf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&wbuf);
    const rc = readResponse(&mem, &w);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expectEqualStrings("alpha\nbeta\ngamma\n", w.buffered());
}

test "readResponse: ERR variants (rc 1, message to stderr)" {
    for ([_][]const u8{ "ERR no such thing\n", "ERR\n", "ERR\ttabby\n" }) |payload| {
        var mem = MemSource{ .data = payload };
        var wbuf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&wbuf);
        const rc = readResponse(&mem, &w);
        try std.testing.expectEqual(@as(i32, 1), rc);
        try std.testing.expectEqualStrings("", w.buffered()); // ERR never on stdout
    }
    // "ERRSUFFIX" is a DATA line, then OK still terminates rc 0
    var mem = MemSource{ .data = "ERRSUFFIX is data\nOK\n" };
    var wbuf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&wbuf);
    try std.testing.expectEqual(@as(i32, 0), readResponse(&mem, &w));
    try std.testing.expectEqualStrings("ERRSUFFIX is data\n", w.buffered());
}

test "readResponse: truncated tail (no trailing newline)" {
    // EOF-terminated final chunk still classifies: "OK" without '\n' -> rc 0
    var mem = MemSource{ .data = "al\nOK" };
    var wbuf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&wbuf);
    try std.testing.expectEqual(@as(i32, 0), readResponse(&mem, &w));
    try std.testing.expectEqualStrings("al\n", w.buffered());
    // data-only stream, EOF before OK/ERR -> rc -1 (no response), data kept
    var mem2 = MemSource{ .data = "aa\nbb" };
    var w2buf: [256]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&w2buf);
    try std.testing.expectEqual(@as(i32, -1), readResponse(&mem2, &w2));
    try std.testing.expectEqualStrings("aa\nbb\n", w2.buffered());
    // empty stream -> rc -1
    var mem3 = MemSource{ .data = "" };
    var w3buf: [256]u8 = undefined;
    var w3: std.Io.Writer = .fixed(&w3buf);
    try std.testing.expectEqual(@as(i32, -1), readResponse(&mem3, &w3));
}

test "readResponse: embedded NUL hides the newline (strlen view)" {
    // fgets fills "ab\0cd\n"; strlen sees "ab", line[1] != '\n' -> no strip;
    // the C prints "ab" via puts.  Then "ef", then OK.
    var mem = MemSource{ .data = "ab\x00cd\nef\nOK\n" };
    var wbuf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&wbuf);
    try std.testing.expectEqual(@as(i32, 0), readResponse(&mem, &w));
    try std.testing.expectEqualStrings("ab\nef\n", w.buffered());
}

test "readResponse: >8191 line arrives in 8191-char chunks" {
    const first: usize = 8191;
    const rest: usize = 809;
    var payload: [first + rest + 1 + 3]u8 = undefined; // line + '\n' + "OK\n"
    @memset(payload[0..first], 'x');
    @memset(payload[first .. first + rest], 'y');
    payload[first + rest] = '\n';
    @memcpy(payload[first + rest + 1 ..], "OK\n");
    var mem = MemSource{ .data = &payload };
    var wbuf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&wbuf);
    try std.testing.expectEqual(@as(i32, 0), readResponse(&mem, &w));
    const got = w.buffered();
    try std.testing.expectEqual(first + 1 + rest + 1, got.len);
    try std.testing.expectEqual(@as(u8, 'x'), got[first - 1]);
    try std.testing.expectEqual(@as(u8, '\n'), got[first]);
    try std.testing.expectEqual(@as(u8, 'y'), got[first + 1]);
    try std.testing.expectEqual(@as(u8, '\n'), got[got.len - 1]);
}
