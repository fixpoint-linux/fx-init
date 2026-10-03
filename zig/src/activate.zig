// activate.zig — faithful Zig port of src/fx-activate.c (U-B, unit 5): the
// build-time activation CLI.  Evaluates config.dhall + package-set.dhall,
// computes the closure through the fxstore ZIG port (packageset/derivation/
// closure/store in the sibling ../fxstore checkout, re-exported via the
// fxstore.zig facade — the C store core is no longer linked), then renders +
// publishes the per-generation buildfile and facts.
//
// Mirrored 1:1 section-for-section (CLI/usage -> Buf + dhall escaper ->
// PathEntry/compute_paths -> render_passwd/group -> on_full/base_name ->
// emit_action_header/emit_buildfile -> serialize_generation -> write_file_p ->
// declare/clear_rel/add_fact -> main).  All error strings are VERBATIM from
// fx-activate.c; the byte shape of the emitted Dhakefile.dhall (incl. the
// trailing-", "-trim quirk at fx-activate.c:320,341) and of the canonical
// genhash serialization must match the C oracle exactly (activate_diff.sh
// byte-compares both).
//
// Fidelity notes:
//   - the C threads `char err[ERR_CAP=4096]` through every call; the Zig side
//     uses config.ErrBuf (2048 cap, unit-1 precedent) for its own fx_err-style
//     messages and a plain [4096]u8 for the store-core modules' error buffers
//     (each module's ErrBuf is copied in via cerrCopy) — divergence only for
//     >2047-byte error strings (unreachable in the corpus).
//   - config strings are Zig slices; every string crossing into the dl_*
//     engine ABI (dl_intern_str) is dupeZ'd.
//   - the C's free-everything error unwinding is dropped (config.zig
//     precedent): this is a process-lifetime CLI, exits make frees moot.
//   - libc snprintf sites (renderers, path joins) go through snfmt/snfmtz,
//     which format unbounded then truncate to the buffer cap — snprintf
//     semantics, byte-identical output.
const std = @import("std");
const cfg_mod = @import("config");
const fx = @import("fxstore");

const FxConfig = cfg_mod.FxConfig;
const FxService = cfg_mod.FxService;
const FxOnKind = cfg_mod.FxOnKind;
const FxProbeKind = cfg_mod.FxProbeKind;
const FxRestart = cfg_mod.FxRestart;
const ErrBuf = cfg_mod.ErrBuf;

// The fxstore Zig port's types (the vendored C store core, now Zig).
const Package = fx.Package;
const PackageSet = fx.PackageSet;
const SrcKind = fx.SrcKind;
const Store = fx.Store;
const DlDb = fx.DlDb;
const DlIter = fx.DlIter;

// libc is linked; use the C malloc allocator (config.zig pattern — the
// process-lifetime CLI allocator).
const gpa_alloc = std.heap.c_allocator;

// libc scratch (log.zig pattern).
extern "c" fn strerror(errnum: c_int) [*:0]const u8;
extern "c" fn getpid() c_int;
extern "c" fn time(t: ?*i64) i64;

const EEXIST: c_int = 17; // Linux
const PATH_MAX: usize = 4096;

fn errStr() []const u8 {
    return std.mem.span(strerror(std.c._errno().*));
}

/// The `generation` fact's epoch column.  Default = the wall clock (the C
/// oracle's time(null); the diff harness normalizes it, so UNSET must stay
/// exactly that).  FX_EPOCH overrides it for reproducible builds (fx-image
/// exports it to every provisioning child), with SOURCE_DATE_EPOCH — the
/// reproducible-builds convention — as fallback.  A set-but-unparseable
/// value FAILS rather than silently falling back to the clock: a typo'd
/// override must not produce a store that only looks reproducible.
/// Deviation from the 1:1 C mirror (the C read no environment here).
fn genEpoch() u32 {
    for ([_][*:0]const u8{ "FX_EPOCH", "SOURCE_DATE_EPOCH" }) |name| {
        const v = std.c.getenv(name) orelse continue;
        const s = std.mem.span(v);
        if (s.len == 0) continue; // set-but-empty behaves as unset
        return std.fmt.parseInt(u32, s, 10) catch {
            std.debug.print("fx-activate: {s} is set but not a u32 epoch: \"{s}\"\n", .{ name, s });
            std.process.exit(1);
        };
    }
    return @truncate(@as(u64, @bitCast(time(null))));
}

/// fx_err into the Zig ErrBuf, then fail (error value chosen by the caller).
/// set() RETURNS the error value (config.zig's `return e.set(...)` contract)
/// — discard it here.
fn eSet(e: *ErrBuf, comptime fmt: []const u8, args: anytype) void {
    e.set(fmt, args) catch {};
}

/// snprintf(buf, cap, fmt, ...): format unbounded, then truncate to
/// buf.len-1 bytes + NUL — the C's everywhere-idiom, byte-identical output.
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

/// snfmt for C-ABI consumers (mkdir/rename/dl_intern_str): NUL-terminated.
fn snfmtz(buf: anytype, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    const s = snfmt(buf, fmt, args);
    const p: [*:0]const u8 = @ptrCast(s.ptr);
    return p[0..s.len :0];
}

/// strdup for config strings crossing into C (process-lifetime leak).
fn dupeZ(s: []const u8) [*:0]const u8 {
    const z = gpa_alloc.dupeZ(u8, s) catch @panic("out of memory");
    return z.ptr;
}

// ─── growable byte buffer ─────────────────────────────────────────────────

pub const Buf = struct {
    d: []u8 = &.{},
    len: usize = 0,

    const init_cap: usize = 4096;

    /// buf_init (the C ignores its return at the call sites that matter, so
    /// OOM here panics rather than diverging).
    pub fn init(b: *Buf) void {
        b.* = .{ .d = gpa_alloc.alloc(u8, init_cap) catch @panic("out of memory"), .len = 0 };
    }

    fn reserve(b: *Buf, add: usize) error{OutOfMemory}!void {
        if (b.len + add + 1 <= b.d.len) return;
        var nc = @max(b.d.len, init_cap);
        while (nc < b.len + add + 1) nc *= 2;
        b.d = gpa_alloc.realloc(b.d, nc) catch return error.OutOfMemory;
    }

    pub fn put(b: *Buf, p: []const u8) error{OutOfMemory}!void {
        try b.reserve(p.len);
        @memcpy(b.d[b.len..][0..p.len], p);
        b.len += p.len;
        b.d[b.len] = 0; // keep NUL-terminated for strlen() consumers (etc content)
    }

    pub fn str(b: *Buf, s: []const u8) error{OutOfMemory}!void {
        return b.put(s);
    }

    pub fn ch(b: *Buf, c: u8) error{OutOfMemory}!void {
        return b.put(&[1]u8{c});
    }

    /// buf_u32: u32be length prefix (canonical serialization).
    pub fn u32be(b: *Buf, v: u32) error{OutOfMemory}!void {
        const t = [4]u8{
            @intCast(v >> 24 & 0xff),
            @intCast(v >> 16 & 0xff),
            @intCast(v >> 8 & 0xff),
            @intCast(v & 0xff),
        };
        return b.put(&t);
    }

    pub fn lpstr(b: *Buf, s: []const u8) error{OutOfMemory}!void {
        try b.u32be(@intCast(s.len));
        return b.put(s);
    }

    /// buf_dhall_str: Dhall Text literal with \" and \\ escapes.
    pub fn dhallStr(b: *Buf, s: []const u8) error{OutOfMemory}!void {
        try b.ch('"');
        for (s) |c| {
            if (c == '"' or c == '\\') try b.ch('\\');
            try b.ch(c);
        }
        return b.ch('"');
    }

    pub fn slice(b: *const Buf) []const u8 {
        return b.d[0..b.len];
    }
};

// ─── helpers ──────────────────────────────────────────────────────────────

/// basename of a path (final component).
pub fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

/// reconstruct the full on= readiness string from kind + arg, so fx-init can
/// re-parse the on= condition (the argument is otherwise lost between
/// activation and boot).
pub fn onFull(k: FxOnKind, arg: ?[]const u8, buf: anytype) [:0]const u8 {
    const a: []const u8 = arg orelse "";
    return switch (k) {
        .all => snfmtz(buf, "all", .{}),
        .up => snfmtz(buf, "up:{s}", .{a}),
        .sock_tcp => snfmtz(buf, "sock:tcp:{s}", .{a}),
        .sock_unix => snfmtz(buf, "sock:unix:{s}", .{a}),
        .time => snfmtz(buf, "time:{s}", .{a}),
        .net => snfmtz(buf, "net", .{}),
    };
}

// ─── etc content renderers ────────────────────────────────────────────────

pub fn renderPasswd(b: *Buf, cfgr: *const FxConfig) error{OutOfMemory}!void {
    for (cfgr.users) |*u| {
        var line: [256]u8 = undefined;
        try b.str(snfmt(&line, "{s}:x:{d}:{d}::/home/{s}:/bin/sh\n", .{ u.name, u.uid, u.uid, u.name }));
    }
}

/// group file: primary group per user + each supplementary group claimed by a
/// user, gid = the first claiming user's uid.
pub fn renderGroup(b: *Buf, cfgr: *const FxConfig) error{OutOfMemory}!void {
    for (cfgr.users) |*u| {
        var line: [256]u8 = undefined;
        try b.str(snfmt(&line, "{s}:x:{d}:\n", .{ u.name, u.uid }));
    }
    for (cfgr.users) |*u| {
        for (u.groups) |gn| {
            var is_user_primary = false;
            for (cfgr.users) |*k| {
                if (std.mem.eql(u8, k.name, gn)) {
                    is_user_primary = true;
                    break;
                }
            }
            if (is_user_primary) continue;
            var line: [256]u8 = undefined;
            try b.str(snfmt(&line, "{s}:x:{d}:\n", .{ gn, u.uid }));
        }
    }
}

// ─── PathEntry (local reimplementation of fxstore/main.c compute_paths) ───

pub const PathEntry = struct {
    p: *Package,
    path: [:0]u8, // store path of p
    hash: []const u8, // derivation sha256 (hex64)
    src_hash: ?[]const u8, // clean source hash (SRC_PATH), else null
};

/// path_of: store path of a closure package by name (or null).
fn pathOf(es: []const PathEntry, name: []const u8) ?[]const u8 {
    for (es) |*it| {
        if (std.mem.eql(u8, it.p.name, name)) return it.path;
    }
    return null;
}

/// entry_of: the PathEntry of a closure package by name (or null).  Used to
/// derive the store-RELATIVE form `<hash>-<name>` of a package's store path:
/// the generation facts and the genhash serialization record relative paths
/// so the generation is relocatable (fx-init resolves them against its
/// --store at boot, when the store may live under a different root than at
/// activation).
fn entryOf(es: []const PathEntry, name: []const u8) ?*const PathEntry {
    for (es) |*it| {
        if (std.mem.eql(u8, it.p.name, name)) return it;
    }
    return null;
}

/// store_path_of: find the store path of a closure package by name.
fn storePathOf(es: []const PathEntry, name: []const u8) ?[]const u8 {
    for (es) |*it| {
        if (std.mem.eql(u8, it.p.name, name)) return it.path;
    }
    return null;
}

// the process-lifetime Io for the store core's filesystem ops
// (fx_content_hash_dir / fx_store_*); main() sets it from init.io.
var g_io: std.Io = undefined;

// src-free fallback visibility: how many closure packages were resolved
// from published srcstore facts this run (0 = the sources were all present
// and the behavior is byte-identical to before).
var src_free_resolved: usize = 0;
var src_free_failed: usize = 0;

/// Copy a port module's ErrBuf message into `cerr` and fail as the C callees
/// did (the C fx_* fns wrote into the caller's `char err[PATH_MAX]`).
fn cerrCopy(eb: anytype, cerr: *[PATH_MAX]u8) ComputeError {
    const m = eb.slice();
    const n = @min(m.len, cerr.len - 1);
    @memcpy(cerr[0..n], m[0..n]);
    cerr[n] = 0;
    return error.CFailed;
}

pub const ComputeError = error{ CFailed, FxErr, OutOfMemory };

// ─── src-free resolution (in-guest activation) ────────────────────────────
//
// In the guest the package source trees are ABSENT (only the store ships),
// so the per-package source hash cannot be computed by walking them.  The
// store's own committed metadata carries the mapping instead:
//
//   srcstore(src_hash, name)  — clean-source artifact index (store.zig;
//                               col0=src_hash, col1=name — commit_srcstore_fact)
//   store(hash, name)         — the built-package index (same column order)
//   activate_root(root)       — the store root the committed hashes were
//                               computed under (committed by fx-activate)
//
// A dep-carrying package's derivation hash embeds each dep's FULL store path
// (fx_derivation_hash_ex serializes dep_paths verbatim), so recomputing under
// a DIFFERENT store root yields a different hash.  The fallback therefore
// recomputes dep paths under the RECORDED activation root — a string
// re-prefix, no filesystem access — and adopts a candidate only when the
// recomputed derivation hash's store dir EXISTS under the live root AND
// store(h,name) is committed.  Adoption is then exactly "the exact bytes the
// sources would have built are already in THIS store, self-attested by its
// own metadata": a different closure would need a different h and its dir
// present, at which point it is not different.

/// Every srcstore row as (src_hash_sym, name_sym) pairs (the relation is
/// package-count small; a full walk + filter beats a leading-prefix bind,
/// which would bind col0=HASH, not the name).
const SrcRows = struct {
    rows: std.ArrayList([2]u32) = .empty,
    oom: bool = false,
};

fn srcRowsCb(cols: [*]const u32, arity: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = arity; // srcstore is arity 2; cols[0..2] are the pair
    const bag: *SrcRows = @ptrCast(@alignCast(user.?));
    bag.rows.append(gpa_alloc, .{ cols[0], cols[1] }) catch {
        bag.oom = true;
        return 1;
    };
    return 0;
}

/// The store root recorded by the activation that committed the hashes
/// (activate_root(root)); null when the relation is empty/undeclared.
fn recordedRoot(db: *DlDb, buf: []u8) ?[]const u8 {
    const RootBag = struct {
        db: *DlDb,
        buf: []u8,
        len: usize = 0,
        got: bool = false,
        oom: bool = false,
    };
    const cb = struct {
        fn f(cols: [*]const u32, arity: u8, user: ?*anyopaque) callconv(.c) c_int {
            _ = arity;
            const rb: *RootBag = @ptrCast(@alignCast(user.?));
            if (rb.got) return 0; // one root per store: first row wins
            const s = fx.dl_intern_str_of(rb.db, cols[0]) orelse {
                rb.oom = true;
                return 1;
            };
            const sv = std.mem.span(s);
            if (sv.len >= rb.buf.len) {
                rb.oom = true;
                return 1;
            }
            @memcpy(rb.buf[0..sv.len], sv);
            rb.len = sv.len;
            rb.got = true;
            return 0;
        }
    }.f;
    var rb = RootBag{ .db = db, .buf = buf };
    _ = fx.dl_query(db, "activate_root", cb, &rb);
    if (rb.oom or !rb.got) return null;
    return rb.buf[0..rb.len];
}

/// Resolve a .path package's hashes WITHOUT its source tree: for every
/// srcstore(?, name) candidate src_hash, recompute the derivation hash over
/// dep paths re-prefixed under the RECORDED activation root, and adopt the
/// first candidate whose store dir exists AND whose store(h,name) fact is
/// committed.  Returns false with `why` set when no candidate resolves — a
/// config adding a genuinely new package must still fail loudly.
fn srcFreeResolve(
    p: *Package,
    db: *DlDb,
    dep_paths: []const []const u8, // dep store paths under the LIVE root
    store_root: []const u8, // the LIVE root (dir-existence tests)
    out_hash: *[65]u8, // adopted derivation hash (hex64)
    out_src: *[65]u8, // adopted src_hash (hex64)
    why: *ErrBuf,
) bool {
    var arena = std.heap.ArenaAllocator.init(gpa_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // dep paths under the RECORDED root: derivation identity requires the
    // root the committed hashes were computed under, not the live one.
    var root_buf: [PATH_MAX]u8 = undefined;
    const rec_root = recordedRoot(db, &root_buf) orelse {
        eSet(why, "package '{s}': source tree absent and the store records no activate_root (activate once with sources present and re-ship the store)", .{p.name});
        return false;
    };
    var rec_deps: [][]const u8 = &.{};
    if (dep_paths.len > 0) {
        const dp = a.alloc([]const u8, dep_paths.len) catch {
            eSet(why, "out of memory", .{});
            return false;
        };
        for (dep_paths, 0..) |dpath, j| {
            // dpath is "<live_root>/<hash>-<name>": keep the store-relative tail
            const rel = std.mem.lastIndexOfScalar(u8, dpath, '/') orelse (dpath.len - 1);
            dp[j] = std.fmt.allocPrint(a, "{s}/{s}", .{ rec_root, dpath[rel + 1 ..] }) catch {
                eSet(why, "out of memory", .{});
                return false;
            };
        }
        rec_deps = dp;
    }

    var nz: [256:0]u8 = undefined;
    if (p.name.len >= nz.len) {
        eSet(why, "package '{s}': name too long", .{p.name});
        return false;
    }
    @memcpy(nz[0..p.name.len], p.name);
    nz[p.name.len] = 0;
    const name_sym = fx.dl_intern_str(db, &nz);
    if (name_sym == 0) {
        eSet(why, "out of memory", .{});
        return false;
    }

    var bag = SrcRows{};
    defer bag.rows.deinit(gpa_alloc);
    const n = fx.dl_query(db, "srcstore", srcRowsCb, &bag);
    if (n < 0 or bag.oom) {
        eSet(why, "package '{s}': srcstore enumeration failed", .{p.name});
        return false;
    }

    var dir_buf: [PATH_MAX]u8 = undefined;
    var hz: [65:0]u8 = undefined;
    for (bag.rows.items) |row| {
        if (row[1] != name_sym) continue;
        const hs = fx.dl_intern_str_of(db, row[0]) orelse continue;
        const h = std.mem.span(hs);
        if (h.len != 64) continue; // not a hex64 src hash: skip, not fail
        var cand_src: [65]u8 = undefined;
        @memcpy(cand_src[0..64], h[0..64]);

        var h2: [65]u8 = undefined;
        var de = fx.derivation.ErrBuf{};
        fx.fx_derivation_hash_ex(p, cand_src[0..64], rec_deps, &h2, &de) catch continue;
        // adopt only if the derivation hash's dir is in THIS store and its
        // store(h,name) fact is committed (self-attestation, not trust)
        const sp = fx.fx_store_path_of(store_root, h2[0..64], p.name, &dir_buf);
        if (!isDir(std.Io.Dir.cwd(), g_io, sp)) continue;
        @memcpy(hz[0..64], h2[0..64]);
        hz[64] = 0;
        const hsym = fx.dl_intern_str(db, &hz);
        if (hsym == 0) {
            eSet(why, "out of memory", .{});
            return false;
        }
        const pair = [2]u32{ hsym, name_sym };
        if (fx.dl_lookup(db, "store", &pair, 2) == 0) continue;
        @memcpy(out_hash[0..64], h2[0..64]);
        out_hash[64] = 0;
        @memcpy(out_src[0..64], cand_src[0..64]);
        out_src[64] = 0;
        return true;
    }
    eSet(why, "package '{s}': source tree absent and no published srcstore/store pair resolves it (build it on a host: fxstore build / fx-activate with sources present) and re-ship the store", .{p.name});
    return false;
}

/// compute_paths — fx_closure_compute -> fx_closure_names -> fx_topo_order,
/// then per package (topo, deps-first): content-hash the SRC_PATH tree, hash
/// the derivation over the (already-computed) dep store paths, format the
/// store path.  Store-core failures report through `cerr` (error.CFailed);
/// the port's own fx_err-style messages go through `e` (error.FxErr).
pub fn computePaths(
    ps: *const PackageSet,
    db: *DlDb,
    roots: []const []const u8,
    store_root: []const u8,
    cerr: *[PATH_MAX]u8,
    e: *ErrBuf,
) ComputeError![]PathEntry {
    var ce = fx.closure.ErrBuf{};
    fx.fx_closure_compute(db, ps, roots, &ce) catch return cerrCopy(&ce, cerr);
    const names = fx.fx_closure_names(db, &ce) catch return cerrCopy(&ce, cerr);
    defer fx.free_names(names);
    const ord = fx.fx_topo_order(ps, names, &ce) catch return cerrCopy(&ce, cerr);
    defer fx.free_order(ord);
    const n_no = ord.len;

    const es = gpa_alloc.alloc(PathEntry, @max(n_no, 1)) catch {
        eSet(e, "out of memory", .{});
        return error.FxErr;
    };
    const entries = es[0..n_no];
    var de = fx.derivation.ErrBuf{};
    for (0..n_no) |i| {
        const p: *Package = ord[i];
        var dep_paths: ?[][]const u8 = null;
        if (p.deps.len > 0) {
            const dp = gpa_alloc.alloc([]const u8, p.deps.len) catch {
                eSet(e, "out of memory", .{});
                return error.FxErr;
            };
            dep_paths = dp[0..];
        }
        var ok = true;
        if (dep_paths) |dp| {
            for (0..dp.len) |j| {
                const dep_name = p.deps[j];
                dp[j] = pathOf(entries[0..i], dep_name) orelse {
                    eSet(e, "internal: dep '{s}' of '{s}' unresolved", .{ dep_name, p.name });
                    ok = false;
                    break;
                };
            }
        }
        if (ok) {
            var h: [65]u8 = undefined;
            var src_hash: ?[]const u8 = null;
            if (p.src.kind == .path) {
                if (isDir(std.Io.Dir.cwd(), g_io, p.src.path.?)) {
                    var sh: [65]u8 = undefined;
                    fx.fx_content_hash_dir(g_io, p.src.path.?, p.excludes, &sh, &de) catch return cerrCopy(&de, cerr);
                    const own = gpa_alloc.dupe(u8, sh[0..64]) catch {
                        eSet(e, "out of memory", .{});
                        return error.FxErr;
                    };
                    entries[i].src_hash = own;
                    src_hash = own;
                } else {
                    // src-free fallback (in-guest activation): resolve from
                    // the store's own committed srcstore/store/activate_root
                    // metadata; LOUD failure when nothing resolves.
                    var fh: [65]u8 = undefined;
                    var fs: [65]u8 = undefined;
                    if (!srcFreeResolve(p, db, dep_paths orelse &.{}, store_root, &fh, &fs, e)) {
                        src_free_failed += 1;
                        return error.FxErr;
                    }
                    const own_h = gpa_alloc.dupe(u8, fh[0..64]) catch {
                        eSet(e, "out of memory", .{});
                        return error.FxErr;
                    };
                    const own_s = gpa_alloc.dupe(u8, fs[0..64]) catch {
                        eSet(e, "out of memory", .{});
                        return error.FxErr;
                    };
                    entries[i].hash = own_h;
                    entries[i].src_hash = own_s;
                    var path: [PATH_MAX]u8 = undefined;
                    const path_s = fx.fx_store_path_of(store_root, own_h, p.name, &path);
                    entries[i].p = p;
                    entries[i].path = gpa_alloc.dupeZ(u8, path_s) catch {
                        eSet(e, "out of memory", .{});
                        return error.FxErr;
                    };
                    src_free_resolved += 1;
                    continue;
                }
            }
            fx.fx_derivation_hash_ex(p, src_hash, dep_paths orelse &.{}, &h, &de) catch return cerrCopy(&de, cerr);
            var path: [PATH_MAX]u8 = undefined;
            const path_s = fx.fx_store_path_of(store_root, h[0..64], p.name, &path);
            entries[i].p = p;
            entries[i].hash = gpa_alloc.dupe(u8, h[0..64]) catch {
                eSet(e, "out of memory", .{});
                return error.FxErr;
            };
            entries[i].path = gpa_alloc.dupeZ(u8, path_s) catch {
                eSet(e, "out of memory", .{});
                return error.FxErr;
            };
        } else return error.FxErr;
    }
    return entries;
}

// ─── Dhakefile.dhall renderer (artifact-1 template, byte shape) ───────────

const action_header =
    "let Action =\n" ++
    "      < Shell : Text\n" ++
    "      | Copy : { from : Text, to : Text }\n" ++
    "      | Mkdir : < Plain : Text | Parents : { path : Text, parents : Bool } >\n" ++
    "      | Rm : < Plain : Text | Recursive : { path : Text, recursive : Bool } >\n" ++
    "      | Touch : Text\n" ++
    "      | Move : { from : Text, to : Text }\n" ++
    "      | Symlink : { from : Text, to : Text }\n" ++
    "      | Chmod : { path : Text, mode : Text }\n" ++
    "      | Echo : Text\n" ++
    "      | Env : { key : Text, value : Text }\n" ++
    "      | Run : { argv : List Text }\n" ++
    "      >\n\n" ++
    "let Target = { deps : List Text, phony : Bool, recipe : List Action }\n\n";

/// (path, content) pair for an /etc file.
pub const EtcItem = struct {
    path: []const u8,
    content: []const u8,
};

/// (name, from, pkg) pair for a /bin symlink: `from` is the store path of
/// the BINARY the link points at (`<store>/<hash>-<pkg>/<target>` — a
/// symlink to the package DIR is un-exec-able, which is how the first
/// in-guest `activate` failed: /bin/fx-activate -> dir => EACCES => 127).
/// `pkg` is the closure package the link points into — the install fact
/// derives the STORE-RELATIVE origin `<hash>-<pkg>` from it (emitBuildfile
/// itself ignores it).
pub const BinLink = struct {
    name: []const u8,
    from: []const u8, // symlink target: the BINARY path, not the store dir
    pkg: []const u8 = "",
};

fn etcItemLt(_: void, x: EtcItem, y: EtcItem) bool {
    // C qsort(etcitem_cmp); the corpus never has equal paths (config
    // validation allows them, glibc's tie order is unspecified — insertion
    // sort is the deterministic stand-in).
    return std.mem.order(u8, x.path, y.path) == .lt;
}

fn binLinkLt(_: void, x: BinLink, y: BinLink) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}

pub fn emitBuildfile(
    b: *Buf,
    gen_dir: []const u8,
    etc: []const EtcItem,
    bin: []const BinLink,
) error{OutOfMemory}!void {
    try b.str(action_header);
    try b.str("let GEN = ");
    try b.dhallStr(gen_dir);
    try b.str("\n\nin  { default = \"rootfs\"\n    , targets =\n        [ { mapKey = \"dirs\"\n          , mapValue =\n              { deps = [] : List Text\n              , phony = True\n              , recipe =\n                  [ < Mkdir = < Parents = { path = \"/etc\", parents = True } > >\n" ++
        "                  , < Mkdir = < Parents = { path = \"/bin\", parents = True } > >\n" ++
        "                  , < Mkdir = < Parents = { path = \"/run\", parents = True } > >\n" ++
        "                  , < Mkdir = < Parents = { path = \"/run/fx\", parents = True } > >\n" ++
        "                  ]\n              }\n          }\n");

    // etc target
    try b.str("        , { mapKey = \"etc\"\n          , mapValue =\n              { deps = [ \"dirs\" ]\n              , phony = True\n              , recipe =\n                  [ ");
    if (etc.len == 0) {
        try b.str("] : List Action\n");
    } else {
        for (etc) |it| {
            var from: [PATH_MAX]u8 = undefined;
            var to: [PATH_MAX]u8 = undefined;
            const from_s = snfmt(&from, "{s}/etc/{s}", .{ gen_dir, it.path });
            const to_s = snfmt(&to, "/etc/{s}", .{it.path});
            try b.str("< Copy = { from = ");
            try b.dhallStr(from_s);
            try b.str(", to = ");
            try b.dhallStr(to_s);
            try b.str(" } >\n                  , < Chmod = { path = ");
            try b.dhallStr(to_s);
            try b.str(", mode = \"0644\" } >\n                  , ");
        }
        // trim the trailing ", " — rewrite last separator (fx-activate.c:320)
        if (b.len >= 2) b.len -= 2;
        try b.str(" ]\n");
    }
    try b.str("              }\n          }\n");

    // bin target
    try b.str("        , { mapKey = \"bin\"\n          , mapValue =\n              { deps = [ \"dirs\" ]\n              , phony = True\n              , recipe =\n                  [ ");
    if (bin.len == 0) {
        try b.str("] : List Action\n");
    } else {
        for (bin) |it| {
            var to: [PATH_MAX]u8 = undefined;
            const to_s = snfmt(&to, "/bin/{s}", .{it.name});
            try b.str("< Rm = < Plain = ");
            try b.dhallStr(to_s);
            try b.str(" > >\n                  , < Symlink = { from = ");
            try b.dhallStr(it.from);
            try b.str(", to = ");
            try b.dhallStr(to_s);
            try b.str(" } >\n                  , ");
        }
        if (b.len >= 2) b.len -= 2; // fx-activate.c:341
        try b.str(" ]\n");
    }
    try b.str("              }\n          }\n");

    // rootfs target
    try b.str("        , { mapKey = \"rootfs\"\n          , mapValue =\n              { deps = [ \"etc\", \"bin\" ]\n              , phony = True\n              , recipe = [] : List Action\n              }\n          }\n        ]\n      }\n");
}

// ─── canonical generation serialization -> sha256 ─────────────────────────
//   magic "fxgen-v1\n"
//   | hostname
//   | u32be netc, then per file (sorted by path): lpstr path, lpstr content
//   | u32be nsvc,  then per service (sorted by name):
//        lpstr name | u32be nargv | per-arg lpstr
//        lpstr pkg (or "" if none) | lpstr on | lpstr restart
//        lpstr probe_kind | lpstr probe_arg (or "")
//   | u32be npaths, then closure store paths sorted (each lpstr)

pub fn serializeGeneration(
    b: *Buf,
    cfgr: *const FxConfig,
    etc: []const EtcItem,
    es: []const PathEntry,
) error{OutOfMemory}!void {
    try b.str("fxgen-v1\n");
    try b.lpstr(cfgr.hostname);
    try b.u32be(@intCast(etc.len));
    for (etc) |it| {
        try b.lpstr(it.path);
        try b.lpstr(it.content);
    }
    try b.u32be(@intCast(cfgr.services.len));

    // services sorted by name (the C's own insertion sort, stable)
    const sv = gpa_alloc.alloc(*const FxService, cfgr.services.len) catch return error.OutOfMemory;
    for (0..cfgr.services.len) |i| sv[i] = &cfgr.services[i];
    var si: usize = 1;
    while (si < cfgr.services.len) : (si += 1) {
        const t = sv[si];
        var j = si;
        while (j > 0 and std.mem.order(u8, sv[j - 1].name, t.name) == .gt) : (j -= 1) sv[j] = sv[j - 1];
        sv[j] = t;
    }
    for (sv) |s| {
        try b.lpstr(s.name);
        try b.u32be(@intCast(s.argv.len));
        for (s.argv) |arg| try b.lpstr(arg);
        try b.lpstr(s.pkg orelse "");
        const on: []const u8 = switch (s.on_kind) {
            .all => "all",
            .up => "up",
            .sock_tcp => "sock:tcp",
            .sock_unix => "sock:unix",
            .time => "time",
            .net => "net",
        };
        try b.lpstr(on);
        try b.lpstr(s.on_arg orelse "");
        const rs: []const u8 = switch (s.restart) {
            .always => "always",
            .on_failure => "on-failure",
            .never => "never",
        };
        try b.lpstr(rs);
        try b.u32be(s.backoff_ms);
        const pk: []const u8 = switch (s.probe_kind) {
            .none => "",
            .tcp => "tcp",
            .unix => "unix",
            .file => "file",
        };
        try b.lpstr(pk);
        try b.lpstr(s.probe_arg orelse "");
    }

    // closure store paths sorted.  RECORDED STORE-RELATIVE (`<hash>-<name>`,
    // NOT `<store_root>/<hash>-<name>`): the genhash must be independent of
    // the store root so a generation activated against one store root boots
    // identically after the store is relocated to another root.  Re-activate
    // idempotency holds because the relative form is the same for the same
    // closure regardless of store root.
    const paths = gpa_alloc.alloc([]const u8, es.len) catch return error.OutOfMemory;
    for (es, 0..) |*it, i| {
        // store-relative form `<hash>-<name>` (see comment above)
        paths[i] = std.fmt.allocPrint(gpa_alloc, "{s}-{s}", .{ it.hash, it.p.name }) catch return error.OutOfMemory;
    }
    var pi: usize = 1;
    while (pi < es.len) : (pi += 1) {
        const t = paths[pi];
        var j = pi;
        while (j > 0 and std.mem.order(u8, paths[j - 1], t) == .gt) : (j -= 1) paths[j] = paths[j - 1];
        paths[j] = t;
    }
    try b.u32be(@intCast(es.len));
    for (paths) |p| try b.lpstr(p);
}

// ─── write a file with mkdir -p of its parent ─────────────────────────────

pub fn writeFileP(path: []const u8, content: []const u8, e: *ErrBuf) error{WriteFailed}!void {
    var dir: [PATH_MAX]u8 = undefined;
    if (path.len >= dir.len) {
        eSet(e, "path too long: {s}", .{path});
        return error.WriteFailed;
    }
    @memcpy(dir[0..path.len], path);
    dir[path.len] = 0; // the C's memcpy(dir, path, pl+1) carries the NUL
    const path_z: [*:0]const u8 = @ptrCast(&dir);
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        dir[slash] = 0;
        // mkdir -p
        var q: usize = 1;
        while (q < slash) : (q += 1) {
            if (dir[q] == '/') {
                dir[q] = 0;
                const pfx: [*:0]const u8 = @ptrCast(&dir);
                if (std.c.mkdir(pfx, 0o755) != 0 and std.c._errno().* != EEXIST) {
                    const msg = errStr();
                    dir[q] = '/';
                    dir[slash] = '/';
                    eSet(e, "mkdir {s}: {s}", .{ std.mem.span(pfx), msg });
                    return error.WriteFailed;
                }
                dir[q] = '/';
            }
        }
        if (std.c.mkdir(path_z, 0o755) != 0 and std.c._errno().* != EEXIST) {
            const msg = errStr();
            dir[slash] = '/';
            eSet(e, "mkdir {s}: {s}", .{ std.mem.span(path_z), msg });
            return error.WriteFailed;
        }
        dir[slash] = '/'; // restore: fopen below must see the full path
    }
    const f = std.c.fopen(path_z, "wb") orelse {
        eSet(e, "open {s}: {s}", .{ path, errStr() });
        return error.WriteFailed;
    };
    if (std.c.fwrite(content.ptr, 1, content.len, f) != content.len) {
        _ = std.c.fclose(f);
        eSet(e, "write {s}: {s}", .{ path, errStr() });
        return error.WriteFailed;
    }
    if (std.c.fclose(f) != 0) {
        eSet(e, "close {s}: {s}", .{ path, errStr() });
        return error.WriteFailed;
    }
}

// ─── fact writer (declare + txn_add_fact) ─────────────────────────────────

fn declare(db: *DlDb, rel: [*:0]const u8, arity: u8, e: *ErrBuf) error{DeclareFailed}!void {
    // dl_declare_relation is idempotent: re-declaring with the same arity is
    // a no-op returning 0; an arity mismatch or arity>8 returns -1.
    if (fx.dl_declare_relation(db, rel, arity) != 0) {
        eSet(e, "declare {s}/{d} failed", .{ std.mem.span(rel), arity });
        return error.DeclareFailed;
    }
}

fn addFact(db: *DlDb, rel: [*:0]const u8, cols: []const u32) void {
    // we intern strings outside and pass sym ids; ints as raw u32
    _ = fx.dl_txn_add_fact(db, rel, cols.ptr, @intCast(cols.len));
}

/// delete-all existing tuples of `rel` (collect then delete — safe vs the
/// live DAFSA cursor).  Must be called inside an open txn.  Used to make each
/// activation's snapshot self-consistent (only THIS activation's generation/
/// svc facts) instead of accumulating stale services across activations.
fn clearRel(db: *DlDb, rel: [*:0]const u8, arity: u8) error{ ClearFailed, OutOfMemory }!void {
    const it = fx.dl_iter_open(db, rel, null, 0) orelse return;
    if (fx.dl_iter_arity(it) != arity) {
        fx.dl_iter_close(it);
        return error.ClearFailed;
    }
    var all: std.ArrayList(u32) = .empty;
    defer all.deinit(gpa_alloc);
    var row: [8]u32 = undefined;
    while (fx.dl_iter_next(it, &row) == 1) {
        all.appendSlice(gpa_alloc, row[0..arity]) catch {
            fx.dl_iter_close(it);
            return error.OutOfMemory;
        };
    }
    fx.dl_iter_close(it);
    for (0..all.items.len / arity) |i| {
        _ = fx.dl_txn_delete_fact(db, rel, all.items[i * arity ..][0..arity].ptr, arity);
    }
}

/// Commit the closure metadata the SRC-FREE fallback resolves from (called
/// inside main's open txn, just before dl_txn_commit):
///   store(hash, name)        for every closure entry
///   srcstore(src_hash, name) for every .path closure entry
///   activate_root(root)      ONLY-IF-ABSENT — the root the committed
///                            derivation hashes embed (dep store paths are
///                            root-qualified); the fallback recomputes dep
///                            paths under exactly this root, and a later
///                            activation under a different root must not
///                            rewrite history the fallback depends on.
/// Duplicates are DAFSA no-ops, so re-activation is idempotent.
fn commitClosureMeta(db: *DlDb, entries: []PathEntry, store_root: []const u8) void {
    // store/srcstore are declared by fx_store_open; activate_root is ours
    // (dl_txn_add_fact REJECTS unknown relations, and addFact does not
    // surface that — declare idempotently so the fact always lands).
    var e_meta: ErrBuf = .{};
    _ = declare(db, "activate_root", 1, &e_meta) catch {};
    for (entries) |*it| {
        const store_cols = [2]u32{ fx.dl_intern_str(db, dupeZ(it.hash)), fx.dl_intern_str(db, dupeZ(it.p.name)) };
        addFact(db, "store", &store_cols);
        if (it.src_hash) |sh| {
            const src_cols = [2]u32{ fx.dl_intern_str(db, dupeZ(sh)), fx.dl_intern_str(db, dupeZ(it.p.name)) };
            addFact(db, "srcstore", &src_cols);
        }
    }
    const root_sym = fx.dl_intern_str(db, dupeZ(store_root));
    if (root_sym != 0 and fx.dl_lookup(db, "activate_root", &[1]u32{root_sym}, 1) == 0) {
        const cols = [1]u32{root_sym};
        addFact(db, "activate_root", &cols);
    }
}

// ─── CLI ──────────────────────────────────────────────────────────────────

const usage_text =
    "fx-activate — fixpoint-linux M4 activation (build-time)\n" ++
    "usage:\n" ++
    "  fx-activate [--store DIR] [--config PATH] [--package-set PATH]\n" ++
    "    evaluates config.dhall, computes the closure, emits a per-generation\n" ++
    "    dhake buildfile, writes generation facts, publishes a store snapshot.\n" ++
    "  --store DIR        store root (default /fx/store)\n" ++
    "  --config PATH      config.dhall path (default config.dhall from cwd)\n" ++
    "  --package-set PATH package-set.dhall path (default package-set.dhall from cwd)\n" ++
    "  -h, --help         show this help\n";

fn usage(w: *std.Io.Writer) void {
    w.print("{s}", .{usage_text}) catch {};
}

fn isDir(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    const st = dir.statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;
    g_io = io;

    var stdout_buf: [16384]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout_w.interface;

    var stderr_buf: [16384]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writerStreaming(io, &stderr_buf);
    const errw = &stderr_w.interface;

    var store_root: ?[:0]const u8 = null;
    var config_path: ?[:0]const u8 = null;
    var pkgset_path: ?[:0]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: [:0]const u8 = args[i];
        if (std.mem.eql(u8, a, "--store")) {
            i += 1;
            if (i >= args.len) {
                errw.print("fx-activate: --store requires a dir\n", .{}) catch {};
                errw.flush() catch {};
                std.process.exit(2);
            }
            store_root = args[i];
        } else if (std.mem.startsWith(u8, a, "--store=")) {
            store_root = a[8..];
        } else if (std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= args.len) {
                errw.print("fx-activate: --config requires a path\n", .{}) catch {};
                errw.flush() catch {};
                std.process.exit(2);
            }
            config_path = args[i];
        } else if (std.mem.startsWith(u8, a, "--config=")) {
            config_path = a[9..];
        } else if (std.mem.eql(u8, a, "--package-set")) {
            i += 1;
            if (i >= args.len) {
                errw.print("fx-activate: --package-set requires a path\n", .{}) catch {};
                errw.flush() catch {};
                std.process.exit(2);
            }
            pkgset_path = args[i];
        } else if (std.mem.startsWith(u8, a, "--package-set=")) {
            pkgset_path = a[14..];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage(out);
            out.flush() catch {};
            return;
        } else {
            errw.print("fx-activate: unknown arg '{s}'\n\n", .{a}) catch {};
            usage(errw);
            errw.flush() catch {};
            std.process.exit(2);
        }
    }
    const store_root_s: [:0]const u8 = store_root orelse "/fx/store";
    const config_path_s: []const u8 = config_path orelse "config.dhall";
    const pkgset_path_s: [:0]const u8 = pkgset_path orelse "package-set.dhall";

    var e: ErrBuf = .{};
    var cerr: [PATH_MAX]u8 = undefined;
    const cerr_z: [*:0]const u8 = @ptrCast(&cerr);

    var ps: PackageSet = undefined;
    var pe = fx.packageset.ErrBuf{};
    fx.fx_packageset_load(&ps, pkgset_path_s, &pe) catch {
        std.debug.print("fx-activate: {s}\n", .{pe.slice()});
        std.process.exit(1);
    };

    var cfg: FxConfig = undefined;
    cfg_mod.fx_config_load(&cfg, config_path_s, &e) catch {
        std.debug.print("fx-activate: {s}\n", .{e.slice()});
        std.process.exit(1);
    };

    var se = fx.store.ErrBuf{};
    const s = fx.fx_store_open(g_io, store_root_s, &se) catch {
        std.debug.print("fx-activate: {s}\n", .{se.slice()});
        std.process.exit(1);
    };
    const db = fx.fx_store_db(s).?;

    // closure roots = config.packages
    const entries = computePaths(&ps, db, cfg.packages, store_root_s, &cerr, &e) catch |err| switch (err) {
        error.CFailed => {
            std.debug.print("fx-activate: {s}\n", .{std.mem.span(cerr_z)});
            std.process.exit(1);
        },
        else => {
            std.debug.print("fx-activate: {s}\n", .{e.slice()});
            std.process.exit(1);
        },
    };

    // verify every closure package is built (store fact + dir), require the
    // tool packages present in the closure
    var missing: usize = 0;
    var miss: Buf = undefined;
    miss.init();
    for (entries) |*it| {
        if (!isDir(std.Io.Dir.cwd(), io, it.path)) {
            miss.str("  ") catch {};
            miss.str(it.p.name) catch {};
            miss.ch('\n') catch {};
            missing += 1;
        }
    }
    if (missing > 0) {
        std.debug.print("fx-activate: {d} closure package(s) not built (run 'fxstore build'):\n{s}", .{ missing, miss.slice() });
        std.process.exit(1);
    }

    const need_tools = [_][]const u8{ "dhake", "fx-init", "fxctl", "fx-activate" };
    for (need_tools) |tool| {
        if (storePathOf(entries, tool) == null) {
            std.debug.print("fx-activate: required package '{s}' not in the closure (add it to config.packages)\n", .{tool});
            std.process.exit(1);
        }
    }
    const dhake_path = storePathOf(entries, "dhake").?;
    // store-RELATIVE dhake path for the generation fact: `<hash>-dhake/dhake.com`.
    // fx-init resolves it against its --store at boot.  (entryOf is non-null:
    // need_tools already required "dhake" in the closure.)
    const dhake_e = entryOf(entries, "dhake").?;
    var dhake_rel_buf: [PATH_MAX]u8 = undefined;
    const dhake_rel = snfmtz(&dhake_rel_buf, "{s}-dhake/dhake.com", .{dhake_e.hash});

    // collect /etc items: hostname, passwd, group, then extraEtc (sorted)
    const netc = 3 + cfg.extra_etc.len;
    const etc = gpa_alloc.alloc(EtcItem, netc) catch @panic("out of memory");
    var ni: usize = 0;
    etc[ni] = .{ .path = "hostname", .content = cfg.hostname };
    ni += 1;
    var passwd: Buf = undefined;
    passwd.init();
    renderPasswd(&passwd, &cfg) catch {};
    etc[ni] = .{ .path = "passwd", .content = passwd.slice() };
    ni += 1;
    var group: Buf = undefined;
    group.init();
    renderGroup(&group, &cfg) catch {};
    etc[ni] = .{ .path = "group", .content = group.slice() };
    ni += 1;
    for (cfg.extra_etc) |it| {
        etc[ni] = .{ .path = it.path, .content = it.content };
        ni += 1;
    }
    std.sort.insertion(EtcItem, etc, {}, etcItemLt);

    // collect /bin symlinks: init, fxctl, dhake, fx-activate, + one per service pkg.
    // `from` is the BINARY path inside the store dir (<dir>/<target>): the
    // guest execs these links (the activate handler runs /bin/fx-activate),
    // and a symlink to the package DIR is un-exec-able (EACCES).
    var nbin: usize = 4;
    for (cfg.services) |*sv| {
        if (sv.pkg != null) nbin += 1;
    }
    const bin = gpa_alloc.alloc(BinLink, nbin) catch @panic("out of memory");
    var fb: [PATH_MAX]u8 = undefined;
    var bi: usize = 0;
    // snfmtz writes into a SHARED scratch buffer — dupe each from or every
    // entry would alias the last write.
    const initp = storePathOf(entries, "fx-init").?;
    bin[bi] = .{ .name = "init", .from = gpa_alloc.dupeZ(u8, snfmtz(&fb, "{s}/fx-init", .{initp})) catch @panic("out of memory"), .pkg = "fx-init" };
    bi += 1;
    bin[bi] = .{ .name = "fxctl", .from = gpa_alloc.dupeZ(u8, snfmtz(&fb, "{s}/fxctl", .{storePathOf(entries, "fxctl").?})) catch @panic("out of memory"), .pkg = "fxctl" };
    bi += 1;
    bin[bi] = .{ .name = "dhake", .from = gpa_alloc.dupeZ(u8, snfmtz(&fb, "{s}/dhake.com", .{dhake_path})) catch @panic("out of memory"), .pkg = "dhake" };
    bi += 1;
    bin[bi] = .{ .name = "fx-activate", .from = gpa_alloc.dupeZ(u8, snfmtz(&fb, "{s}/fx-activate", .{storePathOf(entries, "fx-activate").?})) catch @panic("out of memory"), .pkg = "fx-activate" };
    bi += 1;
    for (cfg.services) |*sv| {
        const pkg = sv.pkg orelse continue;
        const p = storePathOf(entries, pkg) orelse {
            std.debug.print("fx-activate: service '{s}' pkg '{s}' not in the closure\n", .{ sv.name, pkg });
            std.process.exit(1);
        };
        const pk = ps.find(pkg).?;
        const tb = baseName(pk.target);
        bin[bi] = .{ .name = tb, .from = gpa_alloc.dupeZ(u8, snfmtz(&fb, "{s}/{s}", .{ p, tb })) catch @panic("out of memory"), .pkg = pkg };
        bi += 1;
    }
    std.sort.insertion(BinLink, bin, {}, binLinkLt);

    // canonical serialization -> gen hash
    var ser: Buf = undefined;
    ser.init();
    serializeGeneration(&ser, &cfg, etc, entries) catch {
        std.debug.print("fx-activate: serialization failed\n", .{});
        std.process.exit(1);
    };
    var genhash: [65]u8 = undefined;
    fx.sha256_hex(ser.slice(), &genhash);
    const genhash_s: []const u8 = genhash[0..64];

    var gen_dir_buf: [PATH_MAX]u8 = undefined;
    const gen_dir = snfmtz(&gen_dir_buf, "{s}/{s}-system-generation", .{ store_root_s, genhash_s });

    // adopt if exists; otherwise write to <root>.build/<pid>-gen then rename
    const existing = isDir(std.Io.Dir.cwd(), io, gen_dir);
    if (!existing) {
        var scratch_buf: [PATH_MAX]u8 = undefined;
        const scratch = snfmtz(&scratch_buf, "{s}.build/{d}-gen", .{ store_root_s, getpid() });
        // mkdir -p the scratch etc dir
        var ed_buf: [PATH_MAX]u8 = undefined;
        const ed = snfmtz(&ed_buf, "{s}/etc", .{scratch});
        if (std.c.mkdir(scratch.ptr, 0o755) != 0 and std.c._errno().* != EEXIST) {
            std.debug.print("fx-activate: mkdir {s}: {s}\n", .{ scratch, errStr() });
            std.process.exit(1);
        }
        if (std.c.mkdir(ed.ptr, 0o755) != 0 and std.c._errno().* != EEXIST) {
            std.debug.print("fx-activate: mkdir {s}: {s}\n", .{ ed, errStr() });
            std.process.exit(1);
        }
        // write etc files
        for (etc) |it| {
            var p_buf: [PATH_MAX]u8 = undefined;
            const p = snfmtz(&p_buf, "{s}/etc/{s}", .{ scratch, it.path });
            writeFileP(p, it.content, &e) catch {
                std.debug.print("fx-activate: {s}\n", .{e.slice()});
                std.process.exit(1);
            };
        }
        // write Dhakefile.dhall
        var bf: Buf = undefined;
        bf.init();
        emitBuildfile(&bf, gen_dir, etc, bin) catch {
            std.debug.print("fx-activate: buildfile render failed\n", .{});
            std.process.exit(1);
        };
        var dhakefile_buf: [PATH_MAX]u8 = undefined;
        const dhakefile = snfmtz(&dhakefile_buf, "{s}/Dhakefile.dhall", .{scratch});
        writeFileP(dhakefile, bf.slice(), &e) catch {
            std.debug.print("fx-activate: {s}\n", .{e.slice()});
            std.process.exit(1);
        };
        if (std.c.rename(scratch.ptr, gen_dir.ptr) != 0) {
            // maybe a concurrent activation created it: adopt
            if (!isDir(std.Io.Dir.cwd(), io, gen_dir)) {
                std.debug.print("fx-activate: rename {s} -> {s}: {s}\n", .{ scratch, gen_dir, errStr() });
                std.process.exit(1);
            }
        }
    }

    // buildfile path.  buildfile_abs (host-absolute) is kept for the
    // human-facing print line; the generation FACT records the store-RELATIVE
    // form `<genhash>-system-generation/Dhakefile.dhall` so fx-init can
    // resolve it against its --store at boot (the store root may differ from
    // activation time, e.g. host temp dir -> chroot /fx/store).  The
    // buildfile TEXT itself still embeds the host store root
    // (let GEN = "<host_store>/...") — fx-init rewrites that root to its own
    // --store before exec'ing dhake (fx_reloc).
    var buildfile_abs_buf: [PATH_MAX]u8 = undefined;
    const buildfile_abs = snfmtz(&buildfile_abs_buf, "{s}/Dhakefile.dhall", .{gen_dir});
    var buildfile_rel_buf: [PATH_MAX]u8 = undefined;
    const buildfile_rel = snfmtz(&buildfile_rel_buf, "{s}-system-generation/Dhakefile.dhall", .{genhash_s});

    // declare + txn: generation facts
    const now: u32 = genEpoch();
    const Decl = struct { rel: [*:0]const u8, arity: u8 };
    const decls = [_]Decl{
        .{ .rel = "generation", .arity = 4 },
        .{ .rel = "svc", .arity = 3 },
        .{ .rel = "svc_argv", .arity = 3 },
        .{ .rel = "svc_env", .arity = 3 },
        .{ .rel = "svc_probe", .arity = 3 },
        .{ .rel = "svc_bin", .arity = 2 },
        .{ .rel = "svc_backoff", .arity = 2 },
        .{ .rel = "user", .arity = 3 },
        .{ .rel = "tool_fxstore", .arity = 1 },
        .{ .rel = "boot_grace", .arity = 1 },
        .{ .rel = "install", .arity = 4 },
        .{ .rel = "provides", .arity = 2 },
        .{ .rel = "activate_root", .arity = 1 },
    };
    for (decls) |d| declare(db, d.rel, d.arity, &e) catch {
        std.debug.print("fx-activate: {s}\n", .{e.slice()});
        std.process.exit(1);
    };

    if (fx.dl_txn_begin(db) != 0) {
        std.debug.print("fx-activate: dl_txn_begin failed\n", .{});
        std.process.exit(1);
    }

    // clear the previous activation's generation/svc/user facts so each
    // published snapshot is self-consistent (only THIS activation's set).
    // Without this, a re-activation would accumulate stale services and
    // fx-init would boot the union of all past service sets.
    // activate_root is EXEMPT: it records the root the COMMITTED store
    // hashes were computed under — immutable for the life of the store (a
    // later activation under a different root must not rewrite history the
    // src-free fallback depends on).
    for (decls) |d| {
        if (std.mem.eql(u8, std.mem.span(d.rel), "activate_root")) continue;
        clearRel(db, d.rel, d.arity) catch {
            std.debug.print("fx-activate: clear old facts failed\n", .{});
            _ = fx.dl_txn_rollback(db);
            std.process.exit(1);
        };
    }

    // generation(genhash, buildfile, dhake, epoch) a4.
    // buildfile + dhake columns are STORE-RELATIVE paths (resolved by fx-init
    // against its --store at boot) — see the buildfile_rel / dhake_rel notes.
    {
        const cols = [4]u32{
            fx.dl_intern_str(db, genhash[0..64 :0]),
            fx.dl_intern_str(db, buildfile_rel),
            fx.dl_intern_str(db, dhake_rel),
            now,
        };
        addFact(db, "generation", &cols);
    }
    // tool_fxstore(path) a1 — record the activator's conventional rootfs path
    // so fx-init can fork fx-activate for re-activations over the control
    // socket.  (Relation name kept for plan compatibility; the binary IS
    // fx-activate, the activation tool moved out of fxstore in the
    // standalone-repo structure.)  The /bin/fx-activate symlink is created by
    // dhake from the bin target.
    {
        const cols = [1]u32{fx.dl_intern_str(db, "/bin/fx-activate")};
        addFact(db, "tool_fxstore", &cols);
    }
    // boot_grace(ms) a1 — persist the config's bootGraceMs so fx-init honors
    // the per-activation grace timeout (config.dhall's bootGraceMs; default
    // 30000).  fx-init cannot read dhall, so the value must reach it via a
    // store fact.  Stored as a RAW u32 column (same convention as
    // svc_backoff.backoff_ms).
    {
        const cols = [1]u32{cfg.grace_ms};
        addFact(db, "boot_grace", &cols);
    }
    // svc facts
    for (cfg.services) |*sv| {
        const sn = fx.dl_intern_str(db, dupeZ(sv.name));
        var onf_buf: [256]u8 = undefined;
        const onf = onFull(sv.on_kind, sv.on_arg, &onf_buf);
        const rs: [*:0]const u8 = switch (sv.restart) {
            .always => "always",
            .on_failure => "on-failure",
            .never => "never",
        };
        const cols = [3]u32{ sn, fx.dl_intern_str(db, onf), fx.dl_intern_str(db, rs) };
        addFact(db, "svc", &cols);
        // svc_backoff(name, backoff_ms)
        const cbk = [2]u32{ sn, sv.backoff_ms };
        addFact(db, "svc_backoff", &cbk);
        // svc_argv(name, idx, arg)
        for (sv.argv, 0..) |arg, a| {
            const c = [3]u32{ sn, @intCast(a), fx.dl_intern_str(db, dupeZ(arg)) };
            addFact(db, "svc_argv", &c);
        }
        // resolve svc_bin: argv[0] -> store path / target-basename, or
        // absolute.  For a pkg'd service the recorded path is STORE-RELATIVE
        // (`<hash>-<pkg>/<target>`) so fx-init can resolve it against its
        // --store at boot (relocatable).  A non-pkg'd service's argv[0] is
        // recorded verbatim (typically an absolute path like /bin/sh, which
        // fx-init passes through unchanged).
        var resolved_buf: [PATH_MAX]u8 = undefined;
        const resolved = if (sv.pkg) |pkg| blk: {
            const pentry = entryOf(entries, pkg).?;
            const pk = ps.find(pkg).?;
            break :blk snfmtz(&resolved_buf, "{s}-{s}/{s}", .{ pentry.hash, pkg, baseName(pk.target) });
        } else snfmtz(&resolved_buf, "{s}", .{sv.argv[0]});
        const cb = [2]u32{ sn, fx.dl_intern_str(db, resolved) };
        addFact(db, "svc_bin", &cb);
        // svc_env(name, key, value)
        for (sv.env) |kv| {
            const ce = [3]u32{ sn, fx.dl_intern_str(db, dupeZ(kv.key)), fx.dl_intern_str(db, dupeZ(kv.value)) };
            addFact(db, "svc_env", &ce);
        }
        // svc_probe(name, kind, arg)
        if (sv.probe_kind != .none) {
            const pk: [*:0]const u8 = switch (sv.probe_kind) {
                .tcp => "tcp",
                .unix => "unix",
                .file => "file",
                .none => unreachable,
            };
            const cp = [3]u32{ sn, fx.dl_intern_str(db, pk), fx.dl_intern_str(db, dupeZ(sv.probe_arg orelse "")) };
            addFact(db, "svc_probe", &cp);
        }
    }
    // user facts: user(name, uid, groups_csv) a3
    for (cfg.users) |*u| {
        var gcsv: Buf = undefined;
        gcsv.init();
        for (u.groups, 0..) |g, gi| {
            if (gi > 0) gcsv.ch(',') catch {};
            gcsv.str(g) catch {};
        }
        const cols = [3]u32{ fx.dl_intern_str(db, dupeZ(u.name)), u.uid, fx.dl_intern_str(db, dupeZ(gcsv.slice())) };
        addFact(db, "user", &cols);
    }
    // install(target, origin, mode, genhash) a4 — one fact per rootfs
    // mutation the buildfile performs: every /etc copy and every /bin
    // symlink.  `origin` is STORE-RELATIVE (resolved against the store root
    // at query time — the same relocation principle as the generation
    // fact's buildfile/dhake columns).  `mode` is a raw u32 so reconcile
    // can compare it against lstat's st_mode & 0o7777: 0o644 for the etc
    // copies (emitBuildfile's Chmod), 0 for symlinks.
    for (etc) |it| {
        var tgt_buf: [PATH_MAX]u8 = undefined;
        var org_buf: [PATH_MAX]u8 = undefined;
        const cols = [4]u32{
            fx.dl_intern_str(db, snfmtz(&tgt_buf, "/etc/{s}", .{it.path})),
            fx.dl_intern_str(db, snfmtz(&org_buf, "{s}-system-generation/etc/{s}", .{ genhash_s, it.path })),
            0o644,
            fx.dl_intern_str(db, genhash[0..64 :0]),
        };
        addFact(db, "install", &cols);
    }
    for (bin) |it| {
        // store-relative pkg dir `<hash>-<pkg>` (entryOf non-null: the bin
        // construction above already required each pkg in the closure)
        const be = entryOf(entries, it.pkg).?;
        var tgt_buf: [PATH_MAX]u8 = undefined;
        var org_buf: [PATH_MAX]u8 = undefined;
        const cols = [4]u32{
            fx.dl_intern_str(db, snfmtz(&tgt_buf, "/bin/{s}", .{it.name})),
            fx.dl_intern_str(db, snfmtz(&org_buf, "{s}-{s}", .{ be.hash, it.pkg })),
            0,
            fx.dl_intern_str(db, genhash[0..64 :0]),
        };
        addFact(db, "install", &cols);
    }
    // provides(pkg, store_dir) a2 — the closure's store-dir -> pkg-name
    // mapping, today implicit in the derivation hex.  store_dir is
    // STORE-RELATIVE (`<hash>-<pkg>`); entries are in topo (deps-first)
    // order.
    for (entries) |*it| {
        var dir_buf: [PATH_MAX]u8 = undefined;
        const cols = [2]u32{
            fx.dl_intern_str(db, dupeZ(it.p.name)),
            fx.dl_intern_str(db, snfmtz(&dir_buf, "{s}-{s}", .{ it.hash, it.p.name })),
        };
        addFact(db, "provides", &cols);
    }
    // store(hash,name) + srcstore(src_hash,name) for every closure entry —
    // the metadata the SRC-FREE fallback (in-guest activation) resolves
    // from, committed by fx-activate itself (a provisioned/harness store
    // has nobody else to write them).  Duplicates are DAFSA no-ops, so
    // re-activation is idempotent.
    commitClosureMeta(db, entries, store_root_s);

    if (fx.dl_txn_commit(db) != 0) {
        std.debug.print("fx-activate: dl_txn_commit failed\n", .{});
        _ = fx.dl_txn_rollback(db);
        std.process.exit(1);
    }

    var se2 = fx.store.ErrBuf{};
    fx.fx_store_publish(s, &se2) catch {
        std.debug.print("fx-activate: publish: {s}\n", .{se2.slice()});
        std.process.exit(1);
    };
    var v: u32 = 0;
    fx.fx_store_current_version(g_io, s, &v, &se2) catch {
        std.debug.print("fx-activate: {s}\n", .{se2.slice()});
        std.process.exit(1);
    };

    // src-free visibility: ONLY when the fallback actually resolved
    // something (a src-present closure prints nothing — stderr is
    // golden-compared and a 0/N line would be noise on every host run).
    if (src_free_resolved > 0)
        std.debug.print("fx-activate: src-free {d}/{d} packages resolved from published srcstore\n", .{ src_free_resolved, entries.len });

    out.print("activated {s} as version {d}; buildfile {s}\n", .{ genhash_s, v, buildfile_abs }) catch {};
    out.flush() catch {};
}

// ─── unit tests ───────────────────────────────────────────────────────────

const testing = std.testing;

// Round-trip a real package-set through the Zig store core and read every
// field back — the Package/PackageSet native-struct layout (packageset.zig).
test "package-set load round-trip through the Zig store core" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try tmp.dir.createDirPath(io, "src/alpha");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/alpha/a.txt", .data = "alpha\n" });
    try tmp.dir.createDirPath(io, "src/beta");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/beta/b.txt", .data = "beta\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "package-set.dhall", .data =
        \\let Src = < Path : Text | Fetch : { url : Text, hash : Text } >
        \\let Action = < Shell : Text >
        \\let Build = { target : Text, recipe : List Action }
        \\let Package = { name : Text, version : Text, src : Src, deps : List Text,
        \\                excludes : List Text, build : Build }
        \\let PackageSet = { packages : List Package }
        \\in  { packages =
        \\        [ { name = "alpha", version = "1.0", src = < Path = "src/alpha" >,
        \\            deps = [] : List Text, excludes = [] : List Text,
        \\            build = { target = "alpha.bin", recipe = [] : List Action } }
        \\        , { name = "beta", version = "2.0", src = < Path = "src/beta" >,
        \\            deps = [ "alpha" ] : List Text, excludes = [] : List Text,
        \\            build = { target = "beta.bin", recipe = [] : List Action } }
        \\        ] }
        \\  : PackageSet
    });
    // tmpDir lives at <cwd>/.zig-cache/tmp/<sub_path>; the loader takes a
    // filesystem path (realpath resolves it against the cwd).
    var ps_path_buf: [256]u8 = undefined;
    const ps_path = try std.fmt.bufPrint(&ps_path_buf, ".zig-cache/tmp/{s}/package-set.dhall", .{tmp.sub_path});

    var ps: PackageSet = undefined;
    var pe = fx.packageset.ErrBuf{};
    try fx.fx_packageset_load(&ps, ps_path, &pe);
    defer ps.deinit();

    try testing.expectEqual(@as(usize, 2), ps.count);
    const alpha = ps.head.?;
    try testing.expectEqualStrings("alpha", alpha.name);
    try testing.expectEqualStrings("1.0", alpha.version);
    try testing.expectEqual(SrcKind.path, alpha.src.kind);
    try testing.expect(alpha.src.path != null);
    // relative src paths canonicalize (realpath) against the package-set's dir
    try testing.expect(std.mem.endsWith(u8, alpha.src.path.?, "src/alpha"));
    try testing.expectEqual(@as(usize, 0), alpha.deps.len);
    try testing.expectEqualStrings("alpha.bin", alpha.target);

    const beta = alpha.next.?;
    try testing.expectEqualStrings("beta", beta.name);
    try testing.expectEqual(@as(usize, 1), beta.deps.len);
    try testing.expectEqualStrings("alpha", beta.deps[0]);
    try testing.expectEqual(SrcKind.path, beta.src.kind);
    try testing.expectEqualStrings("beta.bin", beta.target);

    try testing.expect(ps.find("beta") == beta);
    try testing.expect(ps.find("ghost") == null);
}

test "buf helpers: u32be/lpstr/dhallStr byte shapes" {
    var b: Buf = undefined;
    b.init();
    try b.lpstr("hi");
    const exp = [_]u8{ 0, 0, 0, 2, 'h', 'i' };
    try testing.expectEqualSlices(u8, &exp, b.slice());

    var b2: Buf = undefined;
    b2.init();
    try b2.u32be(0x01020304);
    const exp2 = [_]u8{ 1, 2, 3, 4 };
    try testing.expectEqualSlices(u8, &exp2, b2.slice());

    var b3: Buf = undefined;
    b3.init();
    try b3.dhallStr("a\"b\\c");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\"", b3.slice());
}

test "serialize_generation golden bytes" {
    var pkg_aa = Package{
        .name = "aa",
        .version = "",
        .src = .{ .kind = .path },
        .target = "",
    };
    var pkg_bb = Package{
        .name = "bb",
        .version = "",
        .src = .{ .kind = .fetch },
        .target = "",
    };
    const entries = [_]PathEntry{
        .{ .p = &pkg_aa, .path = undefined, .hash = "11", .src_hash = null },
        .{ .p = &pkg_bb, .path = undefined, .hash = "44", .src_hash = null },
    };
    const etc = [_]EtcItem{
        // given PRE-SORTED by path (the C sorts in main before serializing;
        // serialize_generation writes the given order)
        .{ .path = "a.txt", .content = "A" },
        .{ .path = "b.txt", .content = "B" },
    };
    const cfg = FxConfig{
        .hostname = "h",
        .packages = &.{},
        .users = &.{},
        .services = &.{
            .{
                .name = "s",
                .argv = &.{ "x", "y" },
                .pkg = null,
                .on_kind = .sock_tcp,
                .on_arg = "1.2.3.4:80",
                .restart = .on_failure,
                .backoff_ms = 7,
                .probe_kind = .file,
                .probe_arg = "/p",
                .env = &.{},
            },
        },
        .extra_etc = &.{},
        .grace_ms = 30000,
    };
    var b: Buf = undefined;
    b.init();
    try serializeGeneration(&b, &cfg, &etc, &entries);

    // hand-derived expected bytes (fxgen-v1 magic | hostname | sorted etc |
    // svc | sorted store-relative closure paths)
    var exp: Buf = undefined;
    exp.init();
    try exp.str("fxgen-v1\n");
    try exp.lpstr("h");
    try exp.u32be(2); // netc — sorted by path
    try exp.lpstr("a.txt");
    try exp.lpstr("A");
    try exp.lpstr("b.txt");
    try exp.lpstr("B");
    try exp.u32be(1); // nsvc
    try exp.lpstr("s");
    try exp.u32be(2); // nargv
    try exp.lpstr("x");
    try exp.lpstr("y");
    try exp.lpstr(""); // pkg
    try exp.lpstr("sock:tcp");
    try exp.lpstr("1.2.3.4:80");
    try exp.lpstr("on-failure");
    try exp.u32be(7); // backoff_ms
    try exp.lpstr("file");
    try exp.lpstr("/p");
    try exp.u32be(2); // npaths — sorted: "11-aa" < "44-bb"
    try exp.lpstr("11-aa");
    try exp.lpstr("44-bb");
    try testing.expectEqualSlices(u8, exp.slice(), b.slice());
}

test "emit_buildfile: shape, Copy+Chmod, Rm+Symlink, trailing-separator trim" {
    var b: Buf = undefined;
    b.init();
    const etc = [_]EtcItem{.{ .path = "m", .content = "x" }};
    const bin = [_]BinLink{.{ .name = "tool", .from = "/store/44-tool/tool" }};
    try emitBuildfile(&b, "/G", &etc, &bin);
    const out = b.slice();

    try testing.expect(std.mem.startsWith(u8, out, "let Action =\n      < Shell : Text\n"));
    try testing.expect(std.mem.indexOf(u8, out, "let GEN = \"/G\"\n\nin  { default = \"rootfs\"\n") != null);
    // dirs target: 4 Mkdirs, phony
    try testing.expect(std.mem.indexOf(u8, out, "< Mkdir = < Parents = { path = \"/run/fx\", parents = True } > >\n") != null);
    // etc: Copy from GEN + Chmod 0644
    try testing.expect(std.mem.indexOf(u8, out, "< Copy = { from = \"/G/etc/m\", to = \"/etc/m\" } >\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, ", < Chmod = { path = \"/etc/m\", mode = \"0644\" } >\n") != null);
    // bin: Rm guard before Symlink (dhake bare symlink fails EEXIST); the
    // link target is the BINARY inside the store dir, not the dir itself
    try testing.expect(std.mem.indexOf(u8, out, "< Rm = < Plain = \"/bin/tool\" > >\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, ", < Symlink = { from = \"/store/44-tool/tool\", to = \"/bin/tool\" } >\n") != null);
    // the trailing-", "-trim quirk: the list closes right after the last
    // action (18-space indent + " ]"), never "<sep>,\n<indent>]"
    try testing.expect(std.mem.indexOf(u8, out, "} >\n                   ]\n") != null); // 18 spaces + " ]" (the trim quirk)
    try testing.expect(std.mem.indexOf(u8, out, ", \n") == null);
    // all four targets phony (dirs, etc, bin, rootfs)
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "phony = True"));
    try testing.expect(std.mem.endsWith(u8, out, "              { deps = [ \"etc\", \"bin\" ]\n              , phony = True\n              , recipe = [] : List Action\n              }\n          }\n        ]\n      }\n"));
}

test "emit_buildfile: empty etc/bin render ] : List Action" {
    var b: Buf = undefined;
    b.init();
    try emitBuildfile(&b, "/G", &.{}, &.{});
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, b.slice(), "] : List Action\n")); // etc + bin + rootfs
}

test "render_passwd/render_group incl. supplementary-gid rule" {
    const cfg = FxConfig{
        .hostname = "h",
        .packages = &.{},
        .users = &.{
            .{ .name = "root", .uid = 0, .groups = &.{} },
            .{ .name = "al", .uid = 1000, .groups = &.{ "wheel", "root" } },
        },
        .services = &.{},
        .extra_etc = &.{},
        .grace_ms = 30000,
    };
    var p: Buf = undefined;
    p.init();
    try renderPasswd(&p, &cfg);
    try testing.expectEqualStrings(
        "root:x:0:0::/home/root:/bin/sh\n" ++
            "al:x:1000:1000::/home/al:/bin/sh\n", p.slice());

    var g: Buf = undefined;
    g.init();
    try renderGroup(&g, &cfg);
    // "root" supplementary group is skipped (a user's primary group exists
    // already); "wheel" is claimed by al -> gid = first claiming user's uid.
    try testing.expectEqualStrings("root:x:0:\nal:x:1000:\nwheel:x:1000:\n", g.slice());
}

test "on_full reconstruction" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("all", onFull(.all, null, &buf));
    try testing.expectEqualStrings("up:heartbeat", onFull(.up, "heartbeat", &buf));
    try testing.expectEqualStrings("up:", onFull(.up, null, &buf));
    try testing.expectEqualStrings("sock:tcp:127.0.0.1:4053", onFull(.sock_tcp, "127.0.0.1:4053", &buf));
    try testing.expectEqualStrings("sock:unix:/run/x.sock", onFull(.sock_unix, "/run/x.sock", &buf));
    try testing.expectEqualStrings("time:250", onFull(.time, "250", &buf));
    try testing.expectEqualStrings("net", onFull(.net, null, &buf));
}

// ─── src-free fallback (in-guest activation) ─────────────────────────────

// The shared fixture of the three src-free tests: a two-package set (alpha
/// <- beta) with REAL source trees, a store rooted at <tmp>/store whose
/// closure dirs exist (fx-activate's "built" check only stats dir-ness), and
/// the metadata committed exactly as fx-activate's happy path does.
fn srcFreeFixture(io: std.Io, tmp: *testing.TmpDir, store_rel: []const u8) !struct {
    ps: PackageSet,
    store_path: [256]u8,
    store_len: usize,
} {
    try tmp.dir.createDirPath(io, "src/alpha");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/alpha/a.txt", .data = "alpha\n" });
    try tmp.dir.createDirPath(io, "src/beta");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/beta/b.txt", .data = "beta\n" });
    // ABSOLUTE src paths: the loader keeps them verbatim (no realpath), so
    // the same pkgset text serves BOTH arms — the src-free arm rewrites the
    // roots to nonexistent dirs under the same tmp.
    // ABSOLUTE src paths (the loader keeps them verbatim — the same
    // mechanism the guest pkgset uses); resolve the tmp dir against cwd.
    var cwd: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.Io.Dir.cwd().realPathFile(io, ".", &cwd);
    const cwd_s = cwd[0..cwd_len];
    var alpha_abs: [std.fs.max_path_bytes]u8 = undefined;
    var beta_abs: [std.fs.max_path_bytes]u8 = undefined;
    const alpha_s = try std.fmt.bufPrint(&alpha_abs, "{s}/.zig-cache/tmp/{s}/src/alpha", .{ cwd_s, tmp.sub_path });
    const beta_s = try std.fmt.bufPrint(&beta_abs, "{s}/.zig-cache/tmp/{s}/src/beta", .{ cwd_s, tmp.sub_path });
    var ps_text: [1024]u8 = undefined;
    const ps_s = try std.fmt.bufPrint(&ps_text,
        \\let Src = < Path : Text | Fetch : {{ url : Text, hash : Text }} >
        \\let Action = < Shell : Text >
        \\let Build = {{ target : Text, recipe : List Action }}
        \\let Package = {{ name : Text, version : Text, src : Src, deps : List Text,
        \\                excludes : List Text, build : Build }}
        \\let PackageSet = {{ packages : List Package }}
        \\in  {{ packages =
        \\        [ {{ name = "alpha", version = "1.0", src = < Path = "{s}" >,
        \\            deps = [] : List Text, excludes = [] : List Text,
        \\            build = {{ target = "alpha.bin", recipe = [] : List Action }} }}
        \\        , {{ name = "beta", version = "2.0", src = < Path = "{s}" >,
        \\            deps = [ "alpha" ] : List Text, excludes = [] : List Text,
        \\            build = {{ target = "beta.bin", recipe = [] : List Action }} }}
        \\        ] }}
        \\  : PackageSet
    , .{ alpha_s, beta_s });
    try tmp.dir.writeFile(io, .{ .sub_path = "package-set.dhall", .data = ps_s });

    var ps: PackageSet = undefined;
    var pe = fx.packageset.ErrBuf{};
    var ps_path_buf: [256]u8 = undefined;
    const ps_path = try std.fmt.bufPrint(&ps_path_buf, ".zig-cache/tmp/{s}/package-set.dhall", .{tmp.sub_path});
    fx.fx_packageset_load(&ps, ps_path, &pe) catch |err| {
        std.debug.print("fixture load failed: {s}\n", .{pe.slice()});
        return err;
    };

    // the store: open, compute the closure WITH sources, materialize each
    // entry's dir (a marker file), commit the closure meta + publish.
    var store_path: [256]u8 = undefined;
    const store_s = try std.fmt.bufPrint(&store_path, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, store_rel });
    var se = fx.store.ErrBuf{};
    const s = fx.fx_store_open(io, store_s, &se) catch |err| {
        std.debug.print("fixture store open failed: {s}\n", .{se.slice()});
        return err;
    };
    const db = fx.fx_store_db(s).?;
    g_io = io;
    var cerr: [PATH_MAX]u8 = undefined;
    var e: ErrBuf = .{};
    const entries = computePaths(&ps, db, &.{}, store_s, &cerr, &e) catch |err| {
        std.debug.print("fixture computePaths failed: {s} / {s}\n", .{ std.mem.span(@as([*:0]const u8, @ptrCast(&cerr))), e.slice() });
        return err;
    };
    for (entries) |*it| {
        // it.path is CWD-relative (the store was opened with a relative
        // root): create the dirs under cwd, NOT under tmp.dir (whose
        // sub_paths are tmp-relative — a doubled prefix would put them
        // where neither the store nor the fallback looks).
        try std.Io.Dir.cwd().createDirPath(io, it.path);
    }
    if (fx.dl_txn_begin(db) != 0) return error.StoreTxn;
    commitClosureMeta(db, entries, store_s);
    if (fx.dl_txn_commit(db) != 0) return error.StoreTxn;
    var se2 = fx.store.ErrBuf{};
    fx.fx_store_publish(s, &se2) catch return error.StorePublish;
    fx.fx_store_close(s);
    return .{ .ps = ps, .store_path = store_path, .store_len = store_s.len };
}

// (i) the publication round trip: after the happy-path commit + publish +
// close + REOPEN, every closure package has store(hash,name) and
// srcstore(src_hash,name) rows, and activate_root is the store root.
test "src-free: publication round trip (store/srcstore/activate_root facts)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var fxq = try srcFreeFixture(io, &tmp, "store");
    defer fxq.ps.deinit();

    var se = fx.store.ErrBuf{};
    const s = fx.fx_store_open(io, fxq.store_path[0..fxq.store_len], &se) catch {
        std.debug.print("reopen failed: {s}\n", .{se.slice()});
        return error.StoreOpen;
    };
    defer fx.fx_store_close(s);
    const db = fx.fx_store_db(s).?;

    // walk BOTH pair relations once, matching by resolved col1 string
    const Bag = struct {
        db: *DlDb,
        alloc: std.mem.Allocator,
        a: std.ArrayList([]const u8) = .empty,
        b: std.ArrayList([]const u8) = .empty,
    };
    const bagCb = struct {
        fn f(cols: [*]const u32, arity: u8, user: ?*anyopaque) callconv(.c) c_int {
            _ = arity;
            const bg: *Bag = @ptrCast(@alignCast(user.?));
            const x = fx.dl_intern_str_of(bg.db, cols[0]) orelse return 1;
            const y = fx.dl_intern_str_of(bg.db, cols[1]) orelse return 1;
            const xd = bg.alloc.dupe(u8, std.mem.span(x)) catch return 1;
            const yd = bg.alloc.dupe(u8, std.mem.span(y)) catch return 1;
            bg.a.append(bg.alloc, xd) catch return 1;
            bg.b.append(bg.alloc, yd) catch return 1;
            return 0;
        }
    }.f;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var sbag = Bag{ .db = db, .alloc = arena.allocator() };
    _ = fx.dl_query(db, "srcstore", &bagCb, &sbag);
    var tbag = Bag{ .db = db, .alloc = arena.allocator() };
    _ = fx.dl_query(db, "store", &bagCb, &tbag);
    try testing.expectEqual(@as(usize, 2), sbag.b.items.len); // col1 = NAME
    try testing.expectEqual(@as(usize, 2), tbag.b.items.len);

    // activate_root == the store root, exactly one row
    var root_buf: [PATH_MAX]u8 = undefined;
    const rr = recordedRoot(db, &root_buf);
    try testing.expect(rr != null);
    try testing.expectEqualStrings(fxq.store_path[0..fxq.store_len], rr.?);
}

// (ii) THE ASYMMETRY PIN: a src-free run must yield BYTE-IDENTICAL hashes
// to the with-sources run.  Same store, same closure, the only difference
// is that the src trees are absent (absolute paths pointing at nonexistent
// dirs — kept verbatim by the loader).  A flipped srcstore column order, a
// wrong recorded root, or any divergence in the fallback's recompute makes
// this test FAIL LOUDLY, not adapt silently.
test "src-free: fallback yields byte-identical hashes to the with-sources run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var fxq = try srcFreeFixture(io, &tmp, "store");
    defer fxq.ps.deinit();
    const store_s = fxq.store_path[0..fxq.store_len];

    // ground truth: WITH sources (the trees still exist)
    var se = fx.store.ErrBuf{};
    const s1 = fx.fx_store_open(io, store_s, &se) catch return error.StoreOpen;
    const db1 = fx.fx_store_db(s1).?;
    g_io = io;
    var cerr1: [PATH_MAX]u8 = undefined;
    var e1: ErrBuf = .{};
    const with_src = computePaths(&fxq.ps, db1, &.{}, store_s, &cerr1, &e1) catch |err| {
        std.debug.print("with-sources computePaths failed: {s}\n", .{e1.slice()});
        return err;
    };
    fx.fx_store_close(s1);

    // RELOCATE the store (the guest scenario: the live root differs from
    // the root the committed hashes were computed under — dep store paths
    // are root-qualified inside the derivation hash, so a fallback that
    // recomputes under the LIVE root would diverge; only the RECORDED root
    // keeps the hashes byte-identical).
    try tmp.dir.rename("store", tmp.dir, "store2", io);
    var store2_path: [512]u8 = undefined;
    var cwd2: [std.fs.max_path_bytes]u8 = undefined;
    const cwd2_len = try std.Io.Dir.cwd().realPathFile(io, ".", &cwd2);
    const store2_s = try std.fmt.bufPrint(&store2_path, "{s}/.zig-cache/tmp/{s}/store2", .{ cwd2[0..cwd2_len], tmp.sub_path });
    const s2 = fx.fx_store_open(io, store2_s, &se) catch return error.StoreOpen;
    const db2 = fx.fx_store_db(s2).?;

    // the src-free arm: rewrite every Path value to a NONEXISTENT absolute
    // dir under the same tmp (absolute => no realpath => load succeeds)
    var p = fxq.ps.head;
    var gone_buf: [std.fs.max_path_bytes]u8 = undefined;
    const gone = try std.fmt.bufPrint(&gone_buf, "{s}/.zig-cache/tmp/{s}/gone", .{ cwd2[0..cwd2_len], tmp.sub_path });
    while (p) |pkg| : (p = pkg.next) {
        // PackageSet strings live in its arena: mutating in place is safe
        // (the fixture's ps is a copy returned by value from srcFreeFixture)
        const arena_p = fxq.ps.arena.allocator();
        const nz = try arena_p.dupe(u8, gone[0..]);
        pkg.src.path = nz;
    }
    // belt: the gone dir must NOT exist (the fallback must not be able to
    // hash anything even by accident)
    try testing.expect(!(std.Io.Dir.cwd().statFile(io, gone, .{}) catch null != null));

    const entries = computePaths(&fxq.ps, db2, &.{}, store2_s, &cerr1, &e1) catch |err| {
        std.debug.print("src-free computePaths FAILED: {s}\n", .{e1.slice()});
        return err;
    };
    try testing.expectEqual(with_src.len, entries.len);
    try testing.expect(src_free_resolved == entries.len); // every package went through the fallback
    for (with_src, entries) |*w, *g| {
        try testing.expectEqualStrings(w.p.name, g.p.name);
        try testing.expectEqualStrings(w.hash, g.hash); // BYTE-IDENTICAL derivation hashes
        // the store path's TAIL must match; the PREFIX is the (differing)
        // live root by design — the relocate arm would fail a full compare
        const w_rel = std.mem.lastIndexOfScalar(u8, w.path, '/').? + 1;
        const g_rel = std.mem.lastIndexOfScalar(u8, g.path, '/').? + 1;
        try testing.expectEqualStrings(w.path[w_rel..], g.path[g_rel..]);
        try testing.expect(w.src_hash != null and g.src_hash != null);
        try testing.expectEqualStrings(w.src_hash.?, g.src_hash.?); // and src hashes
    }
    fx.fx_store_close(s2);
}

// (iii) the loud failure: a package absent from srcstore (a genuinely NEW
// package) must fail computePaths with the naming error — never silently
// adopt something else.
test "src-free: new package fails loudly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var fxq = try srcFreeFixture(io, &tmp, "store");
    defer fxq.ps.deinit();
    const store_s = fxq.store_path[0..fxq.store_len];

    // a third package whose src tree does not exist and whose name has no
    // srcstore row: append it to the package set via a fresh load
    var ps_text: [1024]u8 = undefined;
    const ps_s = try std.fmt.bufPrint(&ps_text,
        \\let Src = < Path : Text | Fetch : {{ url : Text, hash : Text }} >
        \\let Action = < Shell : Text >
        \\let Build = {{ target : Text, recipe : List Action }}
        \\let Package = {{ name : Text, version : Text, src : Src, deps : List Text,
        \\                excludes : List Text, build : Build }}
        \\let PackageSet = {{ packages : List Package }}
        \\in  {{ packages =
        \\        [ {{ name = "gamma", version = "1.0", src = < Path = "/nonexistent/gamma-src" >,
        \\            deps = [] : List Text, excludes = [] : List Text,
        \\            build = {{ target = "gamma.bin", recipe = [] : List Action }} }}
        \\        ] }}
        \\  : PackageSet
    , .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "package-set-gamma.dhall", .data = ps_s });
    var ps2: PackageSet = undefined;
    var pe = fx.packageset.ErrBuf{};
    var ps2_path_buf: [256]u8 = undefined;
    const ps2_path = try std.fmt.bufPrint(&ps2_path_buf, ".zig-cache/tmp/{s}/package-set-gamma.dhall", .{tmp.sub_path});
    fx.fx_packageset_load(&ps2, ps2_path, &pe) catch |err| {
        std.debug.print("gamma load failed: {s}\n", .{pe.slice()});
        return err;
    };
    defer ps2.deinit();

    var se = fx.store.ErrBuf{};
    const s = fx.fx_store_open(io, store_s, &se) catch return error.StoreOpen;
    defer fx.fx_store_close(s);
    g_io = io;
    var cerr: [PATH_MAX]u8 = undefined;
    var e: ErrBuf = .{};
    const r = computePaths(&ps2, fx.fx_store_db(s).?, &.{"gamma"}, store_s, &cerr, &e);
    try testing.expectError(error.FxErr, r);
    try testing.expect(std.mem.indexOf(u8, e.slice(), "gamma") != null);
    try testing.expect(std.mem.indexOf(u8, e.slice(), "no published srcstore/store pair resolves it") != null);
}
