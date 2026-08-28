// reloc_check.zig — CLI twin of the C oracle zig/reloc_dump.c: drives the
// Zig port (reloc.zig) and prints the SAME format, so reloc_diff.sh can
// byte-diff stdout+rc against the oracle:
//
//   success -> "OK <n>\n" + rewritten bytes + "\n" (rc 0)
//   NULL    -> "NULL\n"  (rc 1)
//
// argv: reloc_check <buildfile> <new_store>
const std = @import("std");
const reloc = @import("reloc");

pub fn main(init: std.process.Init) !void {
    // Options strings live in the process arena, freed together at exit.
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    if (args.len != 3) {
        try out.writeAll("usage: reloc_check <buildfile> <new_store>\n");
        try out.flush();
        std.process.exit(2);
    }

    const gfa = std.Io.Dir.cwd();
    const file = gfa.openFile(init.io, args[1], .{}) catch {
        std.debug.print("fx-reloc-dump: cannot open {s}\n", .{args[1]});
        std.process.exit(1);
    };
    defer file.close(init.io);
    const st = file.stat(init.io) catch {
        std.debug.print("fx-reloc-dump: cannot stat {s}\n", .{args[1]});
        std.process.exit(1);
    };
    const text = init.arena.allocator().alloc(u8, @intCast(st.size)) catch return error.OutOfMemory;
    var got: usize = 0;
    while (got < text.len) {
        const n = try file.readPositionalAll(init.io, text[got..], @intCast(got));
        if (n == 0) break;
        got += n;
    }

    const res = try reloc.fx_reloc_rewrite_buildfile(init.arena.allocator(), text[0..got], args[2]);
    const o = res orelse {
        try out.writeAll("NULL\n");
        try out.flush();
        std.process.exit(1);
    };
    try out.print("OK {d}\n{s}\n", .{ o.len, o });
    try out.flush();
}
