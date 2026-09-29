#!/bin/sh
# tests/mkinitramfs.sh — the M4 initramfs builder (image increment).
#
# Assembles a bootable initramfs (gzip'd newc cpio) from:
#   - a fxstore STORE containing the activated generation (fx-activate ran:
#     the .db metadata + the <hash>-system-generation dir are committed)
#   - the host runtime the guest needs at boot: the store's fx-init runs as
#     rdinit PID1 and needs /lib64 (glibc + libdatalog.so) and busybox for
#     debug tooling
#   - device nodes /dev/console /dev/null /dev/tty /dev/ttyS0, emitted as
#     hand-crafted cpio records in a prepended segment: mknod(2) of device
#     nodes needs CAP_MKNOD in the INITIAL user namespace, which an
#     unprivileged builder never has — but a cpio record carries
#     rdevmajor/rdevminor directly, and the kernel's initramfs unpacker
#     processes concatenated archives (the early-cpio pattern dracut/
#     mkinitcpio use for exactly this reason).
#
# Guest layout: /fx/store/* (the whole store minus the .build/.tmp scratch
# dirs), /lib64/<ld + ldd closure of the shipped binaries> + libdatalog.so,
# /usr/bin/busybox + /bin/sh -> busybox (+ /bin/mount, /usr/bin/mount: debug
# tooling only), empty /proc /sys /dev /run/fx mountpoints (mount_early in
# zig/src/init.zig mounts the real ones as its first act), /tmp mode 1777,
# /bin/init -> the store's fx-init (consistent with the bwrap harness
# assertion; dhake re-creates it at boot), /init ABSENT — the kernel cmdline's
# rdinit= names fx-init directly, no shim.  ROOTDIR's contents (the pre-boot
# materialization root) are copied over the skeleton last, so a caller can
# pre-seed /etc etc.; the boots in tests/qemu_boot.sh pass an empty one and
# let dhake materialize at boot.
#
# The zig-built binaries carry a RUNPATH pointing at the HOST datalog lib dir
# (useless in-guest); after the RUNPATH miss the loader falls back to the
# default search path, so libdatalog.so also lives in /lib64 (verified live
# by the QEMU smoke in tests/qemu_boot.sh).
#
# usage: mkinitramfs.sh -s STORE -r ROOTDIR -k KERNEL -o OUT.cpio.gz [-l LISTFILE]
#   -k KERNEL is verified present and recorded but NOT packed (the runner,
#   tests/qemu_boot.sh, owns the kernel + its pin).  Skips loudly (77) when
#   cpio/gzip/ldd or an input is missing.  -l additionally writes the archive
#   file list (dev segment + main segment, sorted) to LISTFILE — cpio -it
#   stops at the first trailer, so the concatenation is otherwise hard to
#   inspect (determinism checks pin this list; mtimes vary by design).
set -u

fail() { echo "mkinitramfs: FAIL: $*" >&2; exit 1; }
skip() { echo "mkinitramfs: SKIP ($*)"; exit 77; }

STORE=""
ROOTDIR=""
KERNEL=""
OUT=""
LIST=""
while [ $# -gt 0 ]; do
    case "$1" in
        -s) [ $# -ge 2 ] || fail "-s needs a value"; STORE=$2; shift 2 ;;
        -r) [ $# -ge 2 ] || fail "-r needs a value"; ROOTDIR=$2; shift 2 ;;
        -k) [ $# -ge 2 ] || fail "-k needs a value"; KERNEL=$2; shift 2 ;;
        -o) [ $# -ge 2 ] || fail "-o needs a value"; OUT=$2; shift 2 ;;
        -l) [ $# -ge 2 ] || fail "-l needs a value"; LIST=$2; shift 2 ;;
        *) fail "unknown arg '$1' (usage: mkinitramfs.sh -s STORE -r ROOTDIR -k KERNEL -o OUT.cpio.gz [-l LISTFILE])" ;;
    esac
done
[ -n "$STORE" ]   || fail "-s STORE required"
[ -n "$ROOTDIR" ] || fail "-r ROOTDIR required"
[ -n "$KERNEL" ]  || fail "-k KERNEL required"
[ -n "$OUT" ]     || fail "-o OUT.cpio.gz required"
[ -d "$STORE" ]   || skip "store not a directory: $STORE"
case "$STORE" in /*) ;; *) STORE=$(cd "$STORE" && pwd) ;; esac
case "$KERNEL" in /*) ;; *) KERNEL=$(cd "$(dirname "$KERNEL")" && pwd)/$(basename "$KERNEL") ;; esac
[ -d "$ROOTDIR" ] || skip "rootdir not a directory: $ROOTDIR"
case "$ROOTDIR" in /*) ;; *) ROOTDIR=$(cd "$ROOTDIR" && pwd) ;; esac
[ -r "$KERNEL" ]  || skip "kernel not readable: $KERNEL"

for t in cpio gzip ldd readlink find head dd basename dirname chmod; do
    command -v "$t" >/dev/null 2>&1 || skip "$t not found"
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# libdatalog.so home: the sibling datalog-dafsa checkout by default (the
# zig-out/lib the fxstore RUNPATHs point at), overridable.
FX_DATALOG_LIB="${FX_DATALOG_LIB:-$REPO/../datalog-dafsa/zig-out/lib}"
[ -f "$FX_DATALOG_LIB/libdatalog.so" ] || skip "libdatalog.so not found at $FX_DATALOG_LIB (set FX_DATALOG_LIB)"

command -v busybox >/dev/null 2>&1 || skip "busybox not found (guest debug shell)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mkinitrd.XXXXXX")" || fail mktemp
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"

# ─── skeleton: mountpoints + tmp + busybox ────────────────────────────────
mkdir -p "$STAGE/fx/store" "$STAGE/lib64" "$STAGE/usr/bin" "$STAGE/bin" \
         "$STAGE/proc" "$STAGE/sys" "$STAGE/dev" "$STAGE/run/fx" "$STAGE/tmp" \
    || fail "cannot create image skeleton"
chmod 1777 "$STAGE/tmp"
cp "$(command -v busybox)" "$STAGE/usr/bin/busybox" || fail "cannot copy busybox"
chmod 755 "$STAGE/usr/bin/busybox"
ln -s /usr/bin/busybox "$STAGE/bin/sh"
ln -s /usr/bin/busybox "$STAGE/bin/mount"
ln -s /usr/bin/busybox "$STAGE/usr/bin/mount"

# ─── the store (minus build scratch) ──────────────────────────────────────
cp -a "$STORE"/. "$STAGE/fx/store/" || fail "cannot copy store"
rm -rf "$STAGE/fx/store/.build" "$STAGE/fx/store/.tmp" 2>/dev/null

# the store's fx-init dir (guest-absolute target for /bin/init)
FXINIT_DIR=$( (cd "$STAGE/fx/store" && ls -d ./*-fx-init 2>/dev/null) | head -1 )
[ -n "$FXINIT_DIR" ] || fail "no *-fx-init dir in the store (activate a generation first)"
ln -s "/fx/store/${FXINIT_DIR#./}/fx-init" "$STAGE/bin/init"

# ─── /lib64: the ldd closure of every ELF we ship + libdatalog.so ─────────
# ldd only on files whose first 4 bytes are \177ELF (ldd on a non-ELF can
# EXECUTE it — the APE sh-preamble binaries); APE/static payloads print "not
# a dynamic executable" and contribute nothing.
is_elf() { [ "$(head -c 4 "$1" 2>/dev/null)" = "$(printf '\177ELF')" ]; }
LIBS=$( { is_elf "$STAGE/usr/bin/busybox" && ldd "$STAGE/usr/bin/busybox"
          find "$STAGE/fx/store" -type f -perm /111 | while IFS= read -r b; do
              is_elf "$b" && ldd "$b" 2>/dev/null
          done
        } | grep -o '/[^ 	]*\.so[^ 	]*' | sort -u )
[ -n "$LIBS" ] || fail "ldd closure came back empty (busybox should need at least libc)"
for l in $LIBS; do
    [ -e "$l" ] || continue
    # NON-symlink-collapsed: cp -a keeps e.g. libc.so.6 a symlink, and the
    # readlink -f target is copied alongside so the link resolves in-guest.
    cp -a "$l" "$STAGE/lib64/" || fail "cannot copy lib $l"
    r=$(readlink -f "$l" 2>/dev/null) || continue
    if [ -n "$r" ] && [ "$(basename "$r")" != "$(basename "$l")" ]; then
        cp -a "$r" "$STAGE/lib64/" || fail "cannot copy lib target $r"
    fi
done
cp "$FX_DATALOG_LIB/libdatalog.so" "$STAGE/lib64/libdatalog.so" || fail "cannot copy libdatalog.so"

# ─── ROOTDIR overlay (pre-boot rootfs state; empty for the qemu boots) ────
cp -a "$ROOTDIR"/. "$STAGE/" || fail "cannot overlay ROOTDIR $ROOTDIR"

# ─── the early device-node cpio segment ───────────────────────────────────
# 070701 (newc) record: 110-byte header = magic + 13 x 8-hex fields (ino
# mode uid gid nlink mtime size devmaj devmin rmaj rmin namesize check), then
# name + NUL, then a 4-byte-alignment pad.  Times are zeroed (deterministic).
# Modes (decimal): dir|0755 = 16877; S_IFCHR = 0o20000 = 8192, so
# chr|0600 = 8576, chr|0666 = 8630.  The kernel opens /dev/console for
# PID1's fds 0-2 BEFORE exec'ing rdinit, so these must be REAL char devices
# (a mode without S_IFMT yields "unable to open an initial console" and
# closed fds — fx-init's mount_early devtmpfs-reopen then has to save it).
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
    cpio_rec dev/ttyS0   8576  4 64   # console=ttyS0
    cpio_rec TRAILER!!!      0  0  0
} > "$WORK/dev.cpio"

# ─── assemble: early devices ++ the staged tree, gzip'd ───────────────────
( cd "$STAGE" && find . | LC_ALL=C sort | cpio -o -H newc ) > "$WORK/main.cpio" \
    || fail "cpio archive failed"
cat "$WORK/dev.cpio" "$WORK/main.cpio" | gzip -9n > "$OUT" || fail "gzip failed"
[ -s "$OUT" ] || fail "archive is empty"

# the archive file list (dev + main segments; cpio -it stops at the first
# trailer so the segments are listed separately, then concatenated + sorted)
if [ -n "$LIST" ]; then
    { cpio -it < "$WORK/dev.cpio" 2>/dev/null
      cpio -it < "$WORK/main.cpio" 2>/dev/null
    } | LC_ALL=C sort > "$LIST" || fail "cannot write list $LIST"
fi

# dev-segment byte count: `cpio -it` stops at the FIRST trailer, so listing
# the main segment means skipping this many bytes first (see header).
echo "mkinitramfs: built $OUT ($(wc -c < "$OUT") bytes, devseg $(wc -c < "$WORK/dev.cpio")) from store $STORE kernel $KERNEL"
