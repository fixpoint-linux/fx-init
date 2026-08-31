// activate_paths.zig — unit-5 differential-harness helper (Zig replacement for
// the C oracle twin zig/activate_paths.c, which is removed with the C engine).
// Loads a package-set and runs the SAME compute_paths flow as fx-activate
// (fx_closure_compute -> fx_closure_names -> fx_topo_order ->
// fx_content_hash_dir / fx_derivation_hash_ex -> fx_store_path_of), then prints
// one store-RELATIVE `<hash>-<name>` per line.  activate_diff.sh pre-creates
// each printed dir (with a dummy payload) so the closure counts as BUILT —
// fx-activate only stats dir-ness (fx-activate.c:545 in the C-oracle era).
//
// usage: activate_paths --store DIR --package-set PATH ROOT...
//
// Built by zig build (activate_diff.sh no longer compiles any C); the dl_*
// externs resolve against the Zig-built libdatalog.so via build.zig's
// linkDatalog.
const std = @import("std");
const fx = @import("fxstore");

const c_alloc = std.heap.c_allocator;

fn die(comptime prog: []const u8, eb: anytype) noreturn {
    std.debug.print("{s}: {s}\n", .{ prog, eb.slice() });
    std.process.exit(1);
}

/// path entry: name + FULL store path (the C's `es[i].path`).
const Ent = struct {
    name: []const u8,
    path: []const u8,
};

fn entOf(es: []const Ent, name: []const u8) ?[]const u8 {
    for (es) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e.path;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;

    var store_root: ?[:0]const u8 = null;
    var pkgset_path: ?[:0]const u8 = null;
    var first_root: usize = args.len;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a: [:0]const u8 = args[i];
        if (std.mem.eql(u8, a, "--store") and i + 1 < args.len) {
            i += 1;
            store_root = args[i];
        } else if (std.mem.startsWith(u8, a, "--store=")) {
            store_root = a[8..];
        } else if (std.mem.eql(u8, a, "--package-set") and i + 1 < args.len) {
            i += 1;
            pkgset_path = args[i];
        } else if (std.mem.startsWith(u8, a, "--package-set=")) {
            pkgset_path = a[14..];
        } else {
            first_root = i;
            break;
        }
    }
    if (store_root == null or pkgset_path == null or first_root >= args.len) {
        std.debug.print("usage: activate_paths --store DIR --package-set PATH ROOT...\n", .{});
        std.process.exit(2);
    }

    var stdout_buf: [16384]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout_w.interface;

    var ps: fx.PackageSet = undefined;
    var pse = fx.packageset.ErrBuf{};
    fx.fx_packageset_load(&ps, pkgset_path.?, &pse) catch die("activate_paths", &pse);

    var se = fx.store.ErrBuf{};
    const s = fx.fx_store_open(io, store_root.?, &se) catch die("activate_paths", &se);
    const db = fx.fx_store_db(s).?;

    // the tail of fx-activate's compute_paths (fx-activate.c:101-145)
    var ce = fx.closure.ErrBuf{};
    fx.fx_closure_compute(db, &ps, args[first_root..], &ce) catch die("activate_paths", &ce);
    const names = fx.fx_closure_names(db, &ce) catch die("activate_paths", &ce);
    defer fx.free_names(names);
    const ord = fx.fx_topo_order(&ps, names, &ce) catch die("activate_paths", &ce);
    defer fx.free_order(ord);

    const es = c_alloc.alloc(Ent, @max(ord.len, 1)) catch @panic("out of memory");
    for (0..ord.len) |k| {
        const p = ord[k];
        var dep_paths: [][]const u8 = &.{};
        if (p.deps.len > 0) {
            const dp = c_alloc.alloc([]const u8, p.deps.len) catch @panic("out of memory");
            dep_paths = dp[0..];
            for (0..p.deps.len) |j| {
                dep_paths[j] = entOf(es[0..k], p.deps[j]) orelse
                    @panic("internal: dep unresolved");
            }
        }
        var h: [65]u8 = undefined;
        var sh: [65]u8 = undefined;
        var src_hash: ?[]const u8 = null;
        if (p.src.kind == .path) {
            var de = fx.derivation.ErrBuf{};
            fx.fx_content_hash_dir(io, p.src.path.?, p.excludes, &sh, &de) catch
                die("activate_paths", &de);
            src_hash = sh[0..64];
        }
        var de2 = fx.derivation.ErrBuf{};
        fx.fx_derivation_hash_ex(p, src_hash, dep_paths, &h, &de2) catch
            die("activate_paths", &de2);
        var path_buf: [4096]u8 = undefined;
        const path_s = fx.fx_store_path_of(store_root.?, h[0..64], p.name, &path_buf);
        // own the path (path_buf is loop-local; deps look it up by name later)
        es[k] = .{
            .name = p.name,
            .path = c_alloc.dupe(u8, path_s) catch @panic("out of memory"),
        };
        out.print("{s}-{s}\n", .{ h[0..64], p.name }) catch {};
    }
    out.flush() catch {};
}
