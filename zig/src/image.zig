// image.zig — fx-image, the standalone disk-image builder (fx-image
// milestone, unit U2 SKELETON).
//
// Takes an fx-activate-style CLI (--config --package-set --pin --out
// [--size-mb] [--extra-cmdline]), provisions a store EXACTLY the way
// tests/qemu_boot.sh's toolchain-free path does (frozen sibling sources ->
// activate_paths closure -> real fx-activate), builds the initramfs via
// tests/mkinitramfs.sh -E (the U1 contract: -E = deterministic archive),
// and assembles a raw image with DIRECT file I/O (writePositionalAll +
// setLength; no qemu-img):
//
//   LBA 0        MBR: [0,446) = the REAL stage1 (assembled at build time
//                from zig/src/boot/stage1.S by build-stage1.sh — U3's
//                verified blob; buildMbr hard-fails if it exceeds 446 code
//                bytes), [446,462) partition entry 1 (type 0x83, bootable,
//                LBA 65536..disk end), 0x55AA at 510.
//   LBA 1..8     FX header, 4 KiB (byte_layout.buildHeader).
//   LBA 9..68    the REAL stage2 (build-stage2.sh output, zero-padded to the
//                full 60-sector area — the header's stage2 crc covers the
//                whole padded area, exactly what stage1 reads back).
//   LBA 69..     the vmlinuz blob, then the initrd blob (each sector-aligned,
//                padded so the next region starts on a fresh sector).
//   LBA 65536..  BLANK partition 1 (zeros) — the guest's ensure_disk_store
//                mkfs.ext2 -F's it on first boot; the host cannot mkfs.
//
// DETERMINISM (the plan's P3 convention): same config bytes + same pinned
// kernel + same toolchain + same WORK DIR -> byte-identical img.raw, with
// img.sha256 beside it.  All image bytes are host-written; the file is
// created fresh and truncated to size, so no host fs metadata enters the
// artifact.  The initrd is mkinitramfs.sh -E output (deterministic by U1's
// contract).
//
// The CHECKOUT PATH is not an input (review round 2's A/B, then round 3's
// fix): the payload binaries are no longer built in the live checkout but
// in {work}/buildroot, a copy of the frozen tree whose absolute path is a
// function of the work dir alone — every path the linker bakes (RUNPATH,
// DWARF source dirs) is work-rooted, so building the same content from two
// different checkout paths yields the same image (the round-3 A/B gate).
//
// REPEAT BUILDS MUST BE WARM (review round 3, MEASURED): two COLD zig
// builds of identical sources at the same path are NOT byte-identical on
// this host (the payloads differ in their symtab/strtab tail;
// SOURCE_DATE_EPOCH and strip do not close it), while warm/incremental
// builds are.  The buildroot therefore PERSISTS across runs: {work} is
// wiped on entry EXCEPT buildroot, and buildroot's sources are refreshed
// in place (rsync -a --delete --checksum, zig's cache dirs protected —
// see provision) — content-decided, so unchanged files keep their mtimes
// and the repeat `zig build` is a warm no-op.  The refresh is
// content-driven (zig's cache re-hashes, not trusts mtimes), so a changed
// source still changes the image (the touch-a-source gate).  One
// measured caveat: a source EDIT followed by a REVERT recompiles on the
// revert, and that fresh compile is NOT byte-equal to the
// never-edited binary (two independent compiles of identical sources
// differ on this host); it IS byte-stable from the first post-revert
// run on.  First run on a clean work dir is a cold build —
// reproducibility is claimed for repeat runs on a PERSISTENT work dir,
// not across independently-cleared ones.
//
// One input was OUTSIDE this tool's control: fx-activate's `generation`
// fact records a wall-clock epoch, which lands in the store db the initrd
// packs.  fx-image therefore exports FX_EPOCH to every provisioning child
// (set to 1 unless the caller supplies FX_EPOCH/SOURCE_DATE_EPOCH), and
// fx-activate honors it (activate.zig genEpoch: FX_EPOCH, then
// SOURCE_DATE_EPOCH, else the wall clock).
//
// The store root itself is another hash input OUTSIDE this tool's control:
// the vendored fxstore's derivation hash folds each direct dep's FULL
// STORE PATH into the hash (fxstore derivation.zig fx_derivation_hash_ex),
// so a random scratch prefix would enter every package-with-deps' hash.
// The work dir is therefore FIXED, not mkdtemp'd: --work, else
// $FX_IMAGE_WORK, else ${TMPDIR:-/tmp}/fx-image-work.  Reproducibility is
// PER WORK-DIR PATH (the store root is a derivation input by design), and
// — with the work-rooted buildroot — not per checkout path.  Concurrency:
// a second fx-image on the same work dir would race the store; the guard
// is an O_EXCL <work>.lock holding the builder pid, HELD UNDER flock(2)
// for the whole build (the kernel drops it on any process death — a
// killed builder cannot leak it) and unlinked on every exit path.
// FX_KEEP=1 keeps the work dir (including the warm buildroot) as before.

const std = @import("std");

/// Everything U5 owns: the on-disk byte layout of LBA0 + the FX header.
/// Kept in ONE place (no scatter of magic offsets through the builder) so
/// U5 can finalize semantics without reworking the provisioning/assembly
/// flow above it.  FIELD OFFSETS FROZEN (the U3/U4 contract — coordinate
/// on the fx-image channel before changing any of them).
const byte_layout = struct {
    pub const SECTOR: u64 = 512;

    /// MBR partition entry 1 (offset 446 in LBA0): bootable, CHS 0xFE/0xFF
    /// 0xFF start+end (the LBA-disk convention), type 0x83 (Linux), start
    /// LBA 2048, span = disk_sectors - 2048.
    pub const PART_ENTRY_OFF: u64 = 446;
    pub const SIG_OFF: u64 = 510;

    /// FX header (LBA 1..8 inclusive, 4 KiB), little-endian:
    ///   0x000  8B   magic "FXIMGv1\n"
    ///   0x008  u32  header version (1)
    ///   0x00C  u64  stage2_lba      ── stage1 (frozen): reads +0x0C,
    ///   0x014  u16  stage2_sectors     enforces 1..60 (dst < 0x10000)
    ///   0x016  u32  stage2_crc32       zlib-compatible crc32 (reflected
    ///                                  0xEDB88320, init/final 0xFFFFFFFF,
    ///                                  == python zlib.crc32) over
    ///                                  stage2_sectors*512 bytes at
    ///                                  stage2_lba
    ///   0x01A  pad  (zero, reserved)
    ///   0x028  u64  kernel_lba      ── stage2 (frozen)
    ///   0x030  u64  kernel_sectors
    ///   0x038  u64  initrd_lba
    ///   0x040  u64  initrd_sectors
    ///   0x048  u32  cmdline_len
    ///   0x04C  u32  partition1_start_lba
    ///   0x050  u32  partition1_sectors
    ///   0x054  pad  (zero, reserved)
    ///   0x100  32B  kernel sha256 (informational; the pin verified it)
    ///   0x120  32B  initrd sha256
    ///   0x140  2048B cmdline, NUL-padded.  stage2 clamps the copy to 2047
    ///          bytes (stage2.S:268-272 — the kernel's cmdline_size), so
    ///          the builder-side bound is CMDLINE_MAX=2047, NOT the 2048
    ///          the field holds: a 2048-byte bake would be silently cut to
    ///          2047 in the guest, losing its last byte (buildHeader now
    ///          refuses > 2047 — the FIX 3 reconciliation)
    ///   0x940  pad  (zero, reserved)
    ///   0xFFC  u32  crc32 of bytes [0, 0xFFC)
    ///
    /// U5 RECONCILIATION: stage1's frozen trio moved to 0x0C/0x14/0x16
    /// (they were at 0x18/0x20 with no crc32 field, colliding with the old
    /// hdr_size/hdr_sectors at 0x0C/0x10).  The old hdr_size/hdr_sectors
    /// fields are REMOVED, not relocated: neither stage reads them, and a
    /// dead field whose only writer is this builder is a lie in the
    /// on-disk format (0x1A..0x27 is zero reserved if a future stage needs
    /// a seat).
    pub const HDR_MAGIC = "FXIMGv1\n";
    pub const HDR_VER: u32 = 1;
    pub const HDR_SIZE: u64 = 4096;
    pub const HDR_LBA: u64 = 1;
    pub const HDR_SECTORS: u64 = 8;
    pub const OFF_VER: u64 = 0x08;
    pub const OFF_STAGE2_LBA: u64 = 0x0C;
    pub const OFF_STAGE2_SECTORS: u64 = 0x14;
    pub const OFF_STAGE2_CRC: u64 = 0x16;
    pub const OFF_KERNEL_LBA: u64 = 0x28;
    pub const OFF_KERNEL_SECTORS: u64 = 0x30;
    pub const OFF_INITRD_LBA: u64 = 0x38;
    pub const OFF_INITRD_SECTORS: u64 = 0x40;
    pub const OFF_CMDLINE_LEN: u64 = 0x48;
    pub const OFF_PART1_START: u64 = 0x4C;
    pub const OFF_PART1_SECTORS: u64 = 0x50;
    pub const OFF_KERNEL_SHA: u64 = 0x100;
    pub const OFF_INITRD_SHA: u64 = 0x120;
    pub const OFF_CMDLINE: u64 = 0x140;
    pub const CMDLINE_CAP: usize = 2048;
    /// the true builder-side bound: stage2 copies at most 2047 bytes
    /// (stage2.S:268-272), so a longer bake would be silently truncated in
    /// the guest.  buildHeader refuses > this (FIX 3).
    pub const CMDLINE_MAX: usize = 2047;
    pub const OFF_HDR_SHA: u64 = 0xFFC;

    /// stage2 sits right after the header, at LBA 9.  60 sectors is the
    /// CEILING stage1 enforces (it refuses >60 so the load stays under
    /// 0x10000); the real stage2 is 3 sectors, the rest of the area is the
    /// zero pad the crc covers.
    pub const STAGE2_LBA: u64 = 9;
    pub const STAGE2_SECTORS: u64 = 60;

    /// partition 1 geometry.  The plan's boot region (LBA 1..2047, ~1 MiB)
    /// is internally inconsistent with its own payload facts: the pinned
    /// vmlinuz alone is 1913856B (~1.83 MiB) and the real -E initrd
    /// measures ~8.1 MiB — the boot region needs ~10 MiB (end LBA ~20442).
    /// Partition 1 therefore starts at LBA 65536 (32 MiB, still a
    /// power-of-two boundary): the pinned kernel (1.83 MiB) + the real -E
    /// initrd (~14.2 MiB with the full store payload) + stage2 fit with
    /// ~15.9 MiB headroom.  DEVIATION from the plan, published on the
    /// fx-image channel + the result node; U5 owns this constant's final
    /// value.
    pub const PART1_START_LBA: u64 = 65536;
    pub const PART_TYPE_LINUX: u8 = 0x83;

    /// Blob regions start after the stage2 area.
    pub fn kernelLba() u64 {
        return STAGE2_LBA + STAGE2_SECTORS;
    }

    pub fn initrdLba(kernel_sectors: u64) u64 {
        return kernelLba() + kernel_sectors;
    }

    /// LBA0: [0, 446) = the stage1 blob's code area (build-stage1.sh emits
    /// the FULL 512 B MBR image — 446-or-fewer code bytes, zero table area,
    /// 0x55AA — of which exactly [0,446) is copied here), [446, 462) =
    /// OUR partition entry 1, [462, 510) = zero, [510, 512) = 0x55 0xAA.
    /// HARD FAIL (error.Stage1TooBig) if the blob is over 512 B or has ANY
    /// nonzero byte in its table/guard area [446,510) — which is also the
    /// 446-byte code-budget enforcement (code reaching past 446 lands
    /// nonzero bytes there; build-stage1.sh asserts the same on its side).
    pub fn buildMbr(stage1: []const u8, disk_sectors: u64) BuildError![512]u8 {
        var mbr = [_]u8{0} ** 512;
        if (stage1.len > 512) return error.Stage1TooBig;
        // a blob whose code overruns 446 necessarily puts nonzero bytes in
        // the table area — the guard check below is the budget enforcement
        const guard_end = @min(stage1.len, SIG_OFF);
        for (stage1[PART_ENTRY_OFF..guard_end]) |b| {
            if (b != 0) return error.Stage1TooBig;
        }
        @memcpy(mbr[0..@min(stage1.len, PART_ENTRY_OFF)], stage1[0..@min(stage1.len, PART_ENTRY_OFF)]);
        mbr[446] = 0x80; // bootable
        mbr[447] = 0xFE; // CHS start (max, the LBA convention)
        mbr[448] = 0xFF;
        mbr[449] = 0xFF;
        mbr[450] = PART_TYPE_LINUX;
        mbr[451] = 0xFE; // CHS end (max)
        mbr[452] = 0xFF;
        mbr[453] = 0xFF;
        putU32le(mbr[454..458], PART1_START_LBA);
        const span: u64 = if (disk_sectors > PART1_START_LBA) disk_sectors - PART1_START_LBA else 0;
        putU32le(mbr[458..462], @intCast(span));
        mbr[510] = 0x55;
        mbr[511] = 0xAA;
        return mbr;
    }

    pub const BuildError = error{ Stage1TooBig, CmdlineTooLong };

    pub const HeaderIn = struct {
        stage2_lba: u64,
        stage2_sectors: u64,
        /// crc32 (std.hash.Crc32 == zlib.crc32) over stage2_sectors*512
        /// bytes at stage2_lba — stage1 recomputes and compares this.
        stage2_crc32: u32,
        kernel_lba: u64,
        kernel_sectors: u64,
        initrd_lba: u64,
        initrd_sectors: u64,
        part1_start_lba: u64,
        part1_sectors: u64,
    };

    /// Serialize the FX header into a 4 KiB zeroed buffer.  Pure: no clock,
    /// no fs — the caller supplies every input.  stage2_sectors is written
    /// as the u16 stage1 reads (1..60; the builder's layout constant
    /// satisfies this by construction — a value over 65535 wraps silently,
    /// so the caller-side constants, not this cast, own the bound).
    /// cmdline is refused over CMDLINE_MAX (2047): stage2 clamps its copy
    /// to 2047, so a longer cmdline would reach the guest silently cut.
    pub fn buildHeader(hd: HeaderIn, cmdline: []const u8, kernel_sha: [32]u8, initrd_sha: [32]u8) BuildError![4096]u8 {
        if (cmdline.len > CMDLINE_MAX) return error.CmdlineTooLong;
        var b = [_]u8{0} ** 4096;
        @memcpy(b[0..8], HDR_MAGIC);
        putU32le(b[OFF_VER..][0..4], HDR_VER);
        putU64le(b[OFF_STAGE2_LBA..][0..8], hd.stage2_lba);
        putU16le(b[OFF_STAGE2_SECTORS..][0..2], @intCast(hd.stage2_sectors));
        putU32le(b[OFF_STAGE2_CRC..][0..4], hd.stage2_crc32);
        putU64le(b[OFF_KERNEL_LBA..][0..8], hd.kernel_lba);
        putU64le(b[OFF_KERNEL_SECTORS..][0..8], hd.kernel_sectors);
        putU64le(b[OFF_INITRD_LBA..][0..8], hd.initrd_lba);
        putU64le(b[OFF_INITRD_SECTORS..][0..8], hd.initrd_sectors);
        putU32le(b[OFF_CMDLINE_LEN..][0..4], @intCast(cmdline.len));
        putU32le(b[OFF_PART1_START..][0..4], @intCast(hd.part1_start_lba));
        putU32le(b[OFF_PART1_SECTORS..][0..4], @intCast(hd.part1_sectors));
        @memcpy(b[OFF_KERNEL_SHA..][0..32], &kernel_sha);
        @memcpy(b[OFF_INITRD_SHA..][0..32], &initrd_sha);
        @memcpy(b[OFF_CMDLINE..][0..cmdline.len], cmdline);
        putU32le(b[OFF_HDR_SHA..][0..4], std.hash.Crc32.hash(b[0..OFF_HDR_SHA]));
        return b;
    }

    fn putU16le(dst: []u8, v: u16) void {
        dst[0] = @truncate(v);
        dst[1] = @truncate(v >> 8);
    }

    fn putU32le(dst: []u8, v: u32) void {
        dst[0] = @truncate(v);
        dst[1] = @truncate(v >> 8);
        dst[2] = @truncate(v >> 16);
        dst[3] = @truncate(v >> 24);
    }

    fn putU64le(dst: []u8, v: u64) void {
        var i: usize = 0;
        while (i < 8) : (i += 1) dst[i] = @truncate(v >> @intCast(8 * i));
    }
};

/// re-exported for image_check.zig's tests and U5's work
pub const layout = byte_layout;

// ─── CLI ───────────────────────────────────────────────────────────────────

const usage_text: []const u8 =
    \\fx-image — build a standalone bootable raw disk image
    \\
    \\usage: fx-image --config C.dhall --package-set P.dhall --pin PINFILE
    \\                 --out IMG.raw [--size-mb N] [--extra-cmdline TEXT]
    \\                 [--work DIR]
    \\
    \\  --config PATH       system config (same surface as fx-activate)
    \\  --package-set PATH  package set (sources frozen like qemu_boot.sh)
    \\  --pin PATH          kernel pin file (scripts/kernel-pin.txt)
    \\  --out PATH          output image; IMG.sha256 is written beside it
    \\  --size-mb N         image size in MiB (default 512)
    \\  --extra-cmdline T   appended to the baked kernel command line
    \\  --work DIR          scratch dir (default $FX_IMAGE_WORK, else
    \\                      ${TMPDIR:-/tmp}/fx-image-work).  The store root
    \\                      is a derivation-hash input, so the SAME work dir
    \\                      is part of the reproducibility contract; DIR/
    \\                      buildroot and DIR/buildroot-fxcore (the zig
    \\                      build caches) are kept across
    \\                      runs so repeat builds are warm — the two-run
    \\                      byte-identity contract holds on a PERSISTENT
    \\                      work dir, not across rm -rf'd ones.  A concurrent
    \\                      LIVE build on it is refused via DIR.lock (a dead
    \\                      builder's lock is taken over automatically — no
    \\                      manual rm)
    \\
;

const Args = struct {
    config: []const u8 = "",
    pkgset: []const u8 = "",
    pin: []const u8 = "",
    out: []const u8 = "",
    size_mb: u64 = 512,
    extra_cmdline: []const u8 = "",
    work: []const u8 = "",
};

fn usageErr(w: *std.Io.Writer, msg: []const u8) noreturn {
    w.print("fx-image: {s}\n\n{s}", .{ msg, usage_text }) catch {};
    w.flush() catch {};
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;

    var out_buf: [16384]u8 = undefined;
    var out_w = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_w.interface;
    var err_buf: [16384]u8 = undefined;
    var err_w = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const errw = &err_w.interface;

    var a: Args = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) usageErr(errw, "--config requires a path");
            a.config = args[i];
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            a.config = arg["--config=".len..];
        } else if (std.mem.eql(u8, arg, "--package-set")) {
            i += 1;
            if (i >= args.len) usageErr(errw, "--package-set requires a path");
            a.pkgset = args[i];
        } else if (std.mem.startsWith(u8, arg, "--package-set=")) {
            a.pkgset = arg["--package-set=".len..];
        } else if (std.mem.eql(u8, arg, "--pin")) {
            i += 1;
            if (i >= args.len) usageErr(errw, "--pin requires a path");
            a.pin = args[i];
        } else if (std.mem.startsWith(u8, arg, "--pin=")) {
            a.pin = arg["--pin=".len..];
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) usageErr(errw, "--out requires a path");
            a.out = args[i];
        } else if (std.mem.startsWith(u8, arg, "--out=")) {
            a.out = arg["--out=".len..];
        } else if (std.mem.eql(u8, arg, "--size-mb")) {
            i += 1;
            if (i >= args.len) usageErr(errw, "--size-mb requires a number");
            a.size_mb = std.fmt.parseInt(u64, args[i], 10) catch
                usageErr(errw, "--size-mb must be a number");
        } else if (std.mem.startsWith(u8, arg, "--size-mb=")) {
            a.size_mb = std.fmt.parseInt(u64, arg["--size-mb=".len..], 10) catch
                usageErr(errw, "--size-mb must be a number");
        } else if (std.mem.eql(u8, arg, "--extra-cmdline")) {
            i += 1;
            if (i >= args.len) usageErr(errw, "--extra-cmdline requires text");
            a.extra_cmdline = args[i];
        } else if (std.mem.startsWith(u8, arg, "--extra-cmdline=")) {
            a.extra_cmdline = arg["--extra-cmdline=".len..];
        } else if (std.mem.eql(u8, arg, "--work")) {
            i += 1;
            if (i >= args.len) usageErr(errw, "--work requires a dir");
            a.work = args[i];
        } else if (std.mem.startsWith(u8, arg, "--work=")) {
            a.work = arg["--work=".len..];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            out.print("{s}", .{usage_text}) catch {};
            out.flush() catch {};
            return;
        } else {
            usageErr(errw, "unknown argument");
        }
    }
    if (a.config.len == 0) usageErr(errw, "--config is required");
    if (a.pkgset.len == 0) usageErr(errw, "--package-set is required");
    if (a.pin.len == 0) usageErr(errw, "--pin is required");
    if (a.out.len == 0) usageErr(errw, "--out is required");
    if (a.size_mb < 16) usageErr(errw, "--size-mb must be >= 16");

    var ctx: BuildCtx = .{
        .config = a.config,
        .pkgset = a.pkgset,
        .pin = a.pin,
        .out_path = a.out,
        .size_mb = a.size_mb,
        .extra_cmdline = a.extra_cmdline,
        .work_arg = a.work,
        .out = out,
        .errw = errw,
    };
    try buildImage(init.gpa, io, &ctx, init.minimal.environ);
    out.flush() catch {};
    errw.flush() catch {};
}

const BuildCtx = struct {
    config: []const u8,
    pkgset: []const u8,
    pin: []const u8,
    out_path: []const u8,
    size_mb: u64,
    extra_cmdline: []const u8,
    /// "" = derive from FX_IMAGE_WORK/TMPDIR (the fixed default)
    work_arg: []const u8 = "",
    out: *std.Io.Writer,
    errw: *std.Io.Writer,
};

fn note(ctx: *const BuildCtx, comptime fmt: []const u8, tpl: anytype) void {
    ctx.out.print(fmt, tpl) catch {};
    ctx.out.flush() catch {};
}

// ─── the work-dir lock (module-level so EVERY exit path can clean it) ──────
//
// makeWork registers <work>.lock here the moment it exists.  fail() (the
// path every transient failure takes: pin mismatch, offline fetch, zig
// build failure, activate parse, disk full) and the fatal-signal handler
// both unlink it before exiting — cleanupScratch's defer no longer has to
// be the only janitor, because std.process.exit() does not run defers.
// The flock held on g_lock_fd is the real guarantee: the kernel drops it
// on ANY process death (kill -9, SIGSEGV, OOM-kill), so a dead builder
// can never hold the work dir; the file's removal is hygiene on top.
var g_lock_path: ?[]const u8 = null;
var g_lock_fd: ?std.Io.File = null;

/// best-effort unlink of the lock file + release of the flock.  Called
/// from fail() (no io — raw unlink only; the flock dies with the process)
/// and from cleanupScratch/releaseWorkLock on the normal path (full: close
/// the fd after unlinking so nothing can observe a held-but-unlinked lock).
fn releaseWorkLock(io: ?std.Io) void {
    const p = g_lock_path orelse return;
    if (p.len == 0 or p.len >= g_lock_path_buf.len) return;
    if (io) |i| {
        if (g_lock_fd) |*lf| {
            std.Io.Dir.cwd().deleteFile(i, p) catch {};
            lf.unlock(i);
            lf.close(i);
            g_lock_fd = null;
        } else {
            std.Io.Dir.cwd().deleteFile(i, p) catch {};
        }
    } else {
        // fail() context: no io handle, the process is about to exit —
        // raw unlink(2) is enough (async-signal-safe, no allocation)
        g_lock_path_buf[p.len] = 0;
        _ = unlink(@ptrCast(&g_lock_path_buf));
    }
    g_lock_path = null;
}

/// fixed buffer holding the lock path: the signal handler cannot allocate
var g_lock_path_buf: [std.fs.max_path_bytes]u8 = undefined;

extern "c" fn unlink(path: [*:0]const u8) c_int;

/// SIGTERM/SIGINT/SIGHUP/SIGQUIT: unlink the lock file and die.  The flock
/// releases itself when the process exits (async-signal-safe: only unlink
/// and _exit — no allocation, no std.Io).
fn fatalSignalHandler(sig: std.posix.SIG) callconv(.c) void {
    if (g_lock_path) |p| {
        if (p.len > 0 and p.len < g_lock_path_buf.len) {
            g_lock_path_buf[p.len] = 0;
            _ = unlink(@ptrCast(&g_lock_path_buf));
        }
    }
    _ = sig;
    std.c._exit(1);
}

/// install the fatal-signal janitor BEFORE any lock exists
fn installFatalHandlers() void {
    var sa = std.mem.zeroes(std.posix.Sigaction);
    sa.handler = .{ .handler = fatalSignalHandler };
    std.posix.sigaction(.TERM, &sa, null);
    std.posix.sigaction(.INT, &sa, null);
    std.posix.sigaction(.HUP, &sa, null);
    std.posix.sigaction(.QUIT, &sa, null);
}

fn fail(ctx: *const BuildCtx, comptime fmt: []const u8, tpl: anytype) noreturn {
    ctx.errw.print("fx-image: FAIL: " ++ fmt ++ "\n", tpl) catch {};
    ctx.errw.flush() catch {};
    releaseWorkLock(null);
    std.process.exit(1);
}

// ─── small fs/env helpers ──────────────────────────────────────────────────

fn envGet(env: *std.process.Environ.Map, key: []const u8) ?[]const u8 {
    if (env.get(key)) |v| {
        if (v.len > 0) return v;
    }
    return null;
}

/// absolute (rooted, symlink-resolved) path of an EXISTING file, or null
fn absPath(alloc: std.mem.Allocator, io: std.Io, p: []const u8) ?[]u8 {
    const dir = std.Io.Dir.cwd();
    if (dir.access(io, p, .{})) |_| {} else |_| return null;
    return dir.realPathFileAlloc(io, p, alloc) catch null;
}

fn isFile(io: std.Io, p: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .file;
}

fn isDir(io: std.Io, p: []const u8) bool {
    const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch return false;
    return st.kind == .directory;
}

fn fileSize(io: std.Io, p: []const u8) ?u64 {
    const st = std.Io.Dir.cwd().statFile(io, p, .{}) catch return null;
    return st.size;
}

fn ceilDiv(a: u64, b: u64) u64 {
    return (a + b - 1) / b;
}

/// run /bin/sh -c `script` (the repo's exec convention), fail(ctx) with the
/// child's captured output on nonzero exit; returns the child's stdout.
fn runShell(
    alloc: std.mem.Allocator,
    io: std.Io,
    ctx: *const BuildCtx,
    env: ?*std.process.Environ.Map,
    cwd: []const u8,
    what: []const u8,
    script: []const u8,
) []u8 {
    const res = std.process.run(alloc, io, .{
        .argv = &.{ "/bin/sh", "-c", script },
        .cwd = .{ .path = cwd },
        .environ_map = env,
    }) catch
        fail(ctx, "cannot spawn: {s}", .{what});
    const rc: u8 = switch (res.term) {
        .exited => |c| c,
        else => 1,
    };
    if (rc != 0) {
        ctx.errw.print("fx-image: {s} failed (rc={d}):\n{s}\n{s}", .{ what, rc, res.stdout, res.stderr }) catch {};
        ctx.errw.flush() catch {};
        std.process.exit(1);
    }
    alloc.free(res.stderr);
    return res.stdout;
}

/// copy src -> dst (absolute), chmod mode (0755 for store payloads)
fn copyTo(alloc: std.mem.Allocator, io: std.Io, ctx: *const BuildCtx, src: []const u8, dst: []const u8, mode: u32) void {
    _ = alloc;
    std.Io.Dir.copyFileAbsolute(src, dst, io, .{}) catch
        fail(ctx, "cannot copy {s} -> {s}", .{ src, dst });
    if (mode != 0) {
        const f = std.Io.Dir.cwd().openFile(io, dst, .{ .mode = .read_write }) catch
            fail(ctx, "cannot chmod {s}", .{dst});
        defer f.close(io);
        f.setPermissions(io, std.Io.File.Permissions.fromMode(mode & 0o7777)) catch
            fail(ctx, "cannot chmod {s}", .{dst});
    }
}

fn fileSha256Hex(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(readFileSmall(alloc, io, path) orelse return null, &digest, .{});
    return std.fmt.allocPrint(alloc, "{x}", .{&digest}) catch null;
}

fn fileSha256Raw(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?[32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(readFileSmall(alloc, io, path) orelse return null, &digest, .{});
    return digest;
}

/// read a whole (small) file — pins and kernels/vmlinuz are a few MB
fn readFileSmall(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(1 << 30)) catch null;
}

// ─── the pinned kernel (scripts/fetch-kernel.sh + explicit sha verify) ─────

const KernelIn = struct {
    path: []u8,
    sha_hex: [64]u8,
};

fn loadKernel(alloc: std.mem.Allocator, io: std.Io, ctx: *const BuildCtx, repo: []const u8, env: *std.process.Environ.Map) KernelIn {
    const pin_path = absPath(alloc, io, ctx.pin) orelse
        fail(ctx, "kernel pin file not found: {s}", .{ctx.pin});
    if (!isFile(io, pin_path))
        fail(ctx, "kernel pin file is not a file: {s}", .{pin_path});
    const pin = readFileSmall(alloc, io, pin_path) orelse
        fail(ctx, "cannot read kernel pin file: {s}", .{pin_path});
    var url: []const u8 = "";
    var tar_sha: []const u8 = "";
    var vmlinuz_rel: []const u8 = "";
    var vmlinuz_sha: []const u8 = "";
    var it = std.mem.splitScalar(u8, pin, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var kv = std.mem.splitScalar(u8, line, ' ');
        const k = kv.next() orelse continue;
        const v = kv.next() orelse continue;
        if (std.mem.eql(u8, k, "url")) {
            url = v;
        } else if (std.mem.eql(u8, k, "tar_sha256")) {
            tar_sha = v;
        } else if (std.mem.eql(u8, k, "vmlinuz_path")) {
            vmlinuz_rel = v;
        } else if (std.mem.eql(u8, k, "vmlinuz_sha256")) {
            vmlinuz_sha = v;
        }
    }
    if (url.len == 0 or tar_sha.len == 0 or vmlinuz_sha.len == 0)
        fail(ctx, "pin file {s} malformed (needs url/tar_sha256/vmlinuz_sha256)", .{pin_path});
    if (vmlinuz_rel.len == 0) vmlinuz_rel = "vmlinuz";

    // fetch-kernel.sh resolves its own repo from $0 — run it via the repo's
    // absolute path so REPO is THIS checkout.
    const script = std.fmt.allocPrint(alloc, "sh {s}/scripts/fetch-kernel.sh", .{repo}) catch
        fail(ctx, "oom", .{});
    _ = runShell(alloc, io, ctx, env, ".", "fetch-kernel.sh", script);

    const cache_root = envGet(env, "FX_KERNEL_CACHE") orelse
        std.fmt.allocPrint(alloc, "{s}/.kernel-cache", .{repo}) catch
        fail(ctx, "oom", .{});
    const kpath = std.fmt.allocPrint(alloc, "{s}/kernel/{s}", .{ cache_root, vmlinuz_rel }) catch
        fail(ctx, "oom", .{});

    // belt beyond fetch-kernel's own checks: verify the sha EXPLICITLY, and
    // a mismatch FAILS (never silently falls back — the harness convention)
    var want: [64]u8 = undefined;
    @memcpy(&want, vmlinuz_sha[0..64]);
    const got = fileSha256Hex(alloc, io, kpath) orelse
        fail(ctx, "fetched vmlinuz missing at {s}", .{kpath});
    if (!std.mem.eql(u8, &want, got))
        fail(ctx, "kernel pin mismatch: want {s}, got {s} for {s}", .{ vmlinuz_sha, got, kpath });
    return .{ .path = kpath, .sha_hex = want };
}

// ─── src freeze (qemu_boot.sh's freeze_src, same find(1) exclusions) ───────

const FREEZE_FIND =
    "find . -not -path \"./.git/*\" -not -name \".git\" " ++
    "-not -path \"./build-tmp/*\" -not -name \"build-tmp\" " ++
    "-not -path \"./zig-out/*\" -not -name \"zig-out\" " ++
    "-not -path \"./zig/zig-out/*\" " ++
    "-not -path \"./zig/.zig-cache/*\" -not -path \"./zig/.zig-global/*\" " ++
    "-not -path \"./node_modules/*\" -not -name \"node_modules\" " ++
    "-not -path \"./elm-stuff/*\" -not -name \"elm-stuff\" " ++
    "-not -path \"./dist/*\" -not -name \"dist\" " ++
    "-not -name \"*.o\" -not -name \"*.a\" -not -name \"*.so\" -not -name \"*.com\" " ++
    "-not -name \"dl-test-*\" -not -name \".ape-*\" -print0";

/// fx-core's freeze: FREEZE_FIND plus the fx-core-shaped cache/output
/// exclusions.  MEASURED on the live tree: without these the freeze copies
/// 46270 files / 9.4GB (the root-level .zig-cache alone is 9.0GB, and
/// vendor/mfe-framework/node_modules is another 27MB of vendored JS the
/// zig build never reads); with them it is ~530 files / ~11MB (src,
/// build.zig, build.zig.zon, schemas, shell, vendor/dhake).
const FREEZE_FIND_FXCORE =
    "find . -not -path \"./.git/*\" -not -name \".git\" " ++
    "-not -path \"./build-tmp/*\" -not -name \"build-tmp\" " ++
    "-not -path \"./zig-out/*\" -not -name \"zig-out\" " ++
    "-not -path \"./.zig-cache/*\" -not -name \".zig-cache\" " ++
    "-not -path \"./node_modules/*\" -not -name \"node_modules\" " ++
    "-not -path \"./vendor/mfe-framework/*\" -not -name \"mfe-framework\" " ++
    "-not -path \"./elm-stuff/*\" -not -name \"elm-stuff\" " ++
    "-not -path \"./dist/*\" -not -name \"dist\" " ++
    "-not -path \"./site/*\" -not -name \"site\" " ++
    "-not -name \"*.o\" -not -name \"*.a\" -not -name \"*.so\" -not -name \"*.com\" " ++
    "-not -name \"dl-test-*\" -not -name \".ape-*\" -print0";

fn freezeSrc(alloc: std.mem.Allocator, io: std.Io, ctx: *const BuildCtx, src: []const u8, dst: []const u8) void {
    freezeSrcFind(alloc, io, ctx, src, dst, FREEZE_FIND);
}

/// freezeSrc with an explicit find(1) expression — fx-core needs EXTRA
/// exclusions (FREEZE_FIND's cache/out exclusions are the fx-init-shaped
/// ./zig/.zig-cache paths; fx-core keeps its zig cache + a 27MB vendored
/// node_modules at OTHER paths, and freezing those would copy ~9GB into
/// the work dir).
fn freezeSrcFind(alloc: std.mem.Allocator, io: std.Io, ctx: *const BuildCtx, src: []const u8, dst: []const u8, find_expr: []const u8) void {
    if (!isDir(io, src))
        fail(ctx, "freeze_src: source tree not found: {s}", .{src});
    const script = std.fmt.allocPrint(alloc,
        \\set -e
        \\mkdir -p {s}
        \\cd {s} && {s} | cpio -pdm0 {s} >/dev/null 2>&1
    , .{ dst, src, find_expr, dst }) catch fail(ctx, "oom", .{});
    _ = runShell(alloc, io, ctx, null, ".", "freeze_src", script);
}

/// rewrite the pkgset's RELATIVE Path values to the frozen absolute ones
/// (qemu_boot.sh:149-154's sed, but structured: only the five roots the m3
/// set names; unknown relative paths are an ERROR, not a silent pass-through)
fn rewritePkgset(alloc: std.mem.Allocator, io: std.Io, ctx: *const BuildCtx, pkgset_path: []const u8, frozen: []const u8, sibs: []const u8) []u8 {
    const src = readFileSmall(alloc, io, pkgset_path) orelse
        fail(ctx, "cannot read package-set: {s}", .{pkgset_path});
    var outw: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        // splice ONLY the matched < Path = "..." > fragment (the harness
        // sed's semantics) — the rest of the line (name/version/src = ...)
        // must survive byte-for-byte
        const marker = "< Path = \"";
        if (std.mem.indexOf(u8, line, marker)) |ix| {
            const rest = line[ix + marker.len ..];
            const close = std.mem.indexOf(u8, rest, "\" >") orelse {
                outw.appendSlice(alloc, line) catch fail(ctx, "oom", .{});
                outw.append(alloc, '\n') catch fail(ctx, "oom", .{});
                continue;
            };
            const target = rest[0..close];
            const after = line[ix + marker.len + close + "\" >".len ..];
            var mapped: []u8 = undefined;
            if (std.mem.eql(u8, target, "../../datalog-dafsa") or
                std.mem.eql(u8, target, "../../dhall-c") or
                std.mem.eql(u8, target, "../../fxstore"))
            {
                mapped = std.fmt.allocPrint(alloc, "{s}/{s}", .{ sibs, target["../../".len..] }) catch fail(ctx, "oom", .{});
            } else if (std.mem.eql(u8, target, "..")) {
                mapped = std.fmt.allocPrint(alloc, "{s}/fx-init", .{frozen}) catch fail(ctx, "oom", .{});
            } else if (std.mem.eql(u8, target, "../vendor/dhake")) {
                mapped = std.fmt.allocPrint(alloc, "{s}/fx-init/vendor/dhake", .{frozen}) catch fail(ctx, "oom", .{});
            } else if (target.len > 0 and target[0] == '/') {
                // absolute: the loader keeps it verbatim
                mapped = alloc.dupe(u8, target) catch fail(ctx, "oom", .{});
            } else {
                fail(ctx, "package-set has an unmapped relative Path \"{s}\" (extend rewritePkgset)", .{target});
            }
            outw.appendSlice(alloc, line[0..ix]) catch fail(ctx, "oom", .{});
            outw.appendSlice(alloc, "< Path = \"") catch fail(ctx, "oom", .{});
            outw.appendSlice(alloc, mapped) catch fail(ctx, "oom", .{});
            outw.appendSlice(alloc, "\" >") catch fail(ctx, "oom", .{});
            outw.appendSlice(alloc, after) catch fail(ctx, "oom", .{});
            alloc.free(mapped);
        } else {
            outw.appendSlice(alloc, line) catch fail(ctx, "oom", .{});
        }
        outw.append(alloc, '\n') catch fail(ctx, "oom", .{});
    }
    const out = outw.toOwnedSlice(alloc) catch fail(ctx, "oom", .{});
    if (std.mem.indexOf(u8, out, frozen) == null)
        fail(ctx, "package-set rewrite produced no frozen paths", .{});
    return out;
}

// ─── provisioning (qemu_boot.sh's toolchain-free path, same steps/order) ───

fn provision(
    alloc: std.mem.Allocator,
    io: std.Io,
    ctx: *const BuildCtx,
    env: *std.process.Environ.Map,
    repo: []const u8,
    sibs: []const u8,
    frozen: []const u8,
    store: []const u8,
) []u8 {
    // ─── the deterministic build root (FIX 2, review round 2) ────────────
    // The payload binaries EMBED absolute build paths (RUNPATH, DWARF
    // source dirs).  Building them in the LIVE checkout made the checkout
    // path an image input (reviewer's A/B: identical tree content at a
    // different path -> different sha).  The build now happens in a COPY
    // of the frozen tree, inside the fixed work dir:
    //   {work}/lib/libdatalog.so     staged engine .so (the RUNPATH target)
    //   {work}/frozen/...            PRISTINE frozen sources — the ONLY
    //                                 input the derivation hash walks
    //   {work}/buildroot             a copy of frozen/fx-init where `zig
    //                                 build` + fakesvc's `zig cc` run
    //                                 (zig-out/.zig-cache land here, never
    //                                 inside a hashed tree: m3's
    //                                 fake-service excludes LACK
    //                                 zig/.zig-cache, so pollution inside
    //                                 the frozen tree would shift its
    //                                 derivation hash — measured on the
    //                                 first A/B attempt)
    // Every absolute path the linker bakes ({work}/buildroot,
    // {work}/frozen/siblings/..., {work}/lib) is a function of (content,
    // work dir) only — the checkout path no longer enters the image.
    const lib_dir = fmt2(alloc, "{s}/lib", .{std.fs.path.dirname(frozen) orelse frozen});
    {
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, lib_dir) catch
            fail(ctx, "cannot create {s}", .{lib_dir});
        const live_dl = fmt2(alloc, "{s}/datalog-dafsa/zig-out/lib/libdatalog.so", .{sibs});
        copyTo(alloc, io, ctx, live_dl, fmt2(alloc, "{s}/libdatalog.so", .{lib_dir}), 0o755);
    }
    const buildroot = fmt2(alloc, "{s}/buildroot", .{std.fs.path.dirname(frozen) orelse frozen});
    {
        // PERSISTENT buildroot, refreshed in place (determinism regression
        // fix, review round 3): the old `rm -rf` re-copy forced a COLD zig
        // build every run, and cold builds are NOT bit-reproducible on this
        // host (MEASURED: identical sources, same path, same env -> payload
        // binaries differ in their symtab/strtab tail; SOURCE_DATE_EPOCH
        // and strip do not close it — warm/incremental builds ARE
        // byte-identical).  So the buildroot (and its zig cache) must
        // SURVIVE runs.  Correctness of the refresh, against the
        // "a leftover buildroot must not leak state" this replaces:
        //   - rsync -a --delete --checksum mirrors the freshly re-frozen
        //     tree in, deciding transfers by CONTENT: unchanged files are
        //     skipped whole, so their mtimes SURVIVE and the next `zig
        //     build` is a genuine warm no-op (the frozen tree is rebuilt
        //     from scratch each run with fresh mtimes — a plain mtime
        //     rsync would churn every file's mtime, and a churned-mtime
        //     build re-links, which is exactly the nondeterministic cold
        //     class); --delete still removes every file the frozen tree
        //     no longer has (stale sources, a removed target's zig-out
        //     binary, last run's /fakesvc) — nothing unmanaged survives
        //     at a source path;
        //   - `protect` keeps ONLY zig's own state (zig/.zig-cache,
        //     zig/.zig-global — the WHOLE SUBTREE, `protect` without a
        //     trailing `/***` guards the dir itself but still deletes its
        //     CONTENTS, which silently de-warms the cache every run)
        //     out of the deletion set — dirs a source tree can never
        //     contain (FREEZE_FIND excludes them too), so the protection
        //     cannot mask a real source;
        //   - zig's cache invalidates by CONTENT (the refresh's mtime
        //     churn only makes it re-hash), so an edited source still
        //     rebuilds and a changed binary still lands in the image —
        //     gated by the touch-a-source probe, because a refresh that
        //     silently ignored edits would be exactly the leak feared.
        // zig-out is deliberately NOT protected: rsync removing it each
        // run is the stale-target guard above, and `zig build` reinstalls
        // the binaries byte-exact from the warm cache (no recompile, so
        // no cold-build nondeterminism — this is the two-run gate).
        const script = fmt2(
            alloc,
            "rsync -a --delete --checksum --filter='protect /zig/.zig-cache/***' --filter='protect /zig/.zig-global/***' {s}/fx-init/ {s}",
            .{ frozen, buildroot },
        );
        _ = runShell(alloc, io, ctx, null, ".", "buildroot refresh", script);
    }
    // the build must resolve its siblings at the FROZEN copies (the build
    // .zig defaults ../../<name> would escape to the live checkouts) and
    // the engine .so at the work-rooted path
    env.put("FX_SIB_DHALL_C", fmt2(alloc, "{s}/siblings/dhall-c", .{frozen})) catch fail(ctx, "oom", .{});
    env.put("FX_SIB_FXSTORE", fmt2(alloc, "{s}/siblings/fxstore", .{frozen})) catch fail(ctx, "oom", .{});
    env.put("FX_SIB_DATALOG_SRC", fmt2(alloc, "{s}/siblings/datalog-dafsa", .{frozen})) catch fail(ctx, "oom", .{});
    env.put("FX_SIB_DATALOG_LIB", lib_dir) catch fail(ctx, "oom", .{});
    env.put("FX_DATALOG_LIB", lib_dir) catch fail(ctx, "oom", .{}); // mkinitramfs's engine source

    // zig build -Doptimize=ReleaseSmall — the payload is seeded into the 32
    // MiB disk partition (PART1_START_LBA 65536 of a 64 MiB image); Debug
    // output is ~47 MB (fx-activate 20M + fx-init 13M + fxctl 12M) and cannot
    // fit, which made init fall back to the ramfs store (no persistence).
    // Still gated on the four binaries we need, NOT the aggregate exit
    // (log_probe_live can fail on unpopulated submodules; qemu_boot.sh:175)
    note(ctx, "=== fx-image: zig build (in the work-dir buildroot) ===\n", .{});
    {
        const zig_dir = fmt2(alloc, "{s}/zig", .{buildroot});
        const res = std.process.run(alloc, io, .{
            .argv = &.{ "/bin/sh", "-c", "zig build -Doptimize=ReleaseSmall" },
            .cwd = .{ .path = zig_dir },
            .environ_map = env,
        }) catch fail(ctx, "cannot spawn zig build", .{});
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }
    const zb = fmt2(alloc, "{s}/zig/zig-out/bin", .{buildroot});
    for ([_][]const u8{ "fx-init", "fx-activate", "fxctl", "activate_paths" }) |b| {
        const p = std.fmt.allocPrint(alloc, "{s}/{s}", .{ zb, b }) catch fail(ctx, "oom", .{});
        if (!isFile(io, p))
            fail(ctx, "zig build did not produce zig-out/bin/{s}", .{b});
    }

    // ─── the fx-core console payload (M6) ─────────────────────────────────
    // fxsh + the fx-* set stage at /usr/fx-core/bin in the guest (one of
    // the pivot binds, so it survives the disk-arm pivot; fxsh resolves its
    // command binaries via its OWN executable dir, no env needed).  NOT an
    // m3 package: the image lane builds it from the frozen tree, work-
    // rooted, exactly like buildroot above — every absolute path the
    // linker bakes is a function of (content, work dir) only.
    //
    //   {work}/{dhall-c,fxstore,datalog-dafsa}  the FROZEN sibling trees,
    //       laid out as buildroot-fxcore's DIRECT ../ siblings so
    //       fx-core/build.zig's hardcoded b.path("../dhall-c/..."),
    //       b.path("../datalog-dafsa") and the ../fxstore/zig module roots
    //       resolve (MEASURED in a /tmp probe: the ReleaseSmall build needs
    //       exactly src + build.zig + build.zig.zon + those three siblings;
    //       datalog needs the PRE-BUILT libdatalog.so at the sibling root,
    //       the same file {work}/lib stages)
    //   {work}/buildroot-fxcore  a PERSISTENT rsync-refreshed copy of the
    //       frozen fx-core (the buildroot mechanism verbatim: its zig cache
    //       surviving makeWork's wipe is what makes run-2 a warm no-op, and
    //       warm builds ARE the two-run byte-identical contract)
    const buildroot_fxcore = fmt2(alloc, "{s}/buildroot-fxcore", .{std.fs.path.dirname(frozen) orelse frozen});
    note(ctx, "=== fx-image: fx-core build (work-rooted buildroot-fxcore) ===\n", .{});
    {
        // sibling layout: cp -a the frozen trees to {work}/<name> (they are
        // pristine — makeWork wiped everything but the buildroots, then
        // freezeSrc re-copied them fresh).  The frozen datalog-dafsa has NO
        // libdatalog.so (every freeze excludes *.so), but fx-core's
        // addLibraryPath("../datalog-dafsa") needs it at the sibling root
        // at link time — stage the SAME file {work}/lib already holds (the
        // live checkout's engine .so, copied once above).
        // The rsync is the buildroot refresh verbatim: --checksum decides
        // by CONTENT so unchanged files keep their mtimes (run-2 is a warm
        // no-op), --delete removes every stale source file, and ONLY the
        // zig caches are protected — zig-out is deliberately NOT (it is
        // the stale-target guard; `zig build` reinstalls the binaries
        // byte-exact from the warm cache).
        const work_root = std.fs.path.dirname(frozen) orelse frozen;
        const script = fmt2(
            alloc,
            "cp -a {s}/siblings/dhall-c {s}/siblings/fxstore {s}/siblings/datalog-dafsa {s}/ && " ++
                "cp {s}/libdatalog.so {s}/datalog-dafsa/libdatalog.so && " ++
                "rsync -a --delete --checksum --filter='protect .zig-cache/***' --filter='protect .zig-global/***' {s}/siblings/fx-core/ {s}",
            .{ frozen, frozen, frozen, work_root, lib_dir, work_root, frozen, buildroot_fxcore },
        );
        _ = runShell(alloc, io, ctx, null, ".", "fx-core layout + refresh", script);
    }
    {
        // ZIG_GLOBAL_CACHE_DIR is buildroot-local (the m3 recipes' exact
        // convention, package-set.dhall:159) so no other zig on this host
        // interleaves state into the image's cache.  The default `zig
        // build` step is INSTALL-only in fx-core (tests hang off the
        // separate `test` step, build.zig:144), so no --summary games.
        const cmdline = fmt2(
            alloc,
            "ZIG_GLOBAL_CACHE_DIR={s}/.zig-global zig build -Doptimize=ReleaseSmall",
            .{buildroot_fxcore},
        );
        const res = std.process.run(alloc, io, .{
            .argv = &.{ "/bin/sh", "-c", cmdline },
            .cwd = .{ .path = buildroot_fxcore },
            .environ_map = env,
        }) catch fail(ctx, "cannot spawn fx-core zig build", .{});
        alloc.free(res.stdout);
        alloc.free(res.stderr);
    }
    // gate on the console payload we need (the image.zig:861 shape: gate
    // on the ARTIFACTS, not the aggregate exit — a usage-test failure in
    // an unrelated target must not burn the image)
    const fxbin = fmt2(alloc, "{s}/zig-out/bin", .{buildroot_fxcore});
    for ([_][]const u8{
        "fxsh",   "fx-echo", "fx-cat",  "fx-head", "fx-tail", "fx-ls",
        "fx-grep", "fx-find", "fx-sort", "fx-uniq", "fx-wc",  "fx-du",
        "fx-what", "fx-why",
    }) |b| {
        const p = std.fmt.allocPrint(alloc, "{s}/{s}", .{ fxbin, b }) catch fail(ctx, "oom", .{});
        if (!isFile(io, p))
            fail(ctx, "fx-core build did not produce zig-out/bin/{s}", .{b});
    }

    // the prebuilt sibling inputs (same checks as the harness)
    const dls = lib_dir;
    {
        const dl = std.fmt.allocPrint(alloc, "{s}/libdatalog.so", .{dls}) catch fail(ctx, "oom", .{});
        if (!isFile(io, dl))
            fail(ctx, "libdatalog.so missing at {s} (build the sibling)", .{dl});
        const dsrc = std.fmt.allocPrint(alloc, "{s}/dhake/dhake.com", .{sibs}) catch fail(ctx, "oom", .{});
        if (!isFile(io, dsrc))
            fail(ctx, "prebuilt dhake.com missing at {s}", .{dsrc});
    }

    // dhake: assimilate the prebuilt APE to a static ELF (drops the
    // sh-preamble tool + APE-loader deps in the guest)
    const dhake_dst = std.fmt.allocPrint(alloc, "{s}/dhake.com", .{frozen}) catch fail(ctx, "oom", .{});
    {
        const script = std.fmt.allocPrint(alloc,
            \\set -e
            \\cp {s}/dhake/dhake.com {s}
            \\chmod +x {s}
            \\{s} --assimilate
            \\file {s} | grep -q 'statically linked'
        , .{ sibs, dhake_dst, dhake_dst, dhake_dst, dhake_dst }) catch fail(ctx, "oom", .{});
        _ = runShell(alloc, io, ctx, null, ".", "dhake --assimilate", script);
    }

    // static fakesvc via zig cc (musl) — the m3 recipe's cosmocc target,
    // toolchain-free.  Compiled in the BUILDROOT (its cwd = the buildroot
    // copy): zig cc embeds the source's absolute path in the binary, so
    // building against the live checkout would put the checkout path in
    // the image (the FIX 2 mechanism, measured on the A/B arms).
    const fakesvc = std.fmt.allocPrint(alloc, "{s}/fakesvc", .{buildroot}) catch fail(ctx, "oom", .{});
    {
        const script = std.fmt.allocPrint(
            alloc,
            "zig cc -target x86_64-linux-musl -std=gnu11 -O2 -static -o {s} tests/fixtures/fakesvc/fakesvc.c",
            .{fakesvc},
        ) catch fail(ctx, "oom", .{});
        _ = runShell(alloc, io, ctx, env, buildroot, "zig cc fakesvc", script);
    }

    // activate_paths closure -> fill each dir with its payload (the
    // harness's exact case dispatch)
    const pkgset_frozen = std.fmt.allocPrint(alloc, "{s}/package-set.dhall", .{frozen}) catch fail(ctx, "oom", .{});
    {
        const pkg_abs = absPath(alloc, io, ctx.pkgset) orelse
            fail(ctx, "package-set not found: {s}", .{ctx.pkgset});
        const rewritten = rewritePkgset(alloc, io, ctx, pkg_abs, frozen, fmt2(alloc, "{s}/siblings", .{frozen}));
        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = pkgset_frozen,
            .data = rewritten,
        }) catch fail(ctx, "cannot write the frozen package-set {s}", .{pkgset_frozen});
    }
    note(ctx, "=== fx-image: provisioning store closure ===\n", .{});
    var path_lines: [][]u8 = undefined;
    {
        const script = std.fmt.allocPrint(
            alloc,
            "LD_LIBRARY_PATH={s} {s}/activate_paths --store {s} --package-set {s} dhake fx-init fxctl fx-activate fake-service datalog-dafsa dhall-c fxstore",
            .{ dls, std.fmt.allocPrint(alloc, "{s}/zig/zig-out/bin", .{buildroot}) catch fail(ctx, "oom", .{}), store, pkgset_frozen },
        ) catch fail(ctx, "oom", .{});
        const outp = runShell(alloc, io, ctx, env, repo, "activate_paths", script);
        var lines: std.ArrayList([]u8) = .empty;
        var lit = std.mem.splitScalar(u8, outp, '\n');
        while (lit.next()) |ln| {
            if (ln.len == 0) continue;
            lines.append(alloc, @constCast(ln)) catch fail(ctx, "oom", .{});
        }
        path_lines = lines.toOwnedSlice(alloc) catch fail(ctx, "oom", .{});
        if (path_lines.len == 0)
            fail(ctx, "activate_paths printed no closure", .{});
    }

    const cwd = std.Io.Dir.cwd();
    for (path_lines) |pd| {
        const d = std.fmt.allocPrint(alloc, "{s}/{s}", .{ store, pd }) catch fail(ctx, "oom", .{});
        cwd.createDirPath(io, d) catch
            fail(ctx, "cannot create store dir {s}", .{d});
        // the payload target = the name AFTER THE FIRST '-' (the hash
        // itself contains '-'; "9a53...726-fx-init" -> "fx-init")
        const first = std.mem.indexOfScalar(u8, pd, '-') orelse pd.len;
        const last = pd[first + 1 ..];
        const fz = fmt2(alloc, "{s}/zig/zig-out/bin", .{buildroot});
        if (std.mem.eql(u8, last, "fx-init")) {
            copyTo(alloc, io, ctx, fmt2(alloc, "{s}/fx-init", .{fz}), fmt2(alloc, "{s}/fx-init", .{d}), 0o755);
        } else if (std.mem.eql(u8, last, "fxctl")) {
            copyTo(alloc, io, ctx, fmt2(alloc, "{s}/fxctl", .{fz}), fmt2(alloc, "{s}/fxctl", .{d}), 0o755);
        } else if (std.mem.eql(u8, last, "fx-activate")) {
            copyTo(alloc, io, ctx, fmt2(alloc, "{s}/fx-activate", .{fz}), fmt2(alloc, "{s}/fx-activate", .{d}), 0o755);
        } else if (std.mem.eql(u8, last, "fake-service")) {
            copyTo(alloc, io, ctx, fakesvc, fmt2(alloc, "{s}/fakesvc", .{d}), 0o755);
        } else if (std.mem.eql(u8, last, "dhake")) {
            copyTo(alloc, io, ctx, dhake_dst, fmt2(alloc, "{s}/dhake.com", .{d}), 0o755);
        } else {
            // dep targets are only hashed inputs — a marker file (their
            // content never executes at boot; the harness's convention)
            const marker = fmt2(alloc, "{s}/.provisioned-by-fx-image", .{d});
            cwd.writeFile(io, .{ .sub_path = marker, .data = "" }) catch
                fail(ctx, "cannot write marker {s}", .{marker});
        }
    }
    return pkgset_frozen;
}

fn fmt2(alloc: std.mem.Allocator, comptime f: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(alloc, f, args) catch @panic("out of memory");
}

// ─── activation (the REAL fx-activate against the frozen pkgset) ───────────

const Activation = struct {
    version: u32,
    genhash: [64]u8,
    fxinit_dirname: []u8, // store-RELATIVE "<hash>-fx-init"
};

fn activate(
    alloc: std.mem.Allocator,
    io: std.Io,
    ctx: *const BuildCtx,
    env: *std.process.Environ.Map,
    repo: []const u8,
    store: []const u8,
    frozen_pkgset: []const u8,
    zb: []const u8,
    dls: []const u8,
) Activation {
    note(ctx, "=== fx-image: activating {s} ===\n", .{basenameOf(ctx.config)});
    const config_abs = absPath(alloc, io, ctx.config) orelse
        fail(ctx, "config not found: {s}", .{ctx.config});
    const script = fmt2(
        alloc,
        "LD_LIBRARY_PATH={s} {s}/fx-activate --store {s} --package-set {s} --config {s}",
        .{ dls, zb, store, frozen_pkgset, config_abs },
    );
    const outp = runShell(alloc, io, ctx, env, repo, "fx-activate", script);
    ctx.out.print("{s}", .{outp}) catch {};

    // "activated <genhash> as version <N>; buildfile <path>"
    var version: u32 = 0;
    var genhash: [64]u8 = undefined;
    var got_gen = false;
    var lit = std.mem.splitScalar(u8, outp, '\n');
    while (lit.next()) |line| {
        const mark = std.mem.indexOf(u8, line, "activated ") orelse continue;
        const rest = line[mark + "activated ".len ..];
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        if (sp != 64) continue;
        @memcpy(&genhash, rest[0..64]);
        got_gen = true;
        const tail = rest[sp + 1 ..];
        if (std.mem.startsWith(u8, tail, "as version ")) {
            const vtail = tail["as version ".len..];
            const vend = std.mem.indexOfScalar(u8, vtail, ';') orelse vtail.len;
            version = std.fmt.parseInt(u32, std.mem.trim(u8, vtail[0..vend], " \t"), 10) catch 0;
        }
        break;
    }
    if (!got_gen or version == 0)
        fail(ctx, "cannot parse 'activated <hash> as version <N>' from fx-activate output", .{});

    // the rdinit target: the store's *-fx-init dir found ON DISK (exactly
    // qemu_boot.sh:265 — never guessed from argv), first in sort order.
    // openDir(.{.iterate=true}): iterating the cwd handle (AT_FDCWD) reads
    // a closed fd — the std flags it BADF.
    var names: std.ArrayList([]u8) = .empty;
    {
        const sd = std.Io.Dir.cwd().openDir(io, store, .{ .iterate = true }) catch
            fail(ctx, "cannot open the store dir {s}", .{store});
        var hit = sd.iterate();
        while (true) {
            const e = (hit.next(io) catch break) orelse break;
            if (e.kind != .directory) continue;
            if (std.mem.endsWith(u8, e.name, "-fx-init"))
                names.append(alloc, alloc.dupe(u8, e.name) catch fail(ctx, "oom", .{})) catch fail(ctx, "oom", .{});
        }
        sd.close(io);
    }
    if (names.items.len == 0)
        fail(ctx, "no *-fx-init dir in the store", .{});
    std.mem.sort([]u8, names.items, {}, lessThanStr);
    const fxdir = names.items[0];
    for (names.items[1..]) |n| alloc.free(n);

    return .{ .version = version, .genhash = genhash, .fxinit_dirname = fxdir };
}

fn lessThanStr(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn basenameOf(p: []const u8) []const u8 {
    return std.fs.path.basename(p);
}

// ─── the top-level build ───────────────────────────────────────────────────

fn buildImage(gpa: std.mem.Allocator, io: std.Io, ctx: *const BuildCtx, cur_environ: std.process.Environ) !void {
    // a whole-build arena: the run allocates paths, child output and store
    // names it never individually frees — freed in bulk at return, so the
    // DebugAllocator never leak-reports at exit (a one-shot CLI exits clean)
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    // repo root = the checkout holding scripts/ + tests/, derived from the
    // running binary (zig-out/bin -> zig-out -> zig -> repo).  m3 recipes
    // build into per-package copies of the tree; the INVARIANT is that the
    // running fx-image sits in <repo>/zig/zig-out/bin with <repo>/scripts
    // beside it — assert that, loudly.
    const exe = std.process.executablePathAlloc(io, alloc) catch
        fail(ctx, "cannot locate the running binary", .{});
    const exe_dir = std.fs.path.dirname(exe) orelse
        fail(ctx, "cannot locate the running binary: {s}", .{exe});
    const zig_out = std.fs.path.dirname(exe_dir) orelse exe_dir;
    const zig_dir = std.fs.path.dirname(zig_out) orelse zig_out;
    const repo = std.fs.path.dirname(zig_dir) orelse zig_dir;
    if (!isDir(io, fmt2(alloc, "{s}/scripts", .{repo})) or
        !isDir(io, fmt2(alloc, "{s}/tests", .{repo})) or
        !isDir(io, fmt2(alloc, "{s}/zig", .{repo})))
    {
        fail(ctx, "repo layout not found around the binary ({s}) — expected <repo>/zig/zig-out/bin/fx-image", .{exe});
    }

    // the environment: current env + FX_SIBLINGS default + FX_EPOCH export.
    // FX_EPOCH pins fx-activate's generation fact (which activate.zig's
    // genEpoch reads, with SOURCE_DATE_EPOCH as its own fallback); it is
    // defaulted ONLY when the caller set NEITHER variable, so a caller's
    // SOURCE_DATE_EPOCH is never shadowed.  The intermediate map is
    // deinit'd (the DebugAllocator leak-reports a dropped copy at exit; a
    // one-shot CLI still exits CLEAN).
    var env = std.process.Environ.Map.init(alloc);
    {
        var cur = std.process.Environ.createMap(cur_environ, alloc) catch
            fail(ctx, "cannot read the environment", .{});
        defer cur.deinit();
        var eit = cur.iterator();
        while (eit.next()) |kv| {
            try env.put(kv.key_ptr.*, kv.value_ptr.*);
        }
    }
    if (envGet(&env, "FX_SIBLINGS") == null) {
        const sibs_default = std.fs.path.dirname(repo) orelse repo;
        try env.put("FX_SIBLINGS", sibs_default);
    }
    if (envGet(&env, "FX_EPOCH") == null and envGet(&env, "SOURCE_DATE_EPOCH") == null)
        try env.put("FX_EPOCH", "1");
    const sibs = envGet(&env, "FX_SIBLINGS").?;

    // ─── work dir (FIXED, not mkdtemp'd; rm -rf on exit unless FX_KEEP=1).
    // The store lives at {work}/store and the vendored fxstore's derivation
    // hash folds each dep's full STORE PATH into the hash, so a random
    // prefix would enter every package-with-deps' hash — determinism needs
    // the SAME root every build (see the header note).  A lock file
    // (O_EXCL <work>.lock holding the pid) refuses concurrent builders;
    // the flock beneath it survives only as long as the process does.
    installFatalHandlers();
    const work = makeWork(alloc, io, ctx, &env);
    defer releaseWorkLock(io);
    defer cleanupScratch(alloc, io, &env, work);

    const frozen = fmt2(alloc, "{s}/frozen", .{work});
    const store = fmt2(alloc, "{s}/store", .{work});
    const root = fmt2(alloc, "{s}/root", .{work});
    // zb/dls are WORK-ROOTED (FIX 2): the payload binaries are built in the
    // {work}/buildroot copy and link against a work-staged engine .so, so
    // no live-checkout path enters the binaries (see provision's note)
    const zb = fmt2(alloc, "{s}/buildroot/zig/zig-out/bin", .{work});
    const dls = fmt2(alloc, "{s}/lib", .{work});
    const disk_bytes: u64 = ctx.size_mb << 20;
    const disk_sectors = disk_bytes >> 9;

    // ─── the pinned kernel ──────────────────────────────────────────────
    const kern = loadKernel(alloc, io, ctx, repo, &env);
    note(ctx, "=== fx-image: kernel {s} (sha256 ok) ===\n", .{basenameOf(kern.path)});

    // ─── freeze the package sources (concurrent-writer shield) ──────────
    note(ctx, "=== fx-image: freezing package sources ===\n", .{});
    freezeSrc(alloc, io, ctx, fmt2(alloc, "{s}/datalog-dafsa", .{sibs}), fmt2(alloc, "{s}/siblings/datalog-dafsa", .{frozen}));
    freezeSrc(alloc, io, ctx, fmt2(alloc, "{s}/dhall-c", .{sibs}), fmt2(alloc, "{s}/siblings/dhall-c", .{frozen}));
    freezeSrc(alloc, io, ctx, fmt2(alloc, "{s}/fxstore", .{sibs}), fmt2(alloc, "{s}/siblings/fxstore", .{frozen}));
    freezeSrc(alloc, io, ctx, repo, fmt2(alloc, "{s}/fx-init", .{frozen}));
    // the 5th freeze: fx-core (the M6 console payload's source).  Its own
    // find: the fx-core tree keeps a 9GB zig cache at ROOT .zig-cache and a
    // vendored node_modules under vendor/mfe-framework — FREEZE_FIND's
    // fx-init-shaped exclusions would copy all of it.
    freezeSrcFind(alloc, io, ctx, fmt2(alloc, "{s}/fx-core", .{sibs}), fmt2(alloc, "{s}/siblings/fx-core", .{frozen}), FREEZE_FIND_FXCORE);

    // ─── provision + activate ───────────────────────────────────────────
    const pkgset_frozen = provision(alloc, io, ctx, &env, repo, sibs, frozen, store);
    const act = activate(alloc, io, ctx, &env, repo, store, pkgset_frozen, zb, dls);
    note(ctx, "=== fx-image: activated version {d} (rdinit /fx/store/{s}/fx-init) ===\n", .{ act.version, act.fxinit_dirname });

    // ─── the initramfs (mkinitramfs -E = deterministic; U1's contract) ──
    // -b stages the fx-core console payload at /usr/fx-core/bin (the M6
    // console service's argv[0] lives there; flag-off callers — every
    // existing harness — get the byte-identical archive of before).
    note(ctx, "=== fx-image: building initramfs (mkinitramfs -E -b fx-core) ===\n", .{});
    const initrd = fmt2(alloc, "{s}/initrd.cpio.gz", .{work});
    {
        const script = fmt2(
            alloc,
            "sh {s}/tests/mkinitramfs.sh -E -b {s}/buildroot-fxcore/zig-out/bin -s {s} -r {s} -k {s} -o {s}",
            .{ repo, work, store, root, kern.path, initrd },
        );
        _ = runShell(alloc, io, ctx, &env, repo, "mkinitramfs", script);
    }
    const initrd_size = fileSize(io, initrd) orelse
        fail(ctx, "initrd missing after mkinitramfs: {s}", .{initrd});
    const kernel_size = fileSize(io, kern.path) orelse
        fail(ctx, "cannot stat kernel {s}", .{kern.path});
    const initrd_sha = fileSha256Raw(alloc, io, initrd) orelse
        fail(ctx, "cannot hash initrd {s}", .{initrd});
    const kernel_sha = fileSha256Raw(alloc, io, kern.path) orelse
        fail(ctx, "cannot hash kernel {s}", .{kern.path});

    // ─── the boot blobs (U3 stage1 + U4 stage2, assembled fresh per build).
    // Design: shell out to the VERIFIED build scripts (as/objcopy, the same
    // gnu toolchain U3/U4 gated byte-identically against zig cc) rather
    // than committing assembled bytes — the .S sources are the artifact of
    // record, and their builds are deterministic (proven by U3/U4's
    // dual-toolchain gate and this builder's own double-build sha gate).
    // Output goes into the FIXED work dir (never the repo), so the repo's
    // zig-out is not an input and no bash-only path is baked into the
    // image.  mkinitramfs -E's initramfs is built below the same way.
    note(ctx, "=== fx-image: assembling stage1/stage2 ===\n", .{});
    const stage1_path = fmt2(alloc, "{s}/stage1.bin", .{work});
    const stage2_path = fmt2(alloc, "{s}/stage2.bin", .{work});
    {
        const s1 = fmt2(alloc, "sh {s}/zig/src/boot/build-stage1.sh -o {s}", .{ repo, stage1_path });
        _ = runShell(alloc, io, ctx, &env, repo, "build-stage1", s1);
        const s2 = fmt2(alloc, "sh {s}/zig/src/boot/build-stage2.sh -o {s}", .{ repo, stage2_path });
        _ = runShell(alloc, io, ctx, &env, repo, "build-stage2", s2);
    }
    const stage1 = readFileSmall(alloc, io, stage1_path) orelse
        fail(ctx, "stage1 blob missing after build-stage1.sh: {s}", .{stage1_path});
    const stage2 = readFileSmall(alloc, io, stage2_path) orelse
        fail(ctx, "stage2 blob missing after build-stage2.sh: {s}", .{stage2_path});
    if (stage1.len != 512)
        fail(ctx, "stage1 blob is {d} bytes, not 512 (build-stage1.sh contract broken)", .{stage1.len});
    if (stage2.len == 0 or stage2.len % byte_layout.SECTOR != 0)
        fail(ctx, "stage2 blob is {d} bytes, not a sector multiple (build-stage2.sh pads)", .{stage2.len});
    // stage1 CRCs stage2_sectors*512 bytes — the WHOLE area, pad included
    // (build-stage2.sh pads only to its own sector count).  The area
    // buffer is what gets written and hashed, so the two cannot diverge.
    const stage2_area: usize = @intCast(byte_layout.STAGE2_SECTORS * byte_layout.SECTOR);
    if (stage2.len > stage2_area)
        fail(ctx, "stage2 blob is {d} bytes, exceeds the {d}-byte area (stage1 enforces <= 60 sectors)", .{ stage2.len, stage2_area });
    const stage2_full = alloc.alloc(u8, stage2_area) catch fail(ctx, "oom", .{});
    @memset(stage2_full, 0);
    @memcpy(stage2_full[0..stage2.len], stage2);
    const stage2_crc32 = std.hash.Crc32.hash(stage2_full);

    // ─── geometry ───────────────────────────────────────────────────────
    const kernel_sectors = ceilDiv(kernel_size, 512);
    const kernel_lba = byte_layout.kernelLba();
    const initrd_lba = byte_layout.initrdLba(kernel_sectors);
    const initrd_sectors = ceilDiv(initrd_size, 512);
    if (disk_sectors <= byte_layout.PART1_START_LBA)
        fail(ctx, "--size-mb {d} leaves no room for partition 1", .{ctx.size_mb});
    if (initrd_lba + initrd_sectors > byte_layout.PART1_START_LBA)
        fail(ctx, "boot region overflows partition 1 start (initrd ends at LBA {d}, partition starts at {d})", .{ initrd_lba + initrd_sectors, byte_layout.PART1_START_LBA });

    // the baked cmdline (qemu_boot.sh:276's set; rdinit from the store dir).
    // The bufPrint cap is CMDLINE_CAP (2048, the field size) so overlong
    // --extra-cmdline input FAILS HERE with the true stage2 bound named;
    // buildHeader's own CMDLINE_MAX check is the second gate.
    var cmdline_buf: [byte_layout.CMDLINE_CAP]u8 = [_]u8{0} ** byte_layout.CMDLINE_CAP;
    const cmdline = std.fmt.bufPrint(&cmdline_buf, "console=ttyS0,115200 rdinit=/fx/store/{s}/fx-init fx.store=/fx/store panic=-1 oops=panic{s}{s}", .{
        act.fxinit_dirname,
        if (ctx.extra_cmdline.len > 0) " " else "",
        ctx.extra_cmdline,
    }) catch {
        fail(ctx, "cmdline exceeds {d} bytes (stage2 copies at most {d}; shorten --extra-cmdline)", .{ byte_layout.CMDLINE_CAP, byte_layout.CMDLINE_MAX });
    };

    // ─── assemble the image (direct I/O; every byte host-written) ───────
    const out_abs = absPath(alloc, io, ctx.out_path) orelse blk: {
        // --out need not exist yet: resolve against cwd
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch break :blk try alloc.dupe(u8, ctx.out_path);
        break :blk try std.fs.path.resolve(alloc, &.{ cwd_buf[0..n], ctx.out_path });
    };
    {
        const f = std.Io.Dir.createFileAbsolute(io, out_abs, .{
            .truncate = true,
            .permissions = std.Io.File.Permissions.fromMode(0o644),
        }) catch
            fail(ctx, "cannot create {s}", .{out_abs});
        defer f.close(io);
        try f.setLength(io, disk_bytes); // the blank partition 1 stays zero
        const mbr = byte_layout.buildMbr(stage1, disk_sectors) catch
            fail(ctx, "stage1 code exceeds the 446-byte MBR budget (build-stage1.sh should have caught this)", .{});
        try f.writePositionalAll(io, &mbr, 0);
        const hdr = byte_layout.buildHeader(.{
            .stage2_lba = byte_layout.STAGE2_LBA,
            .stage2_sectors = byte_layout.STAGE2_SECTORS,
            .stage2_crc32 = stage2_crc32,
            .kernel_lba = kernel_lba,
            .kernel_sectors = kernel_sectors,
            .initrd_lba = initrd_lba,
            .initrd_sectors = initrd_sectors,
            .part1_start_lba = byte_layout.PART1_START_LBA,
            .part1_sectors = disk_sectors - byte_layout.PART1_START_LBA,
        }, cmdline, kernel_sha, initrd_sha) catch
            fail(ctx, "cmdline is {d} bytes; stage2 copies at most {d} (shorten --extra-cmdline)", .{ cmdline.len, byte_layout.CMDLINE_MAX });
        try f.writePositionalAll(io, &hdr, byte_layout.HDR_LBA * byte_layout.SECTOR);
        // the whole stage2 AREA: the header's crc covers the padding too
        try f.writePositionalAll(io, stage2_full, byte_layout.STAGE2_LBA * byte_layout.SECTOR);
        try writeFileAt(alloc, io, ctx, kern.path, f, kernel_lba * byte_layout.SECTOR);
        try writeFileAt(alloc, io, ctx, initrd, f, initrd_lba * byte_layout.SECTOR);
        try f.sync(io);
    }

    // img.sha256 beside the output (the whole image, after the final byte)
    const sha_hex = try imageSha256(alloc, io, out_abs);
    const sha_path = try std.fmt.allocPrint(alloc, "{s}.sha256", .{out_abs});
    const line = try std.fmt.allocPrint(alloc, "{s}  {s}\n", .{ sha_hex, ctx.out_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sha_path, .data = line });

    note(ctx, "=== fx-image: built {s} ({d} MiB; kernel LBA {d} +{d} sect, initrd LBA {d} +{d} sect) ===\n", .{
        ctx.out_path, ctx.size_mb, kernel_lba, kernel_sectors, initrd_lba, initrd_sectors,
    });
    note(ctx, "fx-image: sha256 {s}\n", .{sha_hex});
}

/// The FIXED work dir + its concurrency lock.  Determinism requires the
/// same store-root path every build (fxstore folds dep store paths into
/// the derivation hash), so this is NOT mkdtemp'd: --work, else
/// $FX_IMAGE_WORK, else ${TMPDIR:-/tmp}/fx-image-work, resolved to an
/// ABSOLUTE path (children run with cwd=repo; a relative store path would
/// resolve differently per cwd AND embed that cwd in the hashes).
///
/// Concurrency guard (deliberately the lightest honest one): an O_EXCL
/// <work>.lock sibling holding the builder's pid — a second fx-image on
/// the same work dir is REFUSED with the holder's pid, not queued.
///
/// NO-LEAK DESIGN (review round 1's finding): the lock file is held under
/// flock(2) for the whole build.  flock dies with the process on EVERY
/// death (clean exit, fail(), kill -9, SIGSEGV, OOM-kill), so a killed
/// builder cannot leave the work dir held: the next run finds the leftover
/// file, acquires its flock, verifies the recorded pid is dead, and TAKES
/// OVER.  fail() and the fatal-signal handlers additionally unlink the
/// file on the paths that reach them.  Nothing waits, so a deadlock by
/// waiting cannot happen.
fn makeWork(alloc: std.mem.Allocator, io: std.Io, ctx: *const BuildCtx, env: *std.process.Environ.Map) []u8 {
    const cwd = std.Io.Dir.cwd();
    const tmp = envGet(env, "TMPDIR") orelse "/tmp";
    const want: []const u8 = if (ctx.work_arg.len > 0)
        ctx.work_arg
    else
        envGet(env, "FX_IMAGE_WORK") orelse fmt2(alloc, "{s}/fx-image-work", .{tmp});
    var work: []u8 = undefined;
    if (want.len > 0 and want[0] == '/') {
        work = alloc.dupe(u8, want) catch fail(ctx, "oom", .{});
    } else {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = cwd.realPath(io, &cwd_buf) catch
            fail(ctx, "cannot resolve the cwd for the relative work dir {s}", .{want});
        work = std.fs.path.resolve(alloc, &.{ cwd_buf[0..n], want }) catch fail(ctx, "oom", .{});
    }
    // trailing slashes would split the store path across runs
    while (work.len > 1 and work[work.len - 1] == '/') work = work[0 .. work.len - 1];
    if (work.len == 0 or !std.fs.path.isAbsolute(work))
        fail(ctx, "work dir did not resolve to an absolute path: {s}", .{want});

    const lock = fmt2(alloc, "{s}.lock", .{work});
    acquireWorkLock(io, ctx, work, lock);

    // fresh scratch INSIDE the fixed root: a leftover tree (prior killed
    // run, or FX_KEEP=1) must not leak into the store — the paths are the
    // same, the CONTENT is rebuilt clean.  rm everything EXCEPT buildroot,
    // which must SURVIVE between runs: its zig cache is what makes repeat
    // builds warm (cold zig builds are not bit-reproducible on this host —
    // MEASURED, see provision's note), and wiping it here would undo the
    // two-run determinism gate.  buildroot's own staleness is handled
    // inside provision by the in-place rsync refresh, not by this wipe.
    // Store/root/frozen are re-created below or re-populated by freezeSrc
    // (freezeSrc cpio-copies over whatever is there — but they were just
    // rm'd, so each run freezes from scratch exactly as before).
    {
        // scoped to the work dir's immediate children (never a wider walk);
        // mkdir -p because a CLEAN work dir does not exist yet (the old
        // rm -rf tolerated that too)
        const script = fmt2(alloc, "mkdir -p {s} && find {s} -mindepth 1 -maxdepth 1 ! -name buildroot ! -name buildroot-fxcore -exec rm -rf -- {{}} +", .{ work, work });
        _ = runShell(alloc, io, ctx, null, ".", "clear work dir", script);
    }
    for ([_][]const u8{ "store", "root/run/fx", "root/etc", "root/bin", "root/tmp", "frozen/siblings" }) |sub| {
        const p = fmt2(alloc, "{s}/{s}", .{ work, sub });
        cwd.createDirPath(io, p) catch
            fail(ctx, "cannot create work dir {s}", .{p});
    }
    // /tmp mode 1777 (the harness's chmod) — fchmodat on the dir path
    // (Dir.setPermissions fchmod's the cwd FD, which is AT_FDCWD — BADF)
    {
        const p = fmt2(alloc, "{s}/root/tmp", .{work});
        std.Io.Dir.cwd().setFilePermissions(io, p, .fromMode(0o1777), .{}) catch {};
    }
    return work;
}

/// Create (O_EXCL) or TAKE OVER <work>.lock: write our pid, hold an
/// exclusive flock for the whole build.  Refusal happens ONLY against a
/// LIVE builder (one holding the flock, or one with a live pid recorded).
fn acquireWorkLock(io: std.Io, ctx: *const BuildCtx, work: []const u8, lock: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    // fast path: O_EXCL create — the lock file of a cleanly-exited builder
    // is gone, so reaching the exists-branch means takeover or refusal
    if (cwd.createFile(io, lock, .{ .exclusive = true, .truncate = false, .read = true })) |lf| {
        finishAcquire(io, ctx, lock, lf);
        return;
    } else |_| {}

    // file exists: LIVE builder (flock held -> refuse) or dead builder's
    // leftover (flock free -> take over; the pid check is belt on top)
    const lf = cwd.openFile(io, lock, .{ .mode = .read_write }) catch
        fail(ctx, "cannot open the existing lock {s}", .{lock});
    const got_flock = lf.tryLock(io, .exclusive) catch false;
    if (!got_flock) {
        const held = readLockPid(io, lock);
        lf.close(io);
        fail(ctx, "work dir {s} is locked by LIVE fx-image pid {s} (concurrent builds would race the store; wait or pass --work)", .{ work, held });
    }
    if (held: {
        const pid_s = readLockPid(io, lock);
        break :held @as(?i32, std.fmt.parseInt(i32, pid_s, 10) catch null);
    }) |pid| {
        if (pid > 0 and pidAlive(pid)) {
            lf.unlock(io);
            lf.close(io);
            fail(ctx, "work dir {s} is locked by fx-image pid {d} (concurrent builds would race the store; wait or pass --work)", .{ work, pid });
        }
    }
    finishAcquire(io, ctx, lock, lf);
}

fn readLockPid(io: std.Io, lock: []const u8) []const u8 {
    var buf: [64]u8 = undefined;
    const cwd = std.Io.Dir.cwd();
    const got = cwd.readFile(io, lock, &buf) catch return "?";
    // copy into a fixed buffer the caller owns: `got` borrows `buf`
    const n = @min(got.len, read_pid_buf.len);
    @memcpy(read_pid_buf[0..n], got[0..n]);
    return std.mem.trim(u8, read_pid_buf[0..n], " \n\t");
}
var read_pid_buf: [64]u8 = undefined;

fn finishAcquire(io: std.Io, ctx: *const BuildCtx, lock: []const u8, lf: std.Io.File) void {
    // register the path in the FIXED buffer before anything can fail: the
    // signal handler must find a consistent (path, fd) pair.  On takeover
    // the pid content is rewritten OURS (a dead pid left behind would
    // misreport the next collision).
    if (lock.len >= g_lock_path_buf.len)
        fail(ctx, "lock path too long: {s}", .{lock});
    @memcpy(g_lock_path_buf[0..lock.len], lock);
    g_lock_path = g_lock_path_buf[0..lock.len];
    g_lock_fd = lf;
    var pid_buf: [32]u8 = undefined;
    const pid = std.fmt.bufPrint(&pid_buf, "{d}\n", .{getpid()}) catch "?\n";
    lf.writeStreamingAll(io, pid) catch {};
    lf.sync(io) catch {};
}

/// kill(pid, 0): ESRCH = dead; SUCCESS/EPERM = a live process (a reused
/// pid is indistinguishable from a live builder — refuse, the safe side).
/// Signal 0 = pure existence check (no signal delivered).
fn pidAlive(pid: i32) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |e| switch (e) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}

fn cleanupScratch(alloc: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, work: []const u8) void {
    // the lock file guards a LIVE builder only — always remove it on exit,
    // even under FX_KEEP=1 (which keeps the TREE for inspection); the
    // flock itself dies with the process, this is hygiene for the next
    // run's fast path
    releaseWorkLock(io);
    const keep = envGet(env, "FX_KEEP");
    if (keep != null and !std.mem.eql(u8, keep.?, "0")) return;
    // Same selective wipe as makeWork: buildroot AND buildroot-fxcore
    // SURVIVE the run too (their zig caches are what makes the NEXT run
    // warm — cold zig builds are not bit-reproducible on this host,
    // MEASURED; see provision's note).  FX_KEEP=1 keeps the whole tree as
    // before.  a child rm (deleteTree over the whole tree can hit open fds)
    const script = fmt2(alloc, "find {s} -mindepth 1 -maxdepth 1 ! -name buildroot ! -name buildroot-fxcore -exec rm -rf -- {{}} +", .{work});
    const res = std.process.run(alloc, io, .{
        .argv = &.{ "/bin/sh", "-c", script },
    }) catch return;
    alloc.free(res.stdout);
    alloc.free(res.stderr);
}

/// copy a whole file into the image at `off` (1 MiB chunks — flat memory)
fn writeFileAt(alloc: std.mem.Allocator, io: std.Io, ctx: *const BuildCtx, path: []const u8, img: std.Io.File, off: u64) !void {
    const src = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch
        fail(ctx, "cannot open {s}", .{path});
    defer src.close(io);
    const chunk: usize = 1 << 20;
    const buf = try alloc.alloc(u8, chunk);
    defer alloc.free(buf);
    var pos: u64 = 0;
    while (true) {
        const n = src.readPositionalAll(io, buf, pos) catch {
            fail(ctx, "read failed on {s}", .{path});
        };
        if (n == 0) break;
        try img.writePositionalAll(io, buf[0..n], off + pos);
        pos += n;
        if (n < buf.len) break;
    }
}

fn imageSha256(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch
        return error.CannotOpen;
    defer f.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const chunk: usize = 1 << 20;
    const buf = try alloc.alloc(u8, chunk);
    defer alloc.free(buf);
    var pos: u64 = 0;
    while (true) {
        const n = f.readPositionalAll(io, buf, pos) catch break;
        if (n == 0) break;
        hasher.update(buf[0..n]);
        pos += n;
        if (n < buf.len) break;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return try std.fmt.allocPrint(alloc, "{x}", .{&digest});
}

extern "c" fn getpid() i32;
