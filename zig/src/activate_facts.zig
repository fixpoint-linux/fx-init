// activate_facts.zig — unit-5 differential-harness helper (Zig replacement for
// the C oracle twin zig/activate_facts.c, which is removed with the C engine).
// Opens a store and dumps the 10 M4 relations fx-activate maintains
// (generation, svc, svc_argv, svc_env, svc_probe, svc_bin, svc_backoff, user,
// tool_fxstore, boot_grace) plus the published snapshot versions + CURRENT, as
// SORTED lines with sym columns resolved via dl_intern_str_of.  Raw-u32 columns
// (epoch, uid, idx, backoff_ms, grace_ms) print numerically; activate_diff.sh
// sed-normalizes the generation epoch.
//
// Must run AFTER the activator exits: dl_open holds a process-lifetime
// exclusive fcntl lock, so the dump opens its own store handle only once the
// writer is gone.
//
// usage: activate_facts --store DIR
const std = @import("std");
const fx = @import("fxstore");

const c_alloc = std.heap.c_allocator;

/// sym_mask bit i set = column i is an interned symbol; else raw u32.
const RelSpec = struct {
    rel: []const u8,
    arity: u8,
    sym_mask: u8,
};

const rels = [_]RelSpec{
    .{ .rel = "generation", .arity = 4, .sym_mask = 0x7 }, // (genhash, buildfile, dhake, epoch-raw)
    .{ .rel = "svc", .arity = 3, .sym_mask = 0x7 }, // (name, on, restart)
    .{ .rel = "svc_argv", .arity = 3, .sym_mask = 0x5 }, // (name, idx-raw, arg)
    .{ .rel = "svc_env", .arity = 3, .sym_mask = 0x7 }, // (name, key, value)
    .{ .rel = "svc_probe", .arity = 3, .sym_mask = 0x7 }, // (name, kind, arg)
    .{ .rel = "svc_bin", .arity = 2, .sym_mask = 0x3 }, // (name, path)
    .{ .rel = "svc_backoff", .arity = 2, .sym_mask = 0x1 }, // (name, backoff_ms-raw)
    .{ .rel = "user", .arity = 3, .sym_mask = 0x5 }, // (name, uid-raw, groups_csv)
    .{ .rel = "tool_fxstore", .arity = 1, .sym_mask = 0x1 }, // (path)
    .{ .rel = "boot_grace", .arity = 1, .sym_mask = 0x0 }, // (grace_ms-raw)
};

fn addLine(lines: *std.ArrayList([]const u8), line: []const u8) void {
    lines.append(c_alloc, line) catch @panic("out of memory");
}

fn dumpRel(db: *fx.DlDb, lines: *std.ArrayList([]const u8), r: RelSpec) void {
    const relz = c_alloc.dupeZ(u8, r.rel) catch @panic("out of memory");
    const it = fx.dl_iter_open(db, relz.ptr, null, 0) orelse return; // undeclared/empty
    if (fx.dl_iter_arity(it) != r.arity) {
        std.debug.print("activate_facts: arity mismatch on {s}\n", .{r.rel});
        std.process.exit(1);
    }
    var row: [8]u32 = undefined;
    while (fx.dl_iter_next(it, &row) == 1) {
        var aw: std.Io.Writer.Allocating = .init(c_alloc);
        aw.writer.print("{s}", .{r.rel}) catch unreachable;
        for (0..r.arity) |c| {
            if (r.sym_mask & (@as(u8, 1) << @intCast(c)) != 0) {
                const sp = if (fx.dl_intern_str_of(db, row[c])) |s| std.mem.span(s) else "<sym?>";
                aw.writer.print(" {s}", .{sp}) catch unreachable;
            } else {
                aw.writer.print(" {d}", .{row[c]}) catch unreachable;
            }
        }
        // process-lifetime CLI: the writer's c_alloc buffer becomes the stored
        // line (never freed); duplicate so each line is independently valid.
        addLine(lines, c_alloc.dupe(u8, aw.written()) catch @panic("out of memory"));
    }
    fx.dl_iter_close(it);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;

    var store_root: ?[:0]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: [:0]const u8 = args[i];
        if (std.mem.eql(u8, a, "--store") and i + 1 < args.len) {
            i += 1;
            store_root = args[i];
        } else if (std.mem.startsWith(u8, a, "--store=")) {
            store_root = a[8..];
        }
    }
    if (store_root == null) {
        std.debug.print("usage: activate_facts --store DIR\n", .{});
        std.process.exit(2);
    }

    var se = fx.store.ErrBuf{};
    const s = fx.fx_store_open(io, store_root.?, &se) catch {
        std.debug.print("activate_facts: {s}\n", .{se.slice()});
        std.process.exit(1);
    };
    const db = fx.fx_store_db(s).?;

    var lines = std.ArrayList([]const u8).empty;
    for (rels) |r| dumpRel(db, &lines, r);

    // published snapshot versions + CURRENT
    var vers: [256]u32 = undefined;
    const nv = fx.dl_snapshot_versions(db, &vers, 256);
    for (0..@intCast(nv)) |k| {
        const l = std.fmt.allocPrint(c_alloc, "version {d}", .{vers[k]}) catch @panic("out of memory");
        addLine(&lines, l);
    }
    var cur: u32 = 0;
    var se2 = fx.store.ErrBuf{};
    if (fx.fx_store_current_version(io, s, &cur, &se2)) |_| {
        const l = std.fmt.allocPrint(c_alloc, "current {d}", .{cur}) catch @panic("out of memory");
        addLine(&lines, l);
    } else |_| {}

    std.mem.sort([]const u8, lines.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var stdout_buf: [16384]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout_w.interface;
    for (lines.items) |l| out.print("{s}\n", .{l}) catch {};
    out.flush() catch {};
}
