// activate.zig — faithful Zig port of src/fx-activate.c (U-B, unit 5): the
// build-time activation CLI.  Evaluates config.dhall + package-set.dhall,
// computes the closure through the VENDORED C core (packageset/derivation/
// closure/store — the `fxstore_c` static lib in build.zig, the log.zig FFI
// pattern), then renders + publishes the per-generation buildfile and facts.
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
//     messages and a plain [4096]u8 for the C callees' buffers — divergence
//     only for >2047-byte config error strings (unreachable in the corpus).
//   - config strings are Zig slices; every string crossing into C
//     (dl_intern_str, fx_find_package, closure roots) is dupeZ'd.
//   - the C's free-everything error unwinding is dropped (config.zig
//     precedent): this is a process-lifetime CLI, exits make frees moot.
//   - libc snprintf sites (renderers, path joins) go through snfmt/snfmtz,
//     which format unbounded then truncate to the buffer cap — snprintf
//     semantics, byte-identical output.
const std = @import("std");
const cfg_mod = @import("config");

const FxConfig = cfg_mod.FxConfig;
const FxService = cfg_mod.FxService;
const FxOnKind = cfg_mod.FxOnKind;
const FxProbeKind = cfg_mod.FxProbeKind;
const FxRestart = cfg_mod.FxRestart;
const ErrBuf = cfg_mod.ErrBuf;

// libc is linked; use the C malloc allocator (config.zig pattern — the
// process-lifetime CLI allocator; C memory returned by the vendored core is
// malloc'd too).
const gpa_alloc = std.heap.c_allocator;

// ─── vendored C API (vendor/fxstore + vendor/datalog-dafsa + dhall-c) ─────

/// fxstore.h ActionKind (ABI: c_int; fields never read here, layout only).
pub const ActionKind = enum(c_int) { shell, mkdir, rm, touch, move, symlink, chmod, echo, env, run };

/// fxstore.h Action (fxstore.h:54-64) — EXACT field order is ABI.
pub const Action = extern struct {
    kind: ActionKind,
    a: ?[*:0]u8,
    b: ?[*:0]u8,
    av: ?*?[*:0]u8,
    nav: c_int,
    next: ?*Action,
};

/// fxstore.h SrcKind.
pub const SrcKind = enum(c_int) { path, fetch };

/// fxstore.h Src (fxstore.h:85-90) — EXACT field order is ABI.
pub const Src = extern struct {
    kind: SrcKind,
    path: ?[*:0]u8,
    url: ?[*:0]u8,
    hash: ?[*:0]u8,
};

/// fxstore.h Package (fxstore.h:93-107) — EXACT field order is ABI.
pub const Package = extern struct {
    name: ?[*:0]u8,
    version: ?[*:0]u8,
    src: Src,
    deps: ?[*]?[*:0]u8,
    ndeps: c_int,
    excludes: ?[*]?[*:0]u8,
    nexcludes: c_int,
    target: ?[*:0]u8,
    recipe: ?*Action,
    next: ?*Package,
};

/// fxstore.h PackageSet.
pub const PackageSet = extern struct {
    head: ?*Package,
    count: c_int,
};

pub const FxStore = opaque {};
pub const dl_db = opaque {};
pub const dl_iter = opaque {};

extern fn fx_packageset_load(out: *PackageSet, path: [*:0]const u8, err: ?[*]u8, errcap: usize) c_int;
extern fn fx_find_package(ps: *const PackageSet, name: [*:0]const u8) ?*Package;
extern fn fx_packageset_free(ps: *PackageSet) void;
extern fn fx_content_hash_dir(dir: [*:0]const u8, excludes: ?[*]const ?[*:0]const u8, nexcludes: c_int, hash_out: [*]u8, err: ?[*]u8, errcap: usize) c_int;
extern fn fx_derivation_hash_ex(p: *const Package, src_hash: ?[*:0]const u8, dep_paths: ?[*]const ?[*:0]const u8, ndeps: c_int, hash_out: [*]u8, err: ?[*]u8, errcap: usize) c_int;
extern fn fx_store_path_of(store_root: [*:0]const u8, hash: [*:0]const u8, name: [*:0]const u8, out: [*]u8, cap: usize) void;
extern fn fx_store_open(root: [*:0]const u8, err: ?[*]u8, errcap: usize) ?*FxStore;
extern fn fx_store_close(s: ?*FxStore) void;
extern fn fx_store_db(s: *FxStore) *dl_db;
extern fn fx_store_publish(s: *FxStore, err: ?[*]u8, errcap: usize) c_int;
extern fn fx_store_current_version(s: *const FxStore, out: *u32, err: ?[*]u8, errcap: usize) c_int;
extern fn fx_closure_compute(db: *dl_db, ps: *const PackageSet, roots: ?[*]const ?[*:0]const u8, nroots: c_int, err: ?[*]u8, errcap: usize) c_int;
extern fn fx_closure_names(db: *dl_db, names_out: *?[*]?[*:0]u8, n_out: *c_int, err: ?[*]u8, errcap: usize) c_int;
extern fn fx_topo_order(ps: *const PackageSet, names: ?[*]?[*:0]u8, n: c_int, order_out: *?[*]?*Package, n_out: *c_int, err: ?[*]u8, errcap: usize) c_int;
// dl.h (log.zig:33-52 pattern).
extern fn dl_declare_relation(db: *dl_db, name: [*:0]const u8, arity: u8) c_int;
extern fn dl_txn_begin(db: *dl_db) c_int;
extern fn dl_txn_add_fact(db: *dl_db, rel: [*:0]const u8, cols: [*]const u32, arity: u8) c_int;
extern fn dl_txn_delete_fact(db: *dl_db, rel: [*:0]const u8, cols: [*]const u32, arity: u8) c_int;
extern fn dl_txn_commit(db: *dl_db) c_int;
extern fn dl_txn_rollback(db: *dl_db) c_int;
extern fn dl_intern_str(db: *dl_db, str: ?[*:0]const u8) u32;
extern fn dl_iter_open(db: *dl_db, rel: [*:0]const u8, leading: ?[*]const u32, k: u8) ?*dl_iter;
extern fn dl_iter_arity(it: *const dl_iter) u8;
extern fn dl_iter_next(it: *dl_iter, cols_out: [*]u32) c_int;
extern fn dl_iter_close(it: ?*dl_iter) void;
/// dhall.h:316 — resolved by the DHALLC sha256.c in the linked lib.
extern fn sha256_hex(data: ?*const anyopaque, len: usize, out: [*]u8) void;

// libc scratch (log.zig pattern).
extern fn malloc(size: usize) ?[*]u8;
extern fn free(ptr: ?*anyopaque) void;
extern "c" fn strerror(errnum: c_int) [*:0]const u8;
extern "c" fn getpid() c_int;
extern "c" fn time(t: ?*i64) i64;

const EEXIST: c_int = 17; // Linux
const PATH_MAX: usize = 4096;

fn errStr() []const u8 {
    return std.mem.span(strerror(std.c._errno().*));
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
fn pathOf(es: []const PathEntry, name: []const u8) ?[*:0]const u8 {
    for (es) |*it| {
        if (std.mem.eql(u8, std.mem.span(it.p.name.?), name)) return it.path.ptr;
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
        if (std.mem.eql(u8, std.mem.span(it.p.name.?), name)) return it;
    }
    return null;
}

/// store_path_of: find the store path of a closure package by name.
fn storePathOf(es: []const PathEntry, name: []const u8) ?[]const u8 {
    for (es) |*it| {
        if (std.mem.eql(u8, std.mem.span(it.p.name.?), name)) return it.path;
    }
    return null;
}

/// free the malloc'd closure-name array returned by fx_closure_names.
fn freeNames(names: ?[*]?[*:0]u8, n: c_int) void {
    const arr = names orelse return;
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) free(arr[i]);
    free(@ptrCast(arr));
}

pub const ComputeError = error{ CFailed, FxErr, OutOfMemory };

/// compute_paths — fx_closure_compute -> fx_closure_names -> fx_topo_order,
/// then per package (topo, deps-first): content-hash the SRC_PATH tree, hash
/// the derivation over the (already-computed) dep store paths, format the
/// store path.  C callees report through `cerr` (error.CFailed); the port's
/// own fx_err-style messages go through `e` (error.FxErr).
pub fn computePaths(
    ps: *const PackageSet,
    db: *dl_db,
    roots: [*]const ?[*:0]const u8,
    nroots: usize,
    store_root: [*:0]const u8,
    cerr: *[PATH_MAX]u8,
    e: *ErrBuf,
) ComputeError![]PathEntry {
    if (fx_closure_compute(db, ps, roots, @intCast(nroots), cerr, cerr.len) != 0) return error.CFailed;
    var names: ?[*]?[*:0]u8 = null;
    var nn: c_int = 0;
    if (fx_closure_names(db, &names, &nn, cerr, cerr.len) != 0) return error.CFailed;
    var ord: ?[*]?*Package = null;
    var no: c_int = 0;
    if (fx_topo_order(ps, names, nn, &ord, &no, cerr, cerr.len) != 0) {
        freeNames(names, nn);
        return error.CFailed;
    }
    freeNames(names, nn);
    const n_no: usize = @intCast(no);

    const es = gpa_alloc.alloc(PathEntry, @max(n_no, 1)) catch {
        eSet(e, "out of memory", .{});
        return error.FxErr;
    };
    const entries = es[0..n_no];
    for (0..n_no) |i| {
        const p: *Package = ord.?[i].?;
        var dep_paths: ?[]?[*:0]const u8 = null;
        if (p.ndeps > 0) {
            const dp = gpa_alloc.alloc(?[*:0]const u8, @intCast(p.ndeps)) catch {
                eSet(e, "out of memory", .{});
                return error.FxErr;
            };
            dep_paths = dp[0..];
        }
        var ok = true;
        if (dep_paths) |dp| {
            for (0..dp.len) |j| {
                const dep_name = std.mem.span(p.deps.?[j].?);
                dp[j] = pathOf(entries[0..i], dep_name);
                if (dp[j] == null) {
                    eSet(e, "internal: dep '{s}' of '{s}' unresolved", .{ dep_name, std.mem.span(p.name.?) });
                    ok = false;
                    break;
                }
            }
        }
        if (ok) {
            var h: [65]u8 = undefined;
            var src_hash: ?[*:0]const u8 = null;
            if (p.src.kind == .path) {
                var sh: [65]u8 = undefined;
                if (fx_content_hash_dir(p.src.path.?, p.excludes, p.nexcludes, &sh, cerr, cerr.len) != 0)
                    return error.CFailed;
                const own = gpa_alloc.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&sh)))) catch {
                    eSet(e, "out of memory", .{});
                    return error.FxErr;
                };
                entries[i].src_hash = own;
                src_hash = own.ptr;
            }
            if (fx_derivation_hash_ex(
                p,
                src_hash,
                if (dep_paths) |dp| dp.ptr else null,
                p.ndeps,
                &h,
                cerr,
                cerr.len,
            ) == 0) {
                var path: [PATH_MAX]u8 = undefined;
                fx_store_path_of(store_root, @ptrCast(&h), p.name.?, &path, path.len);
                entries[i].p = p;
                entries[i].hash = gpa_alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&h)))) catch {
                    eSet(e, "out of memory", .{});
                    return error.FxErr;
                };
                entries[i].path = gpa_alloc.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&path)))) catch {
                    eSet(e, "out of memory", .{});
                    return error.FxErr;
                };
            } else return error.CFailed;
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

/// (name, storedir) pair for a /bin symlink.
pub const BinLink = struct {
    name: []const u8,
    storedir: []const u8,
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
            try b.dhallStr(it.storedir);
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
        paths[i] = std.fmt.allocPrint(gpa_alloc, "{s}-{s}", .{ it.hash, std.mem.span(it.p.name.?) }) catch return error.OutOfMemory;
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

fn declare(db: *dl_db, rel: [*:0]const u8, arity: u8, e: *ErrBuf) error{DeclareFailed}!void {
    // dl_declare_relation is idempotent: re-declaring with the same arity is
    // a no-op returning 0; an arity mismatch or arity>8 returns -1.
    if (dl_declare_relation(db, rel, arity) != 0) {
        eSet(e, "declare {s}/{d} failed", .{ std.mem.span(rel), arity });
        return error.DeclareFailed;
    }
}

fn addFact(db: *dl_db, rel: [*:0]const u8, cols: []const u32) void {
    // we intern strings outside and pass sym ids; ints as raw u32
    _ = dl_txn_add_fact(db, rel, cols.ptr, @intCast(cols.len));
}

/// delete-all existing tuples of `rel` (collect then delete — safe vs the
/// live DAFSA cursor).  Must be called inside an open txn.  Used to make each
/// activation's snapshot self-consistent (only THIS activation's generation/
/// svc facts) instead of accumulating stale services across activations.
fn clearRel(db: *dl_db, rel: [*:0]const u8, arity: u8) error{ ClearFailed, OutOfMemory }!void {
    const it = dl_iter_open(db, rel, null, 0) orelse return;
    if (dl_iter_arity(it) != arity) {
        dl_iter_close(it);
        return error.ClearFailed;
    }
    var all: std.ArrayList(u32) = .empty;
    defer all.deinit(gpa_alloc);
    var row: [8]u32 = undefined;
    while (dl_iter_next(it, &row) == 1) {
        all.appendSlice(gpa_alloc, row[0..arity]) catch {
            dl_iter_close(it);
            return error.OutOfMemory;
        };
    }
    dl_iter_close(it);
    for (0..all.items.len / arity) |i| {
        _ = dl_txn_delete_fact(db, rel, all.items[i * arity ..][0..arity].ptr, arity);
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
    if (fx_packageset_load(&ps, pkgset_path_s.ptr, &cerr, cerr.len) != 0) {
        std.debug.print("fx-activate: {s}\n", .{std.mem.span(cerr_z)});
        std.process.exit(1);
    }

    var cfg: FxConfig = undefined;
    cfg_mod.fx_config_load(&cfg, config_path_s, &e) catch {
        std.debug.print("fx-activate: {s}\n", .{e.slice()});
        std.process.exit(1);
    };

    const s = fx_store_open(store_root_s.ptr, &cerr, cerr.len) orelse {
        std.debug.print("fx-activate: {s}\n", .{std.mem.span(cerr_z)});
        std.process.exit(1);
    };
    const db = fx_store_db(s);

    // closure roots = config.packages (dupeZ: config strings are slices)
    const roots = gpa_alloc.alloc(?[*:0]const u8, cfg.packages.len + 1) catch @panic("out of memory");
    for (cfg.packages, 0..) |p, ri| roots[ri] = dupeZ(p);
    roots[cfg.packages.len] = null;

    const entries = computePaths(&ps, db, roots.ptr, cfg.packages.len, store_root_s.ptr, &cerr, &e) catch |err| switch (err) {
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
            miss.str(std.mem.span(it.p.name.?)) catch {};
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

    // collect /bin symlinks: init, fxctl, dhake, fx-activate, + one per service pkg
    var nbin: usize = 4;
    for (cfg.services) |*sv| {
        if (sv.pkg != null) nbin += 1;
    }
    const bin = gpa_alloc.alloc(BinLink, nbin) catch @panic("out of memory");
    var bi: usize = 0;
    const initp = storePathOf(entries, "fx-init").?;
    bin[bi] = .{ .name = "init", .storedir = initp };
    bi += 1;
    bin[bi] = .{ .name = "fxctl", .storedir = storePathOf(entries, "fxctl").? };
    bi += 1;
    bin[bi] = .{ .name = "dhake", .storedir = dhake_path };
    bi += 1;
    bin[bi] = .{ .name = "fx-activate", .storedir = storePathOf(entries, "fx-activate").? };
    bi += 1;
    for (cfg.services) |*sv| {
        const pkg = sv.pkg orelse continue;
        const p = storePathOf(entries, pkg) orelse {
            std.debug.print("fx-activate: service '{s}' pkg '{s}' not in the closure\n", .{ sv.name, pkg });
            std.process.exit(1);
        };
        const pk = fx_find_package(&ps, dupeZ(pkg)).?;
        bin[bi] = .{ .name = baseName(std.mem.span(pk.target.?)), .storedir = p };
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
    sha256_hex(ser.slice().ptr, ser.len, &genhash);
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
    const now: u32 = @truncate(@as(u64, @bitCast(time(null))));
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
    };
    for (decls) |d| declare(db, d.rel, d.arity, &e) catch {
        std.debug.print("fx-activate: {s}\n", .{e.slice()});
        std.process.exit(1);
    };

    if (dl_txn_begin(db) != 0) {
        std.debug.print("fx-activate: dl_txn_begin failed\n", .{});
        std.process.exit(1);
    }

    // clear the previous activation's generation/svc/user facts so each
    // published snapshot is self-consistent (only THIS activation's set).
    // Without this, a re-activation would accumulate stale services and
    // fx-init would boot the union of all past service sets.
    for (decls) |d| clearRel(db, d.rel, d.arity) catch {
        std.debug.print("fx-activate: clear old facts failed\n", .{});
        _ = dl_txn_rollback(db);
        std.process.exit(1);
    };

    // generation(genhash, buildfile, dhake, epoch) a4.
    // buildfile + dhake columns are STORE-RELATIVE paths (resolved by fx-init
    // against its --store at boot) — see the buildfile_rel / dhake_rel notes.
    {
        const cols = [4]u32{
            dl_intern_str(db, genhash[0..64 :0]),
            dl_intern_str(db, buildfile_rel),
            dl_intern_str(db, dhake_rel),
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
        const cols = [1]u32{dl_intern_str(db, "/bin/fx-activate")};
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
        const sn = dl_intern_str(db, dupeZ(sv.name));
        var onf_buf: [256]u8 = undefined;
        const onf = onFull(sv.on_kind, sv.on_arg, &onf_buf);
        const rs: [*:0]const u8 = switch (sv.restart) {
            .always => "always",
            .on_failure => "on-failure",
            .never => "never",
        };
        const cols = [3]u32{ sn, dl_intern_str(db, onf), dl_intern_str(db, rs) };
        addFact(db, "svc", &cols);
        // svc_backoff(name, backoff_ms)
        const cbk = [2]u32{ sn, sv.backoff_ms };
        addFact(db, "svc_backoff", &cbk);
        // svc_argv(name, idx, arg)
        for (sv.argv, 0..) |arg, a| {
            const c = [3]u32{ sn, @intCast(a), dl_intern_str(db, dupeZ(arg)) };
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
            const pe = entryOf(entries, pkg).?;
            const pk = fx_find_package(&ps, dupeZ(pkg)).?;
            break :blk snfmtz(&resolved_buf, "{s}-{s}/{s}", .{ pe.hash, pkg, baseName(std.mem.span(pk.target.?)) });
        } else snfmtz(&resolved_buf, "{s}", .{sv.argv[0]});
        const cb = [2]u32{ sn, dl_intern_str(db, resolved) };
        addFact(db, "svc_bin", &cb);
        // svc_env(name, key, value)
        for (sv.env) |kv| {
            const ce = [3]u32{ sn, dl_intern_str(db, dupeZ(kv.key)), dl_intern_str(db, dupeZ(kv.value)) };
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
            const cp = [3]u32{ sn, dl_intern_str(db, pk), dl_intern_str(db, dupeZ(sv.probe_arg orelse "")) };
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
        const cols = [3]u32{ dl_intern_str(db, dupeZ(u.name)), u.uid, dl_intern_str(db, dupeZ(gcsv.slice())) };
        addFact(db, "user", &cols);
    }

    if (dl_txn_commit(db) != 0) {
        std.debug.print("fx-activate: dl_txn_commit failed\n", .{});
        _ = dl_txn_rollback(db);
        std.process.exit(1);
    }

    if (fx_store_publish(s, &cerr, cerr.len) != 0) {
        std.debug.print("fx-activate: publish: {s}\n", .{std.mem.span(cerr_z)});
        std.process.exit(1);
    }
    var v: u32 = 0;
    if (fx_store_current_version(s, &v, &cerr, cerr.len) != 0) {
        std.debug.print("fx-activate: {s}\n", .{std.mem.span(cerr_z)});
        std.process.exit(1);
    }

    out.print("activated {s} as version {d}; buildfile {s}\n", .{ genhash_s, v, buildfile_abs }) catch {};
    out.flush() catch {};
}

// ─── unit tests ───────────────────────────────────────────────────────────

const testing = std.testing;

// S2 gate: the extern structs must EXACTLY mirror fxstore.h:54-107 — load a
// real package set through the vendored C loader and read every field back;
// a slipped field order corrupts memory silently.
test "extern-struct layout round-trip through the real C loader" {
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
    // tmpDir lives at <cwd>/.zig-cache/tmp/<sub_path>; the C loader takes a
    // filesystem path (realpath resolves it against the cwd).
    var ps_path_buf: [256]u8 = undefined;
    const ps_path = try std.fmt.bufPrint(&ps_path_buf, ".zig-cache/tmp/{s}/package-set.dhall", .{tmp.sub_path});
    const ps_z = try testing.allocator.dupeZ(u8, ps_path);
    defer testing.allocator.free(ps_z);

    var ps: PackageSet = undefined;
    var err: [4096]u8 = undefined;
    try testing.expectEqual(@as(c_int, 0), fx_packageset_load(&ps, ps_z.ptr, &err, err.len));
    defer fx_packageset_free(&ps);

    try testing.expectEqual(@as(c_int, 2), ps.count);
    const alpha = ps.head.?;
    try testing.expectEqualStrings("alpha", std.mem.span(alpha.name.?));
    try testing.expectEqualStrings("1.0", std.mem.span(alpha.version.?));
    try testing.expectEqual(SrcKind.path, alpha.src.kind);
    try testing.expect(alpha.src.path != null);
    // relative src paths canonicalize (realpath) against the package-set's dir
    try testing.expect(std.mem.endsWith(u8, std.mem.span(alpha.src.path.?), "src/alpha"));
    try testing.expectEqual(@as(c_int, 0), alpha.ndeps);
    try testing.expectEqualStrings("alpha.bin", std.mem.span(alpha.target.?));

    const beta = alpha.next.?;
    try testing.expectEqualStrings("beta", std.mem.span(beta.name.?));
    try testing.expectEqual(@as(c_int, 1), beta.ndeps);
    try testing.expectEqualStrings("alpha", std.mem.span(beta.deps.?[0].?));
    try testing.expectEqual(SrcKind.path, beta.src.kind);
    try testing.expectEqualStrings("beta.bin", std.mem.span(beta.target.?));

    try testing.expect(fx_find_package(&ps, "beta") == beta);
    try testing.expect(fx_find_package(&ps, "ghost") == null);
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
    // extern-struct literal: string literals need an explicit many-pointer
    // cast through [*:0]const u8 (no direct *const [N:0]u8 -> ?[*:0]u8).
    const z = struct {
        fn z(comptime s: anytype) [*:0]u8 {
            return @as([*:0]u8, @constCast(s));
        }
    }.z;
    var pkg_aa = Package{
        .name = z("aa"),
        .version = null,
        .src = .{ .kind = .path, .path = null, .url = null, .hash = null },
        .deps = null,
        .ndeps = 0,
        .excludes = null,
        .nexcludes = 0,
        .target = null,
        .recipe = null,
        .next = null,
    };
    var pkg_bb = Package{
        .name = z("bb"),
        .version = null,
        .src = .{ .kind = .fetch, .path = null, .url = null, .hash = null },
        .deps = null,
        .ndeps = 0,
        .excludes = null,
        .nexcludes = 0,
        .target = null,
        .recipe = null,
        .next = null,
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
    const bin = [_]BinLink{.{ .name = "tool", .storedir = "/store/44-tool" }};
    try emitBuildfile(&b, "/G", &etc, &bin);
    const out = b.slice();

    try testing.expect(std.mem.startsWith(u8, out, "let Action =\n      < Shell : Text\n"));
    try testing.expect(std.mem.indexOf(u8, out, "let GEN = \"/G\"\n\nin  { default = \"rootfs\"\n") != null);
    // dirs target: 4 Mkdirs, phony
    try testing.expect(std.mem.indexOf(u8, out, "< Mkdir = < Parents = { path = \"/run/fx\", parents = True } > >\n") != null);
    // etc: Copy from GEN + Chmod 0644
    try testing.expect(std.mem.indexOf(u8, out, "< Copy = { from = \"/G/etc/m\", to = \"/etc/m\" } >\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, ", < Chmod = { path = \"/etc/m\", mode = \"0644\" } >\n") != null);
    // bin: Rm guard before Symlink (dhake bare symlink fails EEXIST)
    try testing.expect(std.mem.indexOf(u8, out, "< Rm = < Plain = \"/bin/tool\" > >\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, ", < Symlink = { from = \"/store/44-tool\", to = \"/bin/tool\" } >\n") != null);
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
