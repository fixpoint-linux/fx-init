// config_check.zig — CLI twin of the C oracle zig/config_dump.c: loads a
// config.dhall via the Zig port (config.zig) and prints the FULL FxConfig in
// the SAME canonical format, so config_diff.sh can byte-diff stdout+stderr+rc
// against the oracle.  Same stderr+rc contract on error.
const std = @import("std");
const config = @import("config");

pub fn main(init: std.process.Init) !void {
    // Options strings live in the process arena, freed together at exit.
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    if (args.len != 2) {
        // The oracle writes usage to stderr (config_dump.c:96).
        std.debug.print("usage: config_check <config.dhall>\n", .{});
        std.process.exit(2);
    }

    var cfg: config.FxConfig = undefined;
    var err = config.ErrBuf{};
    config.fx_config_load(&cfg, args[1], &err) catch {
        // stderr is unbuffered in the C (fprintf); std.debug.print matches.
        std.debug.print("fx-config-dump: {s}\n", .{err.slice()});
        std.process.exit(1);
    };

    try out.print("hostname={s}\n", .{cfg.hostname});
    for (cfg.packages, 0..) |p, i|
        try out.print("package[{d}]={s}\n", .{ i, p });
    for (cfg.users, 0..) |u, i| {
        try out.print("user[{d}].name={s}\n", .{ i, u.name });
        try out.print("user[{d}].uid={d}\n", .{ i, u.uid });
        for (u.groups, 0..) |g, j|
            try out.print("user[{d}].groups[{d}]={s}\n", .{ i, j, g });
    }
    for (cfg.services, 0..) |*s, i| {
        try out.print("service[{d}].name={s}\n", .{ i, s.name });
        for (s.argv, 0..) |a, j|
            try out.print("service[{d}].argv[{d}]={s}\n", .{ i, j, a });
        try out.print("service[{d}].pkg={s}\n", .{ i, s.pkg orelse "-" });
        try out.print("service[{d}].on_kind={s}\n", .{ i, s.on_kind.name() });
        try out.print("service[{d}].on_arg={s}\n", .{ i, s.on_arg orelse "-" });
        try out.print("service[{d}].restart={s}\n", .{ i, s.restart.name() });
        try out.print("service[{d}].backoff_ms={d}\n", .{ i, s.backoff_ms });
        try out.print("service[{d}].probe_kind={s}\n", .{ i, s.probe_kind.name() });
        try out.print("service[{d}].probe_arg={s}\n", .{ i, s.probe_arg orelse "-" });
        for (s.env, 0..) |kv, j| {
            try out.print("service[{d}].env[{d}].key={s}\n", .{ i, j, kv.key });
            try out.print("service[{d}].env[{d}].value={s}\n", .{ i, j, kv.value });
        }
    }
    for (cfg.extra_etc, 0..) |f, i| {
        try out.print("etc[{d}].path={s}\n", .{ i, f.path });
        try out.print("etc[{d}].content={s}\n", .{ i, f.content });
    }
    try out.print("grace_ms={d}\n", .{cfg.grace_ms});
    try out.flush();
}
