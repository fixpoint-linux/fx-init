// image_check.zig — unit tests for image.zig's byte layout (the U2+U5
// FX-header/MBR contract).
//
// These tests pin the FROZEN OFFSETS stage1/stage2 read — a change here is
// a contract change and must be broadcast on the fx-image channel.  U5's
// additions: stage1's trio at 0x0C/0x14/0x16 (u64/u16/u32, the widths
// stage1.S actually loads), the stage2 crc32 (cross-checked against an
// INDEPENDENT by-hand reflected crc32 implementation, not std.Crc32), the
// real stage1 embed + its 446-byte hard limit, and the dead
// hdr_size/hdr_sectors fields' removal (nothing reads them).
const std = @import("std");
const img = @import("image.zig");
const L = img.layout;

fn u16le(b: []const u8) u16 {
    return @as(u16, b[0]) | @as(u16, b[1]) << 8;
}

fn u32le(b: []const u8) u32 {
    return @as(u32, b[0]) | @as(u32, b[1]) << 8 | @as(u32, b[2]) << 16 | @as(u32, b[3]) << 24;
}

fn u64le(b: []const u8) u64 {
    var v: u64 = 0;
    for (b, 0..) |byte, i| v |= @as(u64, byte) << @intCast(8 * i);
    return v;
}

/// INDEPENDENT crc32 (reflected 0xEDB88320, init/final 0xFFFFFFFF — the
/// zlib.crc32 convention stage1.S implements bitwise).  Written from the
/// polynomial, NOT via std.hash.Crc32, so agreement between the two is
/// evidence about the convention and not a tautology.
fn crc32ZlibConv(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc ^= byte;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const mask: u32 = if (crc & 1 != 0) 0xEDB88320 else 0;
            crc = (crc >> 1) ^ mask;
        }
    }
    return ~crc;
}

test "MBR: signature, partition entry 1, real stage1 embed" {
    const disk_sectors: u64 = (512 << 20) >> 9; // 512 MiB
    // a stage1-shaped blob: 512 B, code in [0,446), zero table area (what
    // build-stage1.sh emits)
    var stage1 = [_]u8{0} ** 512;
    for (&stage1, 0..) |*b, i| {
        if (i < 296) b.* = @truncate(0xA0 + i); // 296 code bytes, like U3's
    }
    const mbr = try L.buildMbr(&stage1, disk_sectors);

    // 0x55AA at 510
    try std.testing.expectEqual(@as(u8, 0x55), mbr[510]);
    try std.testing.expectEqual(@as(u8, 0xAA), mbr[511]);

    // the blob's code area lands verbatim in [0, 446)
    try std.testing.expectEqualSlices(u8, stage1[0..446], mbr[0..446]);

    // partition entry 1 at 446: bootable, type 0x83, LBA start 65536, span
    try std.testing.expectEqual(@as(u8, 0x80), mbr[446]);
    try std.testing.expectEqual(@as(u8, 0x83), mbr[450]);
    try std.testing.expectEqual(@as(u32, 65536), u32le(mbr[454..458]));
    try std.testing.expectEqual(@as(u32, @intCast(disk_sectors - 65536)), u32le(mbr[458..462]));

    // entries 2-4 (462..510) stay zero
    for (mbr[462..510]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "MBR: a stage1 blob whose code reaches the table area HARD FAILS" {
    const disk_sectors: u64 = (512 << 20) >> 9;

    // code ending exactly AT 446 is fine (446 is the first table byte)
    var edge = [_]u8{0} ** 446;
    edge[445] = 0x90;
    _ = try L.buildMbr(&edge, disk_sectors);

    // nonzero at 446 (the first partition byte) is refused
    var over = [_]u8{0} ** 447;
    over[446] = 0x90;
    try std.testing.expectError(error.Stage1TooBig, L.buildMbr(&over, disk_sectors));

    // trailing zeros beyond 446 don't matter (a 512 B blob whose code
    // stops at 446 is legal — its table area is overwritten by ours)
    var padded = [_]u8{0} ** 512;
    padded[445] = 0x90;
    const m = try L.buildMbr(&padded, disk_sectors);
    try std.testing.expectEqual(@as(u8, 0x80), m[446]); // OUR entry, not the blob's
}

test "MBR: tiny disk -> zero-length partition span, no underflow" {
    var stage1 = [_]u8{0} ** 512;
    stage1[0] = 0xEB;
    const mbr = try L.buildMbr(&stage1, 65536); // exactly the partition start
    try std.testing.expectEqual(@as(u32, 0), u32le(mbr[458..462]));
    try std.testing.expectEqual(@as(u8, 0x55), mbr[510]);
}

test "FX header: magic, version, geometry round-trip, cmdline, shas, crc" {
    const kernel_sha = [_]u8{0xAB} ** 32;
    const initrd_sha = [_]u8{0xCD} ** 32;
    const cmdline = "console=ttyS0,115200 rdinit=/fx/store/h-fx-init/fx-init fx.store=/fx/store panic=-1 oops=panic";
    const stage2_crc: u32 = 0x12345678;
    const hd = L.HeaderIn{
        .stage2_lba = L.STAGE2_LBA,
        .stage2_sectors = L.STAGE2_SECTORS,
        .stage2_crc32 = stage2_crc,
        .kernel_lba = 69,
        .kernel_sectors = 3738,
        .initrd_lba = 69 + 3738,
        .initrd_sectors = 8192,
        .part1_start_lba = L.PART1_START_LBA,
        .part1_sectors = 1048576 - 65536,
    };
    const h = try L.buildHeader(hd, cmdline, kernel_sha, initrd_sha);

    // magic + fixed fields
    try std.testing.expectEqualSlices(u8, L.HDR_MAGIC, h[0..8]);
    try std.testing.expectEqual(L.HDR_VER, u32le(h[L.OFF_VER..][0..4]));

    // stage1's frozen trio, at stage1's offsets and widths
    try std.testing.expectEqual(@as(u64, 0x0C), L.OFF_STAGE2_LBA);
    try std.testing.expectEqual(@as(u64, 0x14), L.OFF_STAGE2_SECTORS);
    try std.testing.expectEqual(@as(u64, 0x16), L.OFF_STAGE2_CRC);
    try std.testing.expectEqual(hd.stage2_lba, u64le(h[L.OFF_STAGE2_LBA..][0..8]));
    try std.testing.expectEqual(@as(u16, 60), u16le(h[L.OFF_STAGE2_SECTORS..][0..2]));
    try std.testing.expectEqual(stage2_crc, u32le(h[L.OFF_STAGE2_CRC..][0..4]));
    // the bytes between the trio and stage2's kernel_lba (0x1A..0x27) stay
    // zero — no resurrected hdr_size/hdr_sectors ghost
    for (h[0x1A..0x28]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    // geometry round-trip (what stage2 reads)
    try std.testing.expectEqual(@as(u64, 0x28), L.OFF_KERNEL_LBA);
    try std.testing.expectEqual(@as(u64, 0x30), L.OFF_KERNEL_SECTORS);
    try std.testing.expectEqual(@as(u64, 0x38), L.OFF_INITRD_LBA);
    try std.testing.expectEqual(@as(u64, 0x40), L.OFF_INITRD_SECTORS);
    try std.testing.expectEqual(@as(u64, 0x48), L.OFF_CMDLINE_LEN);
    try std.testing.expectEqual(@as(u64, 0x140), L.OFF_CMDLINE);
    try std.testing.expectEqual(hd.kernel_lba, u64le(h[L.OFF_KERNEL_LBA..][0..8]));
    try std.testing.expectEqual(hd.kernel_sectors, u64le(h[L.OFF_KERNEL_SECTORS..][0..8]));
    try std.testing.expectEqual(hd.initrd_lba, u64le(h[L.OFF_INITRD_LBA..][0..8]));
    try std.testing.expectEqual(hd.initrd_sectors, u64le(h[L.OFF_INITRD_SECTORS..][0..8]));
    try std.testing.expectEqual(@as(u32, @intCast(cmdline.len)), u32le(h[L.OFF_CMDLINE_LEN..][0..4]));
    try std.testing.expectEqual(@as(u32, 65536), u32le(h[L.OFF_PART1_START..][0..4]));
    try std.testing.expectEqual(@as(u32, 1048576 - 65536), u32le(h[L.OFF_PART1_SECTORS..][0..4]));

    // payload fields
    try std.testing.expectEqualSlices(u8, &kernel_sha, h[L.OFF_KERNEL_SHA..][0..32]);
    try std.testing.expectEqualSlices(u8, &initrd_sha, h[L.OFF_INITRD_SHA..][0..32]);
    try std.testing.expectEqualSlices(u8, cmdline, h[L.OFF_CMDLINE..][0..cmdline.len]);
    // NUL terminator + zero pad after the cmdline
    try std.testing.expectEqual(@as(u8, 0), h[L.OFF_CMDLINE + cmdline.len]);
    try std.testing.expectEqual(@as(u8, 0), h[L.OFF_CMDLINE + L.CMDLINE_CAP - 1]);

    // reserved area stays zero
    for (h[0x940..0xFFC]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    // header crc over [0, 0xFFC)
    try std.testing.expectEqual(std.hash.Crc32.hash(h[0..L.OFF_HDR_SHA]), u32le(h[L.OFF_HDR_SHA..][0..4]));
    // the crc covers everything before it and sits in the last 4 bytes
    try std.testing.expectEqual(@as(u64, 0xFFC), L.OFF_HDR_SHA);
}

test "FX header: stage2 crc32 is the zlib convention stage1 implements" {
    // std.hash.Crc32 (what the builder hashes with) and the by-hand
    // reflected implementation must agree on the vectors stage1's bitwise
    // crc produces — the header value and stage1's recomputation meet.
    try std.testing.expectEqual(crc32ZlibConv(""), std.hash.Crc32.hash(""));

    try std.testing.expectEqual(crc32ZlibConv("123456789"), std.hash.Crc32.hash("123456789"));
    // the canonical reflected crc32 check value for "123456789"
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32ZlibConv("123456789"));

    // a stage2-area-shaped buffer: patterned code + zero pad to 60 sectors
    const area: usize = @intCast(L.STAGE2_SECTORS * L.SECTOR);
    var buf: [60 * 512]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = if (i < 1210) @truncate(0x5A ^ i) else 0;
    const crc = std.hash.Crc32.hash(buf[0..area]);
    try std.testing.expectEqual(crc32ZlibConv(buf[0..area]), crc);

    // and the header round-trips exactly that crc
    const h = try L.buildHeader(.{
        .stage2_lba = 9,
        .stage2_sectors = 60,
        .stage2_crc32 = crc,
        .kernel_lba = 69,
        .kernel_sectors = 1,
        .initrd_lba = 70,
        .initrd_sectors = 1,
        .part1_start_lba = 65536,
        .part1_sectors = 1,
    }, "", [_]u8{0} ** 32, [_]u8{0} ** 32);
    try std.testing.expectEqual(crc, u32le(h[L.OFF_STAGE2_CRC..][0..4]));
}

test "FX header: fields do not overlap (offset monotonicity)" {
    // the frozen table's fields, with their true widths — dense but
    // non-overlapping; a change to any offset must keep this true
    const fields = [_]struct { off: u64, len: u64 }{
        .{ .off = L.OFF_VER, .len = 4 },
        .{ .off = L.OFF_STAGE2_LBA, .len = 8 },
        .{ .off = L.OFF_STAGE2_SECTORS, .len = 2 },
        .{ .off = L.OFF_STAGE2_CRC, .len = 4 },
        .{ .off = L.OFF_KERNEL_LBA, .len = 8 },
        .{ .off = L.OFF_KERNEL_SECTORS, .len = 8 },
        .{ .off = L.OFF_INITRD_LBA, .len = 8 },
        .{ .off = L.OFF_INITRD_SECTORS, .len = 8 },
        .{ .off = L.OFF_CMDLINE_LEN, .len = 4 },
        .{ .off = L.OFF_PART1_START, .len = 4 },
        .{ .off = L.OFF_PART1_SECTORS, .len = 4 },
    };
    var prev_end: u64 = 8; // after the magic
    for (fields) |f| {
        try std.testing.expect(f.off >= prev_end);
        prev_end = f.off + f.len;
    }
    try std.testing.expect(prev_end <= L.OFF_KERNEL_SHA); // shas start clean
    try std.testing.expect(L.OFF_KERNEL_SHA + 32 <= L.OFF_INITRD_SHA);
    try std.testing.expect(L.OFF_INITRD_SHA + 32 <= L.OFF_CMDLINE);
    try std.testing.expect(L.OFF_CMDLINE + L.CMDLINE_CAP <= 0x940);
}

test "layout: stage2 area honors stage1's bounds" {
    try std.testing.expectEqual(@as(u64, 9), L.STAGE2_LBA);
    try std.testing.expectEqual(@as(u64, 60), L.STAGE2_SECTORS);
    try std.testing.expect(L.STAGE2_SECTORS >= 1 and L.STAGE2_SECTORS <= 60); // stage1's clamp
    // stage1 loads stage2 to 0x7E00: 1..60 sectors keeps the end < 0x10000
    try std.testing.expect(0x7E00 + L.STAGE2_SECTORS * 512 <= 0x10000);
    // kernel starts on a fresh sector after the whole area
    try std.testing.expectEqual(@as(u64, 69), L.kernelLba());
    try std.testing.expectEqual(@as(u64, 69 + 3738), L.initrdLba(3738));
    try std.testing.expect(L.STAGE2_LBA + L.STAGE2_SECTORS == L.kernelLba());
}

test "determinism: buildMbr/buildHeader are pure (same inputs -> same bytes)" {
    var stage1 = [_]u8{0} ** 512;
    for (&stage1, 0..) |*b, i| {
        if (i < 296) b.* = @truncate(0xC0 + i);
    }
    const a = try L.buildMbr(&stage1, 1048576);
    const b = try L.buildMbr(&stage1, 1048576);
    try std.testing.expectEqualSlices(u8, &a, &b);

    const ha = L.buildHeader(.{
        .stage2_lba = 9,
        .stage2_sectors = 60,
        .stage2_crc32 = 0xDEADBEEF,
        .kernel_lba = 69,
        .kernel_sectors = 1,
        .initrd_lba = 70,
        .initrd_sectors = 1,
        .part1_start_lba = 65536,
        .part1_sectors = 1046528,
    }, "abc", [_]u8{1} ** 32, [_]u8{2} ** 32) catch unreachable;
    const hb = L.buildHeader(.{
        .stage2_lba = 9,
        .stage2_sectors = 60,
        .stage2_crc32 = 0xDEADBEEF,
        .kernel_lba = 69,
        .kernel_sectors = 1,
        .initrd_lba = 70,
        .initrd_sectors = 1,
        .part1_start_lba = 65536,
        .part1_sectors = 1046528,
    }, "abc", [_]u8{1} ** 32, [_]u8{2} ** 32) catch unreachable;
    try std.testing.expectEqualSlices(u8, &ha, &hb);
}

// ─── FIX 3: the cmdline bound is stage2's 2047, not the field's 2048 ───────

test "cmdline: buildHeader refuses > 2047 (stage2's clamp), accepts 2047" {
    const hd = L.HeaderIn{
        .stage2_lba = 9,
        .stage2_sectors = 60,
        .stage2_crc32 = 0,
        .kernel_lba = 69,
        .kernel_sectors = 1,
        .initrd_lba = 70,
        .initrd_sectors = 1,
        .part1_start_lba = 65536,
        .part1_sectors = 1,
    };
    const sha = [_]u8{0} ** 32;

    // exactly 2047 is legal: stage2 copies it whole
    const exact = try L.buildHeader(hd, "x" ** 2047, sha, sha);
    try std.testing.expectEqual(@as(u32, 2047), u32le(exact[L.OFF_CMDLINE_LEN..][0..4]));

    // 2048 (the old bound) is refused: stage2 clamps to 2047 and the last
    // byte would be silently lost in the guest
    try std.testing.expectError(
        error.CmdlineTooLong,
        L.buildHeader(hd, "x" ** 2048, sha, sha),
    );
    try std.testing.expectError(
        error.CmdlineTooLong,
        L.buildHeader(hd, "x" ** (L.CMDLINE_CAP + 1), sha, sha),
    );

    // the two bounds stay tied to the frozen contract
    try std.testing.expectEqual(@as(usize, 2048), L.CMDLINE_CAP);
    try std.testing.expectEqual(@as(usize, 2047), L.CMDLINE_MAX);
}

// ─── FIX 4: bind the REAL assembled blobs to the layout contract ──────────
//
// The tests above exercise buildMbr/buildHeader with SYNTHETIC blobs — a
// review-round-2 finding: nothing at `zig build test` level proved the
// ACTUAL stage1.bin/stage2.bin (the bytes the builder embeds) satisfy the
// header/MBR invariants.  This test shells out to the same verified build
// scripts fx-image itself runs (zig/src/boot/build-stage{1,2}.sh) and
// asserts the real artifacts against the layout, INCLUDING an independent
// crc32 (crc32ZlibConv, not std.hash.Crc32).
//
// Runs under plain `zig test` and `zig build test` (both spawn the test
// binary with cwd = the invocation dir; the repo is found by walking up
// from /proc/self/cwd looking for zig/src/boot/build-stage1.sh — a probe
// that also catches a harness run from outside the checkout, where the
// test SKIPS loudly rather than silently passing on nothing).

/// repo root found by walking up from the test process's cwd.  The result
/// lives in a static buffer (the probe slices are freed before return).
var repo_buf: [std.fs.max_path_bytes]u8 = undefined;

fn findRepoRoot(io: std.Io) ?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.Io.Dir.readLinkAbsolute(io, "/proc/self/cwd", &buf) catch return null;
    var dir: []const u8 = buf[0..n];
    const suffix = "/zig/src/boot/build-stage1.sh";
    while (true) {
        const probe = std.fmt.allocPrint(std.testing.allocator, "{s}" ++ suffix, .{dir}) catch return null;
        defer std.testing.allocator.free(probe);
        if (std.Io.Dir.cwd().access(io, probe, .{})) |_| {
            if (dir.len >= repo_buf.len) return null;
            @memcpy(repo_buf[0..dir.len], dir);
            return repo_buf[0..dir.len];
        } else |_| {}
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        dir = parent;
    }
}

test "real blobs: assembled stage1/stage2 satisfy buildMbr/buildHeader" {
    const io = std.testing.io;
    const repo = findRepoRoot(io) orelse return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_n = try tmp.dir.realPath(io, &tmp_buf);
    const tmp_str = tmp_buf[0..tmp_n];

    // run the REAL build scripts into the tmp dir (same form the builder
    // uses; each script self-asserts 512B/55AA/zero-table/sector-pad and
    // fails nonzero on any violation)
    for ([_][]const u8{ "stage1", "stage2" }) |which| {
        const script = try std.fmt.allocPrint(std.testing.allocator, "sh {s}/zig/src/boot/build-{s}.sh -o {s}/{s}.bin", .{ repo, which, tmp_str, which });
        defer std.testing.allocator.free(script);
        const res = std.process.run(std.testing.allocator, io, .{
            .argv = &.{ "/bin/sh", "-c", script },
        }) catch |e| switch (e) {
            error.FileNotFound => return error.SkipZigTest, // no sh on this host
            else => return e,
        };
        defer std.testing.allocator.free(res.stdout);
        defer std.testing.allocator.free(res.stderr);
        const rc: u8 = switch (res.term) {
            .exited => |c| c,
            else => 1,
        };
        if (rc != 0) return error.TestUnexpectedResult; // script's own gate fired
    }

    const stage1 = try tmp.dir.readFileAlloc(io, "stage1.bin", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(stage1);
    const stage2 = try tmp.dir.readFileAlloc(io, "stage2.bin", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(stage2);

    // ── stage1 against buildMbr: the REAL blob must fit the MBR budget
    try std.testing.expectEqual(@as(usize, 512), stage1.len); // build-stage1.sh contract
    const mbr = try L.buildMbr(stage1, (512 << 20) >> 9); // must NOT Stage1TooBig
    try std.testing.expectEqualSlices(u8, stage1[0..446], mbr[0..446]); // verbatim embed
    try std.testing.expectEqual(@as(u8, 0x55), mbr[510]);
    try std.testing.expectEqual(@as(u8, 0xAA), mbr[511]);

    // ── stage2 against buildHeader: geometry + an INDEPENDENT crc32
    try std.testing.expect(stage2.len > 0 and stage2.len % 512 == 0); // sector-padded
    const sectors: u64 = stage2.len / 512;
    try std.testing.expect(sectors >= 1 and sectors <= 60); // stage1's bound
    // pad to the FULL 60-sector area, exactly what the builder CRCs and writes
    const area: usize = @intCast(L.STAGE2_SECTORS * L.SECTOR);
    const full = try std.testing.allocator.alloc(u8, area);
    defer std.testing.allocator.free(full);
    @memset(full, 0);
    @memcpy(full[0..stage2.len], stage2);
    const crc = crc32ZlibConv(full); // independent of std.hash.Crc32
    try std.testing.expectEqual(std.hash.Crc32.hash(full), crc); // conventions agree

    const h = try L.buildHeader(.{
        .stage2_lba = L.STAGE2_LBA,
        .stage2_sectors = sectors,
        .stage2_crc32 = crc,
        .kernel_lba = L.kernelLba(),
        .kernel_sectors = 1,
        .initrd_lba = L.initrdLba(1),
        .initrd_sectors = 1,
        .part1_start_lba = L.PART1_START_LBA,
        .part1_sectors = 1,
    }, "console=ttyS0", [_]u8{0} ** 32, [_]u8{0} ** 32);
    // the header round-trips exactly the crc stage1 will recompute
    try std.testing.expectEqual(crc, u32le(h[L.OFF_STAGE2_CRC..][0..4]));
    // stage2_sectors is the u16 stage1 reads (widths match the frozen contract)
    try std.testing.expectEqual(@as(u16, @intCast(sectors)), u16le(h[L.OFF_STAGE2_SECTORS..][0..2]));
}
