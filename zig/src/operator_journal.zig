//! operator_journal.zig — THE ONE definition of `<store>/.operator`: the
//! header (the contract, written into the file itself), the data-line
//! grammar, and the kernel-command-line boot-nonce parse that binds a row
//! to its boot.
//!
//! TWO writers, ONE grammar.  fx-init's control handler owns the file and
//! writes one row per REQUEST; fx-activate writes ONE row for itself when it
//! was NOT executed by that handler (a direct exec: the harness's
//! channel-less fallback, a shell command) and the boot carries an
//! fx.bootnonce= token.  Two copies of the grammar or of the header text
//! would drift, and the header IS the definition — so both import this.
//!
//! The boot nonce is a PARAMETER of `line`: this module reads no global
//! (fx-init latches its token at boot, fx-activate parses its own out of
//! /proc/cmdline) and no clock beyond the row's epoch.
const std = @import("std");
const fxstat = @import("fxstat"); // target-correct time64 ABI (see fxstat.zig)

const gpa_alloc = std.heap.c_allocator;
const time = fxstat.time;

/// The control channel's request token bound (fx-init IMPORTS this value:
/// ONE definition, two binaries).  An operator operand can never exceed it,
/// so a row can never exceed REQ_MAX + the fixed fields; `line` TRUNCATES
/// on a pathological arg rather than overflowing, as the C's snprintf did.
pub const REQ_MAX: usize = 4096;

const F_OK: c_int = 0;
const EEXIST: c_int = 17; // Linux

// libc scratch.  Declared locally (the activate.zig precedent: this module
// is imported by both binaries and must not depend on either one's externs).
const FILE = std.c.FILE;
extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern "c" fn fclose(f: *FILE) c_int;
extern "c" fn fflush(f: *FILE) c_int;
extern "c" fn fileno(f: *FILE) c_int;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, f: *FILE) usize;
extern "c" fn fsync(fd: c_int) c_int;
extern "c" fn syncfs(fd: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;

const O_RDONLY: c_int = 0o0;
const O_DIRECTORY: c_int = 0o200000; // x86_64 (asm-generic): directory-only open

/// C snprintf semantics into a fixed buffer (init.zig/activate.zig snfmt
/// pattern: format unbounded, then truncate to the cap and NUL-terminate).
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

fn span(p: [*:0]const u8) []const u8 {
    return std.mem.span(p);
}

/// mkdir -p the DIRECTORY part of `path` (everything before the last '/'),
/// the `mkdirp(g_store)` the writer has always done before opening the file.
fn mkdirpDir(path: [*:0]const u8) void {
    var buf: [1100]u8 = undefined;
    const p = span(path);
    if (p.len == 0 or p.len >= buf.len) return;
    @memcpy(buf[0..p.len], p);
    var cut: usize = 0;
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (buf[i] == '/') cut = i;
    }
    buf[cut] = 0;
    var idx: usize = 1;
    while (buf[idx] != 0) : (idx += 1) {
        if (buf[idx] == '/') {
            buf[idx] = 0;
            if (std.c.mkdir(@ptrCast(&buf), 0o755) != 0 and std.c._errno().* != EEXIST) return;
            buf[idx] = '/';
        }
    }
    if (std.c.mkdir(@ptrCast(&buf), 0o755) != 0 and std.c._errno().* != EEXIST) return;
}

/// syncfs the FILESYSTEM HOLDING the journal, by opening its own directory:
/// an fd on the fs reaches every dirty page and inode of that fs.  This is
/// the durability the writer owes (the disk store is mounted r/w, and its
/// metadata churn can sit unflushed when a harness kills the VM at the
/// verdict).  Derived from the journal's own path rather than from a mount
/// constant: fx-activate has no notion of the guest's DISK_MOUNT, and the
/// journal lives on whatever fs its store does.  On a ramfs/tmpfs store this
/// is a harmless no-op for the caller that used to skip it.
fn syncfsDir(path: [*:0]const u8) void {
    var buf: [1100]u8 = undefined;
    const p = span(path);
    if (p.len == 0 or p.len >= buf.len) return;
    @memcpy(buf[0..p.len], p);
    var cut: usize = 0;
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (buf[i] == '/') cut = i;
    }
    if (cut == 0) return;
    buf[cut] = 0;
    const fd = open(@ptrCast(&buf), O_RDONLY | O_DIRECTORY, 0);
    if (fd < 0) return; // best-effort durability, like every other site
    _ = syncfs(fd);
    _ = close(fd);
}

/// The header IS the definition, in the file itself (the .recovery
/// discipline): what is recorded, what is NOT, and — because a record
/// that silently omits a class is worse than none — which intervention
/// paths CANNOT reach this file at all.
pub const OPERATOR_HEADER =
    \\# fx-init operator journal. One DATA line per OPERATOR intervention
    \\# on the generation plane: per control-channel `activate`, `rollback`
    \\# or `shutdown` — INCLUDING the ones that FAILED or were REFUSED; an
    \\# intervention that did not take effect is still one — AND, since the
    \\# runtime-record closure, one row for each publish fx-activate committed
    \\# OUTSIDE that handler.  The count of interventions is the number of
    \\# lines starting with a digit.
    \\# line: <epoch-s> <action> <arg> <outcome> <from-version|-> <to-version|-> <boot-nonce|none>
    \\#   action:  activate | rollback | shutdown (the ctrl arm that wrote it)
    \\#   arg:     the operator's operand VERBATIM (config path, requested
    \\#            version, "-" for shutdown)
    \\#   outcome: ok              took effect (the store moved as asked)
    \\#            failed:<rc>     the activate executor exited rc
    \\#                            (fork/exec failure = -1)
    \\#            refused         the STORE refused (rollback to a version
    \\#                            that does not exist); nothing landed,
    \\#                            to-version is "-"
    \\#            refused-config  the store CURRENT moved but PID1's service
    \\#                            table REFUSED the configuration (the service
    \\#                            bound was exceeded): the generation is in the
    \\#                            store but nothing supervises it
    \\#            dhake-failed    activation committed, live-root reapply
    \\#                            failed
    \\#            unverified      the executor ran but the store could not
    \\#                            be re-opened to confirm the result
    \\#   from/to: the store CURRENT before/after the intervention; "-" =
    \\#            unknown, or no generation move (shutdown); from=0 = the store
    \\#            held no generation yet (a fresh store's first publish)
    \\# NOT recorded (not generation-plane interventions): the READS (status, q,
    \\# grep, search), file transfers (put, rm), per-service runtime commands
    \\# (start/stop/restart), probe — and a malformed request (missing operand)
    \\# that no arm executed.  The INTERACTIVE SHELL is the one request whose
    \\# EFFECT can still land here: the `shell` request itself is not recorded,
    \\# but a DIRECT exec of fx-activate FROM that shell is an activation
    \\# outside this handler and self-records the publish it made (below).
    \\# Written by TWO writers since the runtime-record closure, and this is
    \\# the exception to "the control handler is the only writer".  (1)
    \\# fx-init's control handler: one row per REQUEST, whatever its
    \\# outcome, fsync'd before the reply is flushed.  (2) fx-activate
    \\# ITSELF, when a boot process executes it OUTSIDE that handler (the
    \\# harness's channel-less direct-exec fallback, or a command in the
    \\# interactive shell): ONE row for the publish it committed, and only
    \\# when the boot carries an fx.bootnonce= token — a row must be
    \\# attributable to the boot it happened in, so a machine that issued no
    \\# nonce records nothing (the row would carry "none", which the boot
    \\# ledger cannot account for).  The handler's own child does NOT
    \\# self-record (it is told so), so a channel activation still leaves
    \\# EXACTLY ONE row, never two.  The direct exec's record is NARROWER
    \\# than the handler's, and deliberately so: a request is an
    \\# intervention whether or not it took effect, so the handler records
    \\# its failures too; a direct exec records only a PUBLISH THAT REACHED
    \\# COMMIT (a pre-publish failure moves nothing and leaves no row —
    \\# there is no request to attribute it to).
    \\# NOT recorded AND NOT DETECTABLE from this file — paths that bypass
    \\# PID1's control handler AND this journal's own self-record: a
    \\# host-side `fxstore rollback` (a different process, in a deployment
    \\# possibly not even inside the guest), `fxstore rollback --hard`, and
    \\# a hand-edited store CURRENT.  Their only trace is the store's own
    \\# version history minus this file: treat an unexplained generation
    \\# move as one of these.
    \\# SEPARATE from .recovery ON PURPOSE: a .recovery row is an AUTOMATIC
    \\# roll-forward (the audit relies on that meaning), so operator
    \\# actions are recorded here, never there.
    \\# The final field is THIS boot's fx.bootnonce= token from the kernel
    \\# command line ("none" = the host issued no nonce — an operator
    \\# hand-boot); it binds the row to the boot it happened in exactly as
    \\# .bootlog's 4th field binds a line — the same nonce discipline, not
    \\# a new one.
    \\# Root in-guest can forge or truncate it exactly as it can .bootlog;
    \\# a row is CHECKABLE against the store's version/genhash history, not
    \\# authoritative over it.  Rows from the two writers are ordered by
    \\# epoch, not by writer: nothing here serializes them (each row is ONE
    \\# write under O_APPEND, so rows never tear, but which of two rows in
    \\# the same second landed first is not recorded).
    \\
;

/// One journal line. Pure (unit-tested): epoch first so the file sorts by
/// time, then the operator's own action/operand, the outcome token, the
/// generation pair ("-" = unknown / no move — an honest absence), and
/// the boot nonce.
pub fn line(out: []u8, epoch: u32, action: []const u8, arg: []const u8, outcome: []const u8, v_from: u32, v_to: ?u32, nonce: []const u8) []const u8 {
    var tobuf: [16]u8 = undefined;
    const to: []const u8 = if (v_to) |t| snfmt(&tobuf, "{d}", .{t}) else "-";
    return snfmt(out, "{d} {s} {s} {s} {d} {s} {s}\n", .{ epoch, action, arg, outcome, v_from, to, nonce });
}

/// Ensure the journal (with its definition header) exists on every store —
/// the .recovery discipline: a machine where no operator ever intervened
/// reads "file present, zero data lines", which is a measurement, not an
/// absence.  fx-init runs it once per boot beside recovery_ensure; the
/// self-recording writer runs it before its one row (a store no PID1 has
/// ever opened still gets the definition with its row).
pub fn ensure(path: [*:0]const u8) void {
    if (std.c.access(path, F_OK) == 0) return;
    mkdirpDir(path);
    const f = fopen(path, "w") orelse return;
    _ = fwrite(OPERATOR_HEADER.ptr, 1, OPERATOR_HEADER.len, f);
    _ = fflush(f);
    _ = fsync(fileno(f));
    _ = fclose(f);
    syncfsDir(path);
}

/// Append one intervention.  fx-init calls it from the ctrl arms BEFORE the
/// reply is flushed — the row is durable before the operator sees the
/// answer, so a machine killed right after the response still carries the
/// row (the durability this file exists for; /run/fx/log.db dies with the
/// boot).  fx-activate calls it once, after its publish committed.
/// A failing append (store unmounted, ENOSPC) is silent like every other
/// record site: the intervention still proceeds — the journal must never
/// refuse an action, only record it.
pub fn append(path: [*:0]const u8, action: []const u8, arg: []const u8, outcome: []const u8, v_from: u32, v_to: ?u32, nonce: []const u8) void {
    ensure(path);
    const f = fopen(path, "a") orelse return;
    // the arg is a request token (<= REQ_MAX); +256 covers the fixed
    // fields, and snfmt TRUNCATES on a pathologically long arg rather
    // than overflowing.  ONE fwrite == one write(2) for the whole row:
    // fopen("a") is O_APPEND, and a single write under O_APPEND is
    // positioned and landed as one step, so concurrent writers can never
    // tear a row or interleave mid-row.
    var line_buf: [REQ_MAX + 256]u8 = undefined;
    const l = line(&line_buf, now_s(), action, arg, outcome, v_from, v_to, nonce);
    _ = fwrite(l.ptr, 1, l.len, f);
    _ = fflush(f);
    _ = fsync(fileno(f));
    _ = fclose(f);
    syncfsDir(path);
}

/// Find the `fx.bootnonce=<hex>` token in a kernel command line (the FIRST
/// token-start occurrence wins, exactly like parse_kernel_store).  The value
/// ends at the next space or control byte and must be 1..64 bytes; the
/// literal "none" is RESERVED as the writer's no-nonce placeholder, so a
/// host passing it is refused (treated as absent) rather than allowed to
/// mint indistinguishable placeholder lines.
///
/// ITS SECOND CALLER: fx-activate's self-record predicate.  A direct exec
/// may only self-record when its boot IS attributable — i.e. when this
/// returns a token — so a row this module writes for itself NEVER carries
/// "none".  Offline callers (a CI host, a fixture run with no PID1) have no
/// such token on the HOST's own command line and therefore record nothing.
pub fn parseKernelNonce(text: []const u8) ?[]const u8 {
    const key = "fx.bootnonce=";
    var rest = text;
    while (std.mem.indexOf(u8, rest, key)) |hit| {
        if (hit != 0 and rest[hit - 1] != ' ') {
            rest = rest[hit + key.len ..]; // substring of another token: skip it
            continue;
        }
        const val = rest[hit + key.len ..];
        var end: usize = 0;
        while (end < val.len and val[end] > ' ') end += 1;
        if (end == 0 or end > 64) return null;
        if (std.mem.eql(u8, val[0..end], "none")) return null;
        return val[0..end];
    }
    return null;
}

// ─── unit tests ───────────────────────────────────────────────────────────

const testing = std.testing;

test "parse_kernel_nonce: token-start, reserved placeholder, length bound" {
    // token-start matches, value ends at space/control — the store battery's
    // discipline, applied to the nonce
    try std.testing.expectEqualStrings("a1b2c3d4e5f60718", parseKernelNonce("fx.bootnonce=a1b2c3d4e5f60718").?);
    try std.testing.expectEqualStrings("a1b2c3d4e5f60718", parseKernelNonce("fx.bootnonce=a1b2c3d4e5f60718 console=ttyS0").?);
    try std.testing.expectEqualStrings("a1b2c3d4e5f60718", parseKernelNonce("fx.store=/fx/store fx.bootnonce=a1b2c3d4e5f60718 panic=-1\n").?);
    try std.testing.expectEqualStrings("a1b2c3d4e5f60718", parseKernelNonce("a=1  fx.bootnonce=a1b2c3d4e5f60718  b=2").?);
    // a substring of another token is not a token (the fx.store lesson)
    try std.testing.expect(parseKernelNonce("notfx.bootnonce=deadbeef") == null);
    try std.testing.expect(parseKernelNonce("fx.bootnonce=") == null);
    try std.testing.expect(parseKernelNonce("fx.bootnonce= console=ttyS0") == null);
    try std.testing.expect(parseKernelNonce("fx.bootnonce=\n") == null);
    // "none" is the WRITER's placeholder — a host may not mint lines that
    // read as "no nonce was issued"
    try std.testing.expect(parseKernelNonce("fx.bootnonce=none") == null);
    try std.testing.expect(parseKernelNonce("fx.bootnonce=none fx.bootnonce=deadbeef01") == null); // first token wins, and it is reserved
    // length bound: the 65-byte buffer backs the global; a longer token
    // must not be truncated into a DIFFERENT nonce silently
    const nonce65 = "d" ** 65;
    const nonce64 = "d" ** 64;
    try std.testing.expect(parseKernelNonce("fx.bootnonce=" ++ nonce65) == null);
    try std.testing.expectEqualStrings(nonce64, parseKernelNonce("fx.bootnonce=" ++ nonce64).?); // the cap itself is legal
    // no token: the normal case (hand-boot)
    try std.testing.expect(parseKernelNonce("console=ttyS0,115200 rdinit=/fx/store/x/fx-init fx.store=/fx/store panic=-1 oops=panic\n") == null);
}

test "operator_line: the intervention grammar — epoch-first, verbatim arg, '-' for no move" {
    var buf: [REQ_MAX + 256]u8 = undefined;
    // the nonce is a PARAMETER: a row never reads a global latch, so the
    // same call can carry the controller's token and a direct exec's own
    const l = line(&buf, 1700000000, "rollback", "7", "ok", 9, 7, "none");
    try std.testing.expectEqualStrings("1700000000 rollback 7 ok 9 7 none\n", l);
    // a FAILED activation still records the intervention, with the
    // executor's rc in the outcome token and "-" for the unknown result
    const l2 = line(&buf, 5, "activate", "/etc/bad.dhall", "failed:2", 9, null, "none");
    try std.testing.expectEqualStrings("5 activate /etc/bad.dhall failed:2 9 - none\n", l2);
    // a shutdown moves no generation: from is the running version, to "-"
    const l3 = line(&buf, 6, "shutdown", "-", "ok", 13, null, "none");
    try std.testing.expectEqualStrings("6 shutdown - ok 13 - none\n", l3);
    // an issued nonce binds the row to the boot it happened in — the same
    // latched token .bootlog/.recovery carry, not a new discipline
    const l4 = line(&buf, 7, "rollback", "9999", "refused", 13, null, "deadbeef");
    try std.testing.expectEqualStrings("7 rollback 9999 refused 13 - deadbeef\n", l4);
    // a direct exec's OWN row: the shape is identical (one grammar), the
    // nonce is the parsed token — never "none" (the predicate forbids it)
    const l5 = line(&buf, 8, "activate", "/run/fx/config-a.dhall", "ok", 4, 5, "d00dfeed00000001");
    try std.testing.expectEqualStrings("8 activate /run/fx/config-a.dhall ok 4 5 d00dfeed00000001\n", l5);
    // the header's grammar line documents the data format, and the header
    // itself must NAME the paths it cannot see (a record that silently
    // omits a class is worse than none)
    try std.testing.expect(std.mem.indexOf(u8, OPERATOR_HEADER, "<epoch-s>") != null);
    try std.testing.expect(std.mem.indexOf(u8, OPERATOR_HEADER, "fxstore rollback") != null);
    try std.testing.expect(std.mem.indexOf(u8, OPERATOR_HEADER, "NOT recorded") != null);
    // ...and it must state the EXCEPTION to the single-writer claim, the
    // invariant a channel activation still holds (ONE row), and the direct
    // exec's narrower record (a committed publish, not a request)
    try std.testing.expect(std.mem.indexOf(u8, OPERATOR_HEADER, "TWO writers") != null);
    try std.testing.expect(std.mem.indexOf(u8, OPERATOR_HEADER, "EXACTLY ONE row") != null);
}

test "line: a pathological arg truncates rather than overflowing the row" {
    var buf: [REQ_MAX + 256]u8 = undefined;
    const huge = "x" ** (REQ_MAX + 900);
    const l = line(&buf, 1, "activate", huge, "ok", 0, 1, "abc");
    // snprintf semantics: the row is CUT at the buffer's cap (never written
    // past it), the same truncation the C's fixed buffer did
    try std.testing.expectEqual(buf.len - 1, l.len);
    try std.testing.expect(!std.mem.endsWith(u8, l, "\n"));
}
