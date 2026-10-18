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
//!
//! THIS MODULE ALSO OWNS THE REBOOT ROW — its action/outcome vocabulary,
//! the row parser, the bounded tail reader and the PURE admission function
//! over (verdict latch, .operator tail, shell state).  Pure on purpose: the
//! admission is the thing that must say NO to a reboot that would fabricate
//! a failure, and it is decided without a channel, a store or a boot, so it
//! can be unit-tested exactly where it can be wrong.
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
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, f: *FILE) usize;
extern "c" fn fseek(f: *FILE, off: c_long, whence: c_int) c_int;
extern "c" fn ftell(f: *FILE) c_long;
extern "c" fn fsync(fd: c_int) c_int;
extern "c" fn syncfs(fd: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;

const O_RDONLY: c_int = 0o0;
const O_DIRECTORY: c_int = 0o200000; // x86_64 (asm-generic): directory-only open
const SEEK_SET: c_int = 0;
const SEEK_END: c_int = 2;

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
    \\#   action:  activate | rollback | shutdown | reboot (the ctrl arm that
    \\#            wrote it)
    \\#   arg:     the operator's operand VERBATIM (config path, requested
    \\#            version, "-" for shutdown; for reboot, the requester's
    \\#            reason token — the verb takes no operand)
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
    \\# REBOOT ROWS (action `reboot`) — the one intervention that moves NO
    \\# generation and is recorded here anyway: a reboot re-enters the boot
    \\# path, which re-reads CURRENT from the store and RE-JUDGES it, so it
    \\# acts on the generation plane without moving it.  arg = the
    \\# requester's reason token; from = CURRENT at the request; to = "-"
    \\# (a reboot moves no generation by itself).  The outcome vocabulary is
    \\# these six tokens and nothing else:
    \\#            ok               ADMITTED — the machine re-enters
    \\#            not-decided      REFUSED: NO VERDICT YET — the grace
    \\#                             window is still open.  A TIMING, and
    \\#                             deliberately a different token from
    \\#                             boot-failed below: "did not know yet" and
    \\#                             "knew, and the answer was bad" are two
    \\#                             states, and a durable record must not
    \\#                             conflate them.  WHY IT IS A
    \\#                             REFUSAL AND NOT A WARNING: a reboot
    \\#                             inside the window leaves the bootlog tail
    \\#                             in-progress, and the next boot's
    \\#                             roll-forward fires on in-progress OR
    \\#                             failed — it would ROLL BACK and write a
    \\#                             .recovery row naming a content that never
    \\#                             ran as a FAILURE.  Two of those reach
    \\#                             recovery's content-fail bound and
    \\#                             PERMANENTLY condemn that content.
    \\#            boot-failed      REFUSED: the verdict LANDED and it is
    \\#                             FAILED — a STATE, not a timing, and its
    \\#                             own token for that reason.  Still
    \\#                             refused on purpose: the guardrail
    \\#                             already rolls forward at the next boot,
    \\#                             so an agent-forced extra reboot would be
    \\#                             a redundant boot of a generation already
    \\#                             condemned (the verb for it is `rollback`,
    \\#                             which is gated and recorded).
    \\#            shell-open       REFUSED: an interactive shell is open on
    \\#                             the console — a re-entry under a human is
    \\#                             a surprise (a shutdown leaves the same
    \\#                             shell running).
    \\#            same-version-loop REFUSED: the THIRD consecutive ADMITTED
    \\#                             reboot whose row carries the same
    \\#                             from-version (REBOOT_SAME_VERSION_MAX =
    \\#                             2).  Read the reboot rows backwards: two
    \\#                             with an identical from-version and no
    \\#                             intervening generation move are two
    \\#                             reboots that changed nothing.
    \\#            exec-error       ADMITTED but the re-entry could not be
    \\#                             executed; the machine is UNCHANGED.  The
    \\#                             row records the ADMISSION, not the
    \\#                             execution.
    \\#   The refusal tokens are deliberately NOT the activation-refusal
    \\#   vocabulary (`failed:<rc>`, `refused`, `refused-config` — see
    \\#   tools/fx-report.c outcome_is_refusal): a reboot refusal is not an
    \\#   activation refusal, and reporting it as one is exactly the
    \\#   silent-defect shape a shared token set would create.
    \\#   A reboot row records the ADMISSION, as the shutdown arm records its
    \\#   own request.  An admitted reboot that NEVER EXECUTED is visible as
    \\#   the ABSENCE of a later .bootlog line carrying this row's nonce and a
    \\#   later epoch — a soft reboot re-enters the boot path under the SAME
    \\#   nonce (the kernel command line does not change), so this row and the
    \\#   boot it produced are joined by nonce plus order, exactly as a row is
    \\#   joined to the boot that wrote it.  A machine that never rebooted
    \\#   reads zero reboot rows — a measurement, not an absence.
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

// ─── the reboot row: vocabulary, reader, and the PURE admission ───────────
//
// A soft reboot of the guest is an OPERATOR intervention on the generation
// plane even though it moves no generation: it re-enters the boot path,
// which re-reads CURRENT from the store and re-judges it.  So it is a row
// in THIS file, in THIS grammar — and the vocabulary below is its whole
// definition, shared by the writer (PID1's control handler) and every
// reader.  Neither may invent a sixth outcome token.

/// The action token of a reboot row.  Distinct from `shutdown`, which stops
/// the machine instead of re-entering it.
pub const REBOOT_ACTION = "reboot";

/// The most CONSECUTIVE ADMITTED reboots whose row carries the SAME
/// `from-version`: the third is refused (`same-version-loop`).  A reboot
/// that moves no generation is provably near-no-op in this system — the
/// boot path re-materialises /etc and /bin from the SAME store — so two is
/// already one more than a legitimate loop needs.  2 and not another N,
/// symmetric with the recovery guardrail's content-fail bound
/// (RECOVERY_CONTENT_FAIL_MAX = 2, init.zig:1050); never re-tuned in place:
/// this constant IS the bound the header cites.
pub const REBOOT_SAME_VERSION_MAX: u32 = 2;

/// A reboot row's outcome: the six tokens the header defines.  The two
/// verdict refusals are SEPARATE STATES, not one condition with two causes:
/// `not-decided` is a TIMING (the verdict has not landed yet — the grace
/// window is still open) and `boot-failed` is a STATE (the verdict landed,
/// and it is FAILED).  A durable record may not conflate the two: a reader
/// asking "did this machine refuse because it did not know, or because it
/// knew and the answer was bad?" must be able to tell from the row alone.
pub const RebootOutcome = enum {
    /// admitted — the machine may re-enter
    admitted,
    /// refused — NO VERDICT YET (a timing condition).  The outcome that
    /// exists for the hazard: rebooting on an in-progress bootlog tail makes
    /// the next boot's roll-forward record a FAILURE for a content that
    /// never ran.
    not_decided,
    /// refused — the verdict landed and it is FAILED (a state, not a timing).
    /// Still refused, deliberately: the guardrail already rolls forward at
    /// the next boot, so an agent-forced extra reboot would be a redundant
    /// boot of a generation already condemned.
    boot_failed,
    /// refused — an interactive shell is open on the console
    shell_open,
    /// refused — REBOOT_SAME_VERSION_MAX consecutive admitted reboots at
    /// this from-version
    same_version_loop,
    /// admitted, but the re-entry could not be executed (execve failed);
    /// the machine is unchanged
    exec_error,

    pub fn token(self: RebootOutcome) []const u8 {
        return switch (self) {
            .admitted => "ok",
            .not_decided => "not-decided",
            .boot_failed => "boot-failed",
            .shell_open => "shell-open",
            .same_version_loop => "same-version-loop",
            .exec_error => "exec-error",
        };
    }

    pub fn fromToken(t: []const u8) ?RebootOutcome {
        if (std.mem.eql(u8, t, "ok")) return .admitted;
        if (std.mem.eql(u8, t, "not-decided")) return .not_decided;
        if (std.mem.eql(u8, t, "boot-failed")) return .boot_failed;
        if (std.mem.eql(u8, t, "shell-open")) return .shell_open;
        if (std.mem.eql(u8, t, "same-version-loop")) return .same_version_loop;
        if (std.mem.eql(u8, t, "exec-error")) return .exec_error;
        return null;
    }
};

/// Why an admission was REFUSED — the four refusal tokens, as their own
/// type so a caller cannot record `ok`/`exec-error` as a REFUSAL reason
/// (the mapping to the journal token is the exhaustive switch below).
/// `not_decided` and `boot_failed` are DISTINCT here for the same reason
/// they are distinct in the row: a timing is not a state.
pub const Refusal = enum {
    not_decided,
    boot_failed,
    shell_open,
    same_version_loop,

    pub fn outcome(self: Refusal) RebootOutcome {
        return switch (self) {
            .not_decided => .not_decided,
            .boot_failed => .boot_failed,
            .shell_open => .shell_open,
            .same_version_loop => .same_version_loop,
        };
    }
};

/// The admission's answer: `admit`, or `refuse` with a NAMED reason.
pub const Decision = union(enum) {
    admit,
    refuse: Refusal,

    /// The token to record in the row — admission and refusal are recorded
    /// in the SAME outcome field (the journal's grammar has one).
    pub fn outcome(self: Decision) RebootOutcome {
        return switch (self) {
            .admit => .admitted,
            .refuse => |r| r.outcome(),
        };
    }
};

/// The boot VERDICT LATCH as PID1 holds it (`g_boot_decided` :244 /
/// `g_boot_failed` :245 in init.zig).  Passed by value: the admission reads
/// the latch, it never latches anything.
pub const Latch = struct {
    decided: bool = false,
    failed: bool = false,
};

/// THE COLLISION, named.  `activate` RE-ARMS the boot decision for the
/// generation it landed: fx-init's activate arm resets both latch fields
/// and restarts the grace window (init.zig:3797-3800, the post-activate
/// re-arm), so
/// for up to grace_ms after an activation the machine is UNDECIDED — and
/// "activate, then reboot into it" is exactly that window.  The loop is
/// therefore activate -> POLL STATUS until the post-activate verdict ->
/// reboot, and the refusal says so: the reboot may never contradict a
/// verdict.  Named here (not inlined at the call site) because a caller
/// that "knows" the latch is stale is the bug this constant documents.
pub const LATCH_AFTER_ACTIVATE: Latch = .{ .decided = false, .failed = false };

/// A boot may ask for a reboot only when its verdict is DECIDED and OK.
/// A FAILED verdict cannot ask — the verb for that is `rollback`, which
/// exists, is gated and is recorded.  This one predicate is also what makes
/// the recovery GIVE-UP boot (which holds at current and boots failed)
/// unable to ask for free.
pub fn isDecidedOk(l: Latch) bool {
    return l.decided and !l.failed;
}

/// THE ADMISSION — pure, and deliberately so: it is the thing that must say
/// NO where saying yes is silent, so it is decidable without a channel, a
/// store or a boot, and unit-tested exactly where it can be wrong.
///
/// ORDER IS THE GUARD: the latch first (the hazard), then the human, then
/// the loop bound.
///   1. no decided-OK verdict  -> refuse, and SAY WHICH: `not-decided`
///      when the verdict has not landed (a timing), `boot-failed` when it
///      landed FAILED (a state).  Both refuse; only the record differs —
///      it is a RECORD-HONESTY distinction, not a behaviour one.  A reboot
///      on an in-progress bootlog tail makes decide_boot_version's roll-forward
///      fire (its trigger is in-progress OR failed, init.zig:1729-1731),
///      which ROLLS BACK and writes a .recovery row carrying that
///      generation's genhash AS A FAILURE; RECOVERY_CONTENT_FAIL_MAX of
///      those (init.zig:1050) permanently condemn content that never ran.
///   2. an open interactive shell -> refuse `shell-open` (g_shell_pid,
///      init.zig:226).
///   3. REBOOT_SAME_VERSION_MAX consecutive admitted reboots at this
///      from-version -> refuse `same-version-loop`.
///   else admit.
///
/// `cur_version` is the store CURRENT the would-be row's from-version would
/// carry (the caller passes `g_current_version`); `tail` is the `.operator`
/// tail as bytes — `readTail` supplies an unbounded-journal-bounded slice of
/// it.
pub fn admit(latch: Latch, cur_version: u32, tail: []const u8, shell_open: bool) Decision {
    // ONE guard, TWO named reasons, derived here so the predicate and the
    // reasons cannot drift: a decided-FAILED boot refuses `boot-failed`
    // (a STATE), an undecided one refuses `not-decided` (a TIMING).
    if (!isDecidedOk(latch)) return .{ .refuse = if (!latch.decided) Refusal.not_decided else Refusal.boot_failed };
    if (shell_open) return .{ .refuse = .shell_open };
    if (consecutiveRebootsAt(tail, cur_version) >= REBOOT_SAME_VERSION_MAX) return .{ .refuse = .same_version_loop };
    return .admit;
}

/// One parsed journal row.  Slices point INTO the line the caller passed —
/// no allocation, so a reader over a bounded tail costs nothing.
pub const Row = struct {
    epoch: u32,
    action: []const u8,
    arg: []const u8,
    outcome: []const u8,
    v_from: u32,
    v_to: ?u32,
    nonce: []const u8,
};

/// Parse ONE journal line in the grammar the header defines.  Returns null
/// for anything that is NOT a data row of that grammar: a header/comment
/// line, a blank line, format drift, or a line whose arg field was split by
/// a space (the one input that can produce a row the C reader refuses — see
/// activate.zig's note).  Every caller treats null as "nothing to count":
/// the fail-open direction all readers of these records take, because a
/// misread must never refuse an operator action, only fail to observe one.
pub fn parseLine(text: []const u8) ?Row {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (s.len == 0 or !std.ascii.isDigit(s[0])) return null;
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    const ep = it.next() orelse return null;
    const action = it.next() orelse return null;
    const arg = it.next() orelse return null;
    const outcome = it.next() orelse return null;
    const from = it.next() orelse return null;
    const to = it.next() orelse return null;
    const nonce = it.next() orelse return null;
    if (it.next() != null) return null; // an eighth field: drift, not a row
    const epoch = std.fmt.parseInt(u32, ep, 10) catch return null;
    const v_from = std.fmt.parseInt(u32, from, 10) catch return null;
    const v_to: ?u32 = if (std.mem.eql(u8, to, "-")) null else (std.fmt.parseInt(u32, to, 10) catch return null);
    return .{ .epoch = epoch, .action = action, .arg = arg, .outcome = outcome, .v_from = v_from, .v_to = v_to, .nonce = nonce };
}

pub fn isReboot(r: Row) bool {
    return std.mem.eql(u8, r.action, REBOOT_ACTION);
}

/// Did this row MOVE the generation?  A move ends any reboot streak, because
/// the reboots either side of it were issued against different CURRENTs.
fn movedGeneration(r: Row) bool {
    const to = r.v_to orelse return false;
    return to != r.v_from;
}

/// How many ADMITTED reboot rows at the TAIL of `tail` carry `cur_version`
/// as their from-version, with no generation move between them — i.e. how
/// many reboots have already happened against the generation that is
/// current NOW.  Refused reboot rows are skipped (a refusal is not a reboot
/// that happened); the walk stops at the first reboot row from a different
/// version, at any generation move, and at the end of the buffer.
///
/// Version numbers identify a generation because the store never re-mints
/// one: a publish, a rollback and the recovery republish all allocate a NEW
/// higher version (INTERPRETATION, but it is what makes this row comparison
/// sound — an equal from-version on two rows means the same generation).
///
/// A caller that hands in an arbitrary byte range (rather than `readTail`'s
/// line-aligned one) may include ONE partial line, and only at the OLDEST
/// end: its epoch field is what truncation eats first, so a truncated line
/// either fails to parse (ignored) or parses with all seven fields and can
/// then only be the oldest row.  The error is therefore CONSERVATIVE — it
/// can refuse one reboot that would have been admissible, never admit one
/// that should have been refused.
pub fn consecutiveRebootsAt(tail: []const u8, cur_version: u32) u32 {
    var n: u32 = 0;
    var end: usize = tail.len;
    while (end > 0) {
        var stop = end;
        if (tail[stop - 1] == '\n') stop -= 1;
        if (stop > 0 and tail[stop - 1] == '\r') stop -= 1;
        var start = stop;
        while (start > 0 and tail[start - 1] != '\n') start -= 1;
        end = start;
        const r = parseLine(tail[start..stop]) orelse continue;
        if (isReboot(r)) {
            if (r.v_from != cur_version) break;
            if (RebootOutcome.fromToken(r.outcome)) |o| {
                if (o == .admitted) n += 1;
            }
        } else if (movedGeneration(r)) break;
    }
    return n;
}

/// Read the LAST `buf.len` bytes of the journal at `path` and return them
/// starting at a LINE BOUNDARY (the leading partial line, if any, is
/// dropped) — a bounded read because the journal is append-only and grows
/// for the machine's life, so "read the whole file" is not a shape a boot
/// path can have.  "" when the file is absent or unreadable: the same
/// measurement-by-absence the journal itself uses, and the direction the
/// admission fails open in.
pub fn readTail(path: [*:0]const u8, buf: []u8) []const u8 {
    if (buf.len == 0) return "";
    const f = fopen(path, "r") orelse return "";
    defer _ = fclose(f);
    if (fseek(f, 0, SEEK_END) != 0) return "";
    const size = ftell(f);
    if (size < 0) return "";
    const total: usize = @intCast(size);
    const want: usize = @min(total, buf.len);
    const off: usize = total - want;
    if (fseek(f, @intCast(off), SEEK_SET) != 0) return "";
    const got = fread(buf.ptr, 1, want, f);
    var s = buf[0..got];
    if (off != 0) {
        // the first byte is mid-file: the line it belongs to is partial
        const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return "";
        s = s[nl + 1 ..];
    }
    return s;
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

// ─── reboot row: vocabulary, reader, and the pure admission ───────────────
//
// THE DIRECTION THESE TESTS ARE BUILT IN: an admission function that ALWAYS
// ADMITS looks IDENTICAL on the happy path, so a battery built on the
// admitted case alone would pass with every clause deleted.  Each refusal
// reason therefore has its OWN fixture, each fixture is otherwise quiet (the
// clause under test is the only one that can refuse it), and each states
// which mutation it is the sensitivity for.

/// fx-report's activation-refusal predicate MIRRORED (tools/fx-report.c
/// outcome_is_refusal — a different repo, so it cannot be imported): every
/// row matching it is emitted as an ACTIVATION-REFUSAL event.  It is the
/// trap the reboot outcome vocabulary is constrained by, and the assertion
/// in the vocabulary test below is what keeps a future token from walking
/// into it.
fn fxReportActivationRefusal(outcome: []const u8) bool {
    return std.mem.startsWith(u8, outcome, "failed:") or
        std.mem.eql(u8, outcome, "refused") or
        std.mem.eql(u8, outcome, "refused-config");
}

/// `tail` fixture builder: append one row in the journal's own grammar, in
/// order, so a fixture is written by the SAME builder the writers use.
fn appendRow(out: []u8, used: *usize, epoch: u32, action: []const u8, arg: []const u8, outcome: []const u8, from: u32, to: ?u32, nonce: []const u8) void {
    var one: [REQ_MAX + 256]u8 = undefined;
    const l = line(&one, epoch, action, arg, outcome, from, to, nonce);
    @memcpy(out[used.*..][0..l.len], l);
    used.* += l.len;
}

fn refuseReason(d: Decision) ?Refusal {
    return switch (d) {
        .admit => null,
        .refuse => |r| r,
    };
}

/// The assertions speak in NAMED failures, not in null-unwraps: a mutant that
/// admits where it must refuse then fails with `TestExpectedRefusal` instead
/// of a panic, which is the difference between an asymmetry and a crash.
fn expectRefusal(d: Decision, want: Refusal) !void {
    const got = refuseReason(d) orelse return error.TestExpectedRefusal;
    try testing.expectEqual(want, got);
}

fn expectAdmitted(d: Decision) !void {
    if (refuseReason(d)) |r| {
        std.debug.print("expected ADMIT, got refusal {s} ({s})\n", .{ @tagName(r), d.outcome().token() });
        return error.TestExpectedAdmit;
    }
    try testing.expectEqual(RebootOutcome.admitted, d.outcome());
}

test "reboot vocabulary: six tokens, round-trip, distinct, and none reads as an activation refusal" {
    const all = [_]RebootOutcome{ .admitted, .not_decided, .boot_failed, .shell_open, .same_version_loop, .exec_error };
    for (all) |o| {
        // the token IS the file's word and back again — one vocabulary, not two
        try testing.expectEqual(o, RebootOutcome.fromToken(o.token()).?);
        // THE TRAP (fx-report.c outcome_is_refusal): a reboot refusal must
        // never be reported as an ACTIVATION refusal
        try testing.expect(!fxReportActivationRefusal(o.token()));
    }
    // distinct: one field, one meaning
    for (all, 0..) |a, i| for (all[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.token(), b.token()));
    // drift is NOT a token — an unknown word is unreadable, never silently "ok"
    try testing.expect(RebootOutcome.fromToken("refused") == null);
    try testing.expect(RebootOutcome.fromToken("failed:2") == null);
    try testing.expect(RebootOutcome.fromToken("") == null);
    // the header IS the definition: it names the action, every token, the
    // loop bound, and the hazard the not-decided refusal exists for
    for (all) |o| try testing.expect(std.mem.indexOf(u8, OPERATOR_HEADER, o.token()) != null);
    try testing.expect(std.mem.indexOf(u8, OPERATOR_HEADER, "| reboot") != null);
    try testing.expect(std.mem.indexOf(u8, OPERATOR_HEADER, "REBOOT_SAME_VERSION_MAX") != null);
    // the hazard is stated where a reader of the FILE meets it, not only in
    // this source
    try testing.expect(std.mem.indexOf(u8, OPERATOR_HEADER, "ran as a FAILURE") != null);
    try testing.expect(std.mem.indexOf(u8, OPERATOR_HEADER, "PERMANENTLY condemn") != null);
    try testing.expect(std.mem.indexOf(u8, OPERATOR_HEADER, "ADMISSION, not the") != null);
}

test "reboot admission: a DECIDED-OK boot with a quiet tail is ADMITTED" {
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    appendRow(&buf, &n, 100, "activate", "/etc/a.dhall", "ok", 4, 5, "n1");
    // a NON-reboot row that moves no generation (a shutdown) is quiet too:
    // the tail's shape is the operator's history, not a reboot count
    appendRow(&buf, &n, 101, "shutdown", "-", "ok", 5, null, "n1");
    try expectAdmitted(admit(.{ .decided = true, .failed = false }, 5, buf[0..n], false));
}

test "reboot admission: an UNDECIDED boot (grace window open) is REFUSED not-decided" {
    // THE HAZARD THIS FIXTURE IS: until the verdict, the .bootlog tail is
    // (v, in-progress), and decide_boot_version's roll-forward fires on
    // in-progress OR failed (init.zig:1729-1731) — so a reboot here ROLLS
    // BACK and writes a .recovery row carrying a genhash that never failed.
    // Two of those (RECOVERY_CONTENT_FAIL_MAX) condemn the content.
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    appendRow(&buf, &n, 100, "activate", "/etc/a.dhall", "ok", 4, 5, "n1");
    const tail = buf[0..n];

    // DIRECTION / MUT-DECIDED: delete the latch clause from admit() and THIS
    // is the assertion that fails.  It fails here and not in the ADMITTED
    // test above — the tail is quiet and the shell is closed, so the latch is
    // the only clause that can refuse this fixture, and the mutation's
    // fall-through admits it.  That asymmetry is the whole point: a function
    // that always admits is indistinguishable on the happy path.
    const d = admit(.{ .decided = false, .failed = false }, 5, tail, false);
    try expectRefusal(d, .not_decided);
    try testing.expectEqual(RebootOutcome.not_decided, d.outcome()); // the row token
}

test "reboot admission: a decided-FAILED verdict and an open shell are REFUSED, each named" {
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    appendRow(&buf, &n, 100, "activate", "/etc/a.dhall", "ok", 4, 5, "n1");
    const tail = buf[0..n];

    // THE GIVE-UP BOOT, exactly: it holds at current, boots, fails, holds
    // again — and this clause is the only thing that stops it asking for a
    // reboot of its own failure.  A generation whose verdict is failed uses
    // `rollback`, which exists and is recorded.  (The token is the STATE one,
    // not the timing one — see the dedicated distinction test below.)
    try expectRefusal(admit(.{ .decided = true, .failed = true }, 5, tail, false), .boot_failed);

    // a human at the console: refused, and NAMED — a reboot refused because
    // someone is sitting at a shell must not read as a verdict problem
    try expectRefusal(admit(.{ .decided = true, .failed = false }, 5, tail, true), .shell_open);

    // and the shell clause does not pre-empt the hazard: undecided WITH a
    // shell open reports the latch, because the latch is why a reboot may
    // never contradict a verdict
    try expectRefusal(admit(.{ .decided = false, .failed = false }, 5, tail, true), .not_decided);
}

test "reboot admission: a decided-FAILED boot refuses boot-failed, NOT not-decided" {
    // THE RECORD OWES THE READER THIS DISTINCTION: `not-decided` is a TIMING
    // (no verdict has landed — the grace window is open) and `boot-failed` is
    // a STATE (the verdict landed, and it is FAILED).  One token for both
    // would say "we did not know yet" about a machine that knew perfectly
    // well.
    //
    // DIRECTION, and it is the point of this test: the mutation this fixture
    // is built for is the COLLAPSE (map the failed state onto the timing
    // token, or back onto one shared "no decided-OK verdict" reason), NOT the
    // deletion of the guard.  A collapse still REFUSES the boot — every
    // behavioural assertion in the battery stays true, and an always-refusing
    // function is indistinguishable from a correctly-refusing one on
    // behaviour alone.  Only the TOKEN assertions below can see it, which is
    // why they compare the two reasons explicitly, in both directions.
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    appendRow(&buf, &n, 100, "activate", "/etc/a.dhall", "ok", 4, 5, "n1");
    const tail = buf[0..n];

    // the verdict landed FAILED: that is a state
    const failed = admit(.{ .decided = true, .failed = true }, 5, tail, false);
    try expectRefusal(failed, .boot_failed);
    try testing.expectEqual(RebootOutcome.boot_failed, failed.outcome());
    try testing.expectEqualStrings("boot-failed", failed.outcome().token());
    try testing.expect(refuseReason(failed).? != .not_decided);

    // the verdict has not landed: that is a timing — and it is NOT the state
    const pending = admit(.{ .decided = false, .failed = false }, 5, tail, false);
    try expectRefusal(pending, .not_decided);
    try testing.expect(refuseReason(pending).? != .boot_failed);

    // both still refuse (the behaviour is unchanged, deliberately — the
    // guardrail rolls a failed generation forward on its own, so an
    // agent-forced reboot of it would be a redundant boot of a condemned
    // generation)
    try testing.expect(refuseReason(failed) != null);
    try testing.expect(refuseReason(pending) != null);
    // and the two refusal tokens are distinct WORDS in the row, not two
    // spellings of one
    try testing.expect(!std.mem.eql(u8, RebootOutcome.boot_failed.token(), RebootOutcome.not_decided.token()));
}

test "reboot admission: REBOOT_SAME_VERSION_MAX consecutive same-from reboots is REFUSED" {
    var buf: [4096]u8 = undefined;
    var n0: usize = 0;
    appendRow(&buf, &n0, 100, "activate", "/etc/a.dhall", "ok", 4, 5, "n1");
    var n1: usize = n0;
    appendRow(&buf, &n1, 200, REBOOT_ACTION, "operator-request", "ok", 5, null, "n1");
    var n2: usize = n1;
    appendRow(&buf, &n2, 300, REBOOT_ACTION, "operator-request", "ok", 5, null, "n1");

    const ok_latch = Latch{ .decided = true };
    // ONE admitted reboot at this generation is within the bound — the
    // boundary is exactly REBOOT_SAME_VERSION_MAX, not one less
    try expectAdmitted(admit(ok_latch, 5, buf[0..n1], false));
    // the THIRD is refused, with its own reason (the maximum is two)
    try expectRefusal(admit(ok_latch, 5, buf[0..n2], false), .same_version_loop);

    // KEYED ON THE FROM-VERSION, not on the row count: the same two rows do
    // not bound a reboot of a DIFFERENT generation.  (Keying this on the row
    // count instead would read a legitimate post-activation reboot as a loop
    // — a refusal invented out of a healthy history.)
    try expectAdmitted(admit(ok_latch, 6, buf[0..n2], false));

    // a REFUSED reboot row is not a reboot that happened: two refusals at
    // this generation consume none of the bound
    var n3: usize = n0;
    appendRow(&buf, &n3, 200, REBOOT_ACTION, "operator-request", "not-decided", 5, null, "n1");
    var n4: usize = n3;
    appendRow(&buf, &n4, 300, REBOOT_ACTION, "operator-request", "shell-open", 5, null, "n1");
    try expectAdmitted(admit(ok_latch, 5, buf[0..n4], false));
}

test "reboot admission: activate RESETS the latch — so the loop is activate -> poll -> reboot" {
    // THE NAMED COLLISION (init.zig:3797-3800): the post-activate re-arm sets
    // g_boot_decided = 0 and g_boot_failed = 0 and restarts the grace window,
    // so the generation just activated is UNDECIDED for up to grace_ms — and
    // "activate, then reboot into it" is exactly that window.
    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    appendRow(&buf, &n, 100, "activate", "/etc/new.dhall", "ok", 5, 6, "n1");
    const tail = buf[0..n];

    // the SAME tail under the pre-activate (decided-ok) latch would be
    // admitted — the refusal is attributable to the LATCH, not to the tail,
    // and the tail's activate row breaks no streak either way
    try expectAdmitted(admit(.{ .decided = true, .failed = false }, 6, tail, false));
    // ...and immediately after the activation it is refused, because that is
    // what the latch actually holds then
    try expectRefusal(admit(LATCH_AFTER_ACTIVATE, 6, tail, false), .not_decided);
}

test "reboot row reader: the one grammar, and the tail walk stops at a generation move" {
    // a reboot row is written by the SAME line builder as every other row —
    // no second record format
    var buf: [REQ_MAX + 256]u8 = undefined;
    const l = line(&buf, 1700000500, REBOOT_ACTION, "operator-request", "ok", 7, null, "deadbeef");
    try testing.expectEqualStrings("1700000500 reboot operator-request ok 7 - deadbeef\n", l);
    const r = parseLine(l).?;
    try testing.expectEqual(@as(u32, 1700000500), r.epoch);
    try testing.expectEqualStrings(REBOOT_ACTION, r.action);
    try testing.expectEqualStrings("operator-request", r.arg);
    try testing.expectEqualStrings("ok", r.outcome);
    try testing.expectEqual(@as(u32, 7), r.v_from);
    try testing.expect(r.v_to == null); // a reboot moves no generation
    try testing.expectEqualStrings("deadbeef", r.nonce);
    try testing.expect(isReboot(r));

    // not rows: the file's own header, a blank line, a torn line, format
    // drift — all ignored (fail-open: a misread must never refuse an action,
    // only fail to observe one)
    try testing.expect(parseLine("# fx-init operator journal. One DATA line per OPERATOR intervention") == null);
    try testing.expect(parseLine("") == null);
    try testing.expect(parseLine("   \n") == null);
    try testing.expect(parseLine("99 reboot") == null); // torn
    try testing.expect(parseLine("99 reboot x ok 7 - n1 EXTRA") == null); // an eighth field
    try testing.expect(parseLine("epoch reboot x ok 7 - n1") == null); // drift

    // the walk: a streak, a MOVE, a streak — the move ends the first one, so
    // a reboot of v6 sees exactly one boot behind it
    var tbuf: [4096]u8 = undefined;
    var n: usize = 0;
    appendRow(&tbuf, &n, 100, "activate", "/etc/a.dhall", "ok", 4, 5, "n1");
    appendRow(&tbuf, &n, 200, REBOOT_ACTION, "operator-request", "ok", 5, null, "n1");
    appendRow(&tbuf, &n, 300, "activate", "/etc/b.dhall", "ok", 5, 6, "n1");
    appendRow(&tbuf, &n, 400, REBOOT_ACTION, "operator-request", "ok", 6, null, "n1");
    const tail = tbuf[0..n];
    try testing.expectEqual(@as(u32, 1), consecutiveRebootsAt(tail, 6));
    // v5: the NEWEST row is a reboot from v6, so the walk stops there — the
    // streak at v5 is over, because the last reboot was issued after the
    // generation moved
    try testing.expectEqual(@as(u32, 0), consecutiveRebootsAt(tail, 5));
    try testing.expectEqual(@as(u32, 0), consecutiveRebootsAt(tail, 4)); // no reboot at all at v4

    // and the walk reads the header without counting it
    const with_header = OPERATOR_HEADER ++ "200 reboot operator-request ok 5 - n1\n";
    try testing.expectEqual(@as(u32, 1), consecutiveRebootsAt(with_header, 5));
}

test "reboot tail read: bounded and line-aligned; an absent journal reads empty" {
    // an absent journal is a MEASUREMENT (zero interventions), not an error
    var small: [64]u8 = undefined;
    try testing.expectEqualStrings("", readTail("/nonexistent/fx-store/.operator", &small));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var buf: [4096]u8 = undefined;
    var n: usize = 0;
    // the OLDEST row is long enough that a 96-byte tail starts inside it: the
    // read must land on a line boundary, not mid-row
    appendRow(&buf, &n, 1, "activate", "/etc/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.dhall", "ok", 4, 5, "n1");
    appendRow(&buf, &n, 2, REBOOT_ACTION, "operator-request", "ok", 5, null, "n1");
    appendRow(&buf, &n, 3, REBOOT_ACTION, "operator-request", "ok", 5, null, "n1");
    try tmp.dir.writeFile(io, .{ .sub_path = ".operator", .data = buf[0..n] });

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, ".zig-cache/tmp/{s}/.operator", .{tmp.sub_path});
    var tail_buf: [96]u8 = undefined;
    const t = readTail(path.ptr, &tail_buf);

    // every line returned is WHOLE — the partial first line was dropped
    try testing.expect(t.len > 0 and t[t.len - 1] == '\n');
    var lines: u32 = 0;
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) break;
        try testing.expect(parseLine(ln) != null);
        lines += 1;
    }
    try testing.expectEqual(@as(u32, 2), lines); // the two reboot rows survive; the activate row is the cut

    // and the admission reaches the same verdict over the FILE tail as over
    // the same bytes: two admitted reboots at v5 is the bound
    try expectRefusal(admit(.{ .decided = true }, 5, t, false), .same_version_loop);
}
