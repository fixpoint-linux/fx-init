#!/bin/sh
# scripts/fetch-kernel-aarch64.sh — fetch + verify the PINNED aarch64 kernel
# artifact (scripts/kernel-pin-aarch64.txt; the sibling of the x86
# scripts/fetch-kernel.sh — separate pin, separate cache dir, so the two
# paths never share a hot file with lane 2's pin).
#
# Same policy as the x86 fetch: download the pinned tarball, verify the
# DOWNLOADED FILE's sha256 against the pin (the pin is the trust anchor),
# unpack, and verify the EXTRACTED Image.gz sha256 as the belt.  exit 0 on
# a verified cache, 77 offline (callers skip loudly — no fallback), 1 on
# any other failure.
#
# Cache layout (CACHE = $FX_KERNEL_CACHE, default $REPO/.kernel-cache — the
# SAME dir the x86 fetch uses; the aarch64 entries are DISJOINT names so
# lanes/callers sharing a cache dir do not collide):
#   CACHE/<tarball name>              the verified tarball (13 MB)
#   CACHE/kernel-aarch64/Image.gz     the kernel the aarch64 harness boots
#   CACHE/kernel-aarch64/config       the kernel's own config
# (There is NO modules/ subdir: the arm64 artifact ships none — every
# boot-path symbol is =y in the defconfig build.)
#
# Env: FX_KERNEL_CACHE  cache dir override (default $repo/.kernel-cache)
set -u

fail() { echo "fetch-kernel-aarch64: FAIL: $*" >&2; exit 1; }
offline() { echo "fetch-kernel-aarch64: SKIP ($*)"; exit 77; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$REPO/scripts/kernel-pin-aarch64.txt"
[ -f "$PIN" ] || fail "scripts/kernel-pin-aarch64.txt missing"
[ -r "$PIN" ] || fail "scripts/kernel-pin-aarch64.txt not readable"

command -v sha256sum >/dev/null 2>&1 || fail "sha256sum not found"
command -v tar >/dev/null 2>&1      || fail "tar not found (tarball unpack)"
command -v gzip >/dev/null 2>&1     || fail "gzip not found (tarball unpack)"

# ─── the pin (single source of truth) ──────────────────────────────────────
pin() { sed -n "s/^$1 //p" "$PIN" | head -1; }
pin_path_ok() {
    case $1 in
        ""|/*|../*|*/../*|*/..|..) return 1 ;;
        *) return 0 ;;
    esac
}
URL=$(pin url)
TAR_SHA=$(pin tar_sha256)
TAR_SIZE=$(pin tar_size)
KVER=$(pin kernel_version)
VMLINUX_PATH=$(pin vmlinuz_path)
[ -n "$VMLINUX_PATH" ] || VMLINUX_PATH=fixpoint-kernel-6.12.19-arm64/Image.gz
VMLINUZ_SHA=$(pin vmlinuz_sha256)
CONFIG_PATH=$(pin config_path)
[ -n "$CONFIG_PATH" ] || CONFIG_PATH=fixpoint-kernel-6.12.19-arm64/config
[ -n "$URL" ] && [ -n "$TAR_SHA" ] && [ -n "$KVER" ] && [ -n "$VMLINUZ_SHA" ] \
    || fail "scripts/kernel-pin-aarch64.txt malformed (needs url, tar_sha256, kernel_version, vmlinuz_sha256)"
pin_path_ok "$VMLINUX_PATH" || fail "vmlinuz_path '$VMLINUX_PATH' is not a plain tarball-relative path"
pin_path_ok "$CONFIG_PATH"  || fail "config_path '$CONFIG_PATH' is not a plain tarball-relative path"

CACHE="${FX_KERNEL_CACHE:-$REPO/.kernel-cache}"
KERNEL_DIR="$CACHE/kernel-aarch64"
VMLINUZ="$KERNEL_DIR/Image.gz"
TARBALL="$CACHE/$(basename "$URL")"

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# ─── 1. already extracted + verified?  nothing to do ───────────────────────
extracted_ok() {
    [ "$(sha_of "$VMLINUZ")" = "$VMLINUZ_SHA" ] || return 1
    [ -f "$KERNEL_DIR/config" ] || return 1
    return 0
}
if extracted_ok; then
    echo "fetch-kernel-aarch64: cache hit — $VMLINUZ ($(wc -c < "$VMLINUZ") bytes, kernel $KVER)"
    exit 0
fi

# ─── 2. the tarball: cache hit (hash ok) or (re-)download ──────────────────
NEED_TAR=1
if [ -f "$TARBALL" ]; then
    if [ "$(sha_of "$TARBALL")" = "$TAR_SHA" ]; then
        NEED_TAR=0
    else
        echo "fetch-kernel-aarch64: cached tarball fails its pin — re-fetching"
        rm -f "$TARBALL"
    fi
fi
if [ "$NEED_TAR" = 1 ]; then
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || offline "neither curl nor wget found (cannot fetch the pinned kernel)"
    mkdir -p "$CACHE" || fail "cannot create cache dir $CACHE"
    echo "fetch-kernel-aarch64: downloading $URL"
    echo "              to $TARBALL (~$((${TAR_SIZE:-0} / 1048576)) MB)"
    PART="$CACHE/tarball-aarch64.part"
    rm -f "$PART"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$PART" "$URL" || { rm -f "$PART"; offline "curl could not fetch $URL"; }
    else
        wget -O "$PART" "$URL" || { rm -f "$PART"; offline "wget could not fetch $URL"; }
    fi
    [ -s "$PART" ] || { rm -f "$PART"; offline "download came back empty ($URL)"; }
    [ -n "$TAR_SIZE" ] && [ "$(wc -c < "$PART")" = "$TAR_SIZE" ] \
        || fail "downloaded tarball size $(wc -c < "$PART") != pinned $TAR_SIZE (update scripts/kernel-pin-aarch64.txt)"
    GOT=$(sha_of "$PART")
    [ "$GOT" = "$TAR_SHA" ] \
        || { rm -f "$PART"; fail "downloaded tarball sha256 $GOT != pinned $TAR_SHA (the asset was replaced or moved — update scripts/kernel-pin-aarch64.txt)"; }
    mv -f "$PART" "$TARBALL"
fi

# ─── 3. unpack into the cache layout ───────────────────────────────────────
echo "fetch-kernel-aarch64: unpacking kernel $KVER from the pinned tarball"
rm -rf "$KERNEL_DIR"
mkdir -p "$KERNEL_DIR" || fail "cannot create $KERNEL_DIR"
EXT="$CACHE/extract-aarch64.$$"
rm -rf "$EXT"
mkdir -p "$EXT" || fail "cannot create extraction dir"
if ! tar -xzf "$TARBALL" -C "$EXT"; then
    rm -rf "$EXT"
    fail "tar could not unpack the pinned tarball (corrupt cache? delete $TARBALL and re-run)"
fi

[ -f "$EXT/$VMLINUX_PATH" ] || { rm -rf "$EXT"; fail "Image.gz missing from the tarball at $VMLINUX_PATH (pin out of date?)"; }
[ -f "$EXT/$CONFIG_PATH" ]  || { rm -rf "$EXT"; fail "config missing from the tarball at $CONFIG_PATH (pin out of date?)"; }

mv "$EXT/$VMLINUX_PATH" "$VMLINUZ" || fail "cannot stage Image.gz"
mv "$EXT/$CONFIG_PATH" "$KERNEL_DIR/config" || fail "cannot stage config"
rm -rf "$EXT"

GOT=$(sha_of "$VMLINUZ")
[ "$GOT" = "$VMLINUZ_SHA" ] \
    || fail "EXTRACTED Image.gz sha256 $GOT != pinned $VMLINUZ_SHA (tarball verified but contents differ — update scripts/kernel-pin-aarch64.txt)"
chmod 444 "$VMLINUZ" 2>/dev/null
echo "fetch-kernel-aarch64: OK — $VMLINUZ ($(wc -c < "$VMLINUZ") bytes, kernel $KVER, no modules by construction)"
