//! init.zig — faithful Zig port of src/fx-init.c (U-C1), the lean PID1 /
//! supervisor core of fixpoint-linux.  Mirrored section-for-section: globals/
//! Svc table -> helpers -> runtime-DB relations -> bootlog -> transient store
//! reads -> M4 restore -> boot decision + dhake -> readiness/supervision ->
//! SIGCHLD reap -> control socket -> shutdown -> main loop -> main.
//!
//! The datalog-dafsa engine, fxstore core, and the already-ported log/probe/
//! reloc/supervise modules are reused (the C twins are NOT linked).  All error
//! strings are VERBATIM from fx-init.c; the boot-decision PINNING, WNOHANG
//! drain, self-pipe + subreaper, and M4-restore-before-rollback ordering are
//! preserved exactly.
//!
//! Syscall surface (Zig 0.16, pinned by the plan's artifact-1): std.posix
//! sigaction (void-returning, plain struct) + poll + prctl; std.c fork/execv
//! (declared locally — not in std.c)/waitpid/pipe/pipe2/dup2/setsid/close/
//! read/write/clock_gettime/nanosleep/fcntl/kill/access/mkdir/unlink; the W
//! macros from std.os.linux.W; extern setenv (not in std.c).  Between fork and
//! exec only libc externs are called (no allocator, no std.Io, no locks).
const std = @import("std");
const log_mod = @import("log");
const probe_mod = @import("probe");
const reloc_mod = @import("reloc");
const sup = @import("supervise");
const fx = @import("fxstore");

const gpa_alloc = std.heap.c_allocator;

// ─── constants (fx-init.c:69-74) ──────────────────────────────────────────

const DEFAULT_STORE = "/fx/store";
const DEFAULT_RUN = "/run/fx";
const DEFAULT_PROBE_S: c_int = 10;
const DEFAULT_LOG_CAP: u64 = 100000;
const DEFAULT_GRACE_MS: u32 = 30000;
const REQ_MAX: usize = 4096;
const PATH_MAX: usize = 4096;

// Linux errno / fcntl / stdio constants used by the C.
const EEXIST: c_int = 17;
const EINTR: c_int = 4;
const EAGAIN: c_int = 11;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x800;
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;
const X_OK: c_int = 1;
const F_OK: c_int = 0;
const AF_UNIX: c_int = 1;
const SOCK_STREAM: c_int = 1;
const PR_SET_CHILD_SUBREAPER: c_int = 36;

// ─── on=/probe/restart enums (fx.h) + service state ───────────────────────

const FxOnKind = enum(c_int) { all = 0, up = 1, sock_tcp = 2, sock_unix = 3, time = 4, net = 5 };
const FxProbeKind = enum(c_int) { none = 0, tcp = 1, unix = 2, file = 3 };
const FxRestart = enum(c_int) { always = 0, on_failure = 1, never = 2 };

const ST_PENDING: c_int = 0;
const ST_STARTING: c_int = 1;
const ST_STARTED: c_int = 2;
const ST_BACKOFF: c_int = 3;
const ST_STOPPED: c_int = 4;
const ST_FAILED: c_int = 5;
const ST_NAMES = [_][*:0]const u8{ "pending", "starting", "started", "backoff", "stopped", "failed" };

// ─── service runtime table (fx-init.c:81-102) ─────────────────────────────

const Svc = struct {
    name: [128]u8 = [_]u8{0} ** 128,
    argv: ?[*]?[*:0]u8 = null,
    nargv: c_int = 0,
    env_k: ?[*]?[*:0]u8 = null,
    env_v: ?[*]?[*:0]u8 = null,
    nenv: c_int = 0,
    on_kind: FxOnKind = .all,
    on_arg: [256]u8 = [_]u8{0} ** 256,
    restart: FxRestart = .always,
    backoff_ms: u32 = 0,
    probe_kind: FxProbeKind = .none,
    probe_arg: [256]u8 = [_]u8{0} ** 256,
    pid: c_int = 0,
    state: c_int = ST_PENDING,
    restarts: c_int = 0,
    out_fd: c_int = 0,
    started_at: i64 = 0,
    next_start: i64 = 0,
    cur_backoff: u32 = 0,
    ready: c_int = 0,
};

// ─── global state (fx-init.c:106-131) ─────────────────────────────────────

var g_store: [*:0]const u8 = DEFAULT_STORE;
var g_run: [256]u8 = blk: {
    var b: [256]u8 = [_]u8{0} ** 256;
    @memcpy(b[0..DEFAULT_RUN.len], DEFAULT_RUN);
    break :blk b;
};
var g_probe_s: c_int = DEFAULT_PROBE_S;
var g_log_cap: u64 = DEFAULT_LOG_CAP;
var g_grace_ms: u32 = DEFAULT_GRACE_MS;
var g_probe_root: ?[*:0]const u8 = null;

var g_rt: ?*dl_db = null;
var g_log: ?*dl_db = null;
var g_svc: ?[*]Svc = null;
var g_nsvc: c_int = 0;
var g_svc_cap: c_int = 0;
var g_boot_version: u32 = 0;
var g_current_version: u32 = 0;
var g_buildfile: [1024]u8 = [_]u8{0} ** 1024;
var g_dhake: [1024]u8 = [_]u8{0} ** 1024;
var g_fxstore: [1024]u8 = blk: {
    var b: [1024]u8 = [_]u8{0} ** 1024;
    @memcpy(b[0.."/bin/fx-activate".len], "/bin/fx-activate");
    break :blk b;
};
var g_hostname: [256]u8 = [_]u8{0} ** 256; // mirrored-dead in the C too
var g_boot_start_ms: u64 = 0;
var g_boot_deadline_ms: u64 = 0;
var g_next_probe: i64 = 0;
var g_ctrl_fd: c_int = -1;
var g_sigpipe: [2]c_int = .{ -1, -1 };
var g_shutdown: std.atomic.Value(c_int) = std.atomic.Value(c_int).init(0);
var g_txn_id: u32 = 1;
var g_boot_decided: c_int = 0;
var g_boot_failed: c_int = 0;

// ─── FFI: the vendored C core (fxstore + datalog-dafsa) ──────────────────

pub const dl_db = opaque {};
pub const dl_iter = opaque {};

const dl_tuple_cb = *const fn (cols: [*]const u32, arity: u8, user: ?*anyopaque) callconv(.c) c_int;

extern fn dl_open(dir: [*:0]const u8) ?*dl_db;
extern fn dl_close(db: ?*dl_db) void;
extern fn dl_declare_relation(db: *dl_db, name: [*:0]const u8, arity: u8) c_int;
extern fn dl_txn_begin(db: *dl_db) c_int;
extern fn dl_txn_add_fact(db: *dl_db, rel: [*:0]const u8, cols: [*]const u32, arity: u8) c_int;
extern fn dl_txn_delete_fact(db: *dl_db, rel: [*:0]const u8, cols: [*]const u32, arity: u8) c_int;
extern fn dl_txn_commit(db: *dl_db) c_int;
extern fn dl_txn_rollback(db: *dl_db) c_int;
extern fn dl_intern_str(db: *dl_db, str: [*:0]const u8) u32;
extern fn dl_intern_str_of(db: *dl_db, sym_id: u32) ?[*:0]const u8;
extern fn dl_iter_open(db: *dl_db, rel: [*:0]const u8, leading: ?[*]const u32, k: u8) ?*dl_iter;
extern fn dl_iter_arity(it: *const dl_iter) u8;
extern fn dl_iter_next(it: *dl_iter, cols_out: [*]u32) c_int;
extern fn dl_iter_close(it: ?*dl_iter) void;
extern fn dl_query(db: *dl_db, goal_rel: [*:0]const u8, cb: dl_tuple_cb, user: ?*anyopaque) c_long;
extern fn dl_query_bound(db: *dl_db, goal_rel: [*:0]const u8, leading: [*]const u32, k: u8, cb: dl_tuple_cb, user: ?*anyopaque) c_long;
extern fn dl_query_version(db: *dl_db, version: u32, goal_rel: [*:0]const u8, cb: dl_tuple_cb, user: ?*anyopaque) c_long;
extern fn dl_query_bound_version(db: *dl_db, version: u32, goal_rel: [*:0]const u8, leading: [*]const u32, k: u8, cb: dl_tuple_cb, user: ?*anyopaque) c_long;
extern fn dl_snapshot_versions(db: *const dl_db, out: [*]u32, cap: usize) c_long;

// The fxstore Zig port's store core (store.zig): fx_store_open/close/db/
// current_version/rollback.  Its db handle is closure.zig's DlDb opaque type;
// cast at the boundary (both are plain opaque pointers over libdatalog.so).
var g_io: std.Io = undefined;

fn fx_store_open_wrap(root: [*:0]const u8, err: ?[*]u8, errcap: usize) ?*fx.Store {
    var e = fx.store.ErrBuf{};
    const s = fx.fx_store_open(g_io, std.mem.span(root), &e) catch {
        copyErr(&e, err, errcap);
        return null;
    };
    return s;
}

fn fx_store_current_version_wrap(s: *const fx.Store, out: *u32, err: ?[*]u8, errcap: usize) c_int {
    var e = fx.store.ErrBuf{};
    fx.fx_store_current_version(g_io, s, out, &e) catch {
        copyErr(&e, err, errcap);
        return -1;
    };
    return 0;
}

fn fx_store_rollback_wrap(s: *fx.Store, version: u32, hard: bool, err: ?[*]u8, errcap: usize) c_int {
    var e = fx.store.ErrBuf{};
    fx.fx_store_rollback(s, version, hard, &e) catch {
        copyErr(&e, err, errcap);
        return -1;
    };
    return 0;
}

/// store.zig's db handle (closure.zig's DlDb opaque) cast to this file's
/// dl_db opaque type — both are plain opaque pointers over libdatalog.so.
fn store_db(s: *fx.Store) *dl_db {
    return @ptrCast(fx.fx_store_db(s).?);
}

/// Copy a port module's ErrBuf message into the C-style (err, errcap) buffer.
fn copyErr(eb: anytype, err: ?[*]u8, errcap: usize) void {
    const m = eb.slice();
    if (err == null or errcap == 0) return;
    const n = @min(m.len, errcap - 1);
    @memcpy(err.?[0..n], m[0..n]);
    err.?[n] = 0;
}

// ─── libc externs (std.posix gaps; the supervise.zig/probe.zig pattern) ──

const FILE = std.c.FILE;

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(f: *FILE) c_int;
extern "c" fn fflush(f: *FILE) c_int;
extern "c" fn fsync(fd: c_int) c_int;
extern "c" fn fileno(f: *FILE) c_int;
extern "c" fn fgets(s: [*]u8, size: c_int, f: *FILE) ?[*:0]u8;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, f: *FILE) usize;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, f: *FILE) usize;
extern "c" fn ftell(f: *FILE) c_long;
extern "c" fn fseek(f: *FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*FILE;
extern "c" fn fputs(s: [*:0]const u8, f: *FILE) c_int;
extern "c" fn fputc(c: c_int, f: *FILE) c_int;
extern "c" fn fprintf(f: *FILE, fmt: [*:0]const u8, ...) c_int;
extern "c" fn sscanf(s: [*:0]const u8, fmt: [*:0]const u8, ...) c_int;
extern "c" fn snprintf(buf: [*]u8, cap: usize, fmt: [*:0]const u8, ...) c_int;
extern "c" var stderr: *FILE;
extern "c" var stdout: *FILE;

extern "c" fn malloc(size: usize) ?[*]u8;
extern "c" fn realloc(ptr: ?*anyopaque, size: usize) ?[*]u8;
extern "c" fn free(ptr: ?*anyopaque) void;
extern "c" fn strdup(s: [*:0]const u8) ?[*:0]u8;
extern "c" fn strlen(s: [*:0]const u8) usize;
extern "c" fn strcmp(a: [*:0]const u8, b: [*:0]const u8) c_int;
extern "c" fn strncmp(a: [*:0]const u8, b: [*:0]const u8, n: usize) c_int;
extern "c" fn strncpy(dst: [*]u8, src: [*:0]const u8, n: usize) [*]u8;
extern "c" fn strtok_r(str: ?[*:0]u8, delim: [*:0]const u8, saveptr: *?[*:0]u8) ?[*:0]u8;
extern "c" fn strtoul(s: [*:0]const u8, endptr: ?*[*:0]u8, base: c_int) c_ulong;
extern "c" fn atoi(s: [*:0]const u8) c_int;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn time(t: ?*i64) i64;
extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, addrlen: ?*c_uint) c_int;

const SockaddrUn = extern struct {
    family: u16,
    path: [108]u8,
};

// ─── helpers ───────────────────────────────────────────────────────────────

/// C snprintf semantics into a fixed buffer (activiate.zig's snfmt).
fn snfmt(buf: anytype, comptime fmt: []const u8, args: anytype) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa_alloc);
    defer aw.deinit();
    aw.writer.print(fmt, args) catch unreachable;
    const s = aw.written();
    const n = @min(s.len, buf.len - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    return buf[0..n];
}

/// snfmt into a raw [*]u8 with an explicit cap (vsnprintf semantics).
fn snfmtRaw(buf: [*]u8, cap: usize, comptime fmt: []const u8, args: anytype) void {
    if (cap == 0) return;
    var aw: std.Io.Writer.Allocating = .init(gpa_alloc);
    defer aw.deinit();
    aw.writer.print(fmt, args) catch unreachable;
    const s = aw.written();
    const n = @min(s.len, cap - 1);
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
}

/// fx_err (fxstore.h static inline): vsnprintf into err, return -1.
fn fx_err(err: ?[*]u8, errcap: usize, comptime fmt: []const u8, args: anytype) c_int {
    if (err) |e| {
        if (errcap > 0) snfmtRaw(e, errcap, fmt, args);
    }
    return -1;
}

/// typed malloc (the C's malloc(sizeof *p * n)).
fn mallocT(comptime T: type, n: usize) ?[*]T {
    const raw = malloc(n * @sizeOf(T)) orelse return null;
    return @ptrCast(@alignCast(raw));
}
fn reallocT(comptime T: type, ptr: ?[*]T, n: usize) ?[*]T {
    const raw = realloc(@ptrCast(ptr), n * @sizeOf(T)) orelse return null;
    return @ptrCast(@alignCast(raw));
}
fn cfree(p: anytype) void {
    free(@ptrCast(p));
}

/// std.mem.span wrapper (C sentinel string -> slice).
fn span(p: [*:0]const u8) []const u8 {
    return std.mem.span(p);
}
fn ospan(p: ?[*:0]const u8) []const u8 {
    return if (p) |q| std.mem.span(q) else "?";
}

fn errnoStr() []const u8 {
    return std.mem.span(strerror(std.c._errno().*));
}
fn errf(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

// ─── the already-ported modules, dl_db-cast into this file's opaque type ──

fn fx_log_open(path: [*:0]const u8) ?*dl_db {
    return @ptrCast(log_mod.fx_log_open(path));
}
fn fx_log_close(db: ?*dl_db) void {
    log_mod.fx_log_close(@ptrCast(db));
}
fn fx_log_emit(db: ?*dl_db, ts: u32, svc: [*:0]const u8, lvl: [*:0]const u8, msg: [*:0]const u8) c_int {
    return log_mod.fx_log_emit(@ptrCast(db), ts, svc, lvl, msg);
}
fn fx_log_rotate(db: ?*dl_db, cap: u64) c_int {
    return log_mod.fx_log_rotate(@ptrCast(db), cap);
}
fn fx_log_grep(db: ?*dl_db, regex: ?[*:0]const u8, cb: log_mod.fx_log_cb, user: ?*anyopaque) c_long {
    return log_mod.fx_log_grep(@ptrCast(db), regex, cb, user);
}
fn fx_log_search(db: ?*dl_db, terms: ?[*]const ?[*:0]const u8, n: c_int, cb: log_mod.fx_log_cb, user: ?*anyopaque) c_long {
    return log_mod.fx_log_search(@ptrCast(db), terms, n, cb, user);
}
fn fx_probe_declare(db: ?*dl_db) c_int {
    return probe_mod.fx_probe_declare(@ptrCast(db));
}
fn fx_probe_refresh(db: ?*dl_db, root: ?[*:0]const u8, err: ?[*]u8, errcap: usize) c_int {
    return probe_mod.fx_probe_refresh(@ptrCast(db), root, err, errcap);
}

// ─── helpers (fx-init.c:135-178) ──────────────────────────────────────────

fn now_s() u32 {
    return @truncate(@as(u64, @bitCast(time(null))));
}

fn now_ms() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) {
        return @as(u64, @bitCast(time(null))) *% 1000;
    }
    return @as(u64, @intCast(ts.sec)) *% 1000 +% @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn mkdirp(path: [*:0]const u8) c_int {
    var buf: [1100]u8 = undefined;
    _ = snfmt(&buf, "{s}", .{span(path)});
    var idx: usize = 1;
    while (buf[idx] != 0) : (idx += 1) {
        if (buf[idx] == '/') {
            buf[idx] = 0;
            if (std.c.mkdir(@ptrCast(&buf), 0o755) != 0 and std.c._errno().* != EEXIST) return -1;
            buf[idx] = '/';
        }
    }
    if (std.c.mkdir(@ptrCast(&buf), 0o755) != 0 and std.c._errno().* != EEXIST) return -1;
    return 0;
}

fn isym(db: *dl_db, s: [*:0]const u8) u32 {
    const r = dl_intern_str(db, s);
    return if (r != 0) r else 1;
}

fn svc_find(name: [*:0]const u8) ?*Svc {
    var i: c_int = 0;
    while (i < g_nsvc) : (i += 1) {
        if (strcmp(@ptrCast(&g_svc.?[@intCast(i)].name), name) == 0) return &g_svc.?[@intCast(i)];
    }
    return null;
}

fn log_line(svc: [*:0]const u8, level: [*:0]const u8, msg: [*:0]const u8) void {
    if (g_log) |l| _ = fx_log_emit(l, now_s(), svc, level, msg);
}

fn parse_on(s: [*:0]const u8, kind: *FxOnKind, arg: [*]u8, cap: usize) void {
    const ss = span(s);
    if (std.mem.eql(u8, ss, "all")) {
        kind.* = .all;
        arg[0] = 0;
        return;
    }
    if (std.mem.eql(u8, ss, "net")) {
        kind.* = .net;
        arg[0] = 0;
        return;
    }
    if (std.mem.startsWith(u8, ss, "up:")) {
        kind.* = .up;
        snfmtRaw(arg, cap, "{s}", .{ss[3..]});
        return;
    }
    if (std.mem.startsWith(u8, ss, "sock:tcp:")) {
        kind.* = .sock_tcp;
        snfmtRaw(arg, cap, "{s}", .{ss[9..]});
        return;
    }
    if (std.mem.startsWith(u8, ss, "sock:unix:")) {
        kind.* = .sock_unix;
        snfmtRaw(arg, cap, "{s}", .{ss[10..]});
        return;
    }
    if (std.mem.startsWith(u8, ss, "time:")) {
        kind.* = .time;
        snfmtRaw(arg, cap, "{s}", .{ss[5..]});
        return;
    }
    kind.* = .all;
    arg[0] = 0;
}

// ─── runtime DB relations (fx-init.c:182-238) ─────────────────────────────

fn declare_runtime(db: *dl_db) c_int {
    if (dl_declare_relation(db, "generation_current", 1) != 0) return -1;
    if (dl_declare_relation(db, "boot_status", 2) != 0) return -1;
    if (dl_declare_relation(db, "service_runtime", 4) != 0) return -1;
    if (dl_declare_relation(db, "ready", 1) != 0) return -1;
    if (dl_declare_relation(db, "control", 3) != 0) return -1;
    if (dl_declare_relation(db, "effect", 3) != 0) return -1;
    if (fx_probe_declare(db) != 0) return -1;
    return 0;
}

fn rt_replace1(rel: [*:0]const u8, ar: u8, key: [*]const u32) void {
    const it = dl_iter_open(g_rt.?, rel, key, 1);
    if (it) |iter| {
        var r: [8]u32 = undefined;
        while (dl_iter_next(iter, &r) == 1) _ = dl_txn_delete_fact(g_rt.?, rel, &r, ar);
        dl_iter_close(iter);
    }
}

fn rt_set_service(s: *Svc) void {
    const name = isym(g_rt.?, @ptrCast(&s.name));
    rt_replace1("service_runtime", 4, @ptrCast(&name));
    const st: [*:0]const u8 = if (s.state >= 0 and s.state <= ST_FAILED) ST_NAMES[@intCast(s.state)] else "?";
    const cols = [4]u32{ name, if (s.pid > 0) @intCast(s.pid) else 0, isym(g_rt.?, st), @intCast(s.restarts) };
    _ = dl_txn_add_fact(g_rt.?, "service_runtime", &cols, 4);
}

fn rt_set_ready(s: *Svc, ready: c_int) void {
    const name = isym(g_rt.?, @ptrCast(&s.name));
    rt_replace1("ready", 1, @ptrCast(&name));
    if (ready != 0) {
        const c = [1]u32{name};
        _ = dl_txn_add_fact(g_rt.?, "ready", &c, 1);
    }
    s.ready = ready;
}

fn rt_set_boot(v: u32, status: [*:0]const u8) void {
    rt_replace1("boot_status", 2, @ptrCast(&v));
    const cols = [2]u32{ v, isym(g_rt.?, status) };
    _ = dl_txn_add_fact(g_rt.?, "boot_status", &cols, 2);
}

fn rt_set_generation_current(v: u32) void {
    const it = dl_iter_open(g_rt.?, "generation_current", null, 0);
    if (it) |iter| {
        var r: [1]u32 = undefined;
        while (dl_iter_next(iter, &r) == 1) _ = dl_txn_delete_fact(g_rt.?, "generation_current", &r, 1);
        dl_iter_close(iter);
    }
    const c = [1]u32{v};
    _ = dl_txn_add_fact(g_rt.?, "generation_current", &c, 1);
}

fn rt_control(txn: u32, cmd: [*:0]const u8, target: [*:0]const u8) void {
    const c = [3]u32{ txn, isym(g_rt.?, cmd), isym(g_rt.?, target) };
    _ = dl_txn_add_fact(g_rt.?, "control", &c, 3);
}
fn rt_effect(txn: u32, key: [*:0]const u8, val: [*:0]const u8) void {
    const c = [3]u32{ txn, isym(g_rt.?, key), isym(g_rt.?, val) };
    _ = dl_txn_add_fact(g_rt.?, "effect", &c, 3);
}

fn rt_txn_begin() void {
    _ = dl_txn_begin(g_rt.?);
}
fn rt_txn_commit() c_int {
    return dl_txn_commit(g_rt.?);
}

// ─── durable boot marker: <store>/.bootlog (fx-init.c:242-298) ────────────

fn bootlog_path(out: [*]u8, cap: usize) void {
    snfmtRaw(out, cap, "{s}/.bootlog", .{span(g_store)});
}

fn bootlog_append(v: u32, status: [*:0]const u8, epoch: u32) void {
    var p: [1100]u8 = undefined;
    bootlog_path(&p, p.len);
    _ = mkdirp(g_store);
    const f = fopen(@ptrCast(&p), "a") orelse return;
    _ = fprintf(f, "%u %s %u\n", v, status, epoch);
    _ = fflush(f);
    _ = fsync(fileno(f));
    _ = fclose(f);
}

fn bootlog_last(v_out: *u32, status_out: [*]u8, scap: usize) c_int {
    var p: [1100]u8 = undefined;
    bootlog_path(&p, p.len);
    const f = fopen(@ptrCast(&p), "r") orelse return 0;
    var line: [256]u8 = undefined;
    var sv: [64]u8 = [_]u8{0} ** 64;
    var v: u32 = 0;
    var got: c_int = 0;
    while (fgets(&line, @intCast(line.len), f)) |_| {
        var tv: u32 = 0;
        var tsv: [64]u8 = [_]u8{0} ** 64;
        if (sscanf(@ptrCast(&line), "%u %63s", &tv, &tsv) == 2 and strcmp(@ptrCast(&tsv), "shutdown") != 0) {
            v = tv;
            @memcpy(sv[0..], tsv[0..]);
            got = 1;
        }
    }
    _ = fclose(f);
    if (got != 0) {
        v_out.* = v;
        _ = strncpy(status_out, @ptrCast(&sv), scap - 1);
        status_out[scap - 1] = 0;
    }
    return got;
}

fn bootlog_newest_ok_below(v: u32, out: *u32) c_int {
    var p: [1100]u8 = undefined;
    bootlog_path(&p, p.len);
    const f = fopen(@ptrCast(&p), "r") orelse return 0;
    var line: [256]u8 = undefined;
    var sv: [64]u8 = [_]u8{0} ** 64;
    var lv: u32 = 0;
    var best: u32 = 0;
    var found: c_int = 0;
    while (fgets(&line, @intCast(line.len), f)) |_| {
        if (sscanf(@ptrCast(&line), "%u %63s", &lv, &sv) == 2) {
            if (strcmp(@ptrCast(&sv), "ok") == 0 and lv < v) {
                if (found == 0 or lv > best) best = lv;
                found = 1;
            }
        }
    }
    _ = fclose(f);
    if (found != 0) out.* = best;
    return found;
}

fn version_exists(v: u32) c_int {
    var err: [1024]u8 = undefined;
    const s = fx_store_open_wrap(g_store, &err, err.len) orelse return 0;
    var vers: [256]u32 = undefined;
    const n = dl_snapshot_versions(store_db(s), &vers, vers.len);
    fx.fx_store_close(s);
    if (n <= 0) return 0;
    var i: c_long = 0;
    while (i < n and i < 256) : (i += 1) {
        if (vers[@intCast(i)] == v) return 1;
    }
    return 0;
}

// ─── transient store reads: generation + svc facts AS-OF a version ───────

const GenPick = struct {
    best_epoch: u32 = 0,
    gh: u32 = 0,
    bf: u32 = 0,
    dh: u32 = 0,
    found: c_int = 0,
};
fn gen_pick_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = ar;
    const g: *GenPick = @ptrCast(@alignCast(user.?));
    if (c[3] >= g.best_epoch) {
        g.best_epoch = c[3];
        g.gh = c[0];
        g.bf = c[1];
        g.dh = c[2];
        g.found = 1;
    }
    return 0;
}

const ToolPathCtx = struct {
    db: *dl_db,
    out: [*]u8,
    cap: usize,
    got: c_int = 0,
};
fn tool_path_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = ar;
    const t: *ToolPathCtx = @ptrCast(@alignCast(user.?));
    const p = dl_intern_str_of(t.db, c[0]);
    if (p != null and t.got == 0) {
        _ = strncpy(t.out, p.?, t.cap - 1);
        t.out[t.cap - 1] = 0;
        t.got = 1;
    }
    return 0;
}

const SvcCtx = struct { db: *dl_db };
fn svc_name_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = ar;
    const x: *SvcCtx = @ptrCast(@alignCast(user.?));
    const name = dl_intern_str_of(x.db, c[0]) orelse return 0;
    if (svc_find(name) != null) return 0;
    if (g_nsvc >= g_svc_cap) {
        const nc: c_int = if (g_svc_cap != 0) g_svc_cap * 2 else 16;
        const ns = reallocT(Svc, g_svc, @intCast(nc)) orelse return 1;
        g_svc = ns;
        g_svc_cap = nc;
    }
    const s = &g_svc.?[@intCast(g_nsvc)];
    g_nsvc += 1;
    s.* = Svc{};
    _ = strncpy(&s.name, name, s.name.len - 1);
    s.backoff_ms = 1000;
    s.restart = .always;
    s.probe_kind = .none;
    s.state = ST_PENDING;
    s.out_fd = -1;
    return 0;
}

const SvcMeta = struct {
    db: *dl_db,
    sn: u32 = 0,
    on_kind: FxOnKind = .all,
    on_full: [256]u8 = [_]u8{0} ** 256,
    restart: FxRestart = .always,
    got: c_int = 0,
};
fn svc_meta_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = ar;
    const m: *SvcMeta = @ptrCast(@alignCast(user.?));
    const on = dl_intern_str_of(m.db, c[1]);
    const rs = dl_intern_str_of(m.db, c[2]);
    if (on) |o| {
        _ = strncpy(&m.on_full, o, m.on_full.len - 1);
        m.on_full[m.on_full.len - 1] = 0;
    }
    if (rs) |r| {
        if (strcmp(r, "always") == 0) m.restart = .always
        else if (strcmp(r, "on-failure") == 0) m.restart = .on_failure
        else if (strcmp(r, "never") == 0) m.restart = .never;
    }
    m.got = 1;
    return 0;
}

const ArgCtx = struct {
    db: *dl_db,
    args: ?[*]?[*:0]u8 = null,
    cap: c_int = 0,
    max_idx: c_int = -1,
};
fn svc_argv_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = ar;
    const a: *ArgCtx = @ptrCast(@alignCast(user.?));
    const idx: c_int = @intCast(c[1]);
    if (idx >= a.cap) {
        const nc: c_int = idx + 8;
        const na = reallocT(?[*:0]u8, a.args, @intCast(nc)) orelse return 1;
        a.args = na;
        var i: c_int = a.cap;
        while (i < nc) : (i += 1) a.args.?[@intCast(i)] = null;
        a.cap = nc;
    }
    const s = dl_intern_str_of(a.db, c[2]);
    a.args.?[@intCast(idx)] = if (s) |t| strdup(t) else strdup("");
    if (idx > a.max_idx) a.max_idx = idx;
    return 0;
}

const BinCtx = struct {
    db: *dl_db,
    bin: ?[*:0]u8 = null,
    got: c_int = 0,
};
fn svc_bin_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = ar;
    const b: *BinCtx = @ptrCast(@alignCast(user.?));
    const p = dl_intern_str_of(b.db, c[1]);
    if (p) |pp| {
        free(@ptrCast(b.bin));
        b.bin = strdup(pp);
        b.got = 1;
    }
    return 0;
}

const EnvCtx = struct {
    db: *dl_db,
    k: ?[*]?[*:0]u8 = null,
    v: ?[*]?[*:0]u8 = null,
    n: c_int = 0,
    cap: c_int = 0,
};
fn svc_env_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = ar;
    const e: *EnvCtx = @ptrCast(@alignCast(user.?));
    if (e.n >= e.cap) {
        const nc: c_int = if (e.cap != 0) e.cap * 2 else 8;
        const nk = reallocT(?[*:0]u8, e.k, @intCast(nc));
        const nv = reallocT(?[*:0]u8, e.v, @intCast(nc));
        if (nk == null or nv == null) {
            cfree(nk);
            cfree(nv);
            return 1;
        }
        e.k = nk;
        e.v = nv;
        e.cap = nc;
    }
    const kk = dl_intern_str_of(e.db, c[1]);
    const vv = dl_intern_str_of(e.db, c[2]);
    e.k.?[@intCast(e.n)] = if (kk) |s| strdup(s) else strdup("");
    e.v.?[@intCast(e.n)] = if (vv) |s| strdup(s) else strdup("");
    e.n += 1;
    return 0;
}

const ProbeCtx = struct {
    db: *dl_db,
    kind: FxProbeKind = .none,
    arg: ?[*:0]u8 = null,
    got: c_int = 0,
};
fn svc_probe_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = ar;
    const p: *ProbeCtx = @ptrCast(@alignCast(user.?));
    const k = dl_intern_str_of(p.db, c[1]);
    const a = dl_intern_str_of(p.db, c[2]);
    if (k) |kk| {
        if (strcmp(kk, "tcp") == 0) p.kind = .tcp
        else if (strcmp(kk, "unix") == 0) p.kind = .unix
        else if (strcmp(kk, "file") == 0) p.kind = .file;
    }
    free(@ptrCast(p.arg));
    p.arg = if (a) |aa| strdup(aa) else strdup("");
    p.got = 1;
    return 0;
}

fn build_argv(sv: *Svc, ac: *const ArgCtx, bin: ?[*:0]const u8) void {
    const n: usize = @intCast(ac.max_idx + 1);
    const raw = malloc((n + 1) * @sizeOf(?[*:0]u8)) orelse @panic("out of memory");
    const av: [*]?[*:0]u8 = @ptrCast(@alignCast(raw));
    @memset(av[0 .. n + 1], null);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i == 0 and bin != null) {
            av[0] = strdup(bin.?);
        } else {
            const s: [*:0]const u8 = if (ac.args.?[i]) |a| a else "";
            av[i] = strdup(s);
        }
    }
    sv.argv = av;
    sv.nargv = @intCast(n);
}

const BkCtx = struct { v: u32 = 0, got: c_int = 0 };
fn backoff_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = ar;
    const b: *BkCtx = @ptrCast(@alignCast(user.?));
    b.v = c[1];
    b.got = 1;
    return 0;
}

const GraceCtx = struct { v: u32 = 0, got: c_int = 0 };
fn grace_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = ar;
    const g: *GraceCtx = @ptrCast(@alignCast(user.?));
    g.v = c[0];
    g.got = 1;
    return 0;
}

fn read_store_facts(version: u32) c_int {
    var err: [1024]u8 = undefined;
    const s = fx_store_open_wrap(g_store, &err, err.len) orelse {
        errf("fx-init: store open: {s}\n", .{span(@ptrCast(&err))});
        return -1;
    };
    const db = store_db(s);

    var i: c_int = 0;
    while (i < g_nsvc) : (i += 1) {
        cfree(g_svc.?[@intCast(i)].argv);
        cfree(g_svc.?[@intCast(i)].env_k);
        cfree(g_svc.?[@intCast(i)].env_v);
    }
    cfree(g_svc);
    g_svc = null;
    g_nsvc = 0;
    g_svc_cap = 0;

    var gp = GenPick{};
    _ = dl_query_version(db, version, "generation", gen_pick_cb, &gp);
    if (gp.found == 0) {
        fx.fx_store_close(s);
        return -1;
    }
    const bf = dl_intern_str_of(db, gp.bf);
    const dh = dl_intern_str_of(db, gp.dh);
    if (bf == null or dh == null) {
        fx.fx_store_close(s);
        return -1;
    }
    _ = snfmt(&g_buildfile, "{s}/{s}", .{ span(g_store), span(bf.?) });
    _ = snfmt(&g_dhake, "{s}/{s}", .{ span(g_store), span(dh.?) });

    var tp = ToolPathCtx{ .db = db, .out = @ptrCast(&g_fxstore), .cap = g_fxstore.len };
    _ = dl_query_version(db, version, "tool_fxstore", tool_path_cb, &tp);

    var gc = GraceCtx{};
    _ = dl_query_version(db, version, "boot_grace", grace_cb, &gc);
    if (gc.got != 0 and gc.v > 0) g_grace_ms = gc.v;

    var sc = SvcCtx{ .db = db };
    _ = dl_query_version(db, version, "svc", svc_name_cb, &sc);

    i = 0;
    while (i < g_nsvc) : (i += 1) {
        const sv = &g_svc.?[@intCast(i)];
        const sn = dl_intern_str(db, @ptrCast(&sv.name));
        var sm = SvcMeta{ .db = db, .sn = sn };
        _ = dl_query_bound_version(db, version, "svc", @ptrCast(&sn), 1, svc_meta_cb, &sm);
        sv.restart = sm.restart;
        parse_on(@ptrCast(&sm.on_full), &sv.on_kind, &sv.on_arg, sv.on_arg.len);

        var ac = ArgCtx{ .db = db };
        _ = dl_query_bound_version(db, version, "svc_argv", @ptrCast(&sn), 1, svc_argv_cb, &ac);

        var bc = BinCtx{ .db = db };
        _ = dl_query_bound_version(db, version, "svc_bin", @ptrCast(&sn), 1, svc_bin_cb, &bc);
        if (bc.bin) |bin| {
            if (bin[0] != '/') {
                var abs: [PATH_MAX]u8 = undefined;
                _ = snfmt(&abs, "{s}/{s}", .{ span(g_store), span(bin) });
                free(@ptrCast(bc.bin));
                bc.bin = strdup(@ptrCast(&abs));
            }
        }
        build_argv(sv, &ac, bc.bin);
        free(@ptrCast(bc.bin));

        var bkc = BkCtx{};
        _ = dl_query_bound_version(db, version, "svc_backoff", @ptrCast(&sn), 1, backoff_cb, &bkc);
        sv.backoff_ms = if (bkc.got != 0) bkc.v else 1000;

        var ec = EnvCtx{ .db = db };
        _ = dl_query_bound_version(db, version, "svc_env", @ptrCast(&sn), 1, svc_env_cb, &ec);
        sv.env_k = ec.k;
        sv.env_v = ec.v;
        sv.nenv = ec.n;

        var pc = ProbeCtx{ .db = db };
        _ = dl_query_bound_version(db, version, "svc_probe", @ptrCast(&sn), 1, svc_probe_cb, &pc);
        sv.probe_kind = pc.kind;
        if (pc.arg) |pa| {
            _ = strncpy(&sv.probe_arg, pa, sv.probe_arg.len - 1);
            sv.probe_arg[sv.probe_arg.len - 1] = 0;
            free(@ptrCast(pc.arg));
        }

        var j: c_int = 0;
        while (j < ac.cap) : (j += 1) cfree(ac.args.?[@intCast(j)]);
        cfree(ac.args);
    }

    fx.fx_store_close(s);
    return 0;
}

// ─── roll-forward M4 fact restore (fx-init.c:536-622) ─────────────────────

const M4Rel = struct { name: [*:0]const u8, arity: u8 };
const M4_RELS = [_]M4Rel{
    .{ .name = "generation", .arity = 4 },
    .{ .name = "svc", .arity = 3 },
    .{ .name = "svc_argv", .arity = 3 },
    .{ .name = "svc_env", .arity = 3 },
    .{ .name = "svc_probe", .arity = 3 },
    .{ .name = "svc_bin", .arity = 2 },
    .{ .name = "svc_backoff", .arity = 2 },
    .{ .name = "user", .arity = 3 },
    .{ .name = "tool_fxstore", .arity = 1 },
    .{ .name = "boot_grace", .arity = 1 },
};

const M4Bag = struct {
    tuples: ?[*]u32 = null,
    n: usize = 0,
    cap: usize = 0,
};
fn m4_raw_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    const b: *M4Bag = @ptrCast(@alignCast(user.?));
    if (b.n == b.cap) {
        const nc: usize = if (b.cap != 0) b.cap * 2 else 16;
        const nt = reallocT(u32, b.tuples, nc * ar) orelse return 1;
        b.tuples = nt;
        b.cap = nc;
    }
    @memcpy(b.tuples.?[b.n * ar ..][0..ar], c[0..ar]);
    b.n += 1;
    return 0;
}

fn restore_m4_facts(db: *dl_db, vok: u32, err: ?[*]u8, errcap: usize) c_int {
    for (M4_RELS) |rel0| {
        if (dl_declare_relation(db, rel0.name, rel0.arity) != 0) {
            return fx_err(err, errcap, "declare {s}/{d} failed", .{ span(rel0.name), rel0.arity });
        }
    }
    if (dl_txn_begin(db) != 0) return fx_err(err, errcap, "m4 restore: txn begin failed", .{});
    for (M4_RELS) |rel0| {
        const rel = rel0.name;
        const ar = rel0.arity;
        const it = dl_iter_open(db, rel, null, 0);
        if (it) |iter| {
            const bad = dl_iter_arity(iter) != ar;
            var cap: usize = 64;
            var n: usize = 0;
            var all: ?[*]u32 = if (bad) null else mallocT(u32, cap * ar);
            var row: [8]u32 = undefined;
            var oom: c_int = 0;
            while (!bad and dl_iter_next(iter, &row) == 1) {
                if (n >= cap) {
                    cap *= 2;
                    const na = reallocT(u32, all, cap * ar);
                    if (na == null) {
                        oom = 1;
                        break;
                    }
                    all = na;
                }
                @memcpy(all.?[n * ar ..][0..ar], row[0..ar]);
                n += 1;
            }
            dl_iter_close(iter);
            if (oom != 0) {
                cfree(all);
                _ = fx_err(err, errcap, "m4 restore: oom", .{});
                _ = dl_txn_rollback(db);
                return -1;
            }
            if (bad) {
                _ = fx_err(err, errcap, "m4 restore: {s} arity mismatch", .{span(rel)});
                _ = dl_txn_rollback(db);
                return -1;
            }
            var k: usize = 0;
            while (k < n) : (k += 1)
                _ = dl_txn_delete_fact(db, rel, all.?[k * ar ..], ar);
            cfree(all);
        }
        var bag = M4Bag{};
        const cnt = dl_query_version(db, vok, rel, m4_raw_cb, &bag);
        if (cnt >= 0) {
            var k: usize = 0;
            while (k < bag.n) : (k += 1)
                _ = dl_txn_add_fact(db, rel, bag.tuples.?[k * ar ..], ar);
        }
        cfree(bag.tuples);
    }
    if (dl_txn_commit(db) != 0) {
        _ = fx_err(err, errcap, "m4 restore: commit failed", .{});
        _ = dl_txn_rollback(db);
        return -1;
    }
    return 0;
}

// ─── boot decision + dhake materialization (fx-init.c:628-745) ────────────

fn decide_boot_version() u32 {
    var err: [1024]u8 = undefined;
    const s = fx_store_open_wrap(g_store, &err, err.len) orelse {
        errf("fx-init: store open: {s}\n", .{span(@ptrCast(&err))});
        return 0;
    };
    var v: u32 = 0;
    if (fx_store_current_version_wrap(s, &v, &err, err.len) != 0) {
        errf("fx-init: no current version: {s}\n", .{span(@ptrCast(&err))});
        fx.fx_store_close(s);
        return 0;
    }
    g_current_version = v;
    fx.fx_store_close(s);

    var lv: u32 = 0;
    var lstatus: [64]u8 = [_]u8{0} ** 64;
    if (bootlog_last(&lv, &lstatus, lstatus.len) != 0 and lv == g_current_version and
        (strcmp(@ptrCast(&lstatus), "in-progress") == 0 or strcmp(@ptrCast(&lstatus), "failed") == 0))
    {
        var vok: u32 = 0;
        if (bootlog_newest_ok_below(g_current_version, &vok) != 0 and version_exists(vok) != 0) {
            errf("fx-init: stale {s} for v{d}; rolling forward to v{d}\n", .{ span(@ptrCast(&lstatus)), g_current_version, vok });
            var e2: [1024]u8 = undefined;
            if (fx_store_open_wrap(g_store, &e2, e2.len)) |rs| {
                const restored: c_int = @intFromBool(restore_m4_facts(store_db(rs), vok, &e2, e2.len) == 0);
                const rb: c_int = if (restored != 0) fx_store_rollback_wrap(rs, vok, false, &e2, e2.len) else -1;
                _ = fx_store_current_version_wrap(rs, &g_current_version, &e2, e2.len);
                if (rb == 0) {
                    log_line("fx-init", "info", "rolled forward to known-good generation");
                } else {
                    errf("fx-init: roll-forward failed (m4-restore={d}): {s}\n", .{ restored, span(@ptrCast(&e2)) });
                }
                fx.fx_store_close(rs);
            }
            return g_current_version;
        }
    }
    return g_current_version;
}

fn run_dhake() c_int {
    if (std.c.access(@ptrCast(&g_dhake), X_OK) != 0) {
        log_line("dhake", "error", "dhake binary not executable");
        return -1;
    }
    var bootbf: [1100]u8 = undefined;
    _ = snfmt(&bootbf, "{s}/Dhakefile.boot.dhall", .{span(@ptrCast(&g_run))});
    {
        const f = fopen(@ptrCast(&g_buildfile), "r") orelse {
            log_line("dhake", "error", "cannot open buildfile");
            return -1;
        };
        _ = fseek(f, 0, SEEK_END);
        const sz: c_long = ftell(f);
        _ = fseek(f, 0, SEEK_SET);
        if (sz < 0) {
            _ = fclose(f);
            log_line("dhake", "error", "buildfile stat failed");
            return -1;
        }
        const text = malloc(@as(usize, @intCast(sz)) + 1) orelse {
            _ = fclose(f);
            log_line("dhake", "error", "oom reading buildfile");
            return -1;
        };
        const rd = fread(text, 1, @intCast(sz), f);
        _ = fclose(f);
        text[rd] = 0;
        const rew = reloc_mod.fx_reloc_rewrite_buildfile(gpa_alloc, text[0..rd], span(g_store)) catch null;
        free(text);
        if (rew == null) {
            log_line("dhake", "error", "buildfile reloc rewrite failed");
            return -1;
        }
        const of = fopen(@ptrCast(&bootbf), "w") orelse {
            gpa_alloc.free(rew.?);
            log_line("dhake", "error", "cannot write boot buildfile");
            return -1;
        };
        const wl = rew.?.len;
        if (fwrite(rew.?.ptr, 1, wl, of) != wl) {
            _ = fclose(of);
            gpa_alloc.free(rew.?);
            _ = std.c.unlink(@ptrCast(&bootbf));
            log_line("dhake", "error", "boot buildfile write failed");
            return -1;
        }
        _ = fclose(of);
        gpa_alloc.free(rew.?);
    }
    var outpipe: [2]c_int = .{ -1, -1 };
    if (std.c.pipe(&outpipe) != 0) {
        log_line("dhake", "error", "pipe failed");
        _ = std.c.unlink(@ptrCast(&bootbf));
        return -1;
    }
    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(outpipe[0]);
        _ = std.c.close(outpipe[1]);
        log_line("dhake", "error", "fork failed");
        _ = std.c.unlink(@ptrCast(&bootbf));
        return -1;
    }
    if (pid == 0) {
        _ = std.c.close(outpipe[0]);
        _ = std.c.dup2(outpipe[1], 1);
        _ = std.c.dup2(outpipe[1], 2);
        _ = std.c.close(outpipe[1]);
        const av = [_:null]?[*:0]const u8{ "dhake.com", "-f", @ptrCast(&bootbf), "rootfs" };
        _ = execv(@ptrCast(&g_dhake), &av);
        _ = std.c.write(2, "fx-init: exec dhake failed\n", "fx-init: exec dhake failed\n".len);
        std.c._exit(127);
    }
    _ = std.c.close(outpipe[1]);
    if (fdopen(outpipe[0], "r")) |rf| {
        var line: [1024]u8 = undefined;
        while (fgets(&line, @intCast(line.len), rf)) |_| {
            const L: usize = strlen(@ptrCast(&line));
            if (L != 0 and line[L - 1] == '\n') line[L - 1] = 0;
            log_line("dhake", "info", @ptrCast(&line));
        }
        _ = fclose(rf);
    } else {
        _ = std.c.close(outpipe[0]);
    }
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 0) < 0 and std.c._errno().* == EINTR) {}
    _ = std.c.unlink(@ptrCast(&bootbf));
    const rc: c_int = if (std.os.linux.W.IFEXITED(@bitCast(status))) @as(c_int, std.os.linux.W.EXITSTATUS(@bitCast(status))) else -1;
    return rc;
}

// ─── readiness + supervision (fx-init.c:750-879) ──────────────────────────

fn on_ready(sv: *Svc) c_int {
    return switch (sv.on_kind) {
        .all => 1,
        .up => blk: {
            const d = svc_find(@ptrCast(&sv.on_arg));
            break :blk if (d != null and d.?.ready != 0) 1 else 0;
        },
        .time => blk: {
            const ms: u32 = @truncate(strtoul(@ptrCast(&sv.on_arg), null, 10));
            break :blk if (@as(u32, @truncate(now_ms() -% g_boot_start_ms)) >= ms) 1 else 0;
        },
        .net => blk: {
            const it = dl_iter_open(g_rt.?, "net", null, 0);
            var hit: c_int = 0;
            if (it) |iter| {
                var r: [6]u32 = undefined;
                while (dl_iter_next(iter, &r) == 1) {
                    const iface = dl_intern_str_of(g_rt.?, r[0]);
                    const st = dl_intern_str_of(g_rt.?, r[3]);
                    if (iface != null and strcmp(iface.?, "lo") != 0 and st != null and strcmp(st.?, "up") == 0) {
                        hit = 1;
                        break;
                    }
                }
                dl_iter_close(iter);
            }
            break :blk hit;
        },
        .sock_tcp => @intCast(sup.fx_sock_ready(true, span(@ptrCast(&sv.on_arg)))),
        .sock_unix => @intCast(sup.fx_sock_ready(false, span(@ptrCast(&sv.on_arg)))),
    };
}

fn probe_ready(sv: *Svc) c_int {
    if (sv.probe_kind == .none) return 1;
    if (sv.probe_kind == .file) return if (std.c.access(@ptrCast(&sv.probe_arg), F_OK) == 0) 1 else 0;
    if (sv.probe_kind == .tcp) return @intCast(sup.fx_sock_ready(true, span(@ptrCast(&sv.probe_arg))));
    return @intCast(sup.fx_sock_ready(false, span(@ptrCast(&sv.probe_arg))));
}

fn start_service(sv: *Svc) void {
    var outpipe: [2]c_int = .{ -1, -1 };
    if (std.c.pipe(&outpipe) != 0) {
        log_line(@ptrCast(&sv.name), "error", "pipe failed");
        return;
    }
    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(outpipe[0]);
        _ = std.c.close(outpipe[1]);
        log_line(@ptrCast(&sv.name), "error", "fork failed");
        return;
    }
    if (pid == 0) {
        _ = std.c.close(outpipe[0]);
        _ = std.c.dup2(outpipe[1], 1);
        _ = std.c.dup2(outpipe[1], 2);
        _ = std.c.close(outpipe[1]);
        _ = std.c.setsid();
        _ = setenv("FX_SVC_NAME", @ptrCast(&sv.name), 1);
        _ = setenv("FX_RUN_DIR", @ptrCast(&g_run), 1);
        _ = setenv("PATH", "/bin", 1);
        var i: c_int = 0;
        while (i < sv.nenv) : (i += 1) {
            _ = setenv(sv.env_k.?[@intCast(i)].?, sv.env_v.?[@intCast(i)].?, 1);
        }
        const av: [*:null]const ?[*:0]const u8 = @ptrCast(sv.argv.?);
        _ = execv(sv.argv.?[0].?, av);
        _ = std.c.write(2, "fx-init: exec failed\n", "fx-init: exec failed\n".len);
        std.c._exit(127);
    }
    _ = std.c.close(outpipe[1]);
    sv.pid = pid;
    sv.state = ST_STARTED;
    sv.started_at = time(null);
    sv.out_fd = outpipe[0];
    _ = std.c.fcntl(sv.out_fd, F_SETFL, std.c.fcntl(sv.out_fd, F_GETFL) | O_NONBLOCK);
    rt_txn_begin();
    rt_set_service(sv);
    _ = rt_txn_commit();
    var m: [256]u8 = undefined;
    _ = snfmt(&m, "started (pid {d})", .{pid});
    log_line(@ptrCast(&sv.name), "info", @ptrCast(&m));
}

fn stop_service(sv: *Svc) void {
    if (sv.pid > 0) {
        _ = std.c.kill(sv.pid, std.c.SIG.TERM);
        log_line(@ptrCast(&sv.name), "info", "stopping (SIGTERM)");
    }
}

fn drain_pipe(sv: *Svc) void {
    if (sv.out_fd < 0) return;
    var buf: [4096]u8 = undefined;
    const n = std.c.read(sv.out_fd, &buf, buf.len - 1);
    if (n <= 0) {
        if (n == 0 or std.c._errno().* != EAGAIN) {
            _ = std.c.close(sv.out_fd);
            sv.out_fd = -1;
        }
        return;
    }
    buf[@intCast(n)] = 0;
    var save: ?[*:0]u8 = null;
    var tok = strtok_r(@ptrCast(&buf), "\n", &save);
    while (tok) |t| {
        log_line(@ptrCast(&sv.name), "info", t);
        tok = strtok_r(null, "\n", &save);
    }
}

/// Pure START-ONLY boot-ok decision (fx-init.c:852-879): the side-effecting
/// wrapper (evaluate_boot_ok) applies the pinned rt_set_boot/bootlog/log.
fn boot_decision(boot_decided: bool, svcs: []const Svc, grace_expired: bool) enum(u8) { none, ok, failed } {
    if (boot_decided) return .none;
    var all_started = true;
    var any_failed = false;
    for (svcs) |*sv| {
        if (sv.state != ST_STARTED and sv.state != ST_STOPPED) all_started = false;
        if (sv.state == ST_FAILED) any_failed = true;
    }
    if (grace_expired and all_started and !any_failed) return .ok;
    if (grace_expired or any_failed) return .failed;
    return .none;
}

fn svcSlice() []const Svc {
    if (g_svc) |s| return s[0..@intCast(g_nsvc)];
    return &.{};
}

fn evaluate_boot_ok() void {
    const decision = boot_decision(g_boot_decided != 0, svcSlice(), sup.fx_boot_grace_expired(now_ms(), g_boot_deadline_ms) != 0);
    switch (decision) {
        .none => {},
        .ok => {
            rt_txn_begin();
            rt_set_boot(g_current_version, "ok");
            _ = rt_txn_commit();
            bootlog_append(g_current_version, "ok", now_s());
            log_line("fx-init", "info", "boot ok");
            g_boot_decided = 1;
            g_boot_failed = 0;
        },
        .failed => {
            rt_txn_begin();
            rt_set_boot(g_current_version, "failed");
            _ = rt_txn_commit();
            bootlog_append(g_current_version, "failed", now_s());
            log_line("fx-init", "error", "boot failed");
            g_boot_decided = 1;
            g_boot_failed = 1;
        },
    }
}

// ─── SIGCHLD + child reaping (fx-init.c:883-961) ──────────────────────────

fn sigchld_handler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    if (g_sigpipe[1] >= 0) {
        var b: [1]u8 = .{'C'};
        _ = std.c.write(g_sigpipe[1], &b, 1);
    }
}
fn sigterm_handler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    g_shutdown.store(1, .monotonic);
    if (g_sigpipe[1] >= 0) {
        var b: [1]u8 = .{'T'};
        _ = std.c.write(g_sigpipe[1], &b, 1);
    }
}

fn reap_children() void {
    var status: c_int = 0;
    while (true) {
        const pid = std.c.waitpid(-1, &status, std.os.linux.W.NOHANG);
        if (pid <= 0) break;
        var sv: ?*Svc = null;
        var i: c_int = 0;
        while (i < g_nsvc) : (i += 1) {
            if (g_svc.?[@intCast(i)].pid == pid) {
                sv = &g_svc.?[@intCast(i)];
                break;
            }
        }
        if (sv == null) continue;
        const s = sv.?;
        const st_u32: u32 = @bitCast(status);
        const exited_ok = std.os.linux.W.IFEXITED(st_u32) and std.os.linux.W.EXITSTATUS(st_u32) == 0;
        const was_explicit_stop = (s.state == ST_STOPPED);
        s.pid = 0;
        if (s.out_fd >= 0) {
            _ = std.c.close(s.out_fd);
            s.out_fd = -1;
        }
        var m: [256]u8 = undefined;
        var restart: c_int = 0;
        if (s.restart == .always) restart = 1
        else if (s.restart == .on_failure) restart = @intFromBool(!exited_ok);
        if (was_explicit_stop) restart = 0;
        if (restart != 0) {
            s.restarts += 1;
            const bo = sup.fx_backoff_sleep_ms(s.cur_backoff, s.backoff_ms);
            s.next_start = time(null) + @as(i64, @intCast((bo + 999) / 1000));
            s.cur_backoff = sup.fx_backoff_next(bo);
            s.state = ST_BACKOFF;
            _ = snfmt(&m, "exited ({s}); restart #{d} in {d}ms", .{ if (exited_ok) "ok" else "fail", s.restarts, bo });
            log_line(@ptrCast(&s.name), if (exited_ok) "info" else "error", @ptrCast(&m));
        } else {
            s.state = if (exited_ok) ST_STOPPED else ST_FAILED;
            _ = snfmt(&m, "exited ({s}); not restarting", .{if (exited_ok) "ok" else "fail"});
            log_line(@ptrCast(&s.name), if (exited_ok) "info" else "error", @ptrCast(&m));
        }
        rt_txn_begin();
        rt_set_service(s);
        if (s.state == ST_STARTED or s.state == ST_BACKOFF) {
            if (s.probe_kind == .none) rt_set_ready(s, 1)
            else if (probe_ready(s) != 0) rt_set_ready(s, 1);
        }
        _ = rt_txn_commit();

        if (g_boot_decided == 0 and !was_explicit_stop) {
            rt_txn_begin();
            rt_set_boot(g_current_version, "failed");
            _ = rt_txn_commit();
            bootlog_append(g_current_version, "failed", now_s());
            log_line("fx-init", "error", "boot failed: service exited during grace window");
            g_boot_decided = 1;
            g_boot_failed = 1;
        }
    }
}

// ─── control socket server (fx-init.c:965-1190) ───────────────────────────

const RelSchema = struct {
    name: [*:0]const u8,
    arity: u8,
    strcol: [8]u8 = [_]u8{0} ** 8,
};
const RELS = [_]RelSchema{
    .{ .name = "generation_current", .arity = 1, .strcol = .{ 0, 0, 0, 0, 0, 0, 0, 0 } },
    .{ .name = "boot_status", .arity = 2, .strcol = .{ 1, 0, 0, 0, 0, 0, 0, 0 } },
    .{ .name = "service_runtime", .arity = 4, .strcol = .{ 1, 0, 1, 0, 0, 0, 0, 0 } },
    .{ .name = "ready", .arity = 1, .strcol = .{ 1, 0, 0, 0, 0, 0, 0, 0 } },
    .{ .name = "control", .arity = 3, .strcol = .{ 0, 1, 1, 0, 0, 0, 0, 0 } },
    .{ .name = "effect", .arity = 3, .strcol = .{ 0, 1, 1, 0, 0, 0, 0, 0 } },
    .{ .name = "process", .arity = 6, .strcol = .{ 0, 0, 0, 1, 1, 0, 0, 0 } },
    .{ .name = "fs", .arity = 5, .strcol = .{ 1, 1, 0, 0, 0, 0, 0, 0 } },
    .{ .name = "file", .arity = 6, .strcol = .{ 1, 0, 0, 0, 0, 0, 0, 0 } },
    .{ .name = "device", .arity = 5, .strcol = .{ 1, 0, 0, 1, 0, 0, 0, 0 } },
    .{ .name = "kernel", .arity = 7, .strcol = .{ 1, 1, 1, 0, 0, 0, 0, 0 } },
    .{ .name = "net", .arity = 6, .strcol = .{ 1, 1, 1, 1, 0, 0, 0, 0 } },
    .{ .name = "env", .arity = 2, .strcol = .{ 1, 1, 0, 0, 0, 0, 0, 0 } },
};

fn find_schema(name: [*:0]const u8) ?*const RelSchema {
    for (&RELS) |*rs| {
        if (strcmp(rs.name, name) == 0) return rs;
    }
    return null;
}

fn emit_tuple(o: *FILE, db: *dl_db, rs: *const RelSchema, c: [*]const u32) void {
    var i: usize = 0;
    while (i < rs.arity) : (i += 1) {
        if (i != 0) _ = fputc('\t', o);
        if (rs.strcol[i] != 0) {
            const s = dl_intern_str_of(db, c[i]);
            _ = fputs(s orelse "?", o);
        } else {
            _ = fprintf(o, "%u", c[i]);
        }
    }
    _ = fputc('\n', o);
}

const QCtx = struct { o: *FILE, db: *dl_db, rs: *const RelSchema };
fn query_cb(c: [*]const u32, ar: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = ar;
    const q: *QCtx = @ptrCast(@alignCast(user.?));
    emit_tuple(q.o, q.db, q.rs, c);
    return 0;
}

fn resp_ok(o: *FILE) void {
    _ = fputs("OK\n", o);
    _ = fflush(o);
}
fn resp_err(o: *FILE, msg: [*:0]const u8) void {
    _ = fprintf(o, "ERR %s\n", msg);
    _ = fflush(o);
}

const GrepEmitCtx = struct { o: *FILE, db: ?*dl_db };
fn grep_log_cb(ts: u32, svc: [*:0]const u8, lvl: [*:0]const u8, msg: [*:0]const u8, user: ?*anyopaque) callconv(.c) c_int {
    const g: *GrepEmitCtx = @ptrCast(@alignCast(user.?));
    _ = g.db;
    _ = fprintf(g.o, "%u\t%s\t%s\t%s\n", ts, svc, lvl, msg);
    return 0;
}
fn search_log_cb(ts: u32, svc: [*:0]const u8, lvl: [*:0]const u8, msg: [*:0]const u8, user: ?*anyopaque) callconv(.c) c_int {
    return grep_log_cb(ts, svc, lvl, msg, user);
}

fn handle_request(o: *FILE, line: [*:0]u8) void {
    var save: ?[*:0]u8 = null;
    const cmd = strtok_r(line, " \t", &save) orelse {
        resp_err(o, "empty");
        return;
    };

    if (strcmp(cmd, "status") == 0) {
        _ = fprintf(o, "boot_status:\n");
        {
            const it = dl_iter_open(g_rt.?, "boot_status", null, 0);
            if (it) |iter| {
                var r: [2]u32 = undefined;
                while (dl_iter_next(iter, &r) == 1)
                    _ = fprintf(o, "  %u\t%s\n", r[0], dl_intern_str_of(g_rt.?, r[1]));
                dl_iter_close(iter);
            }
        }
        _ = fprintf(o, "generation_current:\n");
        {
            const it = dl_iter_open(g_rt.?, "generation_current", null, 0);
            if (it) |iter| {
                var r: [1]u32 = undefined;
                while (dl_iter_next(iter, &r) == 1) _ = fprintf(o, "  %u\n", r[0]);
                dl_iter_close(iter);
            }
        }
        _ = fprintf(o, "service_runtime:\n");
        {
            const rs = find_schema("service_runtime").?;
            var q = QCtx{ .o = o, .db = g_rt.?, .rs = rs };
            const it = dl_iter_open(g_rt.?, "service_runtime", null, 0);
            if (it) |iter| {
                var r: [4]u32 = undefined;
                while (dl_iter_next(iter, &r) == 1) _ = query_cb(&r, 4, &q);
                dl_iter_close(iter);
            }
        }
        resp_ok(o);
        return;
    }

    if (strcmp(cmd, "q") == 0) {
        const rel = strtok_r(null, " \t", &save) orelse {
            resp_err(o, "q <rel> [vals]");
            return;
        };
        const rs = find_schema(rel) orelse {
            resp_err(o, "unknown relation");
            return;
        };
        var lead: [8]u32 = undefined;
        var k: c_int = 0;
        while (k < 8) {
            const tok = strtok_r(null, " \t", &save) orelse break;
            if (rs.strcol[@intCast(k)] != 0) lead[@intCast(k)] = isym(g_rt.?, tok)
            else lead[@intCast(k)] = @truncate(strtoul(tok, null, 10));
            k += 1;
        }
        var q = QCtx{ .o = o, .db = g_rt.?, .rs = rs };
        var n: c_long = undefined;
        if (k > 0) n = dl_query_bound(g_rt.?, rel, &lead, @intCast(k), query_cb, &q)
        else n = dl_query(g_rt.?, rel, query_cb, &q);
        if (n < 0) {
            resp_err(o, "query failed");
            return;
        }
        resp_ok(o);
        return;
    }

    if (strcmp(cmd, "start") == 0 or strcmp(cmd, "stop") == 0 or strcmp(cmd, "restart") == 0) {
        const name = strtok_r(null, " \t", &save) orelse {
            resp_err(o, "start|stop|restart <svc>");
            return;
        };
        const txn = g_txn_id;
        g_txn_id += 1;
        rt_txn_begin();
        rt_control(txn, cmd, name);
        _ = rt_txn_commit();
        const sv = svc_find(name) orelse {
            resp_err(o, "unknown service");
            return;
        };
        if (strcmp(cmd, "start") == 0) {
            if (sv.pid <= 0) start_service(sv);
        } else if (strcmp(cmd, "stop") == 0) {
            sv.state = ST_STOPPED;
            stop_service(sv);
        } else {
            sv.state = ST_STOPPED;
            stop_service(sv);
            sv.next_start = time(null);
        }
        rt_txn_begin();
        rt_effect(txn, "applied", name);
        _ = rt_txn_commit();
        resp_ok(o);
        return;
    }

    if (strcmp(cmd, "probe") == 0) {
        var err: [256]u8 = undefined;
        if (fx_probe_refresh(g_rt, g_probe_root, &err, err.len) != 0) {
            resp_err(o, @ptrCast(&err));
            return;
        }
        resp_ok(o);
        return;
    }

    if (strcmp(cmd, "shutdown") == 0) {
        const txn = g_txn_id;
        g_txn_id += 1;
        rt_txn_begin();
        rt_control(txn, "shutdown", "");
        _ = rt_txn_commit();
        g_shutdown.store(1, .monotonic);
        if (g_sigpipe[1] >= 0) {
            var b: [1]u8 = .{'T'};
            _ = std.c.write(g_sigpipe[1], &b, 1);
        }
        resp_ok(o);
        return;
    }

    if (strcmp(cmd, "activate") == 0 or strcmp(cmd, "rollback") == 0) {
        const arg = strtok_r(null, " \t", &save) orelse {
            resp_err(o, "activate <path> | rollback <v>");
            return;
        };
        const txn = g_txn_id;
        g_txn_id += 1;
        rt_txn_begin();
        rt_control(txn, cmd, arg);
        _ = rt_txn_commit();
        if (strcmp(cmd, "activate") == 0) {
            const pid = std.c.fork();
            if (pid == 0) {
                const av = [_:null]?[*:0]const u8{ @ptrCast(&g_fxstore), "--store", g_store, "--config", arg };
                _ = execv(@ptrCast(&g_fxstore), &av);
                std.c._exit(127);
            }
            var rc: c_int = -1;
            if (pid > 0) {
                var st: c_int = 0;
                _ = std.c.waitpid(pid, &st, 0);
                const st_u32: u32 = @bitCast(st);
                rc = if (std.os.linux.W.IFEXITED(st_u32)) @as(c_int, std.os.linux.W.EXITSTATUS(st_u32)) else 1;
            }
            if (rc != 0) {
                rt_txn_begin();
                rt_effect(txn, "activate", "failed");
                _ = rt_txn_commit();
                resp_err(o, "activate failed");
                return;
            }
            var e2: [1024]u8 = undefined;
            const s = fx_store_open_wrap(g_store, &e2, e2.len) orelse {
                resp_err(o, "store open after activate");
                return;
            };
            _ = fx_store_current_version_wrap(s, &g_current_version, &e2, e2.len);
            fx.fx_store_close(s);
            _ = read_store_facts(g_current_version);
            rt_txn_begin();
            rt_set_generation_current(g_current_version);
            _ = rt_txn_commit();
            _ = fprintf(o, "activated version %u\n", g_current_version);
            rt_txn_begin();
            rt_effect(txn, "version", "");
            _ = rt_txn_commit();
            resp_ok(o);
            return;
        } else {
            const v: u32 = @truncate(strtoul(arg, null, 10));
            var e2: [1024]u8 = undefined;
            const s = fx_store_open_wrap(g_store, &e2, e2.len) orelse {
                resp_err(o, "store open");
                return;
            };
            if (restore_m4_facts(store_db(s), v, &e2, e2.len) != 0 or
                fx_store_rollback_wrap(s, v, false, &e2, e2.len) != 0)
            {
                fx.fx_store_close(s);
                resp_err(o, @ptrCast(&e2));
                return;
            }
            _ = fx_store_current_version_wrap(s, &g_current_version, &e2, e2.len);
            fx.fx_store_close(s);
            _ = read_store_facts(g_current_version);
            rt_txn_begin();
            rt_set_generation_current(g_current_version);
            _ = rt_txn_commit();
            _ = fprintf(o, "rolled back to version %u (current %u)\n", v, g_current_version);
            resp_ok(o);
            return;
        }
    }

    if (strcmp(cmd, "grep") == 0 or strcmp(cmd, "search") == 0) {
        const rest = strtok_r(null, "", &save) orelse {
            resp_err(o, "grep <regex> | search <terms>");
            return;
        };
        var rp = rest;
        while (rp[0] == ' ' or rp[0] == '\t') rp += 1;
        if (strcmp(cmd, "grep") == 0) {
            var gc = GrepEmitCtx{ .o = o, .db = g_log };
            const n = fx_log_grep(g_log, rp, grep_log_cb, &gc);
            if (n < 0) {
                resp_err(o, "grep failed");
                return;
            }
        } else {
            var terms: [32]?[*:0]u8 = undefined;
            var nt: c_int = 0;
            var ts: ?[*:0]u8 = rp;
            var tsave: ?[*:0]u8 = null;
            while (nt < 32) {
                const t = strtok_r(ts, " \t", &tsave) orelse break;
                terms[@intCast(nt)] = t;
                nt += 1;
                ts = null;
            }
            var gc = GrepEmitCtx{ .o = o, .db = g_log };
            const n = fx_log_search(g_log, @ptrCast(&terms), nt, search_log_cb, &gc);
            if (n < 0) {
                resp_err(o, "search failed");
                return;
            }
        }
        resp_ok(o);
        return;
    }

    resp_err(o, "unknown command");
}

fn setup_ctrl() c_int {
    var sp: [1100]u8 = undefined;
    _ = snfmt(&sp, "{s}/control.sock", .{span(@ptrCast(&g_run))});
    _ = std.c.unlink(@ptrCast(&sp));
    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    var a = std.mem.zeroes(SockaddrUn);
    a.family = AF_UNIX;
    var pl: usize = strlen(@ptrCast(&sp));
    if (pl >= a.path.len) pl = a.path.len - 1;
    @memcpy(a.path[0..pl], sp[0..pl]);
    a.path[pl] = 0;
    if (bind(fd, @ptrCast(&a), @sizeOf(SockaddrUn)) < 0) {
        _ = std.c.close(fd);
        return -1;
    }
    if (listen(fd, 8) < 0) {
        _ = std.c.close(fd);
        return -1;
    }
    _ = std.c.fcntl(fd, F_SETFL, std.c.fcntl(fd, F_GETFL) | O_NONBLOCK);
    return fd;
}

fn handle_conn(cfd: c_int) void {
    const o = fdopen(cfd, "w") orelse {
        _ = std.c.close(cfd);
        return;
    };
    const r = fdopen(std.c.dup(cfd), "r") orelse {
        _ = fclose(o);
        return;
    };
    var line: [REQ_MAX + 1]u8 = undefined;
    if (fgets(&line, @intCast(line.len), r) == null) {
        _ = fclose(r);
        _ = fclose(o);
        return;
    }
    const L: usize = strlen(@ptrCast(&line));
    if (L != 0 and line[L - 1] == '\n') line[L - 1] = 0;
    handle_request(o, @ptrCast(&line));
    _ = fclose(r);
    _ = fclose(o);
}

// ─── shutdown (fx-init.c:1194-1220) ───────────────────────────────────────

fn do_shutdown() void {
    log_line("fx-init", "info", "shutdown");
    var i: c_int = g_nsvc - 1;
    while (i >= 0) : (i -= 1) {
        const sv = &g_svc.?[@intCast(i)];
        if (sv.pid > 0) {
            _ = std.c.kill(sv.pid, std.c.SIG.TERM);
            sv.state = ST_STOPPED;
        }
    }
    var round: c_int = 0;
    while (round < 50) : (round += 1) {
        var alive: c_int = 0;
        var j: c_int = 0;
        while (j < g_nsvc) : (j += 1) {
            if (g_svc.?[@intCast(j)].pid > 0) alive = 1;
        }
        if (alive == 0) break;
        var status: c_int = 0;
        while (true) {
            const pid = std.c.waitpid(-1, &status, std.os.linux.W.NOHANG);
            if (pid <= 0) break;
            var k: c_int = 0;
            while (k < g_nsvc) : (k += 1) {
                if (g_svc.?[@intCast(k)].pid == pid) {
                    g_svc.?[@intCast(k)].pid = 0;
                    if (g_svc.?[@intCast(k)].out_fd >= 0) {
                        _ = std.c.close(g_svc.?[@intCast(k)].out_fd);
                        g_svc.?[@intCast(k)].out_fd = -1;
                    }
                    break;
                }
            }
        }
        if (alive != 0) {
            const ts = std.c.timespec{ .sec = 0, .nsec = 100 * 1000 * 1000 };
            _ = std.c.nanosleep(&ts, null);
        }
    }
    i = 0;
    while (i < g_nsvc) : (i += 1) {
        if (g_svc.?[@intCast(i)].pid > 0) _ = std.c.kill(g_svc.?[@intCast(i)].pid, std.c.SIG.KILL);
    }
    var status: c_int = 0;
    while (std.c.waitpid(-1, &status, std.os.linux.W.NOHANG) > 0) {}
    bootlog_append(g_current_version, "shutdown", now_s());
    var sp: [1100]u8 = undefined;
    _ = snfmt(&sp, "{s}/control.sock", .{span(@ptrCast(&g_run))});
    _ = std.c.unlink(@ptrCast(&sp));
    if (g_ctrl_fd >= 0) _ = std.c.close(g_ctrl_fd);
    if (g_rt) |r| dl_close(r);
    if (g_log) |l| fx_log_close(l);
}

// ─── main loop (fx-init.c:1225-1352) ──────────────────────────────────────

fn next_timeout_calc(boot_decided: bool, now_ms_val: u64, boot_deadline_ms: u64, now: i64, next_probe: i64, svcs: []const Svc) i32 {
    var ms: i32 = 1000;
    if (!boot_decided) {
        if (boot_deadline_ms > now_ms_val) {
            const d: i64 = @intCast(boot_deadline_ms - now_ms_val);
            if (d < ms) ms = @intCast(d);
        }
    }
    if (next_probe > now) {
        const d: i64 = (next_probe - now) * 1000;
        if (d < ms) ms = @intCast(d);
    }
    for (svcs) |sv| {
        if (sv.state == ST_BACKOFF and sv.next_start > now) {
            const d: i64 = (sv.next_start - now) * 1000;
            if (d < ms) ms = @intCast(d);
        }
    }
    if (ms < 10) ms = 10;
    return ms;
}

fn next_timeout() i32 {
    return next_timeout_calc(g_boot_decided != 0, now_ms(), g_boot_deadline_ms, time(null), g_next_probe, svcSlice());
}

fn main_loop() void {
    while (g_shutdown.load(.monotonic) == 0) {
        var pf: [2 + 64]std.posix.pollfd = undefined;
        var nfd: usize = 0;
        pf[nfd] = .{ .fd = g_sigpipe[0], .events = std.posix.POLL.IN, .revents = 0 };
        nfd += 1;
        if (g_ctrl_fd >= 0) {
            pf[nfd] = .{ .fd = g_ctrl_fd, .events = std.posix.POLL.IN, .revents = 0 };
            nfd += 1;
        }
        var i: c_int = 0;
        while (i < g_nsvc and nfd < pf.len) : (i += 1) {
            if (g_svc.?[@intCast(i)].out_fd >= 0) {
                pf[nfd] = .{ .fd = g_svc.?[@intCast(i)].out_fd, .events = std.posix.POLL.IN, .revents = 0 };
                nfd += 1;
            }
        }
        _ = std.posix.poll(pf[0..nfd], next_timeout()) catch break;

        var pi: usize = 0;
        while (pi < nfd) : (pi += 1) {
            if (pf[pi].fd == g_sigpipe[0] and (pf[pi].revents & std.posix.POLL.IN) != 0) {
                var buf: [16]u8 = undefined;
                while (std.c.read(g_sigpipe[0], &buf, buf.len) > 0) {}
                reap_children();
            }
        }
        if (g_ctrl_fd >= 0) {
            pi = 0;
            while (pi < nfd) : (pi += 1) {
                if (pf[pi].fd == g_ctrl_fd and (pf[pi].revents & std.posix.POLL.IN) != 0) {
                    const cfd = accept(g_ctrl_fd, null, null);
                    if (cfd >= 0) handle_conn(cfd);
                }
            }
        }
        pi = 0;
        while (pi < nfd) : (pi += 1) {
            var j: c_int = 0;
            while (j < g_nsvc) : (j += 1) {
                if (pf[pi].fd == g_svc.?[@intCast(j)].out_fd and (pf[pi].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
                    drain_pipe(&g_svc.?[@intCast(j)]);
                }
            }
        }

        const now: i64 = time(null);

        rt_txn_begin();
        i = 0;
        while (i < g_nsvc) : (i += 1) {
            const sv = &g_svc.?[@intCast(i)];
            if (sv.state == ST_PENDING and on_ready(sv) != 0) {
                rt_set_service(sv);
            }
        }
        _ = rt_txn_commit();
        i = 0;
        while (i < g_nsvc) : (i += 1) {
            const sv = &g_svc.?[@intCast(i)];
            if (sv.state == ST_PENDING and on_ready(sv) != 0) {
                start_service(sv);
            } else if (sv.state == ST_BACKOFF and now >= sv.next_start and on_ready(sv) != 0) {
                sv.state = ST_PENDING;
                start_service(sv);
            }
        }

        i = 0;
        while (i < g_nsvc) : (i += 1) {
            const sv = &g_svc.?[@intCast(i)];
            if (sv.state == ST_STARTED and sv.ready == 0) {
                if (sv.probe_kind == .none) {
                    rt_txn_begin();
                    rt_set_ready(sv, 1);
                    _ = rt_txn_commit();
                } else if (probe_ready(sv) != 0) {
                    rt_txn_begin();
                    rt_set_ready(sv, 1);
                    _ = rt_txn_commit();
                }
            }
        }

        i = 0;
        while (i < g_nsvc) : (i += 1) {
            const sv = &g_svc.?[@intCast(i)];
            if (sv.state == ST_STARTED and sv.cur_backoff != 0) {
                const stable_ms: u32 = @as(u32, @truncate(@as(u64, @bitCast(now - sv.started_at)))) *% 1000;
                if (sup.fx_backoff_should_reset(stable_ms) != 0) {
                    sv.cur_backoff = 0;
                    log_line(@ptrCast(&sv.name), "info", "backoff reset (60s stable)");
                }
            }
        }

        evaluate_boot_ok();

        if (now >= g_next_probe) {
            var err: [256]u8 = undefined;
            _ = fx_probe_refresh(g_rt, g_probe_root, &err, err.len);
            g_next_probe = now + @as(i64, g_probe_s);
        }

        if (g_log) |l| _ = fx_log_rotate(l, g_log_cap);
    }
}

// ─── main (fx-init.c:1356-1489) ───────────────────────────────────────────

fn usage(o: *FILE) void {
    _ = fprintf(o,
        "fx-init — fixpoint-linux PID1/supervisor\n" ++
            "usage: fx-init [--store DIR] [--run-dir DIR] [--probe-interval-s N]\n" ++
            "                [--log-cap N] [--grace-ms N] [--probe-fixture-root DIR]\n" ++
            "  --store DIR              store root (default %s)\n" ++
            "  --run-dir DIR            runtime dir (default %s)\n" ++
            "  --probe-interval-s N     probe refresh seconds (default %d)\n" ++
            "  --log-cap N              log tuple cap before rotation (default %llu)\n" ++
            "  --grace-ms N            boot grace timeout ms (default %u)\n" ++
            "  --probe-fixture-root DIR test-only /proc,/sys,/etc root\n",
        DEFAULT_STORE, DEFAULT_RUN, @as(c_int, DEFAULT_PROBE_S), @as(c_ulonglong, DEFAULT_LOG_CAP), @as(c_uint, DEFAULT_GRACE_MS));
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    g_io = init.io;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: [:0]const u8 = args[i];
        if (std.mem.eql(u8, a, "--store")) {
            i += 1;
            if (i >= args.len) {
                usage(stderr);
                std.process.exit(2);
            }
            g_store = args[i].ptr;
        } else if (std.mem.eql(u8, a, "--run-dir")) {
            i += 1;
            if (i >= args.len) {
                usage(stderr);
                std.process.exit(2);
            }
            _ = snfmt(&g_run, "{s}", .{args[i]});
        } else if (std.mem.eql(u8, a, "--probe-interval-s")) {
            i += 1;
            if (i >= args.len) {
                usage(stderr);
                std.process.exit(2);
            }
            g_probe_s = atoi(args[i].ptr);
        } else if (std.mem.eql(u8, a, "--log-cap")) {
            i += 1;
            if (i >= args.len) {
                usage(stderr);
                std.process.exit(2);
            }
            g_log_cap = strtoul(args[i].ptr, null, 10);
        } else if (std.mem.eql(u8, a, "--grace-ms")) {
            i += 1;
            if (i >= args.len) {
                usage(stderr);
                std.process.exit(2);
            }
            g_grace_ms = @truncate(strtoul(args[i].ptr, null, 10));
        } else if (std.mem.eql(u8, a, "--probe-fixture-root")) {
            i += 1;
            if (i >= args.len) {
                usage(stderr);
                std.process.exit(2);
            }
            g_probe_root = args[i].ptr;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage(stdout);
            _ = fflush(stdout);
            std.process.exit(0);
        } else {
            errf("fx-init: unknown arg '{s}'\n", .{a});
            usage(stderr);
            std.process.exit(2);
        }
    }

    if (std.c.getpid() != 1 and getenv("FX_INIT_FORCE") == null) {
        errf("fx-init: refusing to run (not PID1; set FX_INIT_FORCE=1 to override)\n", .{});
        std.process.exit(1);
    }

    if (std.c.pipe(&g_sigpipe) != 0) {
        errf("fx-init: pipe: {s}\n", .{errnoStr()});
        std.process.exit(1);
    }
    _ = std.c.fcntl(g_sigpipe[0], F_SETFL, std.c.fcntl(g_sigpipe[0], F_GETFL) | O_NONBLOCK);
    _ = std.c.fcntl(g_sigpipe[1], F_SETFL, std.c.fcntl(g_sigpipe[1], F_GETFL) | O_NONBLOCK);
    var sa = std.mem.zeroes(std.posix.Sigaction);
    sa.handler = .{ .handler = sigchld_handler };
    sa.flags = @as(c_ulong, std.os.linux.SA.RESTART | std.os.linux.SA.NOCLDSTOP);
    std.posix.sigaction(std.posix.SIG.CHLD, &sa, null);
    sa.handler = .{ .handler = sigterm_handler };
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    sa.handler = .{ .handler = std.posix.SIG.IGN };
    std.posix.sigaction(std.posix.SIG.PIPE, &sa, null);

    if (std.c.prctl(PR_SET_CHILD_SUBREAPER, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) {
        errf("fx-init: warning: PR_SET_CHILD_SUBREAPER failed: {s} (orphaned daemon grandchildren may not be reaped)\n", .{errnoStr()});
    }

    _ = mkdirp(@ptrCast(&g_run));
    var rtp: [1100]u8 = undefined;
    _ = snfmt(&rtp, "{s}/state.db", .{span(@ptrCast(&g_run))});
    g_rt = dl_open(@ptrCast(&rtp)) orelse {
        errf("fx-init: dl_open {s}: {s}\n", .{ span(@ptrCast(&rtp)), errnoStr() });
        std.process.exit(1);
    };
    if (declare_runtime(g_rt.?) != 0) {
        errf("fx-init: declare_runtime failed\n", .{});
        std.process.exit(1);
    }
    var lp: [1100]u8 = undefined;
    _ = snfmt(&lp, "{s}/log.db", .{span(@ptrCast(&g_run))});
    g_log = fx_log_open(@ptrCast(&lp));
    if (g_log == null) errf("fx-init: warning: log DB open failed (logging disabled)\n", .{});

    var perr: [256]u8 = undefined;
    _ = fx_probe_refresh(g_rt, g_probe_root, &perr, perr.len);
    g_next_probe = time(null) + @as(i64, g_probe_s);

    g_boot_start_ms = now_ms();
    const boot_v = decide_boot_version();
    if (boot_v == 0 or read_store_facts(boot_v) != 0) {
        errf("fx-init: no generation to boot\n", .{});
        g_boot_version = 0;
        g_boot_deadline_ms = sup.fx_boot_deadline_ms(g_boot_start_ms, g_grace_ms);
    } else {
        g_boot_version = boot_v;
        g_boot_deadline_ms = sup.fx_boot_deadline_ms(g_boot_start_ms, g_grace_ms);
        bootlog_append(g_current_version, "in-progress", now_s());
        log_line("fx-init", "info", "materializing rootfs via dhake");
        const drc = run_dhake();
        const dhake_failed: c_int = @intFromBool(drc != 0);
        if (dhake_failed != 0) {
            var m: [256]u8 = undefined;
            _ = snfmt(&m, "dhake exited {d}", .{drc});
            log_line("fx-init", "error", @ptrCast(&m));
            rt_txn_begin();
            rt_set_boot(g_current_version, "failed");
            _ = rt_txn_commit();
            bootlog_append(g_current_version, "failed", now_s());
            g_boot_decided = 1;
            g_boot_failed = 1;
        }
        rt_txn_begin();
        rt_set_generation_current(g_current_version);
        if (dhake_failed == 0) rt_set_boot(g_current_version, "in-progress");
        var si: c_int = 0;
        while (si < g_nsvc) : (si += 1) rt_set_service(&g_svc.?[@intCast(si)]);
        _ = rt_txn_commit();
    }

    g_ctrl_fd = setup_ctrl();
    if (g_ctrl_fd < 0) errf("fx-init: warning: control socket failed\n", .{});

    log_line("fx-init", "info", "entered main loop");
    main_loop();
    do_shutdown();
}

// ─── tests (pure parts: parse_on, boot_decision, next_timeout, on_ready) ──

fn argstr(arg: [*]u8) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(arg)));
}

test "parse_on mirrors the lenient on= grammar" {
    var kind: FxOnKind = undefined;
    var arg: [256]u8 = undefined;
    parse_on("all", &kind, &arg, arg.len);
    try std.testing.expectEqual(FxOnKind.all, kind);
    parse_on("net", &kind, &arg, arg.len);
    try std.testing.expectEqual(FxOnKind.net, kind);
    parse_on("up:gate", &kind, &arg, arg.len);
    try std.testing.expectEqual(FxOnKind.up, kind);
    try std.testing.expectEqualStrings("gate", argstr(&arg));
    parse_on("sock:tcp:8080", &kind, &arg, arg.len);
    try std.testing.expectEqual(FxOnKind.sock_tcp, kind);
    try std.testing.expectEqualStrings("8080", argstr(&arg));
    parse_on("sock:unix:/run/x.sock", &kind, &arg, arg.len);
    try std.testing.expectEqual(FxOnKind.sock_unix, kind);
    try std.testing.expectEqualStrings("/run/x.sock", argstr(&arg));
    parse_on("time:1500", &kind, &arg, arg.len);
    try std.testing.expectEqual(FxOnKind.time, kind);
    try std.testing.expectEqualStrings("1500", argstr(&arg));
    // lenient fallback-to-all for anything unrecognized (incl. empty)
    parse_on("", &kind, &arg, arg.len);
    try std.testing.expectEqual(FxOnKind.all, kind);
    try std.testing.expectEqualStrings("", argstr(&arg));
    parse_on("bogus:thing", &kind, &arg, arg.len);
    try std.testing.expectEqual(FxOnKind.all, kind);
    try std.testing.expectEqualStrings("", argstr(&arg));
}

test "boot_decision state machine (START-ONLY grace rule)" {
    const s_started = Svc{ .state = ST_STARTED };
    const s_failed = Svc{ .state = ST_FAILED };
    const s_pending = Svc{ .state = ST_PENDING };
    const s_stopped = Svc{ .state = ST_STOPPED };
    // grace not expired -> none even when all started
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(boot_decision(false, &.{s_started}, false)));
    // grace expired + all started/stopped -> ok
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(boot_decision(false, &.{s_started}, true)));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(boot_decision(false, &.{ s_started, s_stopped }, true)));
    // pending service -> grace expiry fails (hang)
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(boot_decision(false, &.{s_pending}, true)));
    // any_failed pins failed even BEFORE grace expiry
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(boot_decision(false, &.{s_failed}, false)));
    // already decided -> none
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(boot_decision(true, &.{s_failed}, true)));
}

test "next_timeout arithmetic" {
    // boot already decided: default 1000ms wake-up
    try std.testing.expectEqual(@as(i32, 1000), next_timeout_calc(true, 0, 0, 100, 100, &.{}));
    // boot grace deadline 500ms out (ms-precision)
    try std.testing.expectEqual(@as(i32, 500), next_timeout_calc(false, 1000, 1500, 0, 0, &.{}));
    // grace deadline sub-10ms floors to 10ms
    try std.testing.expectEqual(@as(i32, 10), next_timeout_calc(false, 1000, 1005, 0, 0, &.{}));
    // probe/backoff are whole-second granularity and never beat the default
    const sv = Svc{ .state = ST_BACKOFF, .next_start = 105 };
    try std.testing.expectEqual(@as(i32, 1000), next_timeout_calc(true, 0, 0, 100, 101, &.{sv}));
    // grace still dominates when probe/backoff are >= 1000ms out
    try std.testing.expectEqual(@as(i32, 500), next_timeout_calc(false, 1000, 1500, 100, 101, &.{sv}));
}

test "on_ready: up-graph + time gate (supervise fakes not needed)" {
    var svcs: [2]Svc = .{ Svc{}, Svc{} };
    @memcpy(svcs[0].name[0.."gate".len], "gate");
    @memcpy(svcs[1].name[0.."dep".len], "dep");
    g_svc = &svcs;
    g_nsvc = 2;
    defer {
        g_svc = null;
        g_nsvc = 0;
        g_svc_cap = 0;
    }
    // on=all
    try std.testing.expectEqual(@as(c_int, 1), on_ready(&svcs[0]));
    // on=up:gate when gate ready
    svcs[0].ready = 1;
    @memcpy(svcs[1].on_arg[0.."gate".len], "gate");
    svcs[1].on_kind = .up;
    try std.testing.expectEqual(@as(c_int, 1), on_ready(&svcs[1]));
    // on=up:missing -> not ready
    @memcpy(svcs[1].on_arg[0.."nope".len], "nope");
    try std.testing.expectEqual(@as(c_int, 0), on_ready(&svcs[1]));
    // on=time:1000 not reached (boot start == now)
    svcs[1].on_kind = .time;
    @memcpy(svcs[1].on_arg[0.."1000".len], "1000");
    g_boot_start_ms = now_ms();
    try std.testing.expectEqual(@as(c_int, 0), on_ready(&svcs[1]));
    // on=time:1 reached (boot start 0 => monotonic now is huge)
    g_boot_start_ms = 0;
    @memcpy(svcs[1].on_arg[0.."1".len], "1");
    try std.testing.expectEqual(@as(c_int, 1), on_ready(&svcs[1]));
}
