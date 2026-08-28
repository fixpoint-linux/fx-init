// fxctl_check.zig — CLI twin of the C oracle zig/fxctl_dump.c: builds the
// request line from argv via the Zig port (fxctl.zig) and prints the SAME
// format, so fxctl_diff.sh can byte-diff stdout+stderr+rc against the
// oracle.  No subcommand -> usage on stderr, rc 2 (the C main's behavior
// before it would connect).
const std = @import("std");
const fxctl = @import("fxctl");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [8192]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_w.interface;

    if (args.len < 2) {
        fxctl.usage();
        try out.flush();
        std.process.exit(2);
    }

    var buf: [fxctl.LINE_MAX_REQ]u8 = undefined;
    const line = fxctl.requestLine(&buf, args[1..]);
    try out.print("req[{d}]=<{s}>\n", .{ line.len, line });
    try out.flush();
}
