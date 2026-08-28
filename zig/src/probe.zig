//! probe.zig — faithful Zig port of src/fx_probe.c (U-C2), the init-hosted
//! OS probe loop.
//!
//! The datalog-dafsa engine stays C (the `fxengine` static lib in build.zig);
//! this ports only the wrapper logic.  Zig 0.16 std.posix lacks several of
//! the C entry points (opendir/readdir, statvfs, uname, strtok_r, ...), so
//! they are declared as local libc externs — the established pattern from
//! supervise.zig's socket externs (dhall-c http.zig).
//!
//! Every source read that fails is skipped (a probe that errors on one entry
//! still reports the rest).  `root` is a test-only fixture redirect for
//! /proc, /sys, /etc reads; fs (statvfs) and uname always hit the real
//! system.  sym() returns 1 when the interner fails (unlike fx_log.c's emit,
//! where 0 = hard failure).
const std = @import("std");

pub const dl_db = opaque {};
pub const dl_iter = opaque {};

extern fn dl_declare_relation(db: *dl_db, name: [*:0]const u8, arity: u8) c_int;
extern fn dl_intern_str(db: *dl_db, str: ?[*:0]const u8) u32;
extern fn dl_iter_open(db: *dl_db, rel: [*:0]const u8, leading: ?[*]const u32, k: u8) ?*dl_iter;
extern fn dl_iter_arity(it: *const dl_iter) u8;
extern fn dl_iter_next(it: *dl_iter, cols_out: [*]u32) c_int;
extern fn dl_iter_close(it: ?*dl_iter) void;
extern fn dl_txn_begin(db: *dl_db) c_int;
extern fn dl_txn_add_fact(db: *dl_db, rel: [*:0]const u8, cols: [*]const u32, arity: u8) c_int;
extern fn dl_txn_delete_fact(db: *dl_db, rel: [*:0]const u8, cols: [*]const u32, arity: u8) c_int;
extern fn dl_txn_commit(db: *dl_db) c_int;
extern fn dl_txn_rollback(db: *dl_db) c_int;

// ─── libc externs (std.posix gaps; glibc/Linux) ───────────────────────────

const DIR = std.c.DIR;
const dirent = std.c.dirent; // { ino, off, reclen, type, name[256] }
extern fn opendir(path: [*:0]const u8) ?*DIR;
extern fn readdir(dir: *DIR) ?*dirent;
extern fn closedir(dir: *DIR) c_int;

/// glibc `struct statvfs` (fsblkcnt_t/fsfilcnt_t are u64 on LP64).
const StatVfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
    __f_spare: [6]c_uint,
};
extern fn statvfs(path: [*:0]const u8, buf: *StatVfs) c_int;

/// glibc `struct utsname` (_UTSNAME_LENGTH = 65).
const Utsname = extern struct {
    sysname: [65]u8,
    nodename: [65]u8,
    release: [65]u8,
    version: [65]u8,
    machine: [65]u8,
    domainname: [65]u8,
};
extern fn uname(buf: *Utsname) c_int;

const Timespec = extern struct { sec: i64, nsec: i64 };

/// glibc `struct stat` (x86-64/aarch64 LP64).  st_mtime == st_mtim.sec.
const Stat = extern struct {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    __pad0: c_int,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i64,
    st_blocks: i64,
    st_atim: Timespec,
    st_mtim: Timespec,
    st_ctim: Timespec,
    __unused: [3]i64,
};
extern fn stat(path: [*:0]const u8, buf: *Stat) c_int;

/// Linux _SC_PAGESIZE (= 30 on every Linux ABI zig targets).
const _SC_PAGESIZE: c_int = 30;
extern fn sysconf(name: c_int) c_long;

extern fn strtok_r(str: ?[*:0]u8, delim: [*:0]const u8, saveptr: *?[*:0]u8) ?[*:0]u8;
extern fn strtoul(s: [*:0]const u8, endptr: ?*[*:0]u8, base: c_int) c_ulong;
extern fn strtod(s: [*:0]const u8, endptr: ?*[*:0]u8) f64;
extern fn strstr(hay: [*:0]const u8, needle: [*:0]const u8) ?[*:0]u8;
extern fn strchr(s: [*:0]const u8, c: c_int) ?[*:0]u8;
extern fn strrchr(s: [*:0]const u8, c: c_int) ?[*:0]u8;
extern fn strpbrk(s: [*:0]const u8, accept: [*:0]const u8) ?[*:0]u8;
/// Variadic snprintf keeps the C's exact truncation semantics for path and
/// comm buffers.
extern fn snprintf(buf: [*]u8, cap: usize, fmt: [*:0]const u8, ...) c_int;

const FILE = std.c.FILE;
extern fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern fn fclose(stream: *FILE) c_int;

extern fn malloc(size: usize) ?[*]u8;
extern fn realloc(ptr: [*]u8, size: usize) ?[*]u8;
extern fn free(ptr: ?*anyopaque) void;

// ─── helpers ──────────────────────────────────────────────────────────────

/// Build "<root><sub>" (root may be "" or NULL for the real system) into out.
fn pfx(out: [*]u8, cap: usize, root: ?[*:0]const u8, sub: [*:0]const u8) void {
    const r: [*:0]const u8 = root orelse "";
    if (r[0] != 0)
        _ = snprintf(out, cap, "%s%s", r, sub)
    else
        _ = snprintf(out, cap, "%s", sub);
}

fn isdigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// read a small file fully into a malloc'd buffer (NUL-terminated).
fn read_file(path: [*:0]const u8) ?[*:0]u8 {
    const f = fopen(path, "rb") orelse return null;
    const buf = malloc(65536) orelse {
        _ = fclose(f);
        return null;
    };
    const n = fread(buf, 1, 65535, f);
    _ = fclose(f);
    buf[n] = 0;
    return @ptrCast(buf);
}

/// first integer token in `s` (strtoul).
fn first_u32(s_in: [*:0]const u8) u32 {
    var s = s_in;
    while (s[0] != 0 and !isdigit(s[0])) s += 1;
    return @truncate(strtoul(s, null, 10));
}

/// snprintf(err, errcap, "%s", msg) truncation semantics.
fn set_err(err: ?[*]u8, errcap: usize, msg: []const u8) void {
    const buf = err orelse return;
    if (errcap == 0) return;
    const n = @min(msg.len, errcap - 1);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
}

/// delete-all existing tuples of `rel` (collect then delete — safe vs the
/// live DAFSA cursor).  Must be called inside an open txn.
fn clear_rel(db: *dl_db, rel: [*:0]const u8, arity: u8) c_int {
    const it = dl_iter_open(db, rel, null, 0) orelse return 0; // absent/empty: fine
    if (dl_iter_arity(it) != arity) {
        dl_iter_close(it);
        return -1;
    }
    // collect all tuples
    var cap: usize = 64;
    var n: usize = 0;
    var all = malloc(cap * arity * @sizeOf(u32)) orelse {
        dl_iter_close(it);
        return -1;
    };
    var row: [8]u32 = undefined;
    while (dl_iter_next(it, &row) == 1) {
        if (n >= cap) {
            cap *= 2;
            const na = realloc(all, cap * arity * @sizeOf(u32)) orelse {
                dl_iter_close(it);
                return -1;
            };
            all = na;
        }
        const all32: [*]u32 = @ptrCast(@alignCast(all));
        @memcpy(all32[n * arity ..][0..arity], row[0..arity]);
        n += 1;
    }
    dl_iter_close(it);
    const all32: [*]u32 = @ptrCast(@alignCast(all));
    var i: usize = 0;
    while (i < n) : (i += 1)
        _ = dl_txn_delete_fact(db, rel, all32[i * arity ..], arity);
    free(all);
    return 0;
}

/// add one fact with mixed interned/raw columns.
fn add(db: *dl_db, rel: [*:0]const u8, cols: []const u32) void {
    _ = dl_txn_add_fact(db, rel, cols.ptr, @intCast(cols.len));
}

fn sym(db: *dl_db, s: [*:0]const u8) u32 {
    const r = dl_intern_str(db, s);
    return if (r != 0) r else 1; // 1 is always at least the empty/first sym
}

// ─── process <- /proc/[0-9]+/{stat,status} ────────────────────────────────

fn is_pid_dir(name: [*:0]const u8) bool {
    if (name[0] == 0 or !isdigit(name[0])) return false;
    var p = name;
    while (p[0] != 0) : (p += 1) {
        if (!isdigit(p[0])) return false;
    }
    return true;
}

fn probe_process(db: *dl_db, root: ?[*:0]const u8) void {
    var proc: [512]u8 = undefined;
    pfx(&proc, proc.len, root, "/proc");
    _ = clear_rel(db, "process", 6);
    const d = opendir(@ptrCast(&proc)) orelse return;
    defer _ = closedir(d);
    var pgkb = @divTrunc(sysconf(_SC_PAGESIZE), 1024);
    if (pgkb <= 0) pgkb = 4;
    const pgkb32: u32 = @truncate(@as(u64, @bitCast(pgkb)));
    while (readdir(d)) |e| {
        const name: [*:0]const u8 = @ptrCast(&e.name);
        if (!is_pid_dir(name)) continue;
        var path: [1100]u8 = undefined;
        // /proc/<pid>/stat: pid (comm) state ppid ... rss
        _ = snprintf(&path, path.len, "%s/%s/stat", @as([*:0]const u8, @ptrCast(&proc)), name);
        const statbuf = read_file(@ptrCast(&path)) orelse continue;
        const pid: u32 = @truncate(strtoul(name, null, 10));
        // find last ')' to skip comm (may contain spaces)
        const cp = strrchr(statbuf, ')') orelse {
            free(statbuf);
            continue;
        };
        const cpp = cp + 1; // past ')'
        // tokenize the remainder
        var save: ?[*:0]u8 = null;
        var tok = strtok_r(cpp, " \t\n", &save);
        var fields: [32]?[*:0]u8 = undefined;
        var nf: usize = 0;
        while (tok != null and nf < 32) {
            fields[nf] = tok;
            nf += 1;
            tok = strtok_r(null, " \t\n", &save);
        }
        if (nf < 22) {
            free(statbuf);
            continue;
        }
        const st = fields[0].?[0];
        const ppid: u32 = @truncate(strtoul(fields[1].?, null, 10));
        // comm: between '(' and the last ')'
        var commbuf: [256]u8 = undefined;
        if (strchr(statbuf, '(')) |comm0| {
            if (@intFromPtr(cpp) > @intFromPtr(comm0)) {
                // C: L = (cp_after_incr - 1) - (comm0 + 1); here cp IS the
                // ')' position, so L = cp - comm0 - 1.
                var len = @intFromPtr(cp) - @intFromPtr(comm0) - 1;
                if (len >= commbuf.len) len = commbuf.len - 1;
                @memcpy(commbuf[0..len], (comm0 + 1)[0..len]);
                commbuf[len] = 0;
            } else {
                _ = snprintf(&commbuf, commbuf.len, "%u", pid);
            }
        } else {
            _ = snprintf(&commbuf, commbuf.len, "%u", pid);
        }
        const rss: u32 = @truncate(strtoul(fields[21].?, null, 10));
        const rss_kb = rss *% pgkb32;
        free(statbuf);
        // uid from /proc/<pid>/status Uid: line
        var uid: u32 = 0;
        _ = snprintf(&path, path.len, "%s/%s/status", @as([*:0]const u8, @ptrCast(&proc)), name);
        if (read_file(@ptrCast(&path))) |status| {
            if (strstr(status, "Uid:")) |u| uid = first_u32(u + 4);
            free(status);
        }
        var stbuf = [2]u8{ st, 0 };
        const cols = [6]u32{
            pid,                         ppid,
            uid,                         sym(db, @ptrCast(&commbuf)),
            sym(db, @ptrCast(&stbuf)),   rss_kb,
        };
        add(db, "process", &cols);
    }
}

// ─── fs <- statvfs on {/, /run, /fx/store} ────────────────────────────────

fn probe_fs(db: *dl_db) void {
    _ = clear_rel(db, "fs", 5);
    const paths = [_][*:0]const u8{ "/", "/run", "/fx/store" };
    const fts = [_][*:0]const u8{ "rootfs", "tmpfs", "store" };
    for (paths, fts) |path, ft| {
        var v: StatVfs = undefined;
        if (statvfs(path, &v) != 0) continue;
        var bkb = v.f_bsize / 1024;
        if (bkb == 0) bkb = 1;
        const total: u32 = @truncate(v.f_blocks *% bkb);
        const freeb: u32 = @truncate(v.f_bfree *% bkb);
        const avail: u32 = @truncate(v.f_bavail *% bkb);
        const used: u32 = total -% freeb;
        const cols = [5]u32{ sym(db, path), sym(db, ft), total, used, avail };
        add(db, "fs", &cols);
    }
}

// ─── file <- stat on {/etc/hostname} (fixture-aware) ──────────────────────

fn probe_file(db: *dl_db, root: ?[*:0]const u8) void {
    _ = clear_rel(db, "file", 6);
    var path: [512]u8 = undefined;
    pfx(&path, path.len, root, "/etc/hostname");
    var sb: Stat = undefined;
    if (stat(@ptrCast(&path), &sb) == 0) {
        // keep the logical path as the key (fixture path only for the stat)
        const cols = [6]u32{
            sym(db, "/etc/hostname"),
            @truncate(@as(u64, @bitCast(sb.st_size))),
            sb.st_mode,
            sb.st_uid,
            sb.st_gid,
            @truncate(@as(u64, @bitCast(sb.st_mtim.sec))),
        };
        add(db, "file", &cols);
    }
}

// ─── device + net <- /sys/class/net/<iface>/ ──────────────────────────────

fn probe_net(db: *dl_db, root: ?[*:0]const u8) void {
    var sysnet: [512]u8 = undefined;
    pfx(&sysnet, sysnet.len, root, "/sys/class/net");
    _ = clear_rel(db, "device", 5);
    _ = clear_rel(db, "net", 6);
    const d = opendir(@ptrCast(&sysnet)) orelse return;
    defer _ = closedir(d);
    while (readdir(d)) |e| {
        const name: [*:0]const u8 = @ptrCast(&e.name);
        if (name[0] == '.') continue;
        var base: [1100]u8 = undefined;
        _ = snprintf(&base, base.len, "%s/%s", @as([*:0]const u8, @ptrCast(&sysnet)), name);
        const basep: [*:0]const u8 = @ptrCast(&base);
        // address (MAC)
        var p: [1300]u8 = undefined;
        _ = snprintf(&p, p.len, "%s/address", basep);
        var mac = read_file(@ptrCast(&p));
        if (mac) |mc| {
            if (strpbrk(mc, "\n\r")) |nl| nl[0] = 0;
            if (mc[0] == 0) {
                free(mc);
                mac = null;
            }
        }
        // operstate
        _ = snprintf(&p, p.len, "%s/operstate", basep);
        const op = read_file(@ptrCast(&p));
        if (op) |o| {
            if (strpbrk(o, "\n\r")) |nl| nl[0] = 0;
        }
        // ifindex as minor
        _ = snprintf(&p, p.len, "%s/ifindex", basep);
        const idx = read_file(@ptrCast(&p));
        const ifindex: u32 = if (idx) |ix| first_u32(ix) else 0;
        if (idx) |ix| free(ix);
        // rx/tx bytes
        _ = snprintf(&p, p.len, "%s/statistics/rx_bytes", basep);
        const rx = read_file(@ptrCast(&p));
        _ = snprintf(&p, p.len, "%s/statistics/tx_bytes", basep);
        const tx = read_file(@ptrCast(&p));
        const rxb: u32 = if (rx) |r| first_u32(r) else 0;
        const txb: u32 = if (tx) |t| first_u32(t) else 0;
        const m: [*:0]const u8 = mac orelse "?";
        const s: [*:0]const u8 = op orelse "unknown";
        const cols = [6]u32{ sym(db, name), sym(db, m), sym(db, m), sym(db, s), rxb, txb };
        add(db, "net", &cols);
        // device entry for the same iface
        const dcols = [5]u32{ sym(db, name), 0, ifindex, sym(db, "net"), 0 };
        add(db, "device", &dcols);
        if (mac) |mc| free(mc);
        if (op) |o| free(o);
        if (rx) |r| free(r);
        if (tx) |t| free(t);
    }
}

// ─── kernel <- uname + /proc/loadavg + /proc/meminfo ──────────────────────

/// C's (uint32_t) double cast: truncation.  Out-of-domain values are UB in C
/// (unreachable for loadavg/uptime); @intFromFloat traps on them in
/// ReleaseSafe rather than silently wrapping.
fn f64_to_u32(f: f64) u32 {
    return @intFromFloat(f);
}

fn probe_kernel(db: *dl_db, root: ?[*:0]const u8) void {
    _ = clear_rel(db, "kernel", 7);
    var u: Utsname = undefined;
    if (uname(&u) != 0) return;
    var p: [512]u8 = undefined;
    // loadavg: "0.10 0.20 0.30 ..." -> load1 * 100
    pfx(&p, p.len, root, "/proc/loadavg");
    var load1: u32 = 0;
    if (read_file(@ptrCast(&p))) |la| {
        const f = strtod(la, null);
        load1 = f64_to_u32(f * 100.0);
        free(la);
    }
    // meminfo: MemTotal: X kB / MemFree: Y kB
    pfx(&p, p.len, root, "/proc/meminfo");
    var mt: u32 = 0;
    var mf: u32 = 0;
    if (read_file(@ptrCast(&p))) |mi| {
        if (strstr(mi, "MemTotal:")) |t| mt = first_u32(t + 9);
        if (strstr(mi, "MemFree:")) |fr| mf = first_u32(fr + 8);
        free(mi);
    }
    // uptime_s from /proc/uptime
    pfx(&p, p.len, root, "/proc/uptime");
    var uptime: u32 = 0;
    if (read_file(@ptrCast(&p))) |up| {
        uptime = f64_to_u32(strtod(up, null));
        free(up);
    }
    // hostname from uname (nodename)
    const cols = [7]u32{
        sym(db, @ptrCast(&u.sysname)),
        sym(db, @ptrCast(&u.release)),
        sym(db, @ptrCast(&u.nodename)),
        uptime,
        load1,
        mt,
        mf,
    };
    add(db, "kernel", &cols);
}

// ─── env <- environ snapshot ──────────────────────────────────────────────

fn probe_env(db: *dl_db) void {
    _ = clear_rel(db, "env", 2);
    var i: usize = 0;
    while (std.c.environ[i]) |ep| : (i += 1) {
        const eq = strchr(ep, '=') orelse continue;
        var kl: usize = @intFromPtr(eq) - @intFromPtr(ep);
        var key: [512]u8 = undefined;
        if (kl >= key.len) kl = key.len - 1;
        @memcpy(key[0..kl], ep[0..kl]);
        key[kl] = 0;
        const cols = [2]u32{ sym(db, @ptrCast(&key)), sym(db, eq + 1) };
        add(db, "env", &cols);
    }
}

// ─── public API ───────────────────────────────────────────────────────────

pub fn fx_probe_declare(rt: ?*dl_db) c_int {
    const db = rt orelse return -1;
    if (dl_declare_relation(db, "process", 6) != 0) return -1;
    if (dl_declare_relation(db, "fs", 5) != 0) return -1;
    if (dl_declare_relation(db, "file", 6) != 0) return -1;
    if (dl_declare_relation(db, "device", 5) != 0) return -1;
    if (dl_declare_relation(db, "kernel", 7) != 0) return -1;
    if (dl_declare_relation(db, "net", 6) != 0) return -1;
    if (dl_declare_relation(db, "env", 2) != 0) return -1;
    return 0;
}

pub fn fx_probe_refresh(rt: ?*dl_db, root: ?[*:0]const u8, err: ?[*]u8, errcap: usize) c_int {
    const db = rt orelse {
        set_err(err, errcap, "null db");
        return -1;
    };
    if (dl_txn_begin(db) != 0) {
        set_err(err, errcap, "txn_begin failed");
        return -1;
    }
    probe_process(db, root);
    probe_fs(db);
    probe_file(db, root);
    probe_net(db, root);
    probe_kernel(db, root);
    probe_env(db);
    if (dl_txn_commit(db) != 0) {
        _ = dl_txn_rollback(db);
        set_err(err, errcap, "txn_commit failed");
        return -1;
    }
    return 0;
}

// ─── C ABI surface (linked into zig/log_probe_live.c as zig_probe_*) ──────

export fn zig_probe_declare(rt: ?*dl_db) c_int {
    return fx_probe_declare(rt);
}
export fn zig_probe_refresh(rt: ?*dl_db, root: ?[*:0]const u8, err: ?[*]u8, errcap: usize) c_int {
    return fx_probe_refresh(rt, root, err, errcap);
}

// ─── tests ────────────────────────────────────────────────────────────────

test "is_pid_dir" {
    try std.testing.expect(is_pid_dir("1"));
    try std.testing.expect(is_pid_dir("100"));
    try std.testing.expect(!is_pid_dir(""));
    try std.testing.expect(!is_pid_dir("."));
    try std.testing.expect(!is_pid_dir("1a"));
    try std.testing.expect(!is_pid_dir("acpi"));
}

test "first_u32 skips to first digit, strtoul truncation to u32" {
    try std.testing.expectEqual(@as(u32, 1000), first_u32("\t1000\t1000"));
    try std.testing.expectEqual(@as(u32, 42), first_u32("Uid:\t42"));
    try std.testing.expectEqual(@as(u32, 0), first_u32("no digits"));
    try std.testing.expectEqual(@as(u32, 0), first_u32(""));
    try std.testing.expectEqual(@as(u32, 4294967295), first_u32("99999999999999999999"));
}
