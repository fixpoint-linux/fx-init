//! fxstat.zig — the C ABI structs and symbols that LIBC ACTUALLY FILLS, per
//! target.  ONE place owns the layout, so it can only be got wrong once.
//!
//! Why this module exists: a wrong `struct stat`/`statfs`/`statvfs` layout
//! compiles, links and runs, and then silently reports wrong sizes/modes/dates
//! — it is not a compile error.  So every shape here is pinned by a comptime
//! guard against offsets MEASURED from the target's OWN headers (`zig cc
//! -target <t>` on a C probe that includes <sys/stat.h> etc.), and the
//! i386 time64 symbol redirection is honoured explicitly (see below — the bare
//! symbol is a different, silently-truncating entry point).
//!
//! THE SHAPES (all MEASURED on this host; see the guards at the bottom):
//!
//!   x86_64 (glibc native AND musl)  struct stat sizeof 144, statfs 120,
//!                                   statvfs 112.  Both 64-bit ABIs agree
//!                                   field-for-field, so one shape serves both.
//!   aarch64 (glibc 2.39 AND musl)   struct stat sizeof 128 — NOT the x86_64
//!                                   shape (st_nlink is 32-bit @20, st_mode
//!                                   @16 not @24, st_size @48); statfs 120
//!                                   and statvfs 112 ARE byte-identical to the
//!                                   x86_64 ones, so only struct stat splits.
//!                                   MEASURED, because fx-init's own lane 3
//!                                   (tests/qemu_boot_aarch64.sh:166) builds
//!                                   -Dtarget=aarch64-linux-gnu.2.39 and a
//!                                   144-byte shape there reads 16 bytes past
//!                                   what the kernel fills and reports WRONG
//!                                   mode/uid/size with no error.
//!   i386 musl (x86-linux-musl)      struct stat sizeof 144 but a DIFFERENT
//!                                   layout (st_mode @16 not @24, st_size @44
//!                                   not @48, st_ino @88 not @8); statfs 84
//!                                   (f_type is a 32-bit long at @0 — reading
//!                                   it as i64 yields f_type|f_bsize<<32);
//!                                   statvfs 96.
//!
//! A 64-bit target that is neither x86_64 nor aarch64 is REFUSED at compile
//! time (see unsupported_lp64 below) rather than served the x86_64 shape: a
//! guard asserting 144 for "any 64-bit target" certifies a layout measured on
//! ONE architecture, which is the exact silent-wrong-result this module exists
//! to prevent.
//!
//! MEASURED with a `zig cc -target aarch64-linux-gnu.2.39` probe (and cross-
//! checked on aarch64-linux-musl, which reports the same numbers):
//!   stat:    sizeof 128; dev 0 ino 8 nlink 20 mode 16 uid 24 gid 28 rdev 32
//!            size 48 blksize 56 blocks 64 atim 72 mtim 88 ctim 104
//!            (st_mode/st_nlink/st_uid/st_gid are 32-bit; st_size is 64-bit at
//!            @48 — glibc's `__pad1` @40 plus the align gap before st_size)
//!   statfs:  sizeof 120; type 0 bsize 8 blocks 16 bfree 24 bavail 32 files 40
//!            ffree 48 fsid 56 namelen 64 frsize 72 flags 80  — same as x86_64
//!   statvfs: sizeof 112; bsize 0 frsize 8 blocks 16 bfree 24 bavail 32 files 40
//!            ffree 48 favail 56 fsid 64 flag 72 namemax 80  — same as x86_64
//!   timespec: sizeof 16, tv_nsec @8 (the shared shape below)
//!
//! The aarch64 numbers were re-measured by replaying the same probe on
//! x86-linux-musl, which reproduced THIS module's i386 branch field for field
//! (144 / mode@16 / size@44 / ino@88, statfs 84, statvfs 96) — i.e. the method
//! is validated against a layout already known to be right.
//!
//! MEASURED with a `zig cc -target x86-linux-musl` probe printing @sizeOf and
//! @offsetOf for each member:
//!   stat:    sizeof 144; dev 0 ino 88 nlink 20 mode 16 uid 24 gid 28 rdev 32
//!            size 44 blksize 52 blocks 56 atim 96 mtim 112 ctim 128
//!            (time_t/off_t/ino_t are 8 bytes on i386 musl; c_long is 4)
//!   statfs:  sizeof 84; type 0 bsize 4 blocks 8 bfree 16 bavail 24 files 32
//!            ffree 40 fsid 48 namelen 56 frsize 60 flags 64
//!   statvfs: sizeof 96; bsize 0 frsize 4 blocks 8 bfree 16 bavail 24 files 32
//!            ffree 40 favail 48 fsid 56 flag 64 namemax 68
//!   timespec: sizeof 16, tv_nsec @8 on ALL THREE targets.
//!
//! The layouts were then confirmed EMPIRICALLY (not just by offsetof) by
//! calling the function into a 0xAA-filled buffer and reading it back: the
//! bare `stat` symbol wrote only 96 of the 144 bytes (the 64-bit st_mtim tail
//! untouched — see below), `statfs` wrote 84 and `statvfs` 96, with
//! f_type/st_mode/st_size/st_mtim landing on exactly the offsets above and
//! carrying the values the C header binding reads.
//!
//! THE i386 TIME64 SYMBOL REDIRECTION — the second silent-wrong-result seat.
//! On i386 musl the C headers do NOT bind the symbol you wrote
//! (`__REDIR(x,y)` = `__typeof__(x) x __asm__(#y)`, features.h:38):
//!     sys/stat.h:     __REDIR(stat, __stat_time64)  (also fstat/lstat/fstatat/utimensat)
//!     time.h:         __REDIR(clock_gettime, __clock_gettime64),
//!                     __REDIR(nanosleep, __nanosleep_time64),
//!                     __REDIR(time, __time64)
//! A Zig `extern fn stat(...)` binds the OLD-time compat entry point instead.
//! MEASURED on this host with a sentinel-filled 160-byte buffer: the bare
//! `stat` wrote exactly 96 bytes and left the whole 64-bit time tail
//! (st_atim/st_mtim/st_ctim) as 0xAA — so every timestamp derived from it is
//! garbage, with no error.  The bare `clock_gettime` likewise filled only the
//! pre-time64 8-byte timespec, so a 16-byte reader sees garbage (MEASURED:
//! tv_sec 2180361791945841989 vs the correct 1791237445).  The bindings below
//! therefore name the time64 symbols on i386 musl and the plain ones
//! everywhere else — which is what a C compile of the same call does, not a
//! private ABI.
//!
//! NOT REDIRECTED (MEASURED: bare == header, full struct written): `statfs`,
//! `statvfs`, `uname`, `opendir/readdir`.  And `time`: musl's bare `time`
//! MEASURED identical to `__time64` on this ABI (both returned the same
//! 64-bit value), because i386 musl's time_t is 64-bit — but the binding names
//! `__time64` anyway so correctness rests on the entry point the headers
//! select, not on a compat alias.

const builtin = @import("builtin");

/// 32-bit pointers — the i386 class.  The only reason this module splits.
pub const is_ilp32 = @sizeOf(usize) == 4;

/// The ONE 32-bit musl layout this module knows: i386.  Deliberately not "any
/// 32-bit musl" — arm-linux-musleabi has its own struct stat (152 bytes) and a
/// flat `st_mtime`, so it takes the explicit refusal below rather than an i386
/// layout guard naming the wrong problem.
pub const musl_ilp32 = builtin.target.abi.isMusl() and is_ilp32 and builtin.target.cpu.arch == .x86;

/// The 64-bit architectures whose `struct stat` this module has MEASURED.  The
/// selection is by ARCH, not by "is 64-bit": the two LP64 shapes differ (aarch64
/// st_mode @16/sizeof 128 vs x86_64 @24/sizeof 144), so a single 64-bit branch
/// would certify one of them on the other.
pub const is_x86_64 = builtin.target.cpu.arch == .x86_64;
pub const is_aarch64 = builtin.target.cpu.arch == .aarch64 and !is_ilp32;

/// A 32-bit musl target that is NOT i386: no layout of its own is measured
/// here.
pub const unsupported_musl_ilp32 = builtin.target.abi.isMusl() and is_ilp32 and builtin.target.cpu.arch != .x86;

/// A 64-bit target that is neither x86_64 nor aarch64 (riscv64, loongarch64,
/// ppc64, …): NO layout is measured here, and the x86_64 shape is NOT a
/// stand-in (aarch64 — the closest neighbour, also LP64 — already differs).
/// Refused at compile time so a build for such a target fails LOUDLY instead of
/// reading st_mode/st_size at offsets that happen to compile.
pub const unsupported_lp64 = @sizeOf(usize) == 8 and !is_x86_64 and !is_aarch64;

pub const unsupported_msg = "fxstat: unsupported 32-bit musl target '" ++ @tagName(builtin.target.cpu.arch) ++
    "' — measure its struct stat/statfs/statvfs from the target's own headers (zig cc -target <t> offset probe) and add a layout branch here";

pub const unsupported_lp64_msg = "fxstat: unsupported 64-bit target '" ++ @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.abi) ++
    "' — struct stat is NOT the x86_64 shape on every LP64 target (aarch64 is 128 bytes with st_mode @16), so measure this target's own struct stat/statfs/statvfs (zig cc -target <t> offset probe) and add a layout branch here";

comptime {
    if (unsupported_musl_ilp32)
        @compileError(unsupported_msg);
    if (unsupported_lp64)
        @compileError(unsupported_lp64_msg);
}

/// Linux CLOCK_MONOTONIC (1 on every Linux ABI).  Named here so callers do not
/// reach for std.c.CLOCK and bind the wrong clock_gettime symbol.
pub const CLOCK_MONOTONIC: c_int = 1;

// ─── struct timespec ───────────────────────────────────────────────────────
// MEASURED: sizeof 16, tv_nsec @8 on i386 musl, x86_64 musl and x86_64 glibc.
// i386 musl's header timespec is `{ time_t tv_sec; int :...; long tv_nsec; }`
// with a 64-bit time_t, i.e. tv_sec @0 (8 bytes) / tv_nsec @8 (8 bytes) — the
// same bytes as the kernel's i64 pair, which is why one i64 pair reads both.
// The full 8-byte nsec matters: a 4-byte nsec plus uninitialised padding would
// present to the kernel as a huge nsec and EINVAL the call.
pub const Timespec = extern struct { sec: i64 = 0, nsec: i64 = 0 };

/// i386 musl's `__st_atim32`/`__st_mtim32`/`__st_ctim32`: a plain
/// `{ long tv_sec; long tv_nsec; }` — 8 bytes, NOT the 16-byte Timespec above.
const TimespecLong = extern struct { tv_sec: c_long, tv_nsec: c_long };

// ─── struct stat ───────────────────────────────────────────────────────────

/// i386 musl `struct stat` (musl's x86-linux-musl/bits/stat.h).  Offsets
/// MEASURED; only st_mode/st_uid/st_gid/st_size/st_mtim are read here.
pub const StatI386Musl = extern struct {
    st_dev: u64, // @0
    __st_dev_padding: c_int, // @8
    __st_ino_truncated: c_long, // @12
    st_mode: c_uint, // @16
    st_nlink: c_uint, // @20
    st_uid: c_uint, // @24
    st_gid: c_uint, // @28
    st_rdev: u64, // @32
    __st_rdev_padding: c_int, // @40
    st_size: i64, // @44
    st_blksize: c_long, // @52
    st_blocks: i64, // @56
    __st_atim32: TimespecLong, // @64
    __st_mtim32: TimespecLong, // @72
    __st_ctim32: TimespecLong, // @80
    st_ino: u64, // @88
    st_atim: Timespec, // @96
    st_mtim: Timespec, // @112
    st_ctim: Timespec, // @128
};

/// x86_64 `struct stat` — glibc's LP64 shape and (byte-identical, only the
/// field NAMES of the timestamp members differ) the kernel <asm/stat.h> shape
/// musl's x86_64 sys/stat.h resolves to.  Offsets MEASURED on both.
/// x86_64 ONLY — aarch64's LP64 struct stat is a DIFFERENT shape (StatAarch64).
pub const StatX8664 = extern struct {
    st_dev: u64,
    st_ino: u64,
    st_nlink: u64,
    st_mode: u32,
    st_uid: u32,
    st_gid: u32,
    __pad0: c_int,
    st_rdev: u64,
    st_size: i64,
    st_blksize: i64,
    st_blocks: i64,
    st_atim: Timespec,
    st_mtim: Timespec,
    st_ctim: Timespec,
    __unused: [3]i64,
};

/// aarch64 (glibc 2.39 AND musl) `struct stat`.  Offsets MEASURED (see the
/// module header): sizeof 128, not x86_64's 144.  Note the 32-bit
/// st_mode/st_nlink/st_uid/st_gid (nlink is 32-bit HERE and 64-bit on x86_64),
/// and st_size @48 (glibc's `__pad1` @40 + the align gap).  Only
/// st_mode/st_uid/st_gid/st_size/st_mtim are read by this repo's callers.
pub const StatAarch64 = extern struct {
    st_dev: u64, // @0
    st_ino: u64, // @8
    st_mode: u32, // @16
    st_nlink: u32, // @20
    st_uid: u32, // @24
    st_gid: u32, // @28
    st_rdev: u64, // @32
    __pad1: u32, // @40
    st_size: i64, // @48
    st_blksize: i64, // @56
    st_blocks: i64, // @64
    st_atim: Timespec, // @72
    st_mtim: Timespec, // @88
    st_ctim: Timespec, // @104
    __glibc_reserved: [2]u32, // @120 -> sizeof 128
};

pub const Stat = if (musl_ilp32) StatI386Musl else if (is_aarch64) StatAarch64 else StatX8664;

// ─── struct statfs (f_type is the filesystem magic; the fs_magic seat) ─────

/// i386 musl `struct statfs`.  NOTE the widths: f_type/f_bsize/f_namelen/
/// f_frsize/f_flags are 32-bit `unsigned long` here, but fsblkcnt_t/
/// fsfilcnt_t are 64-bit.  MEASURED sizeof 84.
pub const StatfsI386Musl = extern struct {
    f_type: c_ulong, // @0  — 32-bit on i386; reading it as i64 gives
    //                          f_type | (f_bsize << 32)
    f_bsize: c_ulong, // @4
    f_blocks: u64, // @8
    f_bfree: u64, // @16
    f_bavail: u64, // @24
    f_files: u64, // @32
    f_ffree: u64, // @40
    f_fsid: [2]i32, // @48
    f_namelen: c_ulong, // @56
    f_frsize: c_ulong, // @60
    f_flags: c_ulong, // @64
    f_spare: [4]c_ulong, // @68 -> sizeof 84
};

/// 64-bit `struct statfs` — x86_64 (glibc and musl) AND aarch64 (glibc 2.39 and
/// musl) report the SAME offsets and size, MEASURED on all four, so one LP64
/// shape serves both architectures (unlike struct stat, which splits).
/// MEASURED sizeof 120.
pub const StatfsLp64 = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

pub const Statfs = if (musl_ilp32) StatfsI386Musl else StatfsLp64;

// ─── struct statvfs ────────────────────────────────────────────────────────

/// i386 musl `struct statvfs`.  fsid_t is 8 bytes ([2]i32) — hence f_flag @64.
/// MEASURED sizeof 96.
pub const StatVfsI386Musl = extern struct {
    f_bsize: c_ulong, // @0
    f_frsize: c_ulong, // @4
    f_blocks: u64, // @8
    f_bfree: u64, // @16
    f_bavail: u64, // @24
    f_files: u64, // @32
    f_ffree: u64, // @40
    f_favail: u64, // @48
    f_fsid: [2]i32, // @56
    f_flag: c_ulong, // @64
    f_namemax: c_ulong, // @68
    __f_spare: [6]c_int, // @72 -> sizeof 96
};

/// 64-bit `struct statvfs` — x86_64 AND aarch64 agree field for field
/// (MEASURED on all four ABIs), so one LP64 shape serves both.  MEASURED
/// sizeof 112.
pub const StatVfsLp64 = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
    __f_spare: [6]c_uint,
};

pub const StatVfs = if (musl_ilp32) StatVfsI386Musl else StatVfsLp64;

// ─── the symbols, time64-resolved on i386 musl ─────────────────────────────

const sym = struct {
    extern fn stat(path: [*:0]const u8, buf: *Stat) c_int;
    extern fn statfs(path: [*:0]const u8, buf: *Statfs) c_int;
    extern fn statvfs(path: [*:0]const u8, buf: *StatVfs) c_int;
    extern fn clock_gettime(clk: c_int, tp: *Timespec) c_int;
    extern fn nanosleep(rqtp: *const Timespec, rmtp: ?*Timespec) c_int;
    extern fn time(t: ?*i64) i64;
};

/// The same six as the i386 headers rename them.  Declared on every target (an
/// unreferenced extern fn costs nothing, and it is never LINKED on 64-bit) so
/// the selection below is one expression.
const sym_time64 = struct {
    extern fn __stat_time64(path: [*:0]const u8, buf: *Stat) c_int;
    extern fn __clock_gettime64(clk: c_int, tp: *Timespec) c_int;
    extern fn __nanosleep_time64(rqtp: *const Timespec, rmtp: ?*Timespec) c_int;
    extern fn __time64(t: ?*i64) i64;
};

pub const stat = if (musl_ilp32) &sym_time64.__stat_time64 else &sym.stat;
pub const clock_gettime = if (musl_ilp32) &sym_time64.__clock_gettime64 else &sym.clock_gettime;
pub const nanosleep = if (musl_ilp32) &sym_time64.__nanosleep_time64 else &sym.nanosleep;
pub const time = if (musl_ilp32) &sym_time64.__time64 else &sym.time;
// NOT redirected on i386 musl (MEASURED: bare == header binding).
pub const statfs = &sym.statfs;
pub const statvfs = &sym.statvfs;

/// st_mtime as signed seconds (`st_mtim.tv_sec` on every target this module
/// supports — the flat `st_mtime` shape is arm-musl's, which is refused).
pub fn mtimeSec(st: *const Stat) i64 {
    return st.st_mtim.sec;
}

// ─── LAYOUT GUARD ──────────────────────────────────────────────────────────
// Every shape is pinned by sizeof AND by every field offset the callers read.
// Any drift — a header change, a stdlib change, a target whose ABI differs —
// is a COMPILE error, never a wrong size/mode/date.
comptime {
    if (musl_ilp32) {
        if (@sizeOf(Stat) != 144)
            @compileError("fxstat: i386-musl struct stat sizeof drift (expected 144)");
        const stat_expect = .{
            .{ "st_dev", 0 },     .{ "st_ino", 88 },    .{ "st_nlink", 20 },
            .{ "st_mode", 16 },   .{ "st_uid", 24 },    .{ "st_gid", 28 },
            .{ "st_rdev", 32 },   .{ "st_size", 44 },   .{ "st_blksize", 52 },
            .{ "st_blocks", 56 }, .{ "st_atim", 96 },   .{ "st_mtim", 112 },
            .{ "st_ctim", 128 },
        };
        for (stat_expect) |e| {
            if (@offsetOf(Stat, e[0]) != e[1])
                @compileError("fxstat: i386-musl struct stat layout drift: " ++ e[0] ++ " offset mismatch");
        }
        if (@sizeOf(Statfs) != 84)
            @compileError("fxstat: i386-musl struct statfs sizeof drift (expected 84)");
        const statfs_expect = .{
            .{ "f_type", 0 },  .{ "f_bsize", 4 },   .{ "f_blocks", 8 },
            .{ "f_bfree", 16 }, .{ "f_bavail", 24 }, .{ "f_files", 32 },
            .{ "f_ffree", 40 }, .{ "f_fsid", 48 },   .{ "f_namelen", 56 },
            .{ "f_frsize", 60 }, .{ "f_flags", 64 },
        };
        for (statfs_expect) |e| {
            if (@offsetOf(Statfs, e[0]) != e[1])
                @compileError("fxstat: i386-musl struct statfs layout drift: " ++ e[0] ++ " offset mismatch");
        }
        if (@sizeOf(StatVfs) != 96)
            @compileError("fxstat: i386-musl struct statvfs sizeof drift (expected 96)");
        const statvfs_expect = .{
            .{ "f_bsize", 0 },  .{ "f_frsize", 4 },  .{ "f_blocks", 8 },
            .{ "f_bfree", 16 }, .{ "f_bavail", 24 }, .{ "f_files", 32 },
            .{ "f_ffree", 40 }, .{ "f_favail", 48 }, .{ "f_fsid", 56 },
            .{ "f_flag", 64 },  .{ "f_namemax", 68 },
        };
        for (statvfs_expect) |e| {
            if (@offsetOf(StatVfs, e[0]) != e[1])
                @compileError("fxstat: i386-musl struct statvfs layout drift: " ++ e[0] ++ " offset mismatch");
        }
        // The 32-bit stamp subset must stay 8 bytes: sizing it as the 16-byte
        // Timespec shifts every field after it by 24 and passes sizeof alone.
        if (@sizeOf(TimespecLong) != 8)
            @compileError("fxstat: i386-musl __st_*tim32 drift (expected 8)");
        // The whole reason the time64 symbols are bound: the target's time_t
        // must be the 64-bit width our `extern fn time(*i64) i64` assumes.
        if (@sizeOf(c_long) != 4)
            @compileError("fxstat: i386-musl c_long drift (expected 4)");
    } else if (is_aarch64) {
        // aarch64 (glibc 2.39 and musl, MEASURED — see the module header).
        // Its own branch because the x86_64 assertions below are FALSE here:
        // 128 vs 144, st_mode @16 vs @24, st_nlink 32-bit.
        if (@sizeOf(Stat) != 128)
            @compileError("fxstat: aarch64 struct stat sizeof drift (expected 128)");
        const stat_expect = .{
            .{ "st_dev", 0 },     .{ "st_ino", 8 },     .{ "st_nlink", 20 },
            .{ "st_mode", 16 },   .{ "st_uid", 24 },    .{ "st_gid", 28 },
            .{ "st_rdev", 32 },   .{ "st_size", 48 },   .{ "st_blksize", 56 },
            .{ "st_blocks", 64 }, .{ "st_atim", 72 },   .{ "st_mtim", 88 },
            .{ "st_ctim", 104 },
        };
        for (stat_expect) |e| {
            if (@offsetOf(Stat, e[0]) != e[1])
                @compileError("fxstat: aarch64 struct stat layout drift: " ++ e[0] ++ " offset mismatch");
        }
        // statfs/statvfs are the LP64 shape here too (MEASURED identical to
        // x86_64's on both aarch64 ABIs) — pinned again in THIS branch so a
        // future aarch64-only divergence cannot ride on the x86_64 pins.
        if (@sizeOf(Statfs) != 120)
            @compileError("fxstat: aarch64 struct statfs sizeof drift (expected 120)");
        const statfs_expect = .{
            .{ "f_type", 0 },  .{ "f_bsize", 8 },   .{ "f_blocks", 16 },
            .{ "f_bfree", 24 }, .{ "f_bavail", 32 }, .{ "f_files", 40 },
            .{ "f_ffree", 48 }, .{ "f_fsid", 56 },   .{ "f_namelen", 64 },
            .{ "f_frsize", 72 }, .{ "f_flags", 80 },
        };
        for (statfs_expect) |e| {
            if (@offsetOf(Statfs, e[0]) != e[1])
                @compileError("fxstat: aarch64 struct statfs layout drift: " ++ e[0] ++ " offset mismatch");
        }
        if (@sizeOf(StatVfs) != 112)
            @compileError("fxstat: aarch64 struct statvfs sizeof drift (expected 112)");
        const statvfs_expect = .{
            .{ "f_bsize", 0 },  .{ "f_frsize", 8 },  .{ "f_blocks", 16 },
            .{ "f_bfree", 24 }, .{ "f_bavail", 32 }, .{ "f_files", 40 },
            .{ "f_ffree", 48 }, .{ "f_favail", 56 }, .{ "f_fsid", 64 },
            .{ "f_flag", 72 },  .{ "f_namemax", 80 },
        };
        for (statvfs_expect) |e| {
            if (@offsetOf(StatVfs, e[0]) != e[1])
                @compileError("fxstat: aarch64 struct statvfs layout drift: " ++ e[0] ++ " offset mismatch");
        }
        // LP64: c_long is 64-bit, so the `extern fn time(?*i64) i64` binding
        // and the Timespec pair above match the header's time_t/off_t widths
        // (on ILP32 i386 musl the same widths come from the time64 symbols).
        if (@sizeOf(c_long) != 8)
            @compileError("fxstat: aarch64 c_long drift (expected 8)");
    } else {
        if (@sizeOf(usize) != 8)
            @compileError("fxstat: 64-bit branch on a non-64-bit target");
        if (@sizeOf(Stat) != 144)
            @compileError("fxstat: x86_64 struct stat sizeof drift (expected 144)");
        const stat_expect = .{
            .{ "st_dev", 0 },     .{ "st_ino", 8 },     .{ "st_nlink", 16 },
            .{ "st_mode", 24 },   .{ "st_uid", 28 },    .{ "st_gid", 32 },
            .{ "st_rdev", 40 },   .{ "st_size", 48 },   .{ "st_blksize", 56 },
            .{ "st_blocks", 64 }, .{ "st_atim", 72 },   .{ "st_mtim", 88 },
            .{ "st_ctim", 104 },
        };
        for (stat_expect) |e| {
            if (@offsetOf(Stat, e[0]) != e[1])
                @compileError("fxstat: x86_64 struct stat layout drift: " ++ e[0] ++ " offset mismatch");
        }
        if (@sizeOf(Statfs) != 120)
            @compileError("fxstat: x86_64 struct statfs sizeof drift (expected 120)");
        const statfs_expect = .{
            .{ "f_type", 0 },  .{ "f_bsize", 8 },   .{ "f_blocks", 16 },
            .{ "f_bfree", 24 }, .{ "f_bavail", 32 }, .{ "f_files", 40 },
            .{ "f_ffree", 48 }, .{ "f_fsid", 56 },   .{ "f_namelen", 64 },
            .{ "f_frsize", 72 }, .{ "f_flags", 80 },
        };
        for (statfs_expect) |e| {
            if (@offsetOf(Statfs, e[0]) != e[1])
                @compileError("fxstat: x86_64 struct statfs layout drift: " ++ e[0] ++ " offset mismatch");
        }
        if (@sizeOf(StatVfs) != 112)
            @compileError("fxstat: x86_64 struct statvfs sizeof drift (expected 112)");
        const statvfs_expect = .{
            .{ "f_bsize", 0 },  .{ "f_frsize", 8 },  .{ "f_blocks", 16 },
            .{ "f_bfree", 24 }, .{ "f_bavail", 32 }, .{ "f_files", 40 },
            .{ "f_ffree", 48 }, .{ "f_favail", 56 }, .{ "f_fsid", 64 },
            .{ "f_flag", 72 },  .{ "f_namemax", 80 },
        };
        for (statvfs_expect) |e| {
            if (@offsetOf(StatVfs, e[0]) != e[1])
                @compileError("fxstat: x86_64 struct statvfs layout drift: " ++ e[0] ++ " offset mismatch");
        }
    }
    if (@sizeOf(Timespec) != 16)
        @compileError("fxstat: struct timespec sizeof drift (expected 16)");
    if (@offsetOf(Timespec, "nsec") != 8)
        @compileError("fxstat: struct timespec tv_nsec offset drift (expected 8)");
}
