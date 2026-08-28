//! log.zig — faithful Zig port of src/fx_log.c (U-C2), the DAFSA-interned
//! service log DB.
//!
//! The datalog-dafsa + dafsa engines stay C (built as the `fxengine` static
//! lib in build.zig); only the wrapper logic is ported here, calling the
//! engine through the dl_*/aux_*/tokenize/regex_* externs below — the same
//! C-FFI pattern as fx-core's libdatalog linkage.
//!
//! Ported 1:1 from fx_log.c: emit (intern + add_fact + tokenize->postings),
//! count, grep (".*"-wrapped full-key regex on col 3), search (dl_search
//! collect-then-enumerate), open/close, rotate (collect-then-delete oldest
//! quarter in one txn).  dl_intern_str 0 = failure (emit returns -1).
const std = @import("std");

// ─── engine C API (vendor/datalog-dafsa) ──────────────────────────────────

pub const dl_db = opaque {};
pub const dl_iter = opaque {};

/// regexwalk.h `struct regex_dfa` — field order is ABI.
pub const RegexDfa = extern struct {
    n_states: u32,
    trans: ?[*]u32,
    accept: ?[*]u8,
    errmsg: ?[*:0]u8,
};

/// fx_log.h fx_log_cb.
pub const fx_log_cb = ?*const fn (ts: u32, svc: [*:0]const u8, level: [*:0]const u8, msg: [*:0]const u8, user: ?*anyopaque) callconv(.c) c_int;

/// dl.h dl_tuple_cb.
const dl_tuple_cb = *const fn (cols: [*]const u32, arity: u8, user: ?*anyopaque) callconv(.c) c_int;

/// index.h dl_search_cb.
const dl_search_cb = *const fn (obs_id: u32, score: c_int, user: ?*anyopaque) callconv(.c) c_int;

extern fn dl_open(dir: [*:0]const u8) ?*dl_db;
extern fn dl_close(db: ?*dl_db) void;
extern fn dl_declare_relation(db: *dl_db, name: [*:0]const u8, arity: u8) c_int;
extern fn dl_add_fact(db: *dl_db, rel: [*:0]const u8, cols: [*]const u32, arity: u8) c_int;
extern fn dl_count(db: *dl_db, rel: [*:0]const u8) u64;
extern fn dl_intern_str(db: *dl_db, str: ?[*:0]const u8) u32;
extern fn dl_intern_str_of(db: *dl_db, sym_id: u32) ?[*:0]const u8;
extern fn dl_pattern(db: *dl_db, rel_name: [*:0]const u8, col: u8, dfa: *const RegexDfa, cb: dl_tuple_cb, user: ?*anyopaque) c_long;
extern fn dl_search(db: *dl_db, terms: [*]const u32, n_terms: c_int, cb: dl_search_cb, user: ?*anyopaque) c_long;
extern fn dl_iter_open(db: *dl_db, rel: [*:0]const u8, leading: ?[*]const u32, k: u8) ?*dl_iter;
extern fn dl_iter_arity(it: *const dl_iter) u8;
extern fn dl_iter_next(it: *dl_iter, cols_out: [*]u32) c_int;
extern fn dl_iter_close(it: ?*dl_iter) void;
extern fn dl_txn_begin(db: *dl_db) c_int;
extern fn dl_txn_delete_fact(db: *dl_db, rel: [*:0]const u8, cols: [*]const u32, arity: u8) c_int;
extern fn dl_txn_commit(db: *dl_db) c_int;
extern fn dl_txn_rollback(db: *dl_db) c_int;
extern fn aux_index_ensure_postings(db: *dl_db) c_int;
extern fn aux_index_add_posting(db: *dl_db, term_sym: u32, obs_id: u32) c_int;

/// index.h: NULL-terminated array of tokens (free array AND strings via
/// token_free — NOT the Zig allocator).
extern fn tokenize(text: [*:0]const u8, n_out: *usize) ?[*:null]?[*:0]u8;
extern fn token_free(tokens: ?*const anyopaque) void;
extern fn regex_compile(pattern: [*:0]const u8) ?*RegexDfa;
extern fn regex_dfa_free(dfa: ?*RegexDfa) void;

// The port mirrors the C's malloc/free scratch exactly (free() after
// token_free-style C buffers; nothing here escapes the call).
extern fn malloc(size: usize) ?[*]u8;
extern fn free(ptr: ?*anyopaque) void;

// ─── emit ─────────────────────────────────────────────────────────────────

pub fn fx_log_emit(db: ?*dl_db, ts: u32, svc: [*:0]const u8, level: [*:0]const u8, msg: [*:0]const u8) c_int {
    const d = db orelse return -1;
    const s = dl_intern_str(d, svc);
    const l = dl_intern_str(d, level);
    const m = dl_intern_str(d, msg);
    if (s == 0 or l == 0 or m == 0) return -1;
    const cols = [4]u32{ ts, s, l, m };
    if (dl_add_fact(d, "log", &cols, 4) < 0) return -1;
    // postings: tokenize the message, intern each token, link term->msg_sym
    var ntok: usize = 0;
    if (tokenize(msg, &ntok)) |toks| {
        var i: usize = 0;
        while (i < ntok) : (i += 1) {
            const tsym = dl_intern_str(d, toks[i]);
            if (tsym != 0) _ = aux_index_add_posting(d, tsym, m);
        }
        token_free(@ptrCast(toks));
    }
    return 0;
}

pub fn fx_log_count(db: ?*dl_db) u64 {
    const d = db orelse return std.math.maxInt(u64);
    return dl_count(d, "log");
}

// ─── grep (regex on the msg column) ───────────────────────────────────────
// regexwalk is FULL-KEY match (implicit ^...$), so the pattern is wrapped in
// .* ... .* for substring matching.

const GrepState = struct {
    db: *dl_db,
    cb: fx_log_cb,
    user: ?*anyopaque,
    n: c_long,
};

fn grep_inner(cols: [*]const u32, arity: u8, user: ?*anyopaque) callconv(.c) c_int {
    _ = arity;
    const g: *GrepState = @ptrCast(@alignCast(user.?));
    const ts = cols[0];
    var svc = dl_intern_str_of(g.db, cols[1]);
    var lvl = dl_intern_str_of(g.db, cols[2]);
    var mstr = dl_intern_str_of(g.db, cols[3]);
    if (svc == null) svc = "?";
    if (lvl == null) lvl = "?";
    if (mstr == null) mstr = "?";
    g.n += 1;
    if (g.cb.?(ts, svc.?, lvl.?, mstr.?, g.user) != 0) return 1;
    return 0;
}

pub fn fx_log_grep(db: ?*dl_db, regex: ?[*:0]const u8, cb: fx_log_cb, user: ?*anyopaque) c_long {
    const d = db orelse return -1;
    const re = regex orelse return -1;
    const callback = cb orelse return -1;
    const n = std.mem.len(re);
    const pat = malloc(n + 5) orelse return -1;
    defer free(pat);
    @memcpy(pat[0..2], ".*");
    @memcpy(pat[2 .. 2 + n], re[0..n]);
    @memcpy(pat[2 + n .. 4 + n], ".*");
    pat[n + 4] = 0;
    const dfa = regex_compile(@ptrCast(pat)) orelse return -1;
    if (dfa.errmsg != null) {
        regex_dfa_free(dfa);
        return -1;
    }

    // dl_pattern enumerates tuples whose COL 3 (msg) matches; we resolve the
    // other cols into strings via the interner and stream to user cb.
    var g = GrepState{ .db = d, .cb = callback, .user = user, .n = 0 };
    const r = dl_pattern(d, "log", 3, dfa, grep_inner, &g);
    regex_dfa_free(dfa);
    if (r < 0) return -1;
    return g.n;
}

// ─── search (AND of interned tokens via dl_search) ────────────────────────
// dl_search returns msg_syms matching ALL terms; we then enumerate log
// tuples in ascending order, filtering where col 3 == one of the matched
// msg_syms.

const MatchState = struct {
    a: [*]u32,
    n: *usize,
    cap: usize,
    overflow: c_int,
};

fn search_collect(obs_id: u32, score: c_int, user: ?*anyopaque) callconv(.c) c_int {
    _ = score;
    const m: *MatchState = @ptrCast(@alignCast(user.?));
    if (m.n.* >= m.cap) {
        m.overflow = 1;
        return 1;
    }
    m.a[m.n.*] = obs_id;
    m.n.* += 1;
    return 0;
}

pub fn fx_log_search(db: ?*dl_db, terms: ?[*]const ?[*:0]const u8, nterms: c_int, cb: fx_log_cb, user: ?*anyopaque) c_long {
    const d = db orelse return -1;
    const callback = cb orelse return -1;
    if (nterms <= 0) return -1;
    const tsyms = malloc(@as(usize, @intCast(nterms)) * @sizeOf(u32)) orelse return -1;
    const tsyms32: [*]u32 = @ptrCast(@alignCast(tsyms));
    defer free(tsyms);
    var i: usize = 0;
    while (i < @as(usize, @intCast(nterms))) : (i += 1) {
        tsyms32[i] = dl_intern_str(d, terms.?[i]);
        if (tsyms32[i] == 0) return -1;
    }
    var cap: usize = @as(usize, @intCast(nterms)) * 16;
    if (cap < 16) cap = 16;
    const matched = malloc(cap * @sizeOf(u32)) orelse return -1;
    const matched32: [*]u32 = @ptrCast(@alignCast(matched));
    defer free(matched);
    var nmatch: usize = 0;
    var m = MatchState{ .a = matched32, .n = &nmatch, .cap = cap, .overflow = 0 };
    const r = dl_search(d, tsyms32, nterms, search_collect, &m);
    if (r < 0) return -1;

    var emitted: c_long = 0;
    const it = dl_iter_open(d, "log", null, 0) orelse return -1;
    defer dl_iter_close(it);
    const arity = dl_iter_arity(it);
    if (arity != 4) return -1;
    var cols: [4]u32 = undefined;
    while (dl_iter_next(it, &cols) == 1) {
        const msg = cols[3];
        var hit = false;
        var j: usize = 0;
        while (j < nmatch) : (j += 1) {
            if (matched32[j] == msg) {
                hit = true;
                break;
            }
        }
        if (!hit) continue;
        var svc = dl_intern_str_of(d, cols[1]);
        var lvl = dl_intern_str_of(d, cols[2]);
        var mstr = dl_intern_str_of(d, cols[3]);
        if (svc == null) svc = "?";
        if (lvl == null) lvl = "?";
        if (mstr == null) mstr = "?";
        emitted += 1;
        if (callback(cols[0], svc.?, lvl.?, mstr.?, user) != 0) break;
    }
    return emitted;
}

// ─── open/close/rotate ────────────────────────────────────────────────────

pub fn fx_log_open(path: [*:0]const u8) ?*dl_db {
    const db = dl_open(path) orelse return null;
    if (dl_declare_relation(db, "log", 4) != 0) {
        dl_close(db);
        return null;
    }
    if (aux_index_ensure_postings(db) != 0) {
        dl_close(db);
        return null;
    }
    return db;
}

pub fn fx_log_close(db: ?*dl_db) void {
    if (db) |d| dl_close(d);
}

pub fn fx_log_rotate(db: ?*dl_db, cap: u64) c_int {
    const d = db orelse return -1;
    const n = dl_count(d, "log");
    if (n == std.math.maxInt(u64)) return -1;
    if (n <= cap) return 0;
    const drop = n / 4; // oldest quarter
    if (drop == 0) return 0;
    // ts is the leading column; ascending lex order == ascending ts order, so
    // the first `drop` tuples are the oldest.
    //
    // COLLECT-then-DELETE (same pattern as fx-activate's clear_rel and
    // fx-init's restore_m4_facts): collect the oldest `drop` tuples into a
    // buffer with the iterator CLOSED, then delete them in one txn.
    const it = dl_iter_open(d, "log", null, 0) orelse return -1;
    const ar = dl_iter_arity(it);
    if (ar != 4) {
        dl_iter_close(it);
        return -1;
    }
    const bag = malloc(@as(usize, @intCast(drop)) * ar * @sizeOf(u32)) orelse {
        dl_iter_close(it);
        return -1;
    };
    const bag32: [*]u32 = @ptrCast(@alignCast(bag));
    var k: u64 = 0;
    var row: [4]u32 = undefined;
    while (k < drop and dl_iter_next(it, &row) == 1) {
        @memcpy(bag32[@as(usize, @intCast(k)) * ar ..][0..ar], row[0..ar]);
        k += 1;
    }
    dl_iter_close(it);
    if (dl_txn_begin(d) != 0) {
        free(bag);
        return -1;
    }
    var i: u64 = 0;
    while (i < k) : (i += 1)
        _ = dl_txn_delete_fact(d, "log", bag32[@as(usize, @intCast(i)) * ar ..], ar);
    if (dl_txn_commit(d) != 0) {
        _ = dl_txn_rollback(d);
        free(bag);
        return -1;
    }
    free(bag);
    return 0;
}

// ─── C ABI surface (linked into zig/log_probe_live.c as zig_log_*) ────────

export fn zig_log_open(path: [*:0]const u8) ?*dl_db {
    return fx_log_open(path);
}
export fn zig_log_close(db: ?*dl_db) void {
    fx_log_close(db);
}
export fn zig_log_emit(db: ?*dl_db, ts: u32, svc: [*:0]const u8, level: [*:0]const u8, msg: [*:0]const u8) c_int {
    return fx_log_emit(db, ts, svc, level, msg);
}
export fn zig_log_count(db: ?*dl_db) u64 {
    return fx_log_count(db);
}
export fn zig_log_grep(db: ?*dl_db, regex: ?[*:0]const u8, cb: fx_log_cb, user: ?*anyopaque) c_long {
    return fx_log_grep(db, regex, cb, user);
}
export fn zig_log_search(db: ?*dl_db, terms: ?[*]const ?[*:0]const u8, nterms: c_int, cb: fx_log_cb, user: ?*anyopaque) c_long {
    return fx_log_search(db, terms, nterms, cb, user);
}
export fn zig_log_rotate(db: ?*dl_db, cap: u64) c_int {
    return fx_log_rotate(db, cap);
}

// ─── tests ────────────────────────────────────────────────────────────────

test "grep pattern wrap produces the C \".*regex.*\" byte layout" {
    const re: [*:0]const u8 = "ab";
    const n = std.mem.len(re);
    try std.testing.expectEqual(@as(usize, 7), n + 5); // malloc size in fx_log_grep: ".*ab.*" + NUL
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..2], ".*");
    @memcpy(buf[2 .. 2 + n], re[0..n]);
    @memcpy(buf[2 + n .. 4 + n], ".*");
    buf[n + 4] = 0;
    try std.testing.expectEqualStrings(".*ab.*", std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf)), 0));
}
