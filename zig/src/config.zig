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
    // M6 console increment: None (null) = the default pipe stdio; Some
    // "console" = attach the service to /dev/console (init.zig's
    // start_service opens it onto the child's 0/1/2 instead of the pipe).
    // The TEXT is kept (not a bool) so the schema stays open for later
    // device names; today only "console" is accepted.
    console: ?[]const u8,
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

// ─── inline packages (baliveau §6a E) ──────────────────────────────────────
//
// The agent's write surface is its CONFIG, so that is where its packages
// are declared: no new file becomes agent-writable, and fx-activate merges
// these into the package set BEFORE computing the closure (a config-declared
// package is resolvable by the same path a host-declared one is).  The
// shapes below mirror the fxstore Package/Src/Action types one-for-one
// (packageset.zig); config.zig cannot import that module (the build wires
// `dhall` only into config_mod), so fx-activate converts at the merge.
//
// The recipe is admitted ONLY as a composition over a HOST-FROZEN Action
// subset — the subset IS the capability (§6a).  Which actions are refused
// and why is decided in validate(), with the other cross-field refusals.

/// The eleven Action alternatives (packageset.zig ActionKind order).  All
/// are parsed; whether an agent may DECLARE one is validate()'s call, not
/// the walker's.
pub const FxPkgActionKind = enum(u8) {
    shell,
    copy,
    mkdir,
    rm,
    touch,
    move,
    symlink,
    chmod,
    echo,
    env,
    run,

    /// The Dhall union tag, as the refusal and the config_check dump name it.
    pub fn name(k: FxPkgActionKind) []const u8 {
        return switch (k) {
            .shell => "Shell",
            .copy => "Copy",
            .mkdir => "Mkdir",
            .rm => "Rm",
            .touch => "Touch",
            .move => "Move",
            .symlink => "Symlink",
            .chmod => "Chmod",
            .echo => "Echo",
            .env => "Env",
            .run => "Run",
        };
    }
};

pub const FxPkgAction = struct {
    kind: FxPkgActionKind,
    a: ?[]const u8 = null, // payload: shell text / from / path / text / key / argv[0]
    b: ?[]const u8 = null, // copy-move-symlink to / chmod mode / env value
    argv: []const []const u8 = &.{}, // Run only
};

pub const FxPkgSrcKind = enum(u8) { path, fetch };

/// Parsed so a Fetch can be REFUSED BY NAME in validate(); an agent-declared
/// package never carries one past validation.
pub const FxPkgSrc = struct {
    kind: FxPkgSrcKind = .path,
    path: ?[]const u8 = null,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
};

pub const FxPackage = struct {
    name: []const u8,
    version: []const u8,
    src: FxPkgSrc = .{},
    deps: []const []const u8 = &.{},
    excludes: []const []const u8 = &.{},
    target: []const u8,
    recipe: []const FxPkgAction = &.{},
};

pub const FxConfig = struct {
    hostname: []const u8,
    packages: []const []const u8,
    users: []const FxUser,
    services: []const FxService,
    // REQUIRED in the config record (the FIELD cannot be omitted —
    // build_config refuses; the VALUE may be None to declare "this system
    // has no agent service").  validate() refuses a named agent that does
    // not exist or is not a console service; see the comment there.
    agent_service: ?[]const u8,
    extra_etc: []const FxEtcFile,
    grace_ms: u32, // default 30000
    // inlinePackages: Optional (List Package), defaulting to empty.  Unlike
    // agentService, its ABSENCE is not a silent hole, so the field is
    // optional like extraEtc: agentService names an EXISTING service whose
    // identity fx-init needs at boot, so forgetting it silently changes
    // boot behavior; a package that is not declared simply does not exist —
    // nothing can name, depend on, or build it, and "no agent-authored
    // packages" is an honest state, not a forgotten obligation.  (A declared
    // package nothing references is equally inert: merged, never closed
    // over, invisible to the generation hash.)
    inline_packages: []const FxPackage = &.{},
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
        .console = null,
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

    // console: Optional Text — None (default) = pipe stdio; only "console"
    // (i.e. /dev/console) is accepted today.  Anything else is an ERROR,
    // not a silent pass-through: a typo'd device name would otherwise boot
    // a service with closed-ish pipe stdio and no hint why.
    if (try opt_text(rec, "console", e, where)) |con| {
        if (!std.mem.eql(u8, con, "console"))
            return e.set("{s}: console '{s}' not in {{console}}", .{ where, con });
        svc.console = con;
    }
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

// ─── inlinePackages: Optional (List Package) — §6a E ──────────────────────
//
// Walker mirrors the packageset.zig Package/Src/Action walk one-for-one
// (rec_get + list traversal + union_selected), because the config must
// produce the same shapes a host-declared package produces.  Structural
// errors are the walker's; the SUBSET refusals (Shell / Run-relative /
// Fetch / deps) are validate()'s, with the other cross-field rules.

/// map_action (packageset.zig) into a config-owned FxPkgAction: every one
/// of the eleven alternatives parses, Shell included — validate() decides
/// what an agent may declare, so a refused action is REFUSED BY NAME with
/// its rule, never a parse accident.
fn map_inline_action(u: ?*dhallz.Term, where: []const u8, e: *ErrBuf) error{FxConfig}!FxPkgAction {
    if (u == null or u.?.tag != .TmUnionLit)
        return e.set("{s}: recipe element must be an Action union (< Tag = v >)", .{where});
    const sel = union_selected(u) orelse
        return e.set("{s}: malformed Action union", .{where});
    const tag = std.mem.span(sel.label.?);
    const val = sel.value.?;
    var act: FxPkgAction = .{ .kind = .shell };
    if (std.mem.eql(u8, tag, "Shell")) {
        act.kind = .shell;
        act.a = term_text_cstr(val) orelse
            return e.set("{s}: < Shell = ... > value must be Text", .{where});
    } else if (std.mem.eql(u8, tag, "Copy")) {
        act.kind = .copy;
        if (val.tag != .TmRecordLit)
            return e.set("{s}: Copy must be a {{ from, to }} record", .{where});
        act.a = try need_text(val, "from", where, e);
        act.b = try need_text(val, "to", where, e);
    } else if (std.mem.eql(u8, tag, "Mkdir")) {
        act.kind = .mkdir;
        act.a = term_text_cstr(val) orelse
            return e.set("{s}: < Mkdir = ... > value must be Text", .{where});
    } else if (std.mem.eql(u8, tag, "Rm")) {
        act.kind = .rm;
        act.a = term_text_cstr(val) orelse
            return e.set("{s}: < Rm = ... > value must be Text", .{where});
    } else if (std.mem.eql(u8, tag, "Touch")) {
        act.kind = .touch;
        act.a = term_text_cstr(val) orelse
            return e.set("{s}: < Touch = ... > value must be Text", .{where});
    } else if (std.mem.eql(u8, tag, "Move")) {
        act.kind = .move;
        if (val.tag != .TmRecordLit)
            return e.set("{s}: Move must be a {{ from, to }} record", .{where});
        act.a = try need_text(val, "from", where, e);
        act.b = try need_text(val, "to", where, e);
    } else if (std.mem.eql(u8, tag, "Symlink")) {
        act.kind = .symlink;
        if (val.tag != .TmRecordLit)
            return e.set("{s}: Symlink must be a {{ from, to }} record", .{where});
        act.a = try need_text(val, "from", where, e);
        act.b = try need_text(val, "to", where, e);
    } else if (std.mem.eql(u8, tag, "Chmod")) {
        act.kind = .chmod;
        if (val.tag != .TmRecordLit)
            return e.set("{s}: Chmod must be a {{ path, mode }} record", .{where});
        act.a = try need_text(val, "path", where, e);
        act.b = try need_text(val, "mode", where, e);
    } else if (std.mem.eql(u8, tag, "Echo")) {
        act.kind = .echo;
        act.a = term_text_cstr(val) orelse
            return e.set("{s}: < Echo = ... > value must be Text", .{where});
    } else if (std.mem.eql(u8, tag, "Env")) {
        act.kind = .env;
        if (val.tag != .TmRecordLit)
            return e.set("{s}: Env must be a {{ key, value }} record", .{where});
        act.a = try need_text(val, "key", where, e);
        act.b = try need_text(val, "value", where, e);
    } else if (std.mem.eql(u8, tag, "Run")) {
        act.kind = .run;
        if (val.tag != .TmRecordLit)
            return e.set("{s}: Run must be a {{ argv : List Text }} record", .{where});
        const argv_list = rec_get(val, "argv") orelse
            return e.set("{s}: Run must have an 'argv' field", .{where});
        const n = list_length(argv_list);
        if (n == 0)
            return e.set("{s}: Run argv must be non-empty", .{where});
        const av = gpa_alloc.alloc([]const u8, n) catch
            return e.set("out of memory", .{});
        var i: usize = 0;
        var p: ?*dhallz.Term = argv_list;
        while (p) |t| : (p = t.as.cons.tail) {
            if (t.tag != .TmCons) break;
            av[i] = term_text_cstr(t.as.cons.head) orelse
                return e.set("{s}: Run argv elements must be Text", .{where});
            i += 1;
        }
        act.argv = av[0..i];
        act.a = act.argv[0]; // program name, like packageset's map_action
    } else {
        return e.set("{s}: unknown action '< {s} = ... >'", .{ where, tag });
    }
    return act;
}

/// map_src (packageset.zig): both alternatives parse; a Fetch is refused in
/// validate() by name, so it must survive the walk.
fn map_inline_src(out: *FxPkgSrc, u: ?*dhallz.Term, where: []const u8, e: *ErrBuf) error{FxConfig}!void {
    out.* = .{ .kind = .path };
    if (u == null or u.?.tag != .TmUnionLit)
        return e.set("{s}: src must be < Path = Text | Fetch = {{ url, hash }} >", .{where});
    const sel = union_selected(u) orelse
        return e.set("{s}: malformed src union", .{where});
    const label = std.mem.span(sel.label.?);
    if (std.mem.eql(u8, label, "Path")) {
        out.kind = .path;
        // RAW text, like the C's strdup: canonicalization of a relative
        // path against the config's directory is fx-activate's job (it
        // knows the config's path; this module does not).
        out.path = term_text_cstr(sel.value) orelse
            return e.set("{s}: < Path = ... > value must be Text", .{where});
    } else if (std.mem.eql(u8, label, "Fetch")) {
        out.kind = .fetch;
        const v = sel.value.?;
        if (v.tag != .TmRecordLit)
            return e.set("{s}: Fetch must be a {{ url, hash }} record", .{where});
        out.url = try need_text(v, "url", where, e);
        out.hash = try need_text(v, "hash", where, e);
    } else {
        return e.set("{s}: unknown src alternative '< {s} = ... >' (expected Path or Fetch)", .{ where, label });
    }
}

/// map_package (packageset.zig) into a config-owned FxPackage.  `excludes`
/// is optional (absent = empty), and its entries follow the same clean-path
/// rules as the package-set walk: an entry that can never match would
/// silently keep hashing content the author meant to exclude.
fn map_inline_package(rec: ?*dhallz.Term, e: *ErrBuf) error{FxConfig}!FxPackage {
    var p: FxPackage = .{ .name = "", .version = "", .target = "" };

    p.name = try need_text(rec, "name", "package", e);
    const where = try alloc_where(gpa_alloc, "package", p.name, e);

    p.version = try need_text(rec, "version", where, e);

    const src_t = rec_get(rec, "src") orelse
        return e.set("{s}: missing field 'src'", .{where});
    try map_inline_src(&p.src, src_t, where, e);

    const deps = rec_get(rec, "deps") orelse
        return e.set("{s}: missing field 'deps'", .{where});
    if (deps.tag != .TmNil and deps.tag != .TmCons)
        return e.set("{s}: 'deps' must be a List Text", .{where});
    const ndeps = list_length(deps);
    const dep_arr = gpa_alloc.alloc([]const u8, ndeps) catch
        return e.set("out of memory", .{});
    var i: usize = 0;
    var q: ?*dhallz.Term = deps;
    while (q) |t| : (q = t.as.cons.tail) {
        if (t.tag != .TmCons) break;
        dep_arr[i] = term_text_cstr(t.as.cons.head) orelse
            return e.set("{s}: dependency name must be Text", .{where});
        i += 1;
    }
    p.deps = dep_arr[0..i];

    if (rec_get(rec, "excludes")) |excl| {
        if (excl.tag != .TmNil and excl.tag != .TmCons)
            return e.set("{s}: 'excludes' must be a List Text", .{where});
        const nexcl = list_length(excl);
        const ex_arr = gpa_alloc.alloc([]const u8, nexcl) catch
            return e.set("out of memory", .{});
        var j: usize = 0;
        var xq: ?*dhallz.Term = excl;
        while (xq) |t| : (xq = t.as.cons.tail) {
            if (t.tag != .TmCons) break;
            const x = term_text_cstr(t.as.cons.head) orelse
                return e.set("{s}: excludes entry must be Text", .{where});
            if (x.len == 0 or x[0] == '/' or
                (x.len >= 2 and x[0] == '.' and x[1] == '/') or
                x[x.len - 1] == '/' or std.mem.indexOf(u8, x, "//") != null or
                std.mem.eql(u8, x, ".") or std.mem.eql(u8, x, ".."))
            {
                return e.set("{s}: excludes entry '{s}' is not a clean relative path within the src tree", .{ where, x });
            }
            ex_arr[j] = x;
            j += 1;
        }
        p.excludes = ex_arr[0..j];
    }

    const build = rec_get(rec, "build") orelse
        return e.set("{s}: missing or non-record 'build' (need {{ target, recipe }})", .{where});
    if (build.tag != .TmRecordLit)
        return e.set("{s}: missing or non-record 'build' (need {{ target, recipe }})", .{where});
    p.target = try need_text(build, "target", where, e);

    const recipe = rec_get(build, "recipe") orelse
        return e.set("{s}: build missing 'recipe'", .{where});
    if (recipe.tag != .TmNil and recipe.tag != .TmCons)
        return e.set("{s}: 'recipe' must be a List Action", .{where});
    const nrec = list_length(recipe);
    const rec_arr = gpa_alloc.alloc(FxPkgAction, nrec) catch
        return e.set("out of memory", .{});
    var k: usize = 0;
    var rq: ?*dhallz.Term = recipe;
    while (rq) |t| : (rq = t.as.cons.tail) {
        if (t.tag != .TmCons) break;
        rec_arr[k] = try map_inline_action(t.as.cons.head, where, e);
        k += 1;
    }
    p.recipe = rec_arr[0..k];
    return p;
}

fn map_inline_packages(cfg: *FxConfig, list_in: ?*dhallz.Term, e: *ErrBuf) error{FxConfig}!void {
    var list = list_in;
    if (list == null or list.?.tag == .TmNone) {
        cfg.inline_packages = &.{};
        return;
    }
    if (list.?.tag == .TmSome) list = list.?.as.some.val;
    if (list.?.tag == .TmNil) {
        cfg.inline_packages = &.{};
        return;
    }
    if (list.?.tag != .TmCons)
        return e.set("inlinePackages must be a List Package", .{});
    var pkg_list: std.ArrayList(FxPackage) = .empty;
    var q = list;
    while (q) |t| : (q = t.as.cons.tail) {
        if (t.tag != .TmCons) break;
        const item = t.as.cons.head;
        if (item == null or item.?.tag != .TmRecordLit)
            return e.set("inlinePackages entries must be Package records", .{});
        const p = try map_inline_package(item, e);
        pkg_list.append(gpa_alloc, p) catch return e.set("out of memory", .{});
    }
    cfg.inline_packages = pkg_list.items;
}

// ─── inline-package subset validation (§6a A/B/D + §6b stance) ────────────
//
// THE SUBSET IS THE CAPABILITY.  An agent-authored recipe is admitted only
// as a composition over a host-frozen Action subset, and every refusal
// below fires AT CONFIG LOAD — which config_check and fx-activate both go
// through, so both refuse with the same message from this one place.  An
// out-of-subset action must never survive to build time: a recipe that is
// only rejected when it runs has already been accepted by the system.

/// The store-dir name predicate, mirroring packageset.zig name_safe (itself
/// the packageset.c:192-199 port).  Duplicated here because config.zig
/// cannot import the fxstore module (build wires `dhall` only into
/// config_mod); store dirs are named "<hex64>-<name>", so a name with '/'
/// or a leading '.' could escape the store root.  packageset.zig's copy
/// remains the authority for the host set; this one guards the inline set.
fn inline_name_safe(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphanumeric(s[0])) return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and
            c != '.' and c != '_' and c != '+' and c != '-') return false;
    }
    return true;
}

fn validate_inline_packages(cfg: *FxConfig, e: *ErrBuf) error{FxConfig}!void {
    // duplicate names: the merge would otherwise let the second silently
    // shadow the first inside the merged set
    for (cfg.inline_packages, 0..) |*p, i| {
        for (cfg.inline_packages[0..i]) |*j| {
            if (std.mem.eql(u8, p.name, j.name))
                return e.set("duplicate inline package name '{s}'", .{p.name});
        }
    }
    for (cfg.inline_packages) |*p| {
        const where = try alloc_where(gpa_alloc, "package", p.name, e);
        if (!inline_name_safe(p.name))
            return e.set("{s}: invalid package name (need [A-Za-z0-9][A-Za-z0-9._+-]*)", .{where});

        // src: a Fetch is network egress, and the guest has none (CONFIG_NET
        // is unset on the pinned kernel) — permitting it would be a
        // capability hole rather than a shortcut.
        if (p.src.kind == .fetch)
            return e.set("{s}: agent-declared package src must be < Path = ... > — Fetch is network egress, the guest has none (CONFIG_NET unset), so a fetch here is a capability hole rather than a shortcut", .{where});

        // deps: the derivation hash serialises each dep's FULL STORE PATH
        // (fxstore derivation.zig: "each direct dep's FULL store path"), so
        // a dep-carrying package hashes differently under every store root.
        // The pre-declared slot (fx-init e825d52) is dependency-free for
        // exactly this property: only a dependency-free package hashes
        // identically wherever it is built and activated.
        if (p.deps.len > 0)
            return e.set("{s}: agent-declared packages must have deps = [] — the derivation hash serialises each dep's FULL STORE PATH, so a dep-carrying package hashes differently under every store root (the pre-declared slot's dependency-freedom is load-bearing, e825d52)", .{where});

        for (p.recipe, 0..) |*act, n| {
            // Shell is `<shell> -c <arbitrary text>` (fxstore build.zig
            // run_shell): ONE action that dissolves every other bound on
            // the recipe — it subsumes the Run rule below and every path
            // action besides.  Host-frozen package sets keep it (their
            // recipes are trusted); agent-declared packages never do, and
            // the split is this refusal.
            if (act.kind == .shell)
                return e.set("{s}: recipe action {d} ({s}) is outside the agent-authorable action subset — Shell is '<shell> -c <arbitrary text>', one action that dissolves every other bound; host-frozen package sets keep it, agent-declared packages do not", .{ where, n, act.kind.name() });

            // Run goes through execvp(argv[0]) and the recipe controls the
            // environment (Env setenv's into the build process, the child
            // prepends to PATH), so a relative argv[0] names a binary the
            // package itself may have supplied.  The substrate already
            // applies exactly this discipline to itself when it execs
            // bwrap: "execvp('bwrap') searches the CURRENT PATH, which
            // recipes control.  The child execs this ABSOLUTE path (no
            // PATH search)" (fxstore build.zig).  Same rule, applied to
            // the agent's recipes.
            if (act.kind == .run) {
                const prog = act.argv[0];
                if (prog.len == 0 or prog[0] != '/')
                    return e.set("{s}: recipe action {d} (Run) argv[0] '{s}' must be an ABSOLUTE path — Run is execvp(argv[0]) and the recipe controls PATH (Env prepends to it), so a relative argv[0] can name a binary the package supplied; the substrate execs bwrap by ABSOLUTE path for exactly this reason", .{ where, n, prog });
            }
        }
        // The remaining actions (Copy Mkdir Rm Touch Move Symlink Chmod Echo
        // Env, and Run with an absolute argv[0]) are ADMITTED — and their
        // REACH IS NOT BOUNDED BY THIS UNIT.  §6a's element (C), confining
        // each action's paths to its build workdir, was downgraded to
        // optional defence-in-depth by §6b (auditing, not proofing: the VM
        // is the boundary, and no kernel sandbox primitive exists in the
        // guest).  What this subset buys is the removal of whole classes of
        // ACCIDENT — an arbitrary shell line, a PATH-shadowed binary,
        // network egress — and a narrower surface to audit, NOT a bound on
        // what an admitted action can touch.  An out-of-bounds write is
        // made VISIBLE by the audit seat (host-side record comparison) and
        // answered by rollback, not prevented here.
    }
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
    // The declared AGENT service must exist and MUST be a console service.
    // fx-init pins 'failed' for a NON-console service that exits during the
    // boot grace window WITHOUT consulting the exit status (init.zig
    // reap_children), and the agent's refusal path deliberately exits 0 — a
    // non-console agent would turn every refusal into a roll-forward
    // oscillator: the pinned failure makes the next boot roll forward to an
    // older ok generation that re-runs the agent, which refuses again.
    // Refusing HERE puts the failure at config-check/activation, where the
    // operator sees it named, instead of as that spiral.  (fx-init itself
    // needs the identity for NOTHING else: the console exemption at boot
    // follows from the service's own console flag.)
    if (cfg.agent_service) |name| {
        var found = false;
        for (cfg.services) |*s| {
            if (!std.mem.eql(u8, s.name, name)) continue;
            found = true;
            if (s.console == null)
                return e.set("agentService '{s}': the agent service must be a console service (console = Some \"console\") — a non-console service that exits during the boot grace window pins the boot failed regardless of exit status, and the agent's refusal path exits 0 by design", .{name});
            break;
        }
        if (!found)
            return e.set("agentService '{s}' references an unknown service", .{name});
    }

    try validate_inline_packages(cfg, e);
}

// ─── Structural walk ────────────────────────────────────────────────────────

fn build_config(out: *FxConfig, nf: ?*dhallz.Term, e: *ErrBuf) error{FxConfig}!void {
    out.* = .{
        .hostname = "",
        .packages = &.{},
        .users = &.{},
        .services = &.{},
        .agent_service = null,
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

    // inlinePackages: Optional (List Package) — see the FxConfig field
    // comment for why absence is legitimate here and is not for
    // agentService.  Parsed after the reference list, beside extraEtc.
    const ipkgs = rec_get(rec, "inlinePackages");
    if (ipkgs) |it| try map_inline_packages(out, it, e);

    if (try opt_nat(rec, "bootGraceMs", e, "config")) |g| out.grace_ms = g;

    // agentService: Optional Text naming the agent service — but the FIELD
    // ITSELF IS REQUIRED.  An optional field is silently inert for every
    // deployment that forgets it; "this system has no agent" must be
    // DECLARED (None), not defaulted to.  The presence check is the
    // load-bearing half; the value's existence + console-ness is enforced
    // in validate() with its siblings.
    if (rec_get(rec, "agentService") == null)
        return e.set("config missing 'agentService' (declare None Text if this system has no agent service)", .{});
    out.agent_service = try opt_text(rec, "agentService", e, "config");

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

test "console field: Some \"console\" parses, other values rejected, None default" {
    // a load-based test needs a FILE (fx_config_load reads from disk) —
    // write the fixture into a testing-owned temp dir.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const body =
        \\let Probe = < Tcp : Natural | Unix : Text | File : Text >
        \\let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
        \\                restart : Optional Text, backoffMs : Optional Natural,
        \\                probe : Optional Probe,
        \\                env : Optional (List { key : Text, value : Text }),
        \\                console : Optional Text }
        \\let User = { name : Text, uid : Natural, groups : List Text }
        \\in  { hostname = "fixbox"
        \\    , packages = [ "dhake" ] : List Text
        \\    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
        \\    , services =
        \\        [ { name = "sh", argv = [ "/usr/fx-core/bin/fxsh" ], pkg = None Text,
        \\            on = "all", restart = Some "never", backoffMs = None Natural,
        \\            probe = None Probe,
        \\            env = None (List { key : Text, value : Text }),
        \\            console = Some "console" }
        \\        , { name = "plain", argv = [ "/bin/true" ], pkg = None Text,
        \\            on = "all", restart = None Text, backoffMs = None Natural,
        \\            probe = None Probe,
        \\            env = None (List { key : Text, value : Text }),
        \\            console = None Text }
        \\        ]
        \\    , extraEtc = None (List { path : Text, content : Text })
        \\    , bootGraceMs = Some 3000
        \\    , agentService = Some "sh"
        \\    }
        \\
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "ok.dhall", .data = body });
    const ok_path = try std.fmt.allocPrint(gpa_alloc, ".zig-cache/tmp/{s}/ok.dhall", .{tmp.sub_path});
    defer gpa_alloc.free(ok_path);
    var e = ErrBuf{};
    var cfg: FxConfig = undefined;
    try fx_config_load(&cfg, ok_path, &e);
    try testing.expectEqual(@as(usize, 2), cfg.services.len);
    try testing.expectEqualStrings("sh", cfg.services[0].name);
    try testing.expectEqualStrings("console", cfg.services[0].console.?);
    try testing.expectEqualStrings("plain", cfg.services[1].name);
    try testing.expect(cfg.services[1].console == null); // None = default pipe

    // a non-"console" value is an ERROR, not a silent pass-through
    var bad = std.ArrayList(u8).empty;
    defer bad.deinit(gpa_alloc);
    bad.appendSlice(gpa_alloc, body) catch return error.SkipZigTest;
    // replace `Some "console"` with `Some "tty7777"` — SAME LENGTH, so the
    // splice cannot shift the rest of the document
    const idx = std.mem.indexOf(u8, bad.items, "Some \"console\"") orelse return error.SkipZigTest;
    @memcpy(bad.items[idx .. idx + "Some \"tty7777\"".len], "Some \"tty7777\"");
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.dhall", .data = bad.items });
    const bad_path = try std.fmt.allocPrint(gpa_alloc, ".zig-cache/tmp/{s}/bad.dhall", .{tmp.sub_path});
    defer gpa_alloc.free(bad_path);
    e = .{};
    var cfg2: FxConfig = undefined;
    try testing.expectError(error.FxConfig, fx_config_load(&cfg2, bad_path, &e));
    try testing.expect(std.mem.indexOf(u8, e.slice(), "console 'tty7777'") != null);
}

test "agentService: field required; Some non-console/unknown refused; Some console and None ok" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const pre =
        \\let Probe = < Tcp : Natural | Unix : Text | File : Text >
        \\let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
        \\                restart : Optional Text, backoffMs : Optional Natural,
        \\                probe : Optional Probe,
        \\                env : Optional (List { key : Text, value : Text }),
        \\                console : Optional Text }
        \\let User = { name : Text, uid : Natural, groups : List Text }
        \\in  { hostname = "fixbox"
        \\    , packages = [] : List Text
        \\    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
        \\    , services =
        \\        [ { name = "sh", argv = [ "/usr/fx-core/bin/fxsh" ], pkg = None Text,
        \\            on = "all", restart = Some "never", backoffMs = None Natural,
        \\            probe = None Probe,
        \\            env = None (List { key : Text, value : Text }),
        \\            console = Some "console" }
        \\        , { name = "plain", argv = [ "/bin/true" ], pkg = None Text,
        \\            on = "all", restart = None Text, backoffMs = None Natural,
        \\            probe = None Probe,
        \\            env = None (List { key : Text, value : Text }),
        \\            console = None Text }
        \\        ]
        \\    , extraEtc = None (List { path : Text, content : Text })
        \\    , bootGraceMs = Some 3000
        \\
    ;
    const post =
        \\    }
        \\
    ;
    // load(agent_line, ...): writes <tmp>/cfg.dhall with the given
    // agentService line spliced in ("" omits the field entirely) and loads
    // it. want_err != null expects that refusal; want_name is the expected
    // cfg.agent_service on success ("" = None).
    const Case = struct { line: []const u8, want_err: ?[]const u8, want_name: []const u8 };
    const cases = [_]Case{
        .{ .line = ", agentService = Some \"sh\"", .want_err = null, .want_name = "sh" },
        .{ .line = ", agentService = None Text", .want_err = null, .want_name = "" },
        // omission is refused LOUDLY, not defaulted to None
        .{ .line = "", .want_err = "config missing 'agentService'", .want_name = "" },
        // a NON-console agent is the oscillator shape: refused, named
        .{ .line = ", agentService = Some \"plain\"", .want_err = "agentService 'plain': the agent service must be a console service", .want_name = "" },
        .{ .line = ", agentService = Some \"ghost\"", .want_err = "agentService 'ghost' references an unknown service", .want_name = "" },
    };
    for (cases) |c| {
        const body = std.fmt.allocPrint(gpa_alloc, "{s}{s}{s}", .{ pre, c.line, post }) catch return error.SkipZigTest;
        defer gpa_alloc.free(body);
        try tmp.dir.writeFile(io, .{ .sub_path = "cfg.dhall", .data = body });
        const path = try std.fmt.allocPrint(gpa_alloc, ".zig-cache/tmp/{s}/cfg.dhall", .{tmp.sub_path});
        defer gpa_alloc.free(path);
        var e = ErrBuf{};
        var cfg: FxConfig = undefined;
        if (c.want_err) |want| {
            try testing.expectError(error.FxConfig, fx_config_load(&cfg, path, &e));
            try testing.expect(std.mem.indexOf(u8, e.slice(), want) != null);
        } else {
            try fx_config_load(&cfg, path, &e);
            try testing.expectEqualStrings(c.want_name, cfg.agent_service orelse "");
        }
    }
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

test "inlinePackages: Shell/Run-relative/Fetch/deps each refused BY NAME; admitted control passes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const pre =
        \\let Probe = < Tcp : Natural | Unix : Text | File : Text >
        \\let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
        \\                restart : Optional Text, backoffMs : Optional Natural,
        \\                probe : Optional Probe,
        \\                env : Optional (List { key : Text, value : Text }),
        \\                console : Optional Text }
        \\let User = { name : Text, uid : Natural, groups : List Text }
        \\in  { hostname = "fixbox"
        \\    , packages = [] : List Text
        \\    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
        \\    , services =
        \\        [ { name = "sh", argv = [ "/usr/fx-core/bin/fxsh" ], pkg = None Text,
        \\            on = "all", restart = Some "never", backoffMs = None Natural,
        \\            probe = None Probe,
        \\            env = None (List { key : Text, value : Text }),
        \\            console = Some "console" }
        \\        ]
        \\    , extraEtc = None (List { path : Text, content : Text })
        \\
    ;
    const post =
        \\    , bootGraceMs = Some 3000
        \\    , agentService = None Text
        \\    }
        \\
    ;
    // one admitted package, all TEN admitted action kinds, in a fixed order
    // the assertions walk back
    const ok_pkg =
        \\    , inlinePackages = Some [ { name = "agentsvc", version = "1.0",
        \\        src = < Path = "/fx/disk/agent-src/agentsvc" >,
        \\        deps = [] : List Text, excludes = [ "scratch" ] : List Text,
        \\        build = { target = "agentsvc", recipe =
        \\          [ < Mkdir = "out" >
        \\          , < Copy = { from = "Mcp.elm", to = "out/mcp.lua" } >
        \\          , < Chmod = { path = "out/mcp.lua", mode = "0755" } >
        \\          , < Echo = "built" >
        \\          , < Env = { key = "FX", value = "1" } >
        \\          , < Touch = "out/stamp" >
        \\          , < Run = { argv = [ "/usr/fx-agent/bin/luajit", "-b", "Mcp.elm", "out/mcp.lua" ] } >
        \\          , < Symlink = { from = "out/mcp.lua", to = "mcp" } >
        \\          , < Move = { from = "out/mcp.lua", to = "out/mcp2.lua" } >
        \\          , < Rm = "out/stamp" >
        \\          ] } } ]
        \\
    ;
    // load(line): write <tmp>/cfg.dhall with the given inlinePackages
    // expression (ok_pkg absent = field omitted) and load it.
    const Case = struct { line: ?[]const u8, want_err: ?[]const u8 };
    const cases = [_]Case{
        // absent is the honest "no agent-authored packages" state
        .{ .line = null, .want_err = null },
        // THE CONTROL: every admitted action kind parses and validates
        .{ .line = ok_pkg, .want_err = null },
        // the four subset refusals, each naming package + action + rule
        .{ .line =
        \\    , inlinePackages = Some [ { name = "agentsvc", version = "1.0",
        \\        src = < Path = "/fx/disk/agent-src/agentsvc" >,
        \\        deps = [] : List Text,
        \\        build = { target = "agentsvc", recipe =
        \\          [ < Mkdir = "out" >, < Shell = "make all" > ] } } ]
        \\
        , .want_err = "package 'agentsvc': recipe action 1 (Shell) is outside the agent-authorable action subset" },
        .{ .line =
        \\    , inlinePackages = Some [ { name = "agentsvc", version = "1.0",
        \\        src = < Path = "/fx/disk/agent-src/agentsvc" >,
        \\        deps = [] : List Text,
        \\        build = { target = "agentsvc", recipe =
        \\          [ < Run = { argv = [ "./configure", "--prefix=/build" ] } > ] } } ]
        \\
        , .want_err = "recipe action 0 (Run) argv[0] './configure' must be an ABSOLUTE path" },
        .{ .line =
        \\    , inlinePackages = Some [ { name = "agentsvc", version = "1.0",
        \\        src = < Fetch = { url = "https://example.com/a.tgz", hash = "f2ca1bb3c199e6c9eda0f4d1e7bb8b4b0f1b2a3c4d5e6f708192a3b4c5d6e7f8" } >,
        \\        deps = [] : List Text,
        \\        build = { target = "agentsvc", recipe = [ < Echo = "x" > ] } } ]
        \\
        , .want_err = "package 'agentsvc': agent-declared package src must be < Path = ... >" },
        .{ .line =
        \\    , inlinePackages = Some [ { name = "agentsvc", version = "1.0",
        \\        src = < Path = "/fx/disk/agent-src/agentsvc" >,
        \\        deps = [ "dhake" ] : List Text,
        \\        build = { target = "agentsvc", recipe = [ < Echo = "x" > ] } } ]
        \\
        , .want_err = "agent-declared packages must have deps = []" },
        // dup within the list + unsafe name: merge-ordering hazards
        .{ .line =
        \\    , inlinePackages = Some [ { name = "agentsvc", version = "1.0",
        \\        src = < Path = "/a" >, deps = [] : List Text,
        \\        build = { target = "t", recipe = [ < Echo = "x" > ] } }
        \\      , { name = "agentsvc", version = "2.0",
        \\        src = < Path = "/b" >, deps = [] : List Text,
        \\        build = { target = "t", recipe = [ < Echo = "x" > ] } } ]
        \\
        , .want_err = "duplicate inline package name 'agentsvc'" },
        .{ .line =
        \\    , inlinePackages = Some [ { name = "../evil", version = "1.0",
        \\        src = < Path = "/a" >, deps = [] : List Text,
        \\        build = { target = "t", recipe = [ < Echo = "x" > ] } } ]
        \\
        , .want_err = "package '../evil': invalid package name" },
    };
    for (cases) |c| {
        const body = std.fmt.allocPrint(gpa_alloc, "{s}{s}{s}", .{
            pre,
            c.line orelse "",
            post,
        }) catch return error.SkipZigTest;
        defer gpa_alloc.free(body);
        try tmp.dir.writeFile(io, .{ .sub_path = "cfg.dhall", .data = body });
        const path = try std.fmt.allocPrint(gpa_alloc, ".zig-cache/tmp/{s}/cfg.dhall", .{tmp.sub_path});
        defer gpa_alloc.free(path);
        var e = ErrBuf{};
        var cfg: FxConfig = undefined;
        if (c.want_err) |want| {
            try testing.expectError(error.FxConfig, fx_config_load(&cfg, path, &e));
            try testing.expect(std.mem.indexOf(u8, e.slice(), want) != null);
        } else {
            try fx_config_load(&cfg, path, &e);
            try testing.expect(cfg.agent_service == null);
        }
    }

    // the control's parsed shape: 10 recipe actions in order, excludes kept,
    // src raw.  Re-load the ok case explicitly (the loop above freed nothing
    // it needs, but assert against a fresh load for clarity).
    {
        const body = std.fmt.allocPrint(gpa_alloc, "{s}{s}{s}", .{ pre, ok_pkg, post }) catch return error.SkipZigTest;
        defer gpa_alloc.free(body);
        try tmp.dir.writeFile(io, .{ .sub_path = "ok.dhall", .data = body });
        const path = try std.fmt.allocPrint(gpa_alloc, ".zig-cache/tmp/{s}/ok.dhall", .{tmp.sub_path});
        defer gpa_alloc.free(path);
        var e = ErrBuf{};
        var cfg: FxConfig = undefined;
        try fx_config_load(&cfg, path, &e);
        try testing.expectEqual(@as(usize, 1), cfg.inline_packages.len);
        const p = &cfg.inline_packages[0];
        try testing.expectEqualStrings("agentsvc", p.name);
        try testing.expectEqualStrings("1.0", p.version);
        try testing.expectEqual(FxPkgSrcKind.path, p.src.kind);
        try testing.expectEqualStrings("/fx/disk/agent-src/agentsvc", p.src.path.?);
        try testing.expectEqual(@as(usize, 0), p.deps.len);
        try testing.expectEqual(@as(usize, 1), p.excludes.len);
        try testing.expectEqualStrings("scratch", p.excludes[0]);
        try testing.expectEqualStrings("agentsvc", p.target);
        const want_kinds = [_]FxPkgActionKind{ .mkdir, .copy, .chmod, .echo, .env, .touch, .run, .symlink, .move, .rm };
        try testing.expectEqual(want_kinds.len, p.recipe.len);
        for (want_kinds, 0..) |k, i| try testing.expectEqual(k, p.recipe[i].kind);
        const run = p.recipe[6];
        try testing.expectEqual(@as(usize, 4), run.argv.len);
        try testing.expectEqualStrings("/usr/fx-agent/bin/luajit", run.argv[0]);
    }
}
