//! intent_citation.zig — THE ONE definition of `<store>/.intents`: the INTENT
//! CITATION journal.
//!
//! WHY A NEW FILE AND NOT A COLUMN.  The `.operator` journal's header is ONE
//! frozen definition with TWO writers (operator_journal.zig: fx-init's control
//! handler and fx-activate's self-record), and every reader of it — fx-audit,
//! fx-report, fx-export — parses that frozen grammar.  A citation is a
//! different KIND of thing from an operator intervention (see below), so it
//! gets its own file: an unknown record file is ignored by readers that do not
//! know it, by their own stated rule, which is exactly the additive shape this
//! journal needs.
//!
//! WHAT A ROW IS — A CITATION, NOT AN APPROVAL.  A row says *the writer of this
//! activation CITED intent id X*.  The id is recorded VERBATIM.  This module
//! never validates it against anything and never resolves it, because it
//! cannot: the approvals live on the orchestrator's side (CNC publishes them),
//! and a record is not more authoritative than its writer.  So an id nobody has
//! ever issued is still recorded — it is a claim the agent made, and the READER
//! decides what the claim is worth.  What IS refused is an id that is not the
//! SHAPE of a claim at all (empty, or not `intent-<64 lowercase hex>`): that is
//! noise wearing a citation's name, and recording it would put a line in the
//! record that says nothing.
//!
//! WHY NO BOOT-NONCE PREDICATE (the difference from `.operator`).  An operator
//! row is an INTERVENTION and is only attributable to a boot when the kernel
//! command line carries `fx.bootnonce=`; offline callers therefore record
//! nothing.  A citation is not an intervention: its anchor is the ACTIVATION it
//! belongs to (the version, its genhash and the from-version), which this
//! writer knows exactly because it is the process that published it.  The nonce
//! column is carried when the boot has one and is the literal `none` otherwise
//! — never a silent absence.
//!
//! APPEND-ONLY, ONE ROW PER CITED ACTIVATION.  Two activations citing the same
//! id are two rows: the file records what happened, and deduplicating would
//! edit the record.  The row is written AFTER the publish committed and the
//! version is known, so a citation always names a version that exists; an
//! activation that published nothing cites nothing (its refusal is the
//! `.operator` row's to carry).
const std = @import("std");
const opj = @import("operator_journal"); // the ONE <store>/.operator definition + the store-file durability helpers
const fxstat = @import("fxstat"); // target-correct time64 ABI (see fxstat.zig)

const gpa_alloc = std.heap.c_allocator;
const time = fxstat.time;

// libc scratch.  Declared locally (the operator_journal.zig precedent: this
// module must not depend on either binary's externs).
const FILE = std.c.FILE;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(f: *FILE) c_int;
extern "c" fn fflush(f: *FILE) c_int;
extern "c" fn fileno(f: *FILE) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, f: *FILE) usize;
extern "c" fn fsync(fd: c_int) c_int;

const F_OK: c_int = 0;

/// The id's own namespace and width: CNC's published intent id is
/// `intent-` + the 64 lowercase hex characters of a sha256
/// (`GET /api/projects/:slug/baliveau/intent`).  This is the SHAPE a citation
/// must have to be a claim at all — never a test of whether the id exists.
pub const ID_PREFIX = "intent-";
pub const ID_HEX_LEN: usize = 64;

/// The longest id this journal accepts (the prefix + the hex): a bound, so a
/// row can never be padded into a line that a reader would have to truncate.
pub const ID_MAX: usize = ID_PREFIX.len + ID_HEX_LEN;

/// The header IS the definition, in the file itself (the `.recovery` and
/// `.operator` discipline): what a row means, what it does NOT mean, and which
/// paths cannot reach this file.
pub const INTENTS_HEADER =
    \\# fx-activate intent CITATION journal. One DATA line per ACTIVATION that
    \\# CITED an orchestrator intent id with `--intent <id>`.
    \\#
    \\# A ROW IS A CITATION, NOT AN APPROVAL.  It says the writer of that
    \\# activation cited id X; it does NOT say X was ever issued, that the
    \\# activation was justified, or that anything was approved.  The id is
    \\# recorded VERBATIM and is never validated or resolved here — the approvals
    \\# live on the orchestrator's side, and a record is not more authoritative
    \\# than its writer.  The reader decides what the claim is worth.
    \\# line: <epoch-s> <intent-id> <from-version|-> <version> <genhash|-> <boot-nonce|none>
    \\#   intent-id: intent-<64 lowercase hex>, VERBATIM.  An id of any other
    \\#            shape is REFUSED by the writer (it is not a claim, it is
    \\#            noise); a well-formed id nobody has issued is ACCEPTED.
    \\#   from/version: the store CURRENT before/after the activation that cited
    \\#            it; "-" = the store held no generation yet (from) or the
    \\#            activation could not confirm it (to).  A citation is written
    \\#            only once a version exists, so `version` is a number here.
    \\#   genhash: the generation the activation published — the ACTIVATION this
    \\#            citation belongs to, so a reader can join the two without
    \\#            guessing.
    \\#   boot-nonce: this boot's fx.bootnonce=, or `none` where the boot carries
    \\#            none (a host-side run, a golden diff).  NOT a predicate: a
    \\#            citation is anchored by its ACTIVATION, not by a boot.
    \\#
    \\# APPEND-ONLY.  Two activations citing the same id are TWO rows; a
    \\# deduplicated journal would be an edited record.  The count of citations is
    \\# the number of lines starting with a digit.
    \\# NOT HERE, on purpose: any verdict, any resolution of the id, any claim
    \\# that the citation was honoured.  Those are the reader's to make.
    \\
;

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

fn now_s() u32 {
    return @truncate(@as(u64, @bitCast(time(null))));
}

fn isLowerHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

/// What is WRONG with `id` as a citation — or `null` when it is the right
/// shape.  The three defects are separated because they are different
/// mistakes, and the refusal must name the shape rather than say "invalid".
/// NOTHING here consults the orchestrator: shape only, never validity.
pub fn idDefect(id: []const u8) ?[]const u8 {
    if (id.len == 0) return "it is empty";
    if (!std.mem.startsWith(u8, id, ID_PREFIX))
        return "it does not start with `" ++ ID_PREFIX ++ "`";
    const hex = id[ID_PREFIX.len..];
    if (hex.len != ID_HEX_LEN)
        return "the part after `" ++ ID_PREFIX ++ "` is not 64 characters";
    for (hex) |c| {
        if (!isLowerHex(c)) return "it carries a character outside 0-9a-f";
    }
    return null;
}

/// The row, without its newline: `<epoch> <id> <from|-> <version> <genhash|->
/// <nonce|none>`.  Pure, so the gate can compare the file's bytes against the
/// same rendering the writer uses (the family's canonical-form rule: two
/// renderings of one row would be two records).
pub fn line(out: []u8, epoch: u32, id: []const u8, v_from: u32, v_to: u32, genhash: []const u8, nonce: []const u8) []const u8 {
    var fbuf: [16]u8 = undefined;
    const from: []const u8 = if (v_from == 0) "-" else snfmt(&fbuf, "{d}", .{v_from});
    return snfmt(out, "{d} {s} {s} {d} {s} {s}\n", .{
        epoch, id, from, v_to, genhash, nonce,
    });
}

/// Ensure the journal (with its definition header) exists.  The `.recovery`
/// discipline: a store where no activation ever cited an id reads "file
/// present, zero data lines", which is a measurement and not an absence.
pub fn ensure(path: [*:0]const u8) void {
    if (std.c.access(path, F_OK) == 0) return;
    opj.mkdirpDir(path);
    const f = fopen(path, "w") orelse return;
    _ = fwrite(INTENTS_HEADER.ptr, 1, INTENTS_HEADER.len, f);
    _ = fflush(f);
    _ = fsync(fileno(f));
    _ = fclose(f);
    opj.syncfsDir(path);
}

/// Append one citation.  Silent on failure, like every record site: the
/// activation already committed, and a journal must never undo a publish.
///
/// ONE fwrite == one write(2) for the whole row: fopen("a") is O_APPEND, and a
/// single write under O_APPEND is positioned and landed as one step, so two
/// writers can never tear a row or interleave mid-row.
pub fn append(path: [*:0]const u8, id: []const u8, v_from: u32, v_to: u32, genhash: []const u8, nonce: []const u8) void {
    ensure(path);
    const f = fopen(path, "a") orelse return;
    // the id is bounded by ID_MAX and the genhash by 64; +128 covers the fixed
    // numeric fields and snfmt TRUNCATES rather than overflowing.
    var line_buf: [ID_MAX + 64 + 128]u8 = undefined;
    const l = line(&line_buf, now_s(), id, v_from, v_to, genhash, nonce);
    _ = fwrite(l.ptr, 1, l.len, f);
    _ = fflush(f);
    _ = fsync(fileno(f));
    _ = fclose(f);
    opj.syncfsDir(path);
}

// ─── unit tests ───────────────────────────────────────────────────────────

const testing = std.testing;

/// A real CNC-shaped id: `intent-` + 64 lowercase hex.
const GOOD_ID = "intent-0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0";

test "idDefect: the shape CNC publishes is accepted, and nothing else" {
    try testing.expectEqual(@as(?[]const u8, null), idDefect(GOOD_ID));

    // the three defects are DISTINCT sentences, because they are three
    // different mistakes — a single "invalid id" would not name the shape.
    try testing.expectEqualStrings("it is empty", idDefect("").?);
    try testing.expectEqualStrings("it does not start with `intent-`", idDefect("0f1e2d3c").?);
    try testing.expectEqualStrings("the part after `intent-` is not 64 characters", idDefect("intent-0f1e2d3c").?);
    // 64 characters, one of them uppercase: still not the published shape.
    const upper = "intent-0F1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0";
    try testing.expectEqualStrings("it carries a character outside 0-9a-f", idDefect(upper).?);
    // 65 hex characters is not 64 either (a wider id is a different namespace)
    try testing.expectEqualStrings("the part after `intent-` is not 64 characters", idDefect(GOOD_ID ++ "a").?);

    // THE BOUND THE WRITER DEPENDS ON: an accepted id never exceeds ID_MAX, so
    // the row buffer can never truncate a citation into a different claim.
    try testing.expectEqual(ID_MAX, GOOD_ID.len);
}

test "line: the row is the writer's own grammar, verbatim and stable" {
    var buf: [512]u8 = undefined;
    const l = line(&buf, 1793140263, GOOD_ID, 5, 7,
        "9175d67288cb3e03d6aef61daa5e3e3243525497718eaeeb2cea2ff767c5fcea", "expboot03");
    try testing.expectEqualStrings(
        "1793140263 " ++ GOOD_ID ++ " 5 7 " ++
            "9175d67288cb3e03d6aef61daa5e3e3243525497718eaeeb2cea2ff767c5fcea expboot03\n",
        l,
    );
    // from-version 0 (a store that held no generation yet) is "-", never "0":
    // 0 is a version the store can hold, so it cannot double as "unknown".
    const z = line(&buf, 1, GOOD_ID, 0, 1, "-", "none");
    try testing.expectEqualStrings(
        "1 " ++ GOOD_ID ++ " - 1 - none\n", z,
    );
    // the id is carried VERBATIM — the row is the claim, so the writer must not
    // normalise, re-prefix or shorten it
    try testing.expect(std.mem.indexOf(u8, l, GOOD_ID) != null);
}
