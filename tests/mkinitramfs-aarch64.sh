#!/bin/sh
# tests/mkinitramfs-aarch64.sh — the aarch64 sibling of tests/mkinitramfs.sh.
#
# The x86 builder copies the HOST's busybox + `ldd` closure — both are x86
# facts.  This variant takes an explicit aarch64 runtime DIR (-A) holding the
# guest's pre-cross-built pieces, because NOTHING on an x86_64 host can
# produce them natively:
#   busybox            aarch64 busybox-static (debian busybox-static:arm64,
#                      apt-get download + dpkg-deb -x — STATIC, so it needs
#                      no closure)
#   dhake.aarch64.elf  the guest materializer (prebuilt at the dhake repo
#                      root; STATIC — MEASURED: no dynamic section)
#   libc.so.6          aarch64 glibc runtime (debian libc6:arm64) — the
#                      zig-built fx-init/fxctl/fx-activate are DYNAMIC aarch64
#                      (interpreter /lib/ld-linux-aarch64.so.1, NEEDED
#                      libdatalog.so + libc.so.6; MEASURED by readelf -d)
#   ld-linux-aarch64.so.1  the dynamic loader itself
#   libdatalog.so      the aarch64 engine (the -A dir may carry it, else
#                      FX_DATALOG_LIB must point at the aarch64 build)
#
# The HOST ldd CANNOT resolve aarch64 ELFs (it fails and the closure comes
# back SHORT — the plan's measured warning), so the closure is CROSS-LISTED:
# readelf -d NEEDED over every shipped ELF, resolved against the -A dir +
# libdatalog, iterated to fixpoint, then ASSERTED complete (any unresolved
# NEEDED fails the build: a short closure is a boot death, not a warning).
# zig's bundled glibc tree is NOT a source (zig 0.16 ships no runnable
# aarch64 glibc — abilists/headers only; MEASURED).
#
# Differences from the x86 builder, all forced by the architecture:
#   - NO /lib/modules staging (the pinned arm64 kernel is defconfig: every
#     disk-path symbol =y, the artifact ships no modules, and the guest's
#     ensure_disk_store runs fully built-in)
#   - the early device segment emits dev/ttyAMA0 (major 204 minor 64? no —
#     MEASURED in-guest: PL011 ttyAMA0 is major 204 minor 0; the node is
#     belt-only, devtmpfs provides the real one)
#   - /lib64 is still the image's lib dir: the aarch64 loader's baked
#     default search path includes /lib64 (MEASURED: strings of the
#     ld-linux-aarch64.so.1 shows /lib/, /lib/aarch64-linux-gnu/,
#     /lib64/, /usr/lib/, /usr/lib/aarch64-linux-gnu/), and the zig-built
#     binaries' interpreter is /lib/ld-linux-aarch64.so.1, so the loader
#     is staged BOTH at /lib64/ld-linux-aarch64.so.1 (DT_NEEDED resolution
#     via /lib64) and /lib/ld-linux-aarch64.so.1 (the PT_INTERP path).
#
# usage: mkinitramfs-aarch64.sh -s STORE -r ROOTDIR -k KERNEL -A AARCH64_DIR
#                              -o OUT.cpio.gz [-l LISTFILE]
set -u

fail() { echo "mkinitramfs-aarch64: FAIL: $*" >&2; exit 1; }
skip() { echo "mkinitramfs-aarch64: SKIP ($*)"; exit 77; }

STORE=""
ROOTDIR=""
KERNEL=""
ARCHDIR=""
OUT=""
LIST=""
while [ $# -gt 0 ]; do
    case "$1" in
        -s) [ $# -ge 2 ] || fail "-s needs a value"; STORE=$2; shift 2 ;;
        -r) [ $# -ge 2 ] || fail "-r needs a value"; ROOTDIR=$2; shift 2 ;;
        -k) [ $# -ge 2 ] || fail "-k needs a value"; KERNEL=$2; shift 2 ;;
        -A) [ $# -ge 2 ] || fail "-A needs a value"; ARCHDIR=$2; shift 2 ;;
        -o) [ $# -ge 2 ] || fail "-o needs a value"; OUT=$2; shift 2 ;;
        -l) [ $# -ge 2 ] || fail "-l needs a value"; LIST=$2; shift 2 ;;
        *) fail "unknown arg '$1' (usage: mkinitramfs-aarch64.sh -s STORE -r ROOTDIR -k KERNEL -A AARCH64_DIR -o OUT.cpio.gz [-l LISTFILE])" ;;
    esac
done
[ -n "$STORE" ]   || fail "-s STORE required"
[ -n "$ROOTDIR" ] || fail "-r ROOTDIR required"
[ -n "$KERNEL" ]  || fail "-k KERNEL required"
[ -n "$ARCHDIR" ] || fail "-A AARCH64_DIR required (busybox + dhake.aarch64.elf + aarch64 glibc runtime)"
[ -n "$OUT" ]     || fail "-o OUT.cpio.gz required"
[ -d "$STORE" ]   || skip "store not a directory: $STORE"
case "$STORE" in /*) ;; *) STORE=$(cd "$STORE" && pwd) ;; esac
case "$KERNEL" in /*) ;; *) KERNEL=$(cd "$(dirname "$KERNEL")" && pwd)/$(basename "$KERNEL") ;; esac
case "$ARCHDIR" in /*) ;; *) ARCHDIR=$(cd "$ARCHDIR" && pwd) ;; esac
[ -d "$ROOTDIR" ] || skip "rootdir not a directory: $ROOTDIR"
case "$ROOTDIR" in /*) ;; *) ROOTDIR=$(cd "$ROOTDIR" && pwd) ;; esac
[ -r "$KERNEL" ]  || skip "kernel not readable: $KERNEL"

for t in cpio gzip readelf find head dd basename dirname chmod; do
    command -v "$t" >/dev/null 2>&1 || skip "$t not found"
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# the aarch64 libdatalog.so: -A dir first, else FX_DATALOG_LIB
DL_LIB=""
if [ -f "$ARCHDIR/libdatalog.so" ]; then
    DL_LIB="$ARCHDIR/libdatalog.so"
else
    FX_DATALOG_LIB="${FX_DATALOG_LIB:-$REPO/../datalog-dafsa/zig-out/lib}"
    if [ -f "$FX_DATALOG_LIB/libdatalog.so" ]; then
        DL_LIB="$FX_DATALOG_LIB/libdatalog.so"
    fi
fi
[ -n "$DL_LIB" ] || skip "no aarch64 libdatalog.so (put one in $ARCHDIR or set FX_DATALOG_LIB at the aarch64 build)"

# the aarch64 runtime inputs (each verified AArch64 before use — an x86
# binary staged here is the classic silent mistake)
A_BUSYBOX="$ARCHDIR/busybox"
A_DHAKE="$ARCHDIR/dhake.aarch64.elf"
A_LIBC="$ARCHDIR/libc.so.6"
A_LD="$ARCHDIR/ld-linux-aarch64.so.1"
for f in "$A_BUSYBOX" "$A_DHAKE" "$A_LIBC" "$A_LD"; do
    [ -f "$f" ] || skip "aarch64 runtime input missing: $f"
done
is_aarch64_elf() {
    [ "$(head -c 20 "$1" 2>/dev/null | dd bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "b700" ]
}
for f in "$A_BUSYBOX" "$A_DHAKE" "$A_LIBC" "$A_LD" "$DL_LIB"; do
    is_aarch64_elf "$f" || fail "$f is not an AArch64 ELF (e_machine != 183) — stage the aarch64 build, not the host's"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mkinitrd-aarch64.XXXXXX")" || fail mktemp
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"

# ─── skeleton: mountpoints + tmp + aarch64 busybox ─────────────────────────
mkdir -p "$STAGE/fx/store" "$STAGE/lib64" "$STAGE/lib" "$STAGE/usr/bin" \
         "$STAGE/bin" "$STAGE/proc" "$STAGE/sys" "$STAGE/dev" "$STAGE/run/fx" \
         "$STAGE/tmp" \
    || fail "cannot create image skeleton"
chmod 1777 "$STAGE/tmp"
cp "$A_BUSYBOX" "$STAGE/usr/bin/busybox" || fail "cannot copy busybox"
chmod 755 "$STAGE/usr/bin/busybox"
ln -s /usr/bin/busybox "$STAGE/bin/sh"
ln -s /usr/bin/busybox "$STAGE/bin/mount"
ln -s /usr/bin/busybox "$STAGE/usr/bin/mount"
# the M4 disk-path applets — the arm64 kernel has the drivers BUILT IN, so
# no insmod, but mkfs.ext2/cp/rm/mv/sync stay (ensure_disk_store uses them)
for applet in mkfs.ext2 cp rm mv sync; do
    ln -sf /usr/bin/busybox "$STAGE/usr/bin/$applet"
done

# ─── the store (minus build scratch) ────────────────────────────────────────
cp -a "$STORE"/. "$STAGE/fx/store/" || fail "cannot copy store"
rm -rf "$STAGE/fx/store/.build" "$STAGE/fx/store/.tmp" 2>/dev/null

# the store's fx-init dir (guest-absolute target for /bin/init)
FXINIT_DIR=$( (cd "$STAGE/fx/store" && ls -d ./*-fx-init 2>/dev/null) | head -1 )
[ -n "$FXINIT_DIR" ] || fail "no *-fx-init dir in the store (activate a generation first)"
ln -s "/fx/store/${FXINIT_DIR#./}/fx-init" "$STAGE/bin/init"

# ─── the aarch64 runtime: loader + closure (readelf NEEDED fixpoint) ───────
# Stage the runtime in EVERY directory the aarch64 loader's default search
# path may name (MEASURED the hard way: with the libs ONLY in /lib64 the
# guest loader fails "libdatalog.so: cannot open shared object file" — the
# x86_64 /lib64 convention does not hold on arm64, whose glibc multiarch
# dir is /lib/aarch64-linux-gnu; the zig-built binaries' PT_INTERP is
# /lib/ld-linux-aarch64.so.1, so the loader itself is a real file in /lib).
mkdir -p "$STAGE/lib/aarch64-linux-gnu" "$STAGE/lib64" || fail "cannot create lib dirs"
cp "$A_LD" "$STAGE/lib/ld-linux-aarch64.so.1" || fail "cannot stage loader (/lib)"
cp "$A_LD" "$STAGE/lib64/ld-linux-aarch64.so.1" || fail "cannot stage loader (/lib64)"
cp "$A_LIBC" "$STAGE/lib/aarch64-linux-gnu/libc.so.6" || fail "cannot stage libc"
cp "$A_LIBC" "$STAGE/lib64/libc.so.6" || fail "cannot stage libc (lib64)"
cp "$DL_LIB" "$STAGE/lib/aarch64-linux-gnu/libdatalog.so" || fail "cannot stage libdatalog.so"
cp "$DL_LIB" "$STAGE/lib64/libdatalog.so" || fail "cannot stage libdatalog.so (lib64)"

# every additional aarch64 lib in the -A dir lands in BOTH dirs too (none
# expected today; a future fx-activate needing libgcc_s would land here)
for f in "$ARCHDIR"/*.so*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    [ -e "$STAGE/lib/aarch64-linux-gnu/$b" ] || cp "$f" "$STAGE/lib/aarch64-linux-gnu/$b" || fail "cannot stage $b"
    [ -e "$STAGE/lib64/$b" ] || cp "$f" "$STAGE/lib64/$b" || fail "cannot stage $b (lib64)"
done

# NEEDED fixpoint assertion: every dynamic NEEDED of every ELF under the
# image (busybox/dhake are static, fx-init/fxctl/fx-activate + the libs are
# not) must resolve in a dir the loader searches.  Two rounds max (NEEDED of
# NEEDED); a miss FAILS — a short closure is a boot death, not a warning.
needs_of() { readelf -d "$1" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'; }
NEED1=$( { needs_of "$STAGE/usr/bin/busybox"; needs_of "$A_DHAKE"
           find "$STAGE/fx/store" -type f -perm /111 | while IFS= read -r b; do
               [ "$(head -c 4 "$b" 2>/dev/null)" = "$(printf '\177ELF')" ] && needs_of "$b"
           done
           needs_of "$STAGE/lib/aarch64-linux-gnu/libc.so.6"
           needs_of "$STAGE/lib/aarch64-linux-gnu/libdatalog.so"
         } | sort -u)
for n in $NEED1; do
    [ -e "$STAGE/lib/aarch64-linux-gnu/$n" ] || fail "NEEDED lib $n unresolved (stage it in -A $ARCHDIR)"
done

# ─── ROOTDIR overlay (pre-boot rootfs state; empty for the qemu boots) ──────
cp -a "$ROOTDIR"/. "$STAGE/" || fail "cannot overlay ROOTDIR $ROOTDIR"

# ─── the early device-node cpio segment ────────────────────────────────────
# Same hand-crafted newc records as the x86 builder (mknod needs CAP_MKNOD
# in the initial user namespace; cpio rdev fields do not), with the arm64
# console node: ttyAMA0 is major 204 minor 0 (PL011; MEASURED in-guest on
# the first boot — devtmpfs supplies the real node, this is belt-only).
DEV_INO=900
cpio_rec() {
    # $1 name, $2 mode(decimal), $3 rmaj, $4 rmin
    DEV_INO=$((DEV_INO + 1))
    _n=$1; _m=$2; _rj=$3; _rn=$4
    _ns=$((${#_n} + 1))
    printf '070701%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x00000000' \
        "$DEV_INO" "$_m" 0 0 1 0 0 0 0 "$_rj" "$_rn" "$_ns"
    printf '%s\0' "$_n"
    _pad=$(( (4 - ((110 + _ns) & 3)) & 3 ))
    [ "$_pad" -gt 0 ] && dd if=/dev/zero bs=1 count="$_pad" 2>/dev/null
    return 0
}
{
    cpio_rec dev        16877  0  0
    cpio_rec dev/console 8576  5  1   # init's stdio: the kernel opens this
    cpio_rec dev/null    8630  1  3   # fd 0/1/2 before exec'ing rdinit
    cpio_rec dev/tty     8576  5  0
    cpio_rec dev/ttyAMA0 8576 204 0   # console=ttyAMA0 (PL011, belt-only)
    cpio_rec TRAILER!!!      0  0  0
} > "$WORK/dev.cpio"

# ─── assemble: early devices ++ the staged tree, gzip'd ────────────────────
( cd "$STAGE" && find . | LC_ALL=C sort | cpio -o -H newc ) > "$WORK/main.cpio" \
    || fail "cpio archive failed"
cat "$WORK/dev.cpio" "$WORK/main.cpio" | gzip -9n > "$OUT" || fail "gzip failed"
[ -s "$OUT" ] || fail "archive is empty"

if [ -n "$LIST" ]; then
    { cpio -it < "$WORK/dev.cpio" 2>/dev/null
      cpio -it < "$WORK/main.cpio" 2>/dev/null
    } | LC_ALL=C sort > "$LIST" || fail "cannot write list $LIST"
fi

echo "mkinitramfs-aarch64: built $OUT ($(wc -c < "$OUT") bytes, devseg $(wc -c < "$WORK/dev.cpio")) from store $STORE kernel $KERNEL"
