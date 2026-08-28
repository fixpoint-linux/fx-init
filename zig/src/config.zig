// config.zig — faithful Zig port of src/config.c (U-A): evaluate a Dhall
// config.dhall and walk its normal form into an FxConfig.
//
// Pipeline mirrors fx_packageset_load (packageset.c) exactly:
//     read_all -> arena_reset(dhall_arena) -> ImportLoader+push_root
//     -> parse_source -> infer_type [WARNING-only] -> normalize
//     -> structural walk (rec_get / term_text_cstr / TmCons chains /
//        TmUnionLit selected alt / TmConst Natural / TmSome|TmNone).
//
// All fx_err error strings are VERBATIM from config.c.  Memory model: the C
// walks malloc'd strings out of the per-run dhall arena and frees them in
// fx_config_free; here config strings live in the dhall arena (reset per
// load, like the C resets dhall_arena) and walker scratch lives in a gpa
// that is drained after each load (subsuming fx_config_free).
const std = @import("std");
const dh = @import("dhall");
/// Parser/DhallError live in the facade's own namespace (dhall.zig), NOT
/// re-exported through dhall_mod's `pub const` surface.
const dhallz = dh.dhall;
const dhall = dh;

const ast = dhall.ast;
const parser = dhall.parser;
const typecheck = dhall.typecheck;
const normalize = dhall.normalize;
const import_mod = dhall.import_mod;
const arena = dhall.arena;

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

// ─── on= readiness grammar (fx.h) ─────────────────────────────────────────

pub const FxOnKind = enum(u8) {
    all,
    up,
    sock_tcp,
    sock_unix,
    time,
    net,

    pub fn name(k: FxOnKind) []const u8 {
        return switch (k) {
            .all => "FX_ON_ALL",
            .up => "FX_ON_UP",
            .sock_tcp => "FX_ON_SOCK_TCP",
            .sock_unix => "FX_ON_SOCK_UNIX",
            .time => "FX_ON_TIME",
            .net => "FX_ON_NET",
        };
    }
};

pub const FxProbeKind = enum(u8) {
    none,
    tcp,
    unix,
    file,

    pub fn name(k: FxProbeKind) []const u8 {
        return switch (k) {
            .none => "FX_PROBE_NONE",
            .tcp => "FX_PROBE_TCP",
            .unix => "FX_PROBE_UNIX",
            .file => "FX_PROBE_FILE",
        };
    }
};

pub const FxRestart = enum(u8) {
    always,
    on_failure,
    never,

    pub fn name(r: FxRestart) []const u8 {
        return switch (r) {
            .always => "FX_RESTART_ALWAYS",
            .on_failure => "FX_RESTART_ON_FAILURE",
            .never => "FX_RESTART_NEVER",
        };
    }
};

pub const FxEnv = struct {
    key: []const u8,
    value: []const u8,
};

pub const FxService = struct {
    name: []const u8,
    argv: []const []const u8,
    pkg: ?[]const u8,
    on_kind: FxOnKind,
    on_arg: ?[]const u8,
    restart: FxRestart,
    backoff_ms: u32, // default 1000
    probe_kind: FxProbeKind,
    probe_arg: ?[]const u8,
    env: []const FxEnv,
};

pub const FxUser = struct {
    name: []const u8,
    uid: u32,
    groups: []const []const u8,
};

pub const FxEtcFile = struct {
    path: []const u8, // relative under etc/, no ..
    content: []const u8,
};

pub const FxConfig = struct {
    hostname: []const u8,
    packages: []const []const u8,
    users: []const FxUser,
    services: []const FxService,
    extra_etc: []const FxEtcFile,
    grace_ms: u32, // default 30000
};

pub const err_cap_default = 2048;

/// The fx_err helper (vendor/fxstore/fxstore.h) as a context struct: the C
/// threads `char *err, size_t errcap` through every walker and signals
/// failure by return value; here every failure path calls ErrBuf.set (with
/// the verbatim format string) and returns error.FxConfig.
pub const ErrBuf = struct {
    buf: [err_cap_default]u8 = undefined,
    len: usize = 0,

    /// fx_err(err, errcap, fmt, ...): vsnprintf into the buffer (truncating,
    /// like the C) and always "fail".
    pub fn set(self: *ErrBuf, comptime fmt: []const u8, args: anytype) error{FxConfig} {
        var aw: std.Io.Writer.Allocating = .init(gpa_alloc);
        defer aw.deinit();
        aw.writer.print(fmt, args) catch unreachable;
        const s = aw.written();
        const n = @min(s.len, self.buf.len - 1);
        @memcpy(self.buf[0..n], s[0..n]);
        self.buf[n] = 0;
        self.len = n;
        return error.FxConfig;
    }

    pub fn slice(self: *const ErrBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

// ─── Term-tree helpers (verbatim semantics from packageset.c) ──────────────

/// The C error-context builder (config.c:242,299): snprintf into char
/// where[160], i.e. "<kind> '<name>'" truncated to 159 bytes — a long name
/// also loses the closing quote (snprintf truncates the whole output).
fn alloc_where(
    a: std.mem.Allocator,
    kind: []const u8,
    name: []const u8,
    e: *ErrBuf,
) error{FxConfig}![]const u8 {
    const full = std.fmt.allocPrint(a, "{s} '{s}'", .{ kind, name }) catch
        return e.set("out of memory", .{});
    defer a.free(full);
    return a.dupe(u8, full[0..@min(full.len, 159)]) catch
        e.set("out of memory", .{});
}

fn rec_get(t: ?*dhallz.Term, label: []const u8) ?*dhallz.Term {
    const tt = t orelse return null;
    if (tt.tag != .TmRecordLit) return null;
    for (0..@intCast(tt.as.rec.n)) |i| {
        if (std.mem.eql(u8, std.mem.span(tt.as.rec.fs.?[i].label.?), label))
            return tt.as.rec.fs.?[i].value;
    }
    return null;
}

/// term_text_cstr: concatenated literal chunks; null on stuck interpolation
/// or a non-Text term.
fn term_text_cstr(t: ?*dhallz.Term) ?[]const u8 {
    const tt = t orelse return null;
    if (tt.tag != .TmText) return null;
    var len: usize = 0;
    var p: ?*dhallz.TextPart = tt.as.text;
    while (p) |part| : (p = part.next) {
        if (part.expr != null) return null; // stuck interpolation
        if (part.lit) |lit| len += std.mem.span(lit).len;
    }
    if (len == 0) return "";
    // C term_text_cstr mallocs (config.c:50), so every config owns its
    // strings independently and they survive the next load (freed only by
    // fx_config_free).  Allocate with c_allocator — NOT the shared dhall
    // arena, whose arena_reset on the next load would invalidate them.
    const out = gpa_alloc.alloc(u8, len) catch return null;
    var i: usize = 0;
    p = tt.as.text;
    while (p) |part| : (p = part.next) {
        if (part.lit) |lit| {
            const l = std.mem.span(lit);
            @memcpy(out[i .. i + l.len], l);
            i += l.len;
        }
    }
    return out;
}

fn union_selected(u: ?*dhallz.Term) ?*dhallz.Field {
    const uu = u orelse return null;
    if (uu.tag != .TmUnionLit) return null;
    for (0..@intCast(uu.as.uni.n)) |i| {
        if (uu.as.uni.fs.?[i].value != null) return &uu.as.uni.fs.?[i];
    }
    return null;
}

fn list_length(list: ?*dhallz.Term) usize {
    var n: usize = 0;
    var p = list;
    while (p) |t| : (p = t.as.cons.tail) {
        if (t.tag != .TmCons) break;
        n += 1;
    }
    return n;
}

fn need_text(rec: ?*dhallz.Term, label: []const u8, where: []const u8, e: *ErrBuf) error{FxConfig}![]const u8 {
    const f = rec_get(rec, label) orelse
        return e.set("{s}: missing field '{s}'", .{ where, label });
    return term_text_cstr(f) orelse
        return e.set("{s}: field '{s}' must be Text", .{ where, label });
}

/// Extract a Natural literal as a u32 (rejects > UINT32_MAX and bignums).
/// dhall represents small naturals as TmConst with kind==C_NAT and .nat
/// (no bnat).
fn need_nat(rec: ?*dhallz.Term, label: []const u8, where: []const u8, out: *u32, e: *ErrBuf) error{FxConfig}!void {
    const f = rec_get(rec, label) orelse
        return e.set("{s}: missing field '{s}'", .{ where, label });
    if (f.tag != .TmConst or f.as.c.kind != .C_NAT)
        return e.set("{s}: field '{s}' must be a Natural literal", .{ where, label });
    if (f.as.c.bnat != null)
        return e.set("{s}: field '{s}' exceeds 32-bit Natural range", .{ where, label });
    if (f.as.c.nat > std.math.maxInt(u32))
        return e.set("{s}: field '{s}' exceeds 32-bit Natural range", .{ where, label });
    out.* = @intCast(f.as.c.nat);
}

/// Optional Text field: null if absent/None, else the string.  Error on a
/// malformed present value (the C's -1).
fn opt_text(rec: ?*dhallz.Term, label: []const u8, e: *ErrBuf, where: []const u8) error{FxConfig}!?[]const u8 {
    var f = rec_get(rec, label) orelse return null; // absent
    if (f.tag == .TmNone) return null;
    if (f.tag == .TmSome) f = f.as.some.val.?;
    return term_text_cstr(f) orelse
        return e.set("{s}: field '{s}' must be Optional Text", .{ where, label });
}

fn opt_nat(rec: ?*dhallz.Term, label: []const u8, e: *ErrBuf, where: []const u8) error{FxConfig}!?u32 {
    var f = rec_get(rec, label) orelse return null;
    if (f.tag == .TmNone) return null;
    if (f.tag == .TmSome) f = f.as.some.val.?;
    if (f.tag != .TmConst or f.as.c.kind != .C_NAT)
        return e.set("{s}: field '{s}' must be Optional Natural", .{ where, label });
    if (f.as.c.bnat != null or f.as.c.nat > std.math.maxInt(u32))
        return e.set("{s}: field '{s}' exceeds 32-bit Natural range", .{ where, label });
    return @intCast(f.as.c.nat);
}

// ─── on= grammar parser ────────────────────────────────────────────────────

const OnParsed = struct {
    kind: FxOnKind,
    arg: ?[]const u8,
};

/// C strtoul(s, &end, 10) semantics: skips leading isspace, optional +/-,
/// base-10 digits, must consume the WHOLE string (the C checks *end), ERANGE
/// saturation to ULONG_MAX (nonzero -> accepted by the C), negation wraps
/// modulo 2^64.  Returns null when strtoul would set end == s (no conversion).
fn strtoul_mirror(v: []const u8) ?u64 {
    var i: usize = 0;
    while (i < v.len and std.ascii.isWhitespace(v[i])) : (i += 1) {}
    var neg = false;
    if (i < v.len and (v[i] == '+' or v[i] == '-')) {
        neg = v[i] == '-';
        i += 1;
    }
    if (i == v.len) return null; // no digits: *end == s -> reject
    var acc: u64 = 0;
    var sat = false;
    while (i < v.len) : (i += 1) {
        const c = v[i];
        if (c < '0' or c > '9') break; // trailing garbage: *end != '\0' -> reject
        const d: u64 = c - '0';
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
    if (i != v.len) return null; // stopped before the end: *end != '\0'
    return if (neg) 0 -% acc else acc;
}

fn parse_on(s: []const u8, where: []const u8, e: *ErrBuf) error{FxConfig}!OnParsed {
    if (std.mem.eql(u8, s, "all")) return .{ .kind = .all, .arg = null };
    if (std.mem.eql(u8, s, "net")) return .{ .kind = .net, .arg = null };
    if (std.mem.startsWith(u8, s, "up:")) {
        if (s.len == 3)
            return e.set("{s}: on=up: requires a service name", .{where});
        return .{ .kind = .up, .arg = s[3..] };
    }
    if (std.mem.startsWith(u8, s, "time:")) {
        const v = s[5..];
        if (v.len == 0)
            return e.set("{s}: on=time: requires a millisecond count", .{where});
        const m = strtoul_mirror(v) orelse
            return e.set("{s}: on=time: '{s}' is not a positive integer ms", .{ where, v });
        if (m == 0)
            return e.set("{s}: on=time: '{s}' is not a positive integer ms", .{ where, v });
        return .{ .kind = .time, .arg = v };
    }
    if (std.mem.startsWith(u8, s, "sock:tcp:")) {
        const v = s[9..];
        if (v.len == 0)
            return e.set("{s}: on=sock:tcp: requires a port", .{where});
        const p = strtoul_mirror(v) orelse
            return e.set("{s}: on=sock:tcp: '{s}' is not a valid port", .{ where, v });
        if (p == 0 or p > 65535)
            return e.set("{s}: on=sock:tcp: '{s}' is not a valid port", .{ where, v });
        return .{ .kind = .sock_tcp, .arg = v };
    }
    if (std.mem.startsWith(u8, s, "sock:unix:")) {
        const v = s[10..];
        if (v.len == 0 or v[0] != '/')
            return e.set("{s}: on=sock:unix: requires an absolute path", .{where});
        return .{ .kind = .sock_unix, .arg = v };
    }
    return e.set("{s}: invalid on= '{s}' (expected all | up:<svc> | sock:tcp:<port> | sock:unix:<path> | time:<ms> | net)", .{ where, s });
}

// ─── Probe union: < Tcp : Natural | Unix : Text | File : Text > ─────────────

fn map_probe(svc: *FxService, u_in: ?*dhallz.Term, where: []const u8, e: *ErrBuf) error{FxConfig}!void {
    svc.probe_kind = .none;
    svc.probe_arg = null;
    var u = u_in;
    if (u == null) return;
    if (u.?.tag == .TmNone) return;
    if (u.?.tag == .TmSome) u = u.?.as.some.val;
    if (u == null or u.?.tag != .TmUnionLit)
        return e.set("{s}: probe must be < Tcp : Natural | Unix : Text | File : Text >", .{where});
    const sel = union_selected(u) orelse
        return e.set("{s}: malformed probe union", .{where});
    const label = std.mem.span(sel.label.?);
    if (std.mem.eql(u8, label, "Tcp")) {
        const v = sel.value.?;
        if (v.tag != .TmConst or v.as.c.kind != .C_NAT or
            v.as.c.bnat != null or v.as.c.nat > 65535 or v.as.c.nat == 0)
            return e.set("{s}: probe Tcp requires a Natural port 1..65535", .{where});
        svc.probe_kind = .tcp;
        svc.probe_arg = std.fmt.allocPrint(gpa_alloc, "{d}", .{v.as.c.nat}) catch
            return e.set("out of memory", .{});
    } else if (std.mem.eql(u8, label, "Unix")) {
        const p = term_text_cstr(sel.value) orelse
            return e.set("{s}: probe Unix requires an absolute path", .{where});
        if (p.len == 0 or p[0] != '/')
            return e.set("{s}: probe Unix requires an absolute path", .{where});
        svc.probe_kind = .unix;
        svc.probe_arg = p;
    } else if (std.mem.eql(u8, label, "File")) {
        const p = term_text_cstr(sel.value) orelse
            return e.set("{s}: probe File requires an absolute path", .{where});
        if (p.len == 0 or p[0] != '/')
            return e.set("{s}: probe File requires an absolute path", .{where});
        svc.probe_kind = .file;
        svc.probe_arg = p;
    } else {
        return e.set("{s}: unknown probe alternative '< {s} = ... >'", .{ where, label });
    }
}

// ─── env list walker: Optional (List { key : Text, value : Text }) ─────────

fn map_env(svc: *FxService, list_in: ?*dhallz.Term, where: []const u8, e: *ErrBuf) error{FxConfig}!void {
    var list = list_in;
    if (list == null or list.?.tag == .TmNone) {
        svc.env = &.{};
        return;
    }
    if (list.?.tag == .TmSome) list = list.?.as.some.val;
    if (list.?.tag == .TmNil) {
        svc.env = &.{};
        return;
    }
    if (list.?.tag != .TmCons)
        return e.set("{s}: env must be a List {{ key, value }}", .{where});
    const n = list_length(list);
    if (n == 0) {
        svc.env = &.{};
        return;
    }
    const env = gpa_alloc.alloc(FxEnv, n) catch
        return e.set("out of memory", .{});
    var i: usize = 0;
    var q = list;
    while (q) |t| : (q = t.as.cons.tail) {
        if (t.tag != .TmCons) break;
        const item = t.as.cons.head;
        if (item == null or item.?.tag != .TmRecordLit)
            return e.set("{s}: env entries must be {{ key, value }} records", .{where});
        const k = try need_text(item, "key", where, e);
        const v = try need_text(item, "value", where, e);
        env[i] = .{ .key = k, .value = v };
        i += 1;
    }
    svc.env = env[0..i];
}

// ─── Service record walker ──────────────────────────────────────────────────

fn map_service(svc: *FxService, rec: ?*dhallz.Term, e: *ErrBuf) error{FxConfig}!void {
    svc.* = .{
        .name = "",
        .argv = &.{},
        .pkg = null,
        .on_kind = .all,
        .on_arg = null,
        .restart = .always,
        .backoff_ms = 1000,
        .probe_kind = .none,
        .probe_arg = null,
        .env = &.{},
    };

    svc.name = try need_text(rec, "name", "service", e);
    // C builds the error context in char where[160] via snprintf
    // (config.c:242), so long names are truncated to 149 chars there.
    const where = try alloc_where(gpa_alloc, "service", svc.name, e);

    const argv_t = rec_get(rec, "argv") orelse
        return e.set("{s}: missing field 'argv'", .{where});
    if (argv_t.tag != .TmNil and argv_t.tag != .TmCons)
        return e.set("{s}: 'argv' must be a List Text", .{where});
    const na = list_length(argv_t);
    if (na == 0)
        return e.set("{s}: argv must be non-empty", .{where});
    const argv = gpa_alloc.alloc([]const u8, na) catch
        return e.set("out of memory", .{});
    var i: usize = 0;
    var q: ?*dhallz.Term = argv_t;
    while (q) |t| : (q = t.as.cons.tail) {
        if (t.tag != .TmCons) break;
        const a = term_text_cstr(t.as.cons.head) orelse
            return e.set("{s}: argv elements must be Text", .{where});
        argv[i] = a;
        i += 1;
    }
    svc.argv = argv[0..i];

    svc.pkg = try opt_text(rec, "pkg", e, where);

    const on_s = try need_text(rec, "on", where, e);
    const on = try parse_on(on_s, where, e);
    svc.on_kind = on.kind;
    svc.on_arg = on.arg;

    if (try opt_text(rec, "restart", e, where)) |rst| {
        if (std.mem.eql(u8, rst, "always")) {
            svc.restart = .always;
        } else if (std.mem.eql(u8, rst, "on-failure")) {
            svc.restart = .on_failure;
        } else if (std.mem.eql(u8, rst, "never")) {
            svc.restart = .never;
        } else {
            return e.set("{s}: restart '{s}' not in {{always,on-failure,never}}", .{ where, rst });
        }
    }

    if (try opt_nat(rec, "backoffMs", e, where)) |bo| svc.backoff_ms = bo;

    const probe_t = rec_get(rec, "probe");
    if (probe_t) |pt| try map_probe(svc, pt, where, e);

    const env_t = rec_get(rec, "env");
    if (env_t) |et| try map_env(svc, et, where, e);
}

// ─── User record walker ─────────────────────────────────────────────────────

fn map_user(u: *FxUser, rec: ?*dhallz.Term, e: *ErrBuf) error{FxConfig}!void {
    u.* = .{ .name = "", .uid = 0, .groups = &.{} };

    u.name = try need_text(rec, "name", "user", e);
    const where = try alloc_where(gpa_alloc, "user", u.name, e);
    try need_nat(rec, "uid", where, &u.uid, e);

    const groups = rec_get(rec, "groups") orelse
        return e.set("{s}: missing field 'groups'", .{where});
    if (groups.tag != .TmNil and groups.tag != .TmCons)
        return e.set("{s}: 'groups' must be a List Text", .{where});
    const n = list_length(groups);
    const gs = gpa_alloc.alloc([]const u8, n) catch
        return e.set("out of memory", .{});
    var i: usize = 0;
    var q: ?*dhallz.Term = groups;
    while (q) |t| : (q = t.as.cons.tail) {
        if (t.tag != .TmCons) break;
        const g = term_text_cstr(t.as.cons.head) orelse
            return e.set("{s}: group names must be Text", .{where});
        gs[i] = g;
        i += 1;
    }
    u.groups = gs[0..i];
}

// ─── extraEtc: Optional (List { path, content }) ──────────────────────────

fn map_extra_etc(cfg: *FxConfig, list_in: ?*dhallz.Term, e: *ErrBuf) error{FxConfig}!void {
    var list = list_in;
    if (list == null or list.?.tag == .TmNone) {
        cfg.extra_etc = &.{};
        return;
    }
    if (list.?.tag == .TmSome) list = list.?.as.some.val;
    if (list.?.tag == .TmNil) {
        cfg.extra_etc = &.{};
        return;
    }
    if (list.?.tag != .TmCons)
        return e.set("extraEtc must be a List {{ path, content }}", .{});
    const n = list_length(list);
    const files = gpa_alloc.alloc(FxEtcFile, n) catch
        return e.set("out of memory", .{});
    var i: usize = 0;
    var q = list;
    while (q) |t| : (q = t.as.cons.tail) {
        if (t.tag != .TmCons) break;
        const item = t.as.cons.head;
        if (item == null or item.?.tag != .TmRecordLit)
            return e.set("extraEtc entries must be {{ path, content }} records", .{});
        const p = try need_text(item, "path", "extraEtc", e);
        // clean relative path under etc/, no .. (config.c:339-343)
        if (p.len == 0 or p[0] == '/' or
            std.mem.indexOf(u8, p, "..") != null or
            std.mem.eql(u8, p, ".") or
            std.mem.indexOf(u8, p, "//") != null or
            p[p.len - 1] == '/')
        {
            return e.set("extraEtc path '{s}' must be a clean relative path under etc/", .{p});
        }
        const c = try need_text(item, "content", "extraEtc", e);
        files[i] = .{ .path = p, .content = c };
        i += 1;
    }
    cfg.extra_etc = files[0..i];
}

// ─── Validation pass (cross-field) ──────────────────────────────────────────

fn validate(cfg: *FxConfig, e: *ErrBuf) error{FxConfig}!void {
    // unique service names + up:<svc> targets exist
    for (cfg.services, 0..) |*s, i| {
        for (cfg.services[0..i]) |*j| {
            if (std.mem.eql(u8, s.name, j.name))
                return e.set("duplicate service name '{s}'", .{s.name});
        }
        if (s.on_kind == .up) {
            var found = false;
            for (cfg.services) |*k| {
                if (std.mem.eql(u8, k.name, s.on_arg.?)) {
                    found = true;
                    break;
                }
            }
            if (!found)
                return e.set("service '{s}': on=up:'{s}' references an unknown service", .{ s.name, s.on_arg.? });
        }
    }
    // unique uids
    for (cfg.users, 0..) |*u, i| {
        for (cfg.users[0..i]) |*j| {
            if (u.uid == j.uid)
                return e.set("duplicate uid {d} (users '{s}' and '{s}')", .{ u.uid, j.name, u.name });
        }
    }
}

// ─── Structural walk ────────────────────────────────────────────────────────

fn build_config(out: *FxConfig, nf: ?*dhallz.Term, e: *ErrBuf) error{FxConfig}!void {
    out.* = .{
        .hostname = "",
        .packages = &.{},
        .users = &.{},
        .services = &.{},
        .extra_etc = &.{},
        .grace_ms = 30000,
    };
    const rec = nf orelse
        return e.set("config must be a record {{ hostname, packages, users, services, ... }}", .{});
    if (rec.tag != .TmRecordLit)
        return e.set("config must be a record {{ hostname, packages, users, services, ... }}", .{});

    out.hostname = try need_text(rec, "hostname", "config", e);

    const pkgs = rec_get(rec, "packages") orelse
        return e.set("config missing 'packages'", .{});
    if (pkgs.tag != .TmNil and pkgs.tag != .TmCons)
        return e.set("config 'packages' must be a List Text", .{});
    var pkg_list: std.ArrayList([]const u8) = .empty;
    var q: ?*dhallz.Term = pkgs;
    while (q) |t| : (q = t.as.cons.tail) {
        if (t.tag != .TmCons) break;
        const p = term_text_cstr(t.as.cons.head) orelse
            return e.set("config: package names must be Text", .{});
        pkg_list.append(gpa_alloc, p) catch return e.set("out of memory", .{});
    }
    out.packages = pkg_list.items;

    const users = rec_get(rec, "users") orelse
        return e.set("config missing 'users'", .{});
    if (users.tag != .TmNil and users.tag != .TmCons)
        return e.set("config 'users' must be a List User", .{});
    var user_list: std.ArrayList(FxUser) = .empty;
    q = users;
    while (q) |t| : (q = t.as.cons.tail) {
        if (t.tag != .TmCons) break;
        var u: FxUser = undefined;
        try map_user(&u, t.as.cons.head, e);
        user_list.append(gpa_alloc, u) catch return e.set("out of memory", .{});
    }
    out.users = user_list.items;

    const svcs = rec_get(rec, "services") orelse
        return e.set("config missing 'services'", .{});
    if (svcs.tag != .TmNil and svcs.tag != .TmCons)
        return e.set("config 'services' must be a List Service", .{});
    var svc_list: std.ArrayList(FxService) = .empty;
    q = svcs;
    while (q) |t| : (q = t.as.cons.tail) {
        if (t.tag != .TmCons) break;
        var s: FxService = undefined;
        try map_service(&s, t.as.cons.head, e);
        svc_list.append(gpa_alloc, s) catch return e.set("out of memory", .{});
    }
    out.services = svc_list.items;

    const etc = rec_get(rec, "extraEtc");
    if (etc) |et| try map_extra_etc(out, et, e);

    if (try opt_nat(rec, "bootGraceMs", e, "config")) |g| out.grace_ms = g;

    return validate(out, e);
}

// ─── Evaluation pipeline (fx_packageset_load pattern) ───────────────────────

// libc is linked; use the C malloc allocator (std.c.malloc) — simplest
// correct allocator for a process-lifetime CLI (see dhall-c/zig main.zig).
const gpa_alloc = std.heap.c_allocator;

pub const LoadError = error{ FxConfig, OutOfMemory };

/// fx_config_load — on success `out` holds the config (borrowing dhall-arena
/// memory + c_allocator scratch; the C frees the same strings in
/// fx_config_free — a CLI process-lifetime leak of equal size, noted in the
/// unit report); on error returns error.FxConfig with `e` holding the
/// verbatim config.c error string.
pub fn fx_config_load(out: *FxConfig, path: []const u8, e: *ErrBuf) LoadError!void {
    var path_buf: [4096:0]u8 = undefined;
    if (path.len >= path_buf.len)
        return e.set("cannot open config '{s}': File name too long", .{path});
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);

    const f = std.c.fopen(path_z, "rb") orelse {
        const msg = strerror(std.c._errno().*);
        return e.set("cannot open config '{s}': {s}", .{ path, std.mem.span(msg) });
    };
    defer _ = std.c.fclose(f);

    // read_all (config.c:448-460)
    var src_list: std.ArrayList(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        src_list.appendSlice(gpa_alloc, chunk[0..n]) catch
            return e.set("out of memory reading '{s}'", .{path});
        if (n < chunk.len) break;
    }
    defer src_list.deinit(gpa_alloc);

    if (arena.dhall_arena == null) arena.dhall_arena = arena.arena_new();
    arena.arena_reset(arena.dhall_arena.?);

    const loader = import_mod.import_loader_new();
    defer import_mod.import_loader_free(loader);
    import_mod.import_loader_push_root(loader, path_z);

    var p: dhallz.Parser = std.mem.zeroes(dhallz.Parser);
    p.loader = loader;
    var derr: dhallz.DhallError = undefined;
    ast.dhall_error_clear(&derr);

    const src_z = gpa_alloc.dupeZ(u8, src_list.items) catch
        return e.set("out of memory reading '{s}'", .{path});
    defer gpa_alloc.free(src_z);

    const t = parser.parse_source(&p, src_z.ptr, path_z, &derr);
    if (t == null)
        return e.set("config parse error: {s}", .{std.mem.sliceTo(&derr.msg, 0)});

    // typecheck is WARNING-only: print the same block to stderr and continue
    // (config.c:487-492).
    const ty = typecheck.infer_type(&p, t.?, &derr);
    if (ty == null) {
        std.debug.print(
            "fx: warning: config does not typecheck (structural walk continues):\n  {s}\n",
            .{std.mem.sliceTo(&derr.msg, 0)},
        );
    }

    normalize.normalize_clear_error();
    const nf = normalize.normalize(t.?);
    if (normalize.normalize_has_error()) {
        derr = normalize.normalize_get_error().*;
        return e.set("config normalize error: {s}", .{std.mem.sliceTo(&derr.msg, 0)});
    }

    return build_config(out, nf, e);
}

// ─── unit tests (on= grammar + extraEtc path rules) ────────────────────────

const testing = std.testing;

test "parse_on grammar" {
    var e = ErrBuf{};
    const w = "service 'x'";

    try testing.expectEqual(OnParsed{ .kind = .all, .arg = null }, try parse_on("all", w, &e));
    try testing.expectEqual(OnParsed{ .kind = .net, .arg = null }, try parse_on("net", w, &e));

    const up = try parse_on("up:heartbeat", w, &e);
    try testing.expectEqual(FxOnKind.up, up.kind);
    try testing.expectEqualStrings("heartbeat", up.arg.?);

    const tcp = try parse_on("sock:tcp:8080", w, &e);
    try testing.expectEqual(FxOnKind.sock_tcp, tcp.kind);
    try testing.expectEqualStrings("8080", tcp.arg.?);

    const uni = try parse_on("sock:unix:/run/x.sock", w, &e);
    try testing.expectEqual(FxOnKind.sock_unix, uni.kind);
    try testing.expectEqualStrings("/run/x.sock", uni.arg.?);

    const tm = try parse_on("time:250", w, &e);
    try testing.expectEqual(FxOnKind.time, tm.kind);
    try testing.expectEqualStrings("250", tm.arg.?);

    const bad_ons = [_][]const u8{
        "up:",     "time:",     "time:0",     "time:1x",
        "time:-0", "sock:tcp:", "sock:tcp:0", "sock:tcp:65536",
        "sock:",   "sock:unix:rel", "sock:unix:",  "garbage",
        "",        "ALL",
    };
    // ACCEPTED by the C too (verified against the oracle; now corpus cases):
    // "time:-1" (strtoul wraps to ULONG_MAX, nonzero) and "up:heart beat"
    // (any non-empty suffix is a service name).
    for (bad_ons) |s| {
        e = .{};
        try testing.expectError(error.FxConfig, parse_on(s, w, &e));
    }
}

test "two-load independence (C malloc semantics of term_text_cstr)" {
    var e = ErrBuf{};
    var a: FxConfig = undefined;
    var b: FxConfig = undefined;
    // Loading B resets the shared dhall arena; A's strings must survive
    // (each is c_allocator-owned, like the C's malloc'd strings).
    try fx_config_load(&a, "corpus/good.dhall", &e);
    try fx_config_load(&b, "corpus/adv-time-whitespace.dhall", &e);
    try testing.expectEqualStrings("fixbox", a.hostname);
    try testing.expectEqualStrings("heartbeat", a.services[0].name);
    try testing.expect(a.services[0].on_arg == null); // on = "all"
    try testing.expectEqualStrings("x", b.hostname);
    try testing.expectEqualStrings(" 5", b.services[0].on_arg.?);
}

test "clean_etc_path rules (config.c:339-343)" {
    var e = ErrBuf{};
    const bad = [_][]const u8{ "/abs", "a/../b", "..", ".", "", "a//b", "a/", "x/../y" };
    for (bad) |p| {
        e = .{};
        try testing.expectError(error.FxConfig, clean_etc_path(p, &e));
        try testing.expect(e.len > 0);
    }
    const ok = [_][]const u8{ "motd", "a/b/c", "nginx.conf" };
    for (ok) |p| {
        e = .{};
        try clean_etc_path(p, &e);
    }
    // "a..b" contains ".." as a SUBSTRING and must be rejected (strstr
    // semantics — the C rejects it too).
    e = .{};
    try testing.expectError(error.FxConfig, clean_etc_path("a..b", &e));
}

/// The exact extraEtc path predicate from map_extra_etc (config.c:339-343),
/// extracted only for unit testing; map_extra_etc inlines the same check.
fn clean_etc_path(p: []const u8, e: *ErrBuf) error{FxConfig}!void {
    if (p.len == 0 or p[0] == '/' or
        std.mem.indexOf(u8, p, "..") != null or
        std.mem.eql(u8, p, ".") or
        std.mem.indexOf(u8, p, "//") != null or
        p[p.len - 1] == '/')
    {
        return e.set("extraEtc path '{s}' must be a clean relative path under etc/", .{p});
    }
}
