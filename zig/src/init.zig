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
const ENOEXEC: c_int = 8;
const ENOENT: c_int = 2;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x800;
const O_RDWR: c_int = 0o2;
const O_RDONLY: c_int = 0o0;
const O_DIRECTORY: c_int = 0o200000; // x86_64 (asm-generic): directory-only open
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
// M4 virtio-serial control channel (tests/qemu_ctrl.sh): the guest end of a
// qemu virtserialport.  Inert everywhere else — the gate in
// setup_virtio_ctrl needs BOTH pid1 AND a /dev/vport*p* node, which only a
// virtio-serial-equipped guest has.
var g_vio_fd: c_int = -1;
var g_vio_wf: ?*FILE = null;
// Latched "no live peer on the port" — TRUE also initially (before the host
// has ever connected, and again after read(2) returned 0).  A disconnected
// virtserialport reports POLLHUP/EOF-readable to poll FOREVER, so while
// latched the fd stays OUT of the poll set (poll would spin) and the main
// loop instead reprobe-reads it once per iteration (cadence bounded by the
// poll timeout, <=1s).  Any read that yields data clears the latch and the
// fd rejoins the poll set for instant dispatch.
var g_vio_peer_gone: bool = true;
var g_vio_carry: [REQ_MAX]u8 = undefined;
var g_vio_carry_len: usize = 0;
// M4 in-guest activate: the `put <path>` upload state (config transport
// over the line-oriented channel — base64 lines until a lone `.`).  The
// pump calls handle_request once per COMPLETE line, so the multi-line
// framing state must live in file-statics toggled across calls (the
// g_vio_carry precedent).  Path + accumulated payload + an open flag; a
// `.` with no open put is an ERR, never a silent no-op.
const PUT_MAX: usize = 1 << 20; // 1 MiB decoded cap (a config is ~2 KiB)
const PUT_LINE_MAX: usize = 4096;
var g_put_open: bool = false;
var g_put_path: [PATH_MAX]u8 = [_]u8{0} ** PATH_MAX;
var g_put_b64: ?[*]u8 = null; // malloc'd base64 payload (NUL-terminated)
var g_put_b64_len: usize = 0;
var g_put_b64_cap: usize = 0;
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

/// Close a store handle and make what it wrote DURABLE — but only when the
/// store lives on the DISK mount (post-pivot "/" is tmpfs: syncfs there
/// flushes nothing that survives the kill).  dl_close/dl_publish_snapshot
/// fsync their FILES (atomic_write_str: tmp+fsync+rename+dir-fsync), yet
/// ext4-NOJOURNAL still owes the INODE/BLOCK BITMAP updates of every
/// create/unlink the handle caused (open() mkdirs the .build sibling and
/// O_CREATs LOCK; publish creates+renames snapshot dirs) — and ext4 writes
/// bitmaps LAZILY, seconds after the inode table itself is on disk.
/// MEASURED on the ctrl harness's killed disk: e2fsck -fn reported BOTH
/// missing allocations (inode 8224, blocks 33978-33992 — bitmap pages the
/// kill caught mid-writeback, leaving freed-but-marked-busy extents) AND a
/// missing free (inode 8336 = store/.db/dep.dafsa, blocks 33998-34013 —
/// the newly-created file's journal-less allocation had not reached its
/// bitmap page when boot 3's syncfs raced it).  Boot 3 then hit
/// __ext4_new_inode:1284 "doubly allocated?" trying to reuse a block whose
/// bitmap still said busy, and roll-forward died at its first publish.
/// This is the durability class bootlog_append's sync() already covers for
/// ITS writes; store mutations need the same protection on the SAME fs.
fn store_close_durable(s: *fx.Store) void {
    const root = fx.store.Store.root(s); // []const u8
    fx.fx_store_close(s);
    if (!std.mem.startsWith(u8, root, DISK_MOUNT)) return; // ramfs store: nothing durable owed
    syncfs_path(DISK_MOUNT);
}

/// Durability flush of the ACTIVE store's filesystem (no handle needed) —
/// the call the rollback arms use right after a store mutation commit.
fn syncfs_store() void {
    if (std.mem.startsWith(u8, span(g_store), DISK_MOUNT)) syncfs_path(DISK_MOUNT);
}

/// syncfs(2) by MOUNT POINT: an fd on the fs itself reaches every dirty
/// inode on it (the .db and any nested version dirs included), unlike
/// sync() from the pivoted root, which flushes the ROOT fs (tmpfs) and
/// only whatever disk pages chance to be queued when it runs.
fn syncfs_path(path: [*:0]const u8) void {
    const fd = open(path, O_RDONLY | O_DIRECTORY, 0);
    if (fd < 0) return; // best-effort durability, like every other site
    _ = syncfs(fd);
    _ = std.c.close(fd);
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
extern "c" fn ferror(f: *FILE) c_int;
extern "c" fn clearerr(f: *FILE) void;
extern "c" fn setvbuf(f: *FILE, buf: ?[*]u8, mode: c_int, size: usize) c_int;
const _IONBF: c_int = 2;
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
// execvp (not execv) for store binaries: modern cosmocc emits APEs without
// a #!-shell preamble, so a raw execve fails ENOEXEC.  glibc's execvp then
// retries via /bin/sh itself; musl's does NOT (a slash path is a plain
// execve), so exec_sh_retry does the sh retry EXPLICITLY and a
// static/-musl build boots the same APEs instead of dying with 127.  The
// C oracle's execv only worked because the era's cosmocc still emitted
// #!-polyglots.
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// execvp with the explicit ENOEXEC -> /bin/sh retry (glibc's fallback,
/// made portable).  Like glibc, the retry DROPS argv[0]: sh sees
/// $0=<file>, $1..=argv[1..] (every call site's argv[0] is a cosmetic
/// path/label, and env is untouched).  Fork-child context: libc externs +
/// stack only.
fn exec_sh_retry(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int {
    const rc = execvp(file, argv);
    if (std.c._errno().* != ENOEXEC) return rc;
    var sh: [80]?[*:0]const u8 = undefined;
    var n: usize = 0;
    sh[n] = "/bin/sh";
    n += 1;
    sh[n] = file;
    n += 1;
    var i: usize = 1;
    while (argv[i] != null) : (i += 1) {
        if (n + 1 >= sh.len) return rc; // absurd argv: plain-execvp behavior
        sh[n] = argv[i];
        n += 1;
    }
    sh[n] = null;
    return execv("/bin/sh", @ptrCast(&sh));
}
extern "c" fn time(t: ?*i64) i64;
extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, addrlen: ?*c_uint) c_int;
// real-init bootstrap (M4 image): mount(2) + open(2) for the console reopen —
// not in std.c, declared locally per the repo's fork/execv precedent.
extern "c" fn mount(source: [*:0]const u8, target: [*:0]const u8, fstype: [*:0]const u8, flags: c_ulong, data: ?*const anyopaque) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn sync() void;
extern "c" fn syncfs(fd: c_int) c_int;

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
    // the disk store is mounted r/w NOJOURNAL4 (busybox mkfs.ext2 under
    // ext4): metadata churn can sit unflushed when a harness kills the VM
    // at the verdict — the next mount then finds "doubly allocated" inode
    // state (see store_close_durable for the measured failure).  Target the
    // STORE's own filesystem: post-pivot "/" is tmpfs, so a bare sync()
    // from there flushes the wrong fs.
    syncfs_store();
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
    store_close_durable(s);
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
        store_close_durable(s);
        return -1;
    }
    const bf = dl_intern_str_of(db, gp.bf);
    const dh = dl_intern_str_of(db, gp.dh);
    if (bf == null or dh == null) {
        store_close_durable(s);
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

    store_close_durable(s);
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
        store_close_durable(s);
        return 0;
    }
    g_current_version = v;
    store_close_durable(s);

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
                // fx_store_rollback is snapshot-complete: it restores every
                // relation as-of vok (facts + provenance pair) itself.
                const rb: c_int = fx_store_rollback_wrap(rs, vok, false, &e2, e2.len);
                _ = fx_store_current_version_wrap(rs, &g_current_version, &e2, e2.len);
                if (rb == 0) {
                    log_line("fx-init", "info", "rolled forward to known-good generation");
                    // second durability point: the roll-forward's CURRENT
                    // rewrite is a separate commit from bootlog_append's
                    // fsync — and on the DISK store the nojournal-ext4
                    // BITMAPS of the rollback's snapshot churn can still be
                    // mid-writeback (see store_close_durable).  Flush the
                    // store's OWN filesystem before this boot can be killed.
                    syncfs_store();
                } else {
                    errf("fx-init: roll-forward failed: {s}\n", .{span(@ptrCast(&e2))});
                }
                store_close_durable(rs);
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
        _ = exec_sh_retry(@ptrCast(&g_dhake), &av);
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
        _ = exec_sh_retry(sv.argv.?[0].?, av);
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

/// Real-init bootstrap (M4 image increment): as a rdinit PID1, mount the
/// kernel filesystems /proc, /sys, /dev before anything reads them
/// (fx_probe_refresh hits /proc + /sys at the top of main).  The probe is a
/// file that exists ONLY on the live fs (an empty /proc directory — what the
/// image ships — has no /proc/1/stat), so this is INERT on every existing
/// path: the bwrap harnesses (bwrap --proc/--dev, /sys ro-bind) and
/// FX_INIT_FORCE runs all find the live fs and skip the mounts entirely.  A
/// mount that fails is non-fatal (console + log warning; boot continues —
/// probe/supervision already tolerate missing files).  devtmpfs is populated
/// by the kernel (no mknod by us; CONFIG_DEVTMPFS_MOUNT only auto-mounts onto
/// a real rootfs, never an initramfs).  When devtmpfs WAS mounted here, also
/// reopen /dev/console on fds 0-2: the kernel opened init's fds before exec,
/// and an initramfs without a baked-in /dev/console node leaves them closed —
/// every errf below (incl. the boot-ok/FAILED verdicts) would be lost.
fn mount_early() void {
    const M = struct {
        fs: [:0]const u8,
        dir: [:0]const u8,
        probe: [:0]const u8,
    };
    const ms = [_]M{
        .{ .fs = "proc", .dir = "/proc", .probe = "/proc/1/stat" },
        .{ .fs = "sysfs", .dir = "/sys", .probe = "/sys/class" },
        .{ .fs = "devtmpfs", .dir = "/dev", .probe = "/dev/null" },
    };
    var mounted_dev = false;
    for (ms) |m| {
        if (std.c.access(m.probe.ptr, F_OK) == 0) continue; // already up (harness/bwrap)
        if (mount("none", m.dir.ptr, m.fs.ptr, 0, null) != 0) {
            errf("fx-init: warning: mount {s} on {s} failed: {s}\n", .{ m.fs, m.dir, errnoStr() });
            log_line("fx-init", "error", "early mount failed");
            continue;
        }
        if (std.mem.eql(u8, m.dir, "/dev")) mounted_dev = true;
    }
    if (mounted_dev) {
        const fd = open("/dev/console", O_RDWR, 0);
        if (fd >= 0) {
            _ = std.c.dup2(fd, 0);
            _ = std.c.dup2(fd, 1);
            _ = std.c.dup2(fd, 2);
            if (fd > 2) _ = std.c.close(fd);
        }
    }
}

// ─── M4 disk store: persist the store on a virtio-blk disk ────────────────

/// The disk store lives on a writable virtio-blk device (tests/qemu_boot.sh
/// attaches one; the guest sees /dev/vda).  rdinit receives NO argv from the
/// kernel (MEASURED, handoff-image-disk-artifact-1), so the path is chosen by
/// DEVICE PRESENCE, not a flag: only the QEMU boots ever get a /dev/vda (the
/// bwrap harnesses and the host have no virtio-blk device), which keeps this
/// whole block inert on every existing path.
///
/// Layout: the disk is mounted at /fx/disk and g_store is repointed at
/// /fx/disk/store BEFORE anything opens the store (the first fx_store_open
/// happens inside decide_boot_version).  NOT at /fx/store itself:
/// fx_store_open puts the .build scratch SIBLING of the root and rejects a
/// root whose sibling lands on another st_dev — i.e. a store root that is
/// itself a mountpoint cannot be opened at all.
///
/// Three cases once the disk is mounted (busybox mkfs.ext2 -F when blank;
/// mounted -t ext4, NOT ext2: CONFIG_EXT2_FS is unset, only
/// EXT4_USE_FOR_EXT2=y, and busybox `mount -t ext2` fails EINVAL — MEASURED
/// in the POC):
///   unseeded disk:                     seed = cp -a the ramfs store over;
///   seeded, ramfs CURRENT <= disk:     the DISK wins (persistence);
///   seeded, ramfs CURRENT >  disk:     ADOPT the ramfs store (a newer
///                                      initramfs supersedes the disk
///                                      generation) while PRESERVING the
///                                      disk .bootlog — the boot history a
///                                      prior boot wrote is exactly what
///                                      the next boot's roll-forward reads.
const DISK_MOUNT = "/fx/disk";
const DISK_STORE = "/fx/disk/store";
const DISK_DEV = "/dev/vda";
const DISK_STORE_DB = DISK_STORE ++ "/.db";
const DISK_STORE_BOOTLOG = DISK_STORE ++ "/.bootlog";
// insmod order (POC, from the pinned kernel's modules.dep): ext4 depends on
// crc16 + mbcache + jbd2; virtio_blk has no deps.
const DISK_MODULE_ORDER = [_][]const u8{ "crc16.ko", "mbcache.ko", "jbd2.ko", "ext4.ko", "virtio_blk.ko" };

const Dirent = extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
};
extern "c" fn opendir(name: [*:0]const u8) ?*anyopaque;
extern "c" fn readdir(dir: *anyopaque) ?*Dirent;
extern "c" fn closedir(dir: *anyopaque) c_int;

/// Run a busybox applet to completion (the image ships busybox at
/// /usr/bin/busybox; argv = {"busybox", applet, a1..} is the multi-call
/// form).  Returns the exit status, or -1 on fork/exec/wait failure (127 =
/// exec failed).  Used only BEFORE the SIGCHLD handler + main loop exist,
/// so a plain waitpid is safe here.
fn run_bb(applet: [*:0]const u8, a1: ?[*:0]const u8, a2: ?[*:0]const u8, a3: ?[*:0]const u8) c_int {
    const pid = std.c.fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        const av = [_:null]?[*:0]const u8{ "busybox", applet, a1, a2, a3 };
        _ = execv("/usr/bin/busybox", @ptrCast(&av));
        std.c._exit(127);
    }
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 0) < 0 and std.c._errno().* == EINTR) {}
    return if (std.os.linux.W.IFEXITED(@bitCast(status))) @as(c_int, std.os.linux.W.EXITSTATUS(@bitCast(status))) else -1;
}

/// Is /dev already a kernel-populated devtmpfs mount?  On the host (and in
/// bwrap) it is — or the devtmpfs mount below fails in the user namespace —
/// and both mean "no virtio disk can appear later", so the disk path stays
/// inert there.
fn dev_is_devtmpfs() bool {
    const f = fopen("/proc/mounts", "r") orelse return false;
    defer _ = fclose(f);
    var line: [512]u8 = undefined;
    while (fgets(&line, @intCast(line.len), f)) |_| {
        var spec: [128]u8 = undefined;
        var mnt: [128]u8 = undefined;
        var fst: [64]u8 = undefined;
        if (sscanf(@ptrCast(&line), "%127s %127s %63s", &spec, &mnt, &fst) == 3) {
            if (strcmp(@ptrCast(&mnt), "/dev") == 0 and strcmp(@ptrCast(&fst), "devtmpfs") == 0) return true;
        }
    }
    return false;
}

/// The single /lib/modules/<ver> entry the image ships (tests/mkinitramfs.sh
/// writes exactly one, version-locked to the pinned kernel at BUILD time).
fn modules_dir(out: []u8) bool {
    const d = opendir("/lib/modules") orelse return false;
    defer _ = closedir(d);
    while (readdir(d)) |e| {
        const name = std.mem.sliceTo(&e.d_name, 0);
        if (name.len == 0 or name[0] == '.') continue;
        if (name.len + 1 > out.len) continue;
        @memcpy(out[0..name.len], name);
        out[name.len] = 0;
        return true;
    }
    return false;
}

/// Best-effort read of <root>/.db/snapshots/CURRENT (0 when unreadable) —
/// the same file fx_store_current_version parses, read directly so this
/// never needs an open store handle (or creates scratch dirs) this early.
fn store_current_of(root: [:0]const u8) u32 {
    var p: [512]u8 = undefined;
    _ = snfmt(&p, "{s}/.db/snapshots/CURRENT", .{root});
    const f = fopen(@ptrCast(&p), "r") orelse {
        // ENOENT is the ordinary unseeded case (silent, the caller's job);
        // anything else (e.g. EACCES) deserves the old "cannot be opened"
        // loudness — the read is being skipped for a reason the operator
        // can fix.  Return semantics unchanged: 0 either way.
        if (std.c._errno().* != ENOENT) {
            errf("fx-init: WARNING: {s} cannot be opened: {s} — treating as no store\n", .{ span(@ptrCast(&p)), errnoStr() });
        }
        return 0;
    };
    defer _ = fclose(f);
    var line: [64]u8 = undefined;
    var v: u32 = 0;
    // CURRENT exists but is unreadable/unparsable: returning 0 makes the
    // caller treat the store as unseeded and adopt/overwrite — a defensible
    // recovery, but it must be LOUD.  (Open ONCE and read ONCE: the old shape
    // fclosed the probe handle and then fgets'd it — a use-after-close whose
    // heap corruption segfaulted the first boot that actually ran this code.)
    if (fgets(&line, @intCast(line.len), f) == null or sscanf(@ptrCast(&line), "%u", &v) != 1) {
        errf("fx-init: WARNING: {s} exists but is unreadable/unparsable — treating as no store\n", .{span(@ptrCast(&p))});
        return 0;
    }
    return v;
}

/// Bring up the persistent disk store (see the block comment above).  Runs
/// right after mount_early() and before any store handle is opened.
/// Non-fatal by design (mirrors mount_early): every failure warns on the
/// console and the boot continues from the ramfs store — the QEMU harness
/// asserts the success line, so a broken disk path fails the harness, not
/// the boot.
fn ensure_disk_store() void {
    // PID1 only: the path mkfs's a block device, and presence-discovery
    // (below) is exactly the right gate for a real init.  An FX_INIT_FORCE
    // run on a host that happens to have a /dev/vda must never reach it.
    if (std.c.getpid() != 1) return;
    // /dev must be kernel-populated for /dev/vda to appear once virtio_blk
    // loads.  The image ships baked device nodes, so mount_early SKIPPED
    // devtmpfs (its /dev/null probe hits) — mount it here.  INTERPRETATION:
    // this mount succeeding also separates "initramfs PID1 in the initial
    // user namespace" from every harness path (bwrap/user ns: EPERM).  If a
    // future image ships no baked /dev nodes, mount_early mounts devtmpfs
    // itself and the `else` branch below takes over cleanly.
    if (!dev_is_devtmpfs()) {
        if (mount("devtmpfs", "/dev", "devtmpfs", 0, null) != 0) return; // harness / bwrap: inert
    } else if (std.c.access(DISK_DEV, F_OK) != 0) {
        return; // /dev already kernel-populated and no virtio disk: host / harness
    }

    // modules first: virtio_blk makes the disk appear, ext4 mounts it.
    var mdir: [256]u8 = undefined;
    if (!modules_dir(&mdir)) {
        errf("fx-init: warning: no /lib/modules — disk store disabled\n", .{});
        return;
    }
    for (DISK_MODULE_ORDER) |mod| {
        var mp: [512]u8 = undefined;
        _ = snfmt(&mp, "/lib/modules/{s}/{s}", .{ span(@ptrCast(&mdir)), mod });
        const rc = run_bb("insmod", @ptrCast(&mp), null, null);
        if (rc != 0) {
            errf("fx-init: disk: insmod {s} FAILED (exit {d}) — disk store disabled\n", .{ mod, rc });
            return;
        }
    }
    if (std.c.access(DISK_DEV, F_OK) != 0) {
        errf("fx-init: disk store: no {s} — using ramfs store\n", .{DISK_DEV});
        return;
    }

    _ = mkdirp(DISK_MOUNT);
    if (mount(DISK_DEV, DISK_MOUNT, "ext4", 0, null) != 0) {
        // blank disk: the GUEST formats it (the host cannot mkfs/populate
        // the image as uid 1001 — that constraint is this whole design)
        const mk = run_bb("mkfs.ext2", "-F", DISK_DEV, null);
        if (mk != 0) {
            errf("fx-init: disk: mkfs.ext2 FAILED (exit {d}) — disk store disabled\n", .{mk});
            return;
        }
        if (mount(DISK_DEV, DISK_MOUNT, "ext4", 0, null) != 0) {
            errf("fx-init: disk: mount {s} ext4 FAILED: {s} — disk store disabled\n", .{ DISK_DEV, errnoStr() });
            return;
        }
    }

    if (std.c.access(DISK_STORE_DB, F_OK) != 0) {
        // unseeded: copy the whole ramfs store over (mkinitramfs already
        // stripped the .build/.tmp scratch from the image copy)
        _ = run_bb("rm", "-rf", DISK_STORE, null);
        const cp = run_bb("cp", "-a", DEFAULT_STORE, DISK_MOUNT);
        if (cp != 0) {
            errf("fx-init: disk: seed cp FAILED (exit {d}) — disk store disabled\n", .{cp});
            return;
        }
    } else {
        const disk_v = store_current_of(DISK_STORE);
        const ramfs_v = store_current_of(DEFAULT_STORE);
        if (ramfs_v != 0 and ramfs_v > disk_v) {
            // adopt: the ramfs (image) generation is NEWER.  Replace the
            // disk store wholesale but keep its .bootlog aside — restoring
            // the boot history is what makes the next boot's roll-forward
            // decision read a disk a PRIOR boot wrote.
            _ = run_bb("mv", DISK_STORE_BOOTLOG, "/fx/disk/bootlog.keep", null);
            _ = run_bb("rm", "-rf", DISK_STORE, null);
            const cp = run_bb("cp", "-a", DEFAULT_STORE, DISK_MOUNT);
            _ = run_bb("mv", "/fx/disk/bootlog.keep", DISK_STORE_BOOTLOG, null);
            if (cp != 0) {
                errf("fx-init: disk: adopt cp FAILED (exit {d}) — disk store disabled\n", .{cp});
                return;
            }
            errf("fx-init: disk store adopted ramfs v{d} over disk v{d} (bootlog preserved)\n", .{ ramfs_v, disk_v });
        }
    }
    _ = run_bb("sync", null, null, null); // belt: flush the copy before an abrupt harness kill

    g_store = DISK_STORE;
    errf("fx-init: disk store mounted (current v{d})\n", .{store_current_of(DISK_STORE)});
}

// ─── M4 real rootfs: pivot_root from the initramfs to a tmpfs ─────────────

/// statfs(2) constant (linux/magic.h), pinned by the unit test at the bottom
/// of this file so a wrong constant is a TEST failure, not a boot mystery.
/// NOTE (MEASURED, static-probe on the pinned kernel 7.1.8-1-default): with
/// CONFIG_TMPFS=y the initramfs rootfs is TMPFS-BACKED — statfs("/") reports
/// 0x01021994 there too, so the magic alone cannot distinguish the initramfs
/// root from the pivoted tmpfs.  The discriminator the pivot actually uses is
/// the /proc/mounts ROOT ENTRY FSTYPE: "rootfs" before the pivot, "tmpfs"
/// after (probe evidence: pre "rootfs / rootfs rw,...", post "none / tmpfs
/// rw,..." + "rootfs /oldroot rootfs ...").  TMPFS_MAGIC remains the
/// post-pivot belt check.
const TMPFS_MAGIC: i64 = 0x01021994;
const MS_MOVE: c_ulong = 8192;
const MS_BIND: c_ulong = 4096;
const MNT_DETACH: c_int = 2;

/// The /proc/mounts root-entry fstype of an initramfs root (MEASURED on the
/// pinned kernel; see root_mount_fstype) — the gate string.  Named so the
/// unit test can pin it: a wrong literal here is a gate that never fires.
const ROOTFS_FST = "rootfs";
/// The same entry AFTER a successful pivot ("none / tmpfs") — the proof
/// string.  Must differ from ROOTFS_FST or the gate proves nothing.
const TMPFS_FST = "tmpfs";

/// The kernel filesystems that must travel into the new root.  ONE table
/// shared by the forward pass and pivot_undo so the undo list can never
/// drift from the moves list.
const pivot_kernel_moves = [_][2][:0]const u8{
    .{ "/proc", "/newroot/proc" },
    .{ "/sys",  "/newroot/sys" },
    .{ "/dev",  "/newroot/dev" },
};

/// The plain bind mounts the new root needs (they stay behind in /oldroot's
/// own tree on success; pivot_undo detaches their copies from /newroot).
const pivot_binds = [_][2][:0]const u8{
    .{ "/lib64", "/newroot/lib64" },
    .{ "/usr",   "/newroot/usr" },
};

/// glibc's struct statfs (x86_64) — only f_type is read.
const Statfs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};
extern "c" fn statfs(path: [*:0]const u8, buf: *Statfs) c_int;
extern "c" fn pivot_root(new_root: [*:0]const u8, put_old: [*:0]const u8) c_int;
extern "c" fn umount2(target: [*:0]const u8, flags: c_int) c_int;

/// The kernel-reported filesystem magic of a path (0 when statfs fails).
fn fs_magic(path: [:0]const u8) i64 {
    var st: Statfs = undefined;
    if (statfs(path.ptr, &st) != 0) return 0;
    return st.f_type;
}

/// The fstype of the /proc/mounts entry for the ROOT mount, "" when it cannot
/// be read.  This — not the statfs magic — is what distinguishes an initramfs
/// root ("rootfs"; MEASURED) from every harness root (btrfs on the host,
/// whatever bwrap --binds) and from the pivoted tmpfs ("tmpfs").
fn root_mount_fstype(out: []u8) []const u8 {
    const f = fopen("/proc/mounts", "r") orelse return "";
    defer _ = fclose(f);
    var line: [512]u8 = undefined;
    while (fgets(&line, @intCast(line.len), f)) |_| {
        var spec: [128]u8 = undefined;
        var mnt: [128]u8 = undefined;
        var fst: [64]u8 = undefined;
        if (sscanf(@ptrCast(&line), "%127s %127s %63s", &spec, &mnt, &fst) == 3) {
            if (strcmp(@ptrCast(&mnt), "/") == 0) {
                const n = @min(std.mem.sliceTo(&fst, 0).len, out.len - 1);
                @memcpy(out[0..n], fst[0..n]);
                out[n] = 0;
                return out[0..n];
            }
        }
    }
    return "";
}

/// Mount src on dst by MOVING it (MS_MOVE); fall back to a bind mount so a
/// subtree that is not itself a mountpoint still rides along (MEASURED:
/// MS_MOVE of a non-mountpoint dir — a baked /dev — fails EINVAL).  Returns
/// 0 on success, -1 when both attempts failed.
fn move_or_bind(src: [:0]const u8, dst: [*:0]const u8) c_int {
    if (mount(src.ptr, dst, "", MS_MOVE, null) == 0) return 0;
    if (mount(src.ptr, dst, "", MS_BIND, null) == 0) return 0;
    return -1;
}

/// Best-effort ROLLBACK of a half-finished pivot (see pivot_root_to_tmpfs).
/// Moves every already-moved mount BACK to its original location — the disk
/// mount first (g_store's path must resolve to the real store again before
/// anything re-reads it), then the first n_moves kernel filesystems in
/// REVERSE order — and detaches every bind laid onto /newroot, plus the
/// tmpfs itself.  n_moves is how many of pivot_kernel_moves COMPLETED: an
/// entry that never moved must not be "moved back" (the fallback bind would
/// graft an empty dir over the live filesystem — worse than the failure it
/// was recovering from).
///
/// The contract of every "staying on initramfs root" return is that the
/// initramfs root is genuinely WORKING afterwards: canonical /proc, /sys,
/// /dev back in place, g_store pointing at an openable store.  Where the
/// kernel refuses a move-back, that contract is only partially met — the
/// WARNING names what could not be restored (and, for the disk store, the
/// fallback repoints g_store at the ramfs store so the boot at least has a
/// store to read).
fn pivot_undo(n_moves: usize, disk_moved: bool, fx_bound: bool) void {
    // binds first (they sit ON /newroot; detaching is order-free among them)
    for (pivot_binds) |b| _ = umount2(@ptrCast(b[1].ptr), MNT_DETACH);
    if (fx_bound) _ = umount2("/newroot/fx", MNT_DETACH);
    // the disk mount back under /fx — g_store's path must resolve to the
    // ext4 store again BEFORE anything re-reads it.
    if (disk_moved) {
        if (move_or_bind("/newroot/fx/disk", DISK_MOUNT) == 0) {
            errf("fx-init: pivot: rolled back {s} -> {s}\n", .{ "/newroot/fx/disk", DISK_MOUNT });
        } else {
            // nothing was DESTROYED (the ext4 mount lives on under
            // /newroot/fx/disk) — but g_store's path is now an empty dir,
            // so fall back to the ramfs store the image still carries.
            g_store = DEFAULT_STORE;
            errf("fx-init: pivot: WARNING: could not move the disk store back to {s} ({s}) — falling back to the ramfs store {s}\n", .{ DISK_MOUNT, errnoStr(), DEFAULT_STORE });
        }
    }
    // the kernel filesystems that DID move, REVERSED (mirrors the forward
    // order; whatever submounts /proc or /sys carry ride back with them)
    var i: usize = n_moves;
    while (i > 0) {
        i -= 1;
        const m = pivot_kernel_moves[i];
        if (move_or_bind(m[1], @ptrCast(m[0].ptr)) == 0) {
            errf("fx-init: pivot: rolled back {s} -> {s}\n", .{ m[1], m[0] });
        } else {
            errf("fx-init: pivot: WARNING: could not move {s} back to {s} ({s}) — the initramfs root is WITHOUT a canonical {s}\n", .{ m[1], m[0], errnoStr(), m[0] });
        }
    }
    // the tmpfs itself: by now empty of ours.  MNT_DETACH (not UMOUNT) so a
    // still-referenced mount cannot block the rollback; if even that fails
    // (EBUSY) leave it mounted — an empty tmpfs is harmless.
    _ = umount2("/newroot", MNT_DETACH);
}

/// Materialize a REAL rootfs (a tmpfs) and pivot_root onto it, leaving the
/// initramfs under /oldroot (M4 image increment, plan section B; the gate
/// deviates from the plan for a measured reason — see root_mount_fstype).
///
/// GATES — this must be INERT everywhere but a genuine rdinit boot:
///   getpid() == 1  — fxinit_boot.sh (bwrap) is never PID1;
///   the /proc/mounts ROOT entry's fstype is "rootfs" — true ONLY of an
///     initramfs root.  fxinit_pid1.sh IS PID1 but its root is the host fs
///     (btrfs there), so the fstype check alone keeps the pivot off that
///     harness too.
///
/// The pivot point is load-bearing: main calls this IMMEDIATELY after
/// ensure_disk_store() and BEFORE the pipe/signal setup — at that instant no
/// store handle is open (the first fx_store_open is inside
/// decide_boot_version), /run/fx does not exist yet, and the ctrl socket +
/// state.db + log.db are created ON the new root, so nothing has to be
/// re-homed afterwards.  dhake is fork+exec'd after the pivot, so its
/// ABSOLUTE Mkdir/Copy/Symlink targets (/etc, /bin, /run) land in the NEW
/// root for free (absolute paths resolve at the process root) — no path
/// rewriting anywhere.  EVERY step is non-fatal: a failure warns and RETURNS,
/// leaving the boot to continue on the initramfs root — a pivot failure must
/// never take down a boot that would otherwise have succeeded.
///
/// FAILURE CONTRACT (the order below is what makes the claim above true):
///   phase 1 — every cheap, non-destructive precondition (mkdirs, source
///     existence, the tmpfs) runs BEFORE anything is moved; a failure there
///     leaves a root indistinguishable from a no-pivot boot;
///   phase 2 — the BIND mounts (/fx ramfs arm, /lib64, /usr) land ON the
///     new root only: the old root's own mounts are untouched, and the undo
///     detaches them;
///   phase 3 — only the MS_MOVEs remain, immediately before the pivot, so
///     the window in which a failure needs rollback is minimal;
///   undo  — any failure after phase 2 begins runs pivot_undo(): the moves
///     are reversed (disk mount first, then /proc,/sys,/dev in reverse) and
///     the binds detached, so "staying on initramfs root" means the root is
///     genuinely working again — /proc,/sys,/dev at their canonical paths,
///     and g_store back on a real store (moved back, or repointed at the
///     ramfs store when the disk mount cannot return).
fn pivot_root_to_tmpfs() void {
    if (std.c.getpid() != 1) return; // harness/bwrap path: inert
    var fst: [64]u8 = undefined;
    const root_fst = root_mount_fstype(&fst);
    if (!std.mem.eql(u8, root_fst, ROOTFS_FST)) {
        // Visible, not silent: if this fires on a path that SHOULD pivot, the
        // gate is mis-wired and the console says so instead of the pivot line
        // just being mysteriously absent.  fxinit_pid1.sh boots PID1 on the
        // host fs, where this line is EXPECTED (and asserted by that harness).
        errf("fx-init: root fstype is '{s}' (not {s}) — pivot not attempted\n", .{ if (root_fst.len == 0) "?" else root_fst, ROOTFS_FST });
        return;
    }

    // ── phase 1: cheap, non-destructive preconditions ─────────────────────
    // Everything that can fail WITHOUT touching the mount table goes FIRST:
    // a failure here leaves the system identical to a boot that never
    // attempted the pivot (only some /newroot dirs were created).
    const dirs = [_][*:0]const u8{
        "/newroot", "/newroot/proc", "/newroot/sys", "/newroot/dev", "/newroot/run",
        "/newroot/fx", "/newroot/fx/disk", "/newroot/lib64", "/newroot/usr", "/newroot/oldroot",
    };
    for (dirs) |d| {
        if (std.c.mkdir(d, 0o755) != 0 and std.c._errno().* != EEXIST) {
            errf("fx-init: warning: pivot: mkdir {s} failed: {s} — staying on initramfs root\n", .{ span(d), errnoStr() });
            return;
        }
    }
    // bind sources must exist in the OLD root — a missing /fx, /lib64 or /usr
    // in the image is a build error, caught here BEFORE the tmpfs mount so a
    // failure still changes nothing about the root.
    const bind_sources = [_][*:0]const u8{ "/fx", "/lib64", "/usr" };
    for (bind_sources) |s| {
        if (std.c.access(s, F_OK) != 0) {
            errf("fx-init: warning: pivot: bind source {s} absent: {s} — staying on initramfs root\n", .{ span(s), errnoStr() });
            return;
        }
    }
    // /proc must be up: it is both the gate's source and a move target below.
    if (std.c.access("/proc", F_OK) != 0) {
        errf("fx-init: warning: pivot: /proc absent: {s} — staying on initramfs root\n", .{errnoStr()});
        return;
    }
    if (mount("none", "/newroot", "tmpfs", 0, null) != 0) {
        errf("fx-init: warning: pivot: tmpfs on /newroot failed: {s} — staying on initramfs root\n", .{errnoStr()});
        return;
    }
    // /newroot's subdirs must exist ON the tmpfs (the mkdirs above created
    // them in the initramfs layer before the mount covered them).
    for (dirs[1..]) |d| {
        if (std.c.mkdir(d, 0o755) != 0 and std.c._errno().* != EEXIST) {
            errf("fx-init: warning: pivot: mkdir {s} failed: {s} — staying on initramfs root\n", .{ span(d), errnoStr() });
            return;
        }
    }

    // ── phase 2: reversible mounts ONTO the new root ──────────────────────
    // From here a failure leaves a bind ON the tmpfs — detached by the undo;
    // the OLD root's own mounts are still untouched.
    const disk_arm = std.mem.eql(u8, span(g_store), DISK_STORE);
    var fx_bound = false;
    if (!disk_arm) {
        // The ramfs-store arm: bind the PARENT /fx, NEVER /fx/store itself
        // (fx_store_open puts its .build scratch SIBLING of the root and
        // rejects a root whose sibling lands on another st_dev — a store
        // root that is itself a mountpoint cannot be opened at all; the
        // same rejection ensure_disk_store's /fx/disk layout avoids).
        if (mount("/fx", "/newroot/fx", "", MS_BIND, null) != 0) {
            errf("fx-init: warning: pivot: bind /fx failed: {s} — staying on initramfs root\n", .{errnoStr()});
            pivot_undo(0, false, false);
            return;
        }
        fx_bound = true;
    }
    // Keep the new root a complete runtime for the store's dynamic binaries
    // (fx-activate needs the loader + libc; /usr carries busybox for later
    // store ops).  B itself needs neither — dhake/fakesvc are static.
    for (pivot_binds) |b| {
        if (mount(b[0].ptr, @ptrCast(b[1].ptr), "", MS_BIND, null) != 0) {
            errf("fx-init: warning: pivot: bind {s} failed: {s} — staying on initramfs root\n", .{ b[0], errnoStr() });
            pivot_undo(0, false, fx_bound);
            return;
        }
    }

    // ── phase 3: the MS_MOVEs — the irreversible window, kept minimal ─────
    // Every mount the new root needs is already in place; only the moves,
    // the chdir and pivot_root remain.  A failure inside this window runs
    // pivot_undo, which moves everything already moved BACK (reverse order).
    var done: usize = 0;
    for (pivot_kernel_moves) |m| {
        if (move_or_bind(m[0], @ptrCast(m[1].ptr)) != 0) {
            errf("fx-init: warning: pivot: move {s} failed: {s} — staying on initramfs root\n", .{ m[0], errnoStr() });
            pivot_undo(done, false, fx_bound);
            return;
        }
        done += 1;
    }

    // The store, disk arm: g_store == /fx/disk/store — MS_MOVE the whole
    // disk MOUNT into the new root (the mount travels; /oldroot/fx/disk
    // becomes an empty dir).  This is the LAST move: it needs nothing the
    // kernel-fs moves provide, and undoing it is g_store's path restore.
    var disk_moved = false;
    if (disk_arm) {
        if (move_or_bind(DISK_MOUNT, "/newroot/fx/disk") != 0) {
            errf("fx-init: warning: pivot: move {s} failed: {s} — staying on initramfs root\n", .{ DISK_MOUNT, errnoStr() });
            pivot_undo(pivot_kernel_moves.len, false, fx_bound);
            return;
        }
        disk_moved = true;
    }

    // ── phase 4: the pivot itself ─────────────────────────────────────────
    if (std.c.chdir("/newroot") != 0) {
        errf("fx-init: warning: pivot: chdir /newroot failed: {s} — staying on initramfs root\n", .{errnoStr()});
        pivot_undo(pivot_kernel_moves.len, disk_moved, fx_bound);
        return;
    }
    if (pivot_root(".", "oldroot") != 0) {
        errf("fx-init: warning: pivot_root failed: {s} — staying on initramfs root\n", .{errnoStr()});
        // back to the old root FIRST — the undo's move-back targets
        // (/proc, /sys, /dev, /fx/disk) are old-root paths.
        _ = std.c.chdir("/");
        pivot_undo(pivot_kernel_moves.len, disk_moved, fx_bound);
        return;
    }
    _ = std.c.chdir("/");

    // PROOF (both conditions are impossible on the initramfs root, MEASURED):
    // the /proc/mounts root entry is "rootfs <anything> rootfs" there, and
    // becomes "none / tmpfs" only after the pivot; the statfs magic is the
    // belt (identical pre/post on a CONFIG_TMPFS=y kernel — see the comment
    // at TMPFS_MAGIC — so it cannot carry the proof alone).
    var fst2: [64]u8 = undefined;
    const new_fst = root_mount_fstype(&fst2);
    if (std.mem.eql(u8, new_fst, TMPFS_FST) and fs_magic("/") == TMPFS_MAGIC) {
        errf("fx-init: pivoted to tmpfs root (magic 0x1021994)\n", .{});
    } else {
        errf("fx-init: warning: post-pivot root fstype '{s}' magic 0x{x:0>8} (want {s}/0x01021994)\n", .{ if (new_fst.len == 0) "?" else new_fst, @as(u32, @truncate(@as(u64, @bitCast(fs_magic("/"))))), TMPFS_FST });
    }

    // B2: detach the old initramfs root from the namespace.  This is namespace
    // hygiene only — what switch_root does — NOT memory reclaim: the /lib64 and
    // /usr MS_BINDs above hold their OWN reference to the initramfs superblock,
    // so the initramfs pages stay pinned and are NOT freed by this umount.
    // MNT_DETACH (lazy) detaches immediately even if a reference lingers, and
    // cannot fail EBUSY the way a plain umount can.  The system is already fully
    // up on the new root, so any failure is a WARNING only — never fatal, never
    // affects the boot or the verdict.  The /oldroot directory entry is left in
    // place; the binds are untouched.
    if (umount2("/oldroot", MNT_DETACH) != 0) {
        errf("fx-init: warning: detach /oldroot failed: {s} (non-fatal — boot continues on new root)\n", .{errnoStr()});
    }
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
            // console verdict (image/QEMU path): fd 2 = /dev/console for a
            // rdinit PID1; captured stderr in the bwrap harnesses.
            errf("fx-init: boot-ok v{d}\n", .{g_current_version});
            g_boot_decided = 1;
            g_boot_failed = 0;
        },
        .failed => {
            rt_txn_begin();
            rt_set_boot(g_current_version, "failed");
            _ = rt_txn_commit();
            bootlog_append(g_current_version, "failed", now_s());
            log_line("fx-init", "error", "boot failed");
            errf("fx-init: boot-FAILED v{d}\n", .{g_current_version});
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
            // console verdict (image/QEMU path): fd 2 = /dev/console for a
            // rdinit PID1; captured stderr in the bwrap harnesses.
            errf("fx-init: boot-FAILED v{d}\n", .{g_current_version});
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

// ─── put <path> (M4 in-guest activate: config upload over the channel) ────
//
// Framing: `put <path>` opens, raw base64 lines accumulate (RFC 4648,
// padding allowed, lines short enough for REQ_MAX), a lone `.` decodes +
// writes + answers "OK put <n> bytes" or "ERR ...".  The write target is
// WHITELISTED to /run/ — the channel must not be able to write arbitrary
// guest files (a config is the only intended payload, and /run/fx is where
// the activate handler's consumers live).

fn putAbort() void {
    g_put_open = false;
    g_put_b64_len = 0;
    if (g_put_b64) |p| _ = free(@ptrCast(p));
    g_put_b64 = null;
    g_put_b64_cap = 0;
}

fn putBegin(o: *FILE, path: [*:0]u8) void {
    const p = span(path);
    // whitelist: /run/ only (and an absolute path — no CWD games)
    if (p.len < "/run/x".len or p[0] != '/' or !std.mem.startsWith(u8, p, "/run/")) {
        resp_err(o, "put: path must be under /run/");
        return;
    }
    if (g_put_open) putAbort(); // a stale open put: reset before starting
    if (p.len >= g_put_path.len) {
        resp_err(o, "put: path too long");
        return;
    }
    @memcpy(g_put_path[0..p.len], p);
    g_put_path[p.len] = 0;
    g_put_open = true;
    g_put_b64_len = 0;
    resp_ok(o);
}

/// Append one payload line to the open put; on the lone `.` terminator,
/// base64-decode, write the file, answer.  Always leaves g_put_open false
/// after a `.` (success or failure) — never a half-open upload.
fn putPayloadLine(o: *FILE, line: [*:0]u8) void {
    const l = span(line);
    if (l.len == 1 and l[0] == '.') {
        g_put_open = false;
        putFinish(o);
        return;
    }
    // base64 payload (with padding; blank lines are tolerated as no-ops so
    // a trailing newline in the stream cannot corrupt the upload)
    if (l.len == 0) return;
    if (g_put_b64_len + l.len + 1 > PUT_MAX) {
        putAbort();
        resp_err(o, "put: payload too large");
        return;
    }
    if (g_put_b64 == null) {
        const cap: usize = 64 * 1024;
        const p = malloc(cap) orelse {
            putAbort();
            resp_err(o, "put: out of memory");
            return;
        };
        g_put_b64 = p;
        g_put_b64_cap = cap;
    }
    if (g_put_b64_len + l.len + 1 > g_put_b64_cap) {
        var nc = g_put_b64_cap;
        while (nc < g_put_b64_len + l.len + 1) nc *= 2;
        if (nc > PUT_MAX + 1) nc = PUT_MAX + 1;
        const p = realloc(@ptrCast(g_put_b64), nc);
        if (p == null) {
            putAbort();
            resp_err(o, "put: out of memory");
            return;
        }
        g_put_b64 = @ptrCast(@alignCast(p));
        g_put_b64_cap = nc;
    }
    @memcpy(g_put_b64.?[g_put_b64_len..][0..l.len], l);
    g_put_b64_len += l.len;
    g_put_b64.?[g_put_b64_len] = 0;
}

fn putFinish(o: *FILE) void {
    const dec = std.base64.standard.Decoder;
    const src = g_put_b64.?[0..g_put_b64_len];
    const n = dec.calcSizeForSlice(src) catch {
        putAbort();
        resp_err(o, "put: invalid base64");
        return;
    };
    if (n > PUT_MAX) {
        putAbort();
        resp_err(o, "put: decoded too large");
        return;
    }
    const buf = malloc(n) orelse {
        putAbort();
        resp_err(o, "put: out of memory");
        return;
    };
    defer _ = free(buf);
    dec.decode(buf[0..n], src) catch {
        putAbort();
        resp_err(o, "put: invalid base64");
        return;
    };
    // write via fopen/fwrite (the C-style file surface used here)
    const f = fopen(@ptrCast(&g_put_path), "wb") orelse {
        putAbort();
        resp_err(o, "put: open failed");
        return;
    };
    if (fwrite(buf, 1, n, f) != n) {
        _ = fclose(f);
        putAbort();
        resp_err(o, "put: write failed");
        return;
    }
    if (fclose(f) != 0) {
        putAbort();
        resp_err(o, "put: close failed");
        return;
    }
    var m: [64]u8 = undefined;
    _ = snprintf(&m, m.len, "OK put %zu bytes", n);
    _ = fputs(@ptrCast(&m), o);
    _ = fputc('\n', o);
    _ = fflush(o);
    putAbort();
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
    // an OPEN put swallows every line as payload (even one that looks like
    // a command) until the lone `.` terminator — the framing state must be
    // consulted BEFORE the command grammar, or a payload line colliding
    // with a command name would corrupt the upload.
    if (g_put_open) {
        putPayloadLine(o, line);
        return;
    }
    const cmd = strtok_r(line, " \t", &save) orelse {
        resp_err(o, "empty");
        return;
    };

    if (strcmp(cmd, "put") == 0) {
        const arg = strtok_r(null, " \t", &save) orelse {
            resp_err(o, "put <path>");
            return;
        };
        putBegin(o, arg);
        return;
    }

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
            // Capture the child's stderr: an in-guest activate failure must
            // be diagnosable FROM THE CHANNEL (fx-activate's own message —
            // "package not built", a config parse error, a missing pkgset —
            // is the only clue; the child's console stderr does not reach
            // the host transcript).
            var epipe: [2]c_int = .{ -1, -1 };
            const have_pipe = std.c.pipe(&epipe) == 0;
            const pid = std.c.fork();
            if (pid == 0) {
                // /usr/fx/package-set.dhall: the IMAGE-shipped guest pkgset
                // (absolute src paths, frozen at build time).  /usr is one
                // of the pivot binds, so the file is readable both pre- and
                // post-pivot; without it fx-activate defaults to a CWD
                // package-set.dhall that does not exist in the guest, and
                // in-guest activation would fail at load.
                if (have_pipe) {
                    _ = std.c.close(epipe[0]);
                    _ = std.c.dup2(epipe[1], 2);
                    _ = std.c.close(epipe[1]);
                }
                const av = [_:null]?[*:0]const u8{ @ptrCast(&g_fxstore), "--store", g_store, "--package-set", "/usr/fx/package-set.dhall", "--config", arg };
                _ = exec_sh_retry(@ptrCast(&g_fxstore), &av);
                _ = std.c.write(2, "fx-init: exec fx-activate failed\n", "fx-init: exec fx-activate failed\n".len);
                std.c._exit(127);
            }
            var rc: c_int = -1; // fork failed => rc stays -1 => failure below
            var eb: [512]u8 = undefined;
            var elen: usize = 0;
            if (pid > 0) {
                if (have_pipe) {
                    _ = std.c.close(epipe[1]);
                    // Drain the child's stderr to EOF (the child exits, all
                    // its fds close), keeping the LAST 512 bytes — the final
                    // lines carry the reason, the head is progress output.
                    // Reading BEFORE waitpid also empties the pipe so a
                    // chatty child cannot deadlock on a full pipe buffer.
                    while (true) {
                        var c: [256]u8 = undefined;
                        const n = std.c.read(epipe[0], &c, c.len);
                        if (n <= 0) break;
                        const un: usize = @intCast(n);
                        if (un >= eb.len) {
                            @memcpy(&eb, c[un - eb.len ..][0..eb.len]);
                            elen = eb.len;
                            continue;
                        }
                        if (elen + un > eb.len) {
                            const drop = elen + un - eb.len;
                            std.mem.copyForwards(u8, eb[0 .. eb.len - drop], eb[drop..]);
                            elen -= drop;
                        }
                        @memcpy(eb[elen..][0..un], c[0..un]);
                        elen += un;
                    }
                    _ = std.c.close(epipe[0]);
                }
                var st: c_int = 0;
                _ = std.c.waitpid(pid, &st, 0);
                const st_u32: u32 = @bitCast(st);
                rc = if (std.os.linux.W.IFEXITED(st_u32)) @as(c_int, std.os.linux.W.EXITSTATUS(st_u32)) else 1;
            }
            if (rc != 0) {
                rt_txn_begin();
                rt_effect(txn, "activate", "failed");
                _ = rt_txn_commit();
                // ONE channel line: "activate failed (rc N): <stderr tail>"
                // — inner newlines collapse to spaces so the response cannot
                // forge extra protocol lines.
                var msg: [560]u8 = undefined;
                var mi: usize = 0;
                const hdr = if (have_pipe) "activate failed" else "activate failed (no stderr capture)";
                @memcpy(msg[0..hdr.len], hdr);
                mi = hdr.len;
                const rcw = std.fmt.bufPrint(msg[mi..], " (rc {d})", .{rc}) catch msg[mi..][0..0];
                mi += rcw.len;
                var tl = elen;
                while (tl > 0 and (eb[tl - 1] == '\n' or eb[tl - 1] == '\r' or eb[tl - 1] == ' ')) tl -= 1;
                if (tl > 0 and mi + 2 < msg.len - 1) {
                    if (tl > msg.len - 1 - (mi + 2)) tl = msg.len - 1 - (mi + 2);
                    msg[mi] = ':';
                    msg[mi + 1] = ' ';
                    mi += 2;
                    var j: usize = 0;
                    while (j < tl) : (j += 1) {
                        const ch = eb[j];
                        if (ch == '\n' or ch == '\r' or ch == '\t') {
                            if (msg[mi - 1] == ' ') continue;
                            msg[mi] = ' ';
                        } else msg[mi] = ch;
                        mi += 1;
                    }
                    while (mi > 0 and msg[mi - 1] == ' ') mi -= 1;
                }
                msg[mi] = 0;
                resp_err(o, @ptrCast(&msg));
                return;
            }
            var e2: [1024]u8 = undefined;
            const s = fx_store_open_wrap(g_store, &e2, e2.len) orelse {
                resp_err(o, "store open after activate");
                return;
            };
            _ = fx_store_current_version_wrap(s, &g_current_version, &e2, e2.len);
            store_close_durable(s);
            _ = read_store_facts(g_current_version);
            rt_txn_begin();
            rt_set_generation_current(g_current_version);
            _ = rt_txn_commit();
            // HOT-APPLY: read_store_facts just swapped g_buildfile to the
            // NEW generation's Dhakefile, but nothing put its /etc + /bin on
            // the RUNNING root — the boot path's run_dhake() does exactly
            // that (idempotent: dhake Rm's before each Symlink and Copy
            // overwrites), so re-run it here on the live (post-pivot tmpfs)
            // root.  Post-activate the running root IS the tmpfs root, and
            // /fx/disk/store is reachable from it, so the rewritten
            // buildfile's absolute from-paths resolve.
            const drc = run_dhake();
            if (drc != 0) {
                // The generation IS activated in the store (published above
                // by the child, CURRENT committed) — do NOT roll it back.
                // But answering OK would be a lie about the RUNNING system,
                // so surface the reapply failure in the response (run_dhake
                // already logged the per-action detail as svc=dhake).
                rt_txn_begin();
                rt_effect(txn, "activate", "dhake-failed");
                _ = rt_txn_commit();
                var dm: [96]u8 = undefined;
                _ = snfmt(&dm, "activated version {d} (rootfs reapply FAILED, rc {d})", .{ g_current_version, drc });
                // same loss window as the OK path below: the child's
                // snapshot manifest must be on disk before the response.
                syncfs_store();
                resp_err(o, @ptrCast(&dm));
                return;
            }
            _ = fprintf(o, "activated version %u\n", g_current_version);
            rt_txn_begin();
            rt_effect(txn, "version", "");
            _ = rt_txn_commit();
            // Same loss window as the rollback arm below (its comment):
            // the child's publish writes snapshot manifests with buffered
            // stdio (dl.zig materializeSnapshot — the .dafsa files are
            // per-file fsync'd, the manifest is NOT), and the LAST store
            // touch before the response is read_store_facts' open/close —
            // a kill before writeback lands leaves the manifest 0-byte on
            // disk (MEASURED: next boot's dl_query_version finds no
            // generation and the guest boot-FAILED v7).  Flush everything
            // before answering.
            syncfs_store();
            resp_ok(o);
            return;
        } else {
            const v: u32 = @truncate(strtoul(arg, null, 10));
            var e2: [1024]u8 = undefined;
            const s = fx_store_open_wrap(g_store, &e2, e2.len) orelse {
                resp_err(o, "store open");
                return;
            };
            if (fx_store_rollback_wrap(s, v, false, &e2, e2.len) != 0) {
                store_close_durable(s);
                resp_err(o, @ptrCast(&e2));
                return;
            }
            _ = fx_store_current_version_wrap(s, &g_current_version, &e2, e2.len);
            store_close_durable(s);
            // The CURRENT rewrite is a separate commit from the rollback's
            // journal appends (same loss window as decide_boot_version's
            // roll-forward, init.zig:966-970): a kill between the socket
            // response and the next bootlog fsync loses it, and the next
            // boot rolls FORWARD again over the rollback the operator just
            // asked for.  The ctrl harness kills QEMU seconds after this
            // response — flush everything before answering.
            syncfs_store();
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

// ─── virtio-serial control channel (M4: tests/qemu_ctrl.sh) ───────────────

/// Is there a /dev/vport<p>n<p> node?  Scans (opendir/readdir, mirrors
/// modules_dir) rather than hardcoding vport0p1 — the first virtserialport is
/// INTERPRETED to land at vport0p1, but the node name is the kernel's to pick.
fn find_vport(out: []u8) bool {
    const d = opendir("/dev") orelse return false;
    defer _ = closedir(d);
    while (readdir(d)) |e| {
        const name = std.mem.sliceTo(&e.d_name, 0);
        if (std.mem.startsWith(u8, name, "vport") and std.mem.indexOf(u8, name, "p") != null) {
            if (name.len + ("/dev/".len) > out.len) continue;
            @memcpy(out[0.."/dev/".len], "/dev/");
            @memcpy(out["/dev/".len .. "/dev/".len + name.len], name);
            out["/dev/".len + name.len] = 0;
            return true;
        }
    }
    return false;
}

/// Open the guest end of the virtserialport, if this boot can have one:
/// PID1 (a harness running as a normal process must stay inert) AND an actual
/// vport node (no virtio-serial device attached => none exists => inert).
fn setup_virtio_ctrl() void {
    if (std.c.getpid() != 1) return;
    var vp: [256]u8 = undefined;
    if (!find_vport(&vp)) return;
    const fd = open(@ptrCast(&vp), O_RDWR | O_NONBLOCK, 0);
    if (fd < 0) {
        errf("fx-init: warning: virtio control: open {s}: {s}\n", .{ span(@ptrCast(&vp)), errnoStr() });
        return;
    }
    // ONE stdio write handle for the channel's lifetime: handle_request's
    // resp_ok/resp_err fprintf into it and fflush (init.zig resp_*), so the
    // response leaves for the host immediately.
    g_vio_wf = fdopen(fd, "w");
    const wf = g_vio_wf orelse {
        errf("fx-init: warning: virtio control: fdopen {s} failed\n", .{span(@ptrCast(&vp))});
        _ = std.c.close(fd);
        return;
    };
    g_vio_fd = fd;
    // The channel outlives many host sessions: make the FILE unbuffered (a
    // failed write loses only that response — nothing stale sits in a stdio
    // buffer for the NEXT session) and clear the stdio error flag whenever a
    // write failed (musl/glibc refuse all writes on a FILE once ferror is
    // set; without clearerr one dropped response would silence the channel
    // for every later peer).  MEASURED: nc -N's half-close makes qemu drop
    // the chardev before the guest's response write -> EAGAIN; the next
    // session must still be able to answer.
    _ = setvbuf(wf, null, _IONBF, 0);
    errf("fx-init: virtio control up ({s})\n", .{span(@ptrCast(&vp))});
}

/// One POLLIN dispatch on the virtio port: a single read, appended to the
/// carry buffer, split on newlines; each COMPLETE line runs the EXISTING
/// handle_request (the command grammar is the socket's, not a copy).
/// read()==0 (host chardev closed/dropped) LATCHES g_vio_peer_gone: a
/// disconnected port reports POLLIN|POLLHUP with an endless EOF, so the
/// latch both stops this path spinning and (see main_loop) drops the fd from
/// the poll set.  Any read that yields data clears the latch — the host
/// connected (or reconnected) and the port is live again.
fn handle_virtio() void {
    const wf = g_vio_wf orelse return;
    var buf: [4096]u8 = undefined;
    const n = std.c.read(g_vio_fd, &buf, buf.len);
    if (n < 0) return; // EAGAIN or a transient error: nothing to do
    if (n == 0) {
        if (!g_vio_peer_gone) errf("fx-init: vio: peer EOF (latched)\n", .{});
        g_vio_peer_gone = true;
        return;
    }
    if (g_vio_peer_gone) errf("fx-init: vio: peer is back\n", .{});
    g_vio_peer_gone = false;
    // One command per read (MEASURED on this channel: the host's requests
    // arrive as separate reads) — handle_request takes a MUTABLE [*:0]u8
    // (strtok_r), so a shared static line buffer would alias g_vio_carry.
    var consumed: usize = 0;
    while (consumed < @as(usize, @intCast(n))) {
        const nl = std.mem.indexOfScalar(u8, buf[consumed..@intCast(n)], '\n') orelse {
            // partial line: carry it, capped — a line longer than the buffer
            // is truncated at REQ_MAX-1 and handled (garbage-in) rather than
            // wedgeing the channel.
            const room = @min(g_vio_carry.len - 1 - g_vio_carry_len, @as(usize, @intCast(n)) - consumed);
            @memcpy(g_vio_carry[g_vio_carry_len .. g_vio_carry_len + room], buf[consumed .. consumed + room]);
            g_vio_carry_len += room;
            consumed += room;
            break;
        };
        const seg = buf[consumed .. consumed + nl];
        var line: [REQ_MAX + 1]u8 = undefined;
        const clen = @min(g_vio_carry_len, REQ_MAX);
        @memcpy(line[0..clen], g_vio_carry[0..clen]);
        const total = clen + seg.len;
        if (total <= REQ_MAX) {
            @memcpy(line[clen..total], seg);
            line[total] = 0;
            handle_request(wf, @ptrCast(&line));
        }
        // overlong line: copy the truncated seg and NUL-terminate, then feed
        // it (garbage-in).  line[clen..REQ_MAX] is zeroed first so a truncated
        // segment cannot carry uninitialized garbage into the handled line;
        // line[REQ_MAX] terminates it so strtok_r stops at the boundary.
        else {
            @memset(line[clen..REQ_MAX], 0);
            const copy_len = @min(seg.len, REQ_MAX - clen);
            @memcpy(line[clen..clen + copy_len], seg[0..copy_len]);
            line[REQ_MAX] = 0;
            handle_request(wf, @ptrCast(&line));
        }
        g_vio_carry_len = 0;
        consumed += nl + 1;
    }
    // One flushed, observed response per dispatch; a failed write (host
    // dropped the chardev mid-response — MEASURED with nc -N) clears the
    // error flag so the NEXT session can still answer.
    _ = fflush(wf);
    if (ferror(wf) != 0) {
        errf("fx-init: vio: response write failed (host dropped?) — clearing\n", .{});
        clearerr(wf);
    }
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
    if (g_vio_fd >= 0) {
        // g_vio_wf is an fdopen over g_vio_fd and owns it — one fclose
        // closes both (fdclose(3) is not in this libc; no double close).
        if (g_vio_wf) |wf| _ = fclose(wf) else _ = std.c.close(g_vio_fd);
        g_vio_fd = -1;
        g_vio_wf = null;
    }
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
        // Latched (no live peer / host dropped): keep the port OUT of the
        // poll set — a disconnected virtserialport is POLLIN|POLLHUP-readable
        // FOREVER and would spin poll at 100% — and reprobe it once per
        // iteration below instead (MEASURED on the first qemu_ctrl run).
        if (g_vio_fd >= 0 and !g_vio_peer_gone) {
            pf[nfd] = .{ .fd = g_vio_fd, .events = std.posix.POLL.IN, .revents = 0 };
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
        if (g_vio_fd >= 0 and !g_vio_peer_gone) {
            pi = 0;
            while (pi < nfd) : (pi += 1) {
                if (pf[pi].fd == g_vio_fd and (pf[pi].revents & (std.posix.POLL.IN | std.posix.POLL.HUP)) != 0) {
                    handle_virtio();
                }
            }
        } else if (g_vio_fd >= 0) {
            // reprobe: ONE nonblocking read per main-loop iteration — the
            // latched port may have a host again (qemu's chardev accepts a
            // new connection without touching the guest).  A poll() with a
            // <=1s timeout bounds the cadence, so this is not a spin; the
            // first data read clears the latch and the fd rejoins the poll
            // set above.  Silent by design: handle_virtio logs only STATE
            // CHANGES (peer EOF latched / peer is back) — one console line
            // that matters must not drown in per-iteration reprobes.
            handle_virtio();
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

    // Real-init path (rdinit in the initramfs image): nothing has mounted the
    // kernel filesystems yet, and fx_probe_refresh below reads /proc + /sys.
    // Inert everywhere else — the bwrap harnesses and FX_INIT_FORCE runs
    // always have /proc up, and mount_early skips when it finds it — followed
    // by the one console line proving PID1 itself started (fd 2 is
    // /dev/console for a rdinit PID1; a captured stderr in the harnesses).
    mount_early();
    errf("fx-init: boot start store {s}\n", .{span(g_store)});
    // the persistent store must be up (and g_store repointed at it) before
    // ANY store handle is opened — the first open is inside
    // decide_boot_version below.
    ensure_disk_store();
    // the real-rootfs pivot: must run at THIS instant — after the disk store
    // (so its mount can travel into the new root) and before the pipe/signal
    // setup, the first store open, and /run/fx (all of which then land ON the
    // new root).  Inert unless PID1 on an initramfs rootfs (see the gates).
    pivot_root_to_tmpfs();

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
        errf("fx-init: boot-FAILED v{d}\n", .{g_current_version});
        g_boot_version = 0;
        // Pin the verdict: no services were loaded, so boot_decision would
        // see an EMPTY slice at grace expiry — all_started vacuously true,
        // any_failed false — and emit a SECOND, contradicting boot-ok v0
        // (plus a false rt_set_boot "ok" commit) for this already-failed boot.
        g_boot_decided = 1;
        g_boot_failed = 1;
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
            // console verdict — same line the other failure sites emit; the
            // QEMU harness greps it.  Without this a dhake-failure boot has
            // no observable verdict and the harness sees a bare timeout.
            errf("fx-init: boot-FAILED v{d}\n", .{g_current_version});
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
    setup_virtio_ctrl();

    log_line("fx-init", "info", "entered main loop");
    main_loop();
    do_shutdown();
}

// ─── tests (pure parts: parse_on, boot_decision, next_timeout, on_ready) ──

test "pivot gate constants (linux/magic.h + the measured rootfs fstype)" {
    // The pivot gate/proof depend on kernel-fixed values.  A wrong constant
    // here is a silent boot regression (the gate never fires, or the proof
    // line never prints), so pin them: TMPFS_MAGIC from linux/magic.h, and
    // the /proc/mounts root-entry fstype strings MEASURED on the pinned
    // kernel 7.1.8-1-default (initramfs root = "rootfs", pivoted new root =
    // "tmpfs").  Note statfs("/") reports TMPFS_MAGIC on the initramfs root
    // TOO when CONFIG_TMPFS=y (measured) — which is exactly why the fstype
    // strings, not the magic, carry the gate; this test pins all of them.
    try std.testing.expectEqual(@as(i64, 0x01021994), TMPFS_MAGIC);
    try std.testing.expectEqual(@as(c_ulong, 8192), MS_MOVE);
    try std.testing.expectEqual(@as(c_ulong, 4096), MS_BIND);
    // the gate/proof fstype literals are LOAD-BEARING and kernel-fixed:
    // "rootfs" is what mounts(5) reports for the root entry of an
    // initramfs root and "tmpfs" for the pivoted new root (both MEASURED
    // via a static rdinit probe pre/post pivot_root on the pinned kernel).
    // The gate would silently never fire (and the proof never print) if
    // either literal were edited to anything else — including each OTHER,
    // so assert they differ too.
    try std.testing.expectEqualStrings("rootfs", ROOTFS_FST);
    try std.testing.expectEqualStrings("tmpfs", TMPFS_FST);
    try std.testing.expect(!std.mem.eql(u8, ROOTFS_FST, TMPFS_FST));
    // the moves the undo reverses must be exactly the canonical kernel
    // filesystems — a dropped entry leaves the initramfs root without it
    // after a rolled-back pivot; a wrong path fails the move itself.
    try std.testing.expectEqualStrings("/proc", pivot_kernel_moves[0][0]);
    try std.testing.expectEqualStrings("/sys", pivot_kernel_moves[1][0]);
    try std.testing.expectEqualStrings("/dev", pivot_kernel_moves[2][0]);
    try std.testing.expectEqualStrings("/newroot/proc", pivot_kernel_moves[0][1]);
    try std.testing.expectEqualStrings("/newroot/sys", pivot_kernel_moves[1][1]);
    try std.testing.expectEqualStrings("/newroot/dev", pivot_kernel_moves[2][1]);
}

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
