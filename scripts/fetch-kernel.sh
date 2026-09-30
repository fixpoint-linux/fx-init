#!/bin/sh
# scripts/fetch-kernel.sh — fetch + verify the PINNED kernel artifact
# (DESIGN.md §8.5 v1 "fetch-with-hash"; the input scripts/kernel-pin.txt
# names).  The image's kernel is NO LONGER the build host's — this script
# makes it a download any machine can reproduce.
#
# The pinned input is a TRIMMED TARBALL hosted as a release asset of THIS
# repo (vmlinuz + config — see the provenance comment in
# scripts/kernel-pin.txt).  Self-hosting the pin removes the last external
# URL that rots (openSUSE PRUNES old packages, which is what killed the
# previous pin).  The RPM fetch path this script used to carry is gone —
# one pinned input, no second truth; it lives in git history, as does the
# M4 module-shipping layout this M5 zero-module kernel deletes (every
# disk-path driver is built =y, so there is no modules/ tree to fetch,
# stage or insmod).
#
# Downloads the pinned tarball, verifies the sha256 of the DOWNLOADED FILE
# against scripts/kernel-pin.txt (the pin is the trust anchor: a replaced
# or deleted asset fails here, loudly), unpacks vmlinuz + config into the
# cache layout the harnesses consume, and verifies the EXTRACTED vmlinuz
# sha256 against the pin as well (the belt: a tarball that hashes right
# but unpacks wrong is still caught).
#
# Cache layout (CACHE defaults to $REPO/.kernel-cache, FX_KERNEL_CACHE
# overrides; the dir is gitignored):
#   CACHE/<tarball name>         the verified tarball (2 MB; kept so a
#                                 second run never re-downloads)
#   CACHE/kernel/vmlinuz         the kernel the harnesses boot (-kernel)
#   CACHE/kernel/config          the kernel's own config
# (CACHE/rpm and CACHE/kernel/modules from the M4 pins are inert — nothing
#  reads them anymore.)
#
# IDEMPOTENT: a cache hit (kernel dir hashes ok) does NO work and prints
# "cache hit".  A cached tarball that FAILS its pin hash is re-fetched,
# never trusted — corrupt the cached tarball and the next run re-downloads
# it (the kernel dir is then rebuilt from the verified tarball).
#
# Env: FX_KERNEL_CACHE  cache dir override (default $repo/.kernel-cache)
#
# exit 0 on a verified cache; 77 when offline (curl/wget cannot fetch the
# pinned tarball — the callers skip loudly, they do NOT fall back to the
# host kernel); 1 on any other failure (bad pin file, hash mismatch after
# a FRESH download, unpack failure).
set -u

fail() { echo "fetch-kernel: FAIL: $*" >&2; exit 1; }
offline() { echo "fetch-kernel: SKIP ($*)"; exit 77; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$REPO/scripts/kernel-pin.txt"
[ -f "$PIN" ] || fail "scripts/kernel-pin.txt missing"
[ -r "$PIN" ] || fail "scripts/kernel-pin.txt not readable"

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
[ -n "$VMLINUX_PATH" ] || VMLINUZ_PATH=vmlinuz
VMLINUZ_SHA=$(pin vmlinuz_sha256)
CONFIG_PATH=$(pin config_path)
[ -n "$CONFIG_PATH" ] || CONFIG_PATH=config
[ -n "$URL" ]       && [ -n "$TAR_SHA" ]       && [ -n "$KVER" ] \
    && [ -n "$VMLINUZ_SHA" ] \
    || fail "scripts/kernel-pin.txt malformed (needs url, tar_sha256, kernel_version, vmlinuz_sha256)"
pin_path_ok "$VMLINUX_PATH" || fail "vmlinuz_path '$VMLINUX_PATH' is not a plain tarball-relative path"
pin_path_ok "$CONFIG_PATH"  || fail "config_path '$CONFIG_PATH' is not a plain tarball-relative path"
CACHE="${FX_KERNEL_CACHE:-$REPO/.kernel-cache}"
KERNEL_DIR="$CACHE/kernel"
VMLINUZ="$KERNEL_DIR/vmlinuz"
TARBALL="$CACHE/$(basename "$URL")"

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# ─── 1. already extracted + verified?  nothing to do ───────────────────────
extracted_ok() {
    [ "$(sha_of "$VMLINUZ")" = "$VMLINUZ_SHA" ] || return 1
    [ -f "$KERNEL_DIR/config" ] || return 1
    return 0
}
if extracted_ok; then
    echo "fetch-kernel: cache hit — $VMLINUZ ($(wc -c < "$VMLINUZ") bytes, kernel $KVER)"
    exit 0
fi

# ─── 2. the tarball: cache hit (hash ok) or (re-)download ──────────────────
NEED_TAR=1
if [ -f "$TARBALL" ]; then
    if [ "$(sha_of "$TARBALL")" = "$TAR_SHA" ]; then
        NEED_TAR=0
    else
        echo "fetch-kernel: cached tarball fails its pin — re-fetching"
        rm -f "$TARBALL"
    fi
fi
if [ "$NEED_TAR" = 1 ]; then
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || offline "neither curl nor wget found (cannot fetch the pinned kernel)"
    mkdir -p "$CACHE" || fail "cannot create cache dir $CACHE"
    echo "fetch-kernel: downloading $URL"
    echo "              to $TARBALL (~$((${TAR_SIZE:-0} / 1048576)) MB)"
    PART="$CACHE/tarball.part"
    rm -f "$PART"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$PART" "$URL" || { rm -f "$PART"; offline "curl could not fetch $URL"; }
    else
        wget -O "$PART" "$URL" || { rm -f "$PART"; offline "wget could not fetch $URL"; }
    fi
    [ -s "$PART" ] || { rm -f "$PART"; offline "download came back empty ($URL)"; }
    [ -n "$TAR_SIZE" ] && [ "$(wc -c < "$PART")" = "$TAR_SIZE" ] \
        || fail "downloaded tarball size $(wc -c < "$PART") != pinned $TAR_SIZE (update scripts/kernel-pin.txt)"
    GOT=$(sha_of "$PART")
    [ "$GOT" = "$TAR_SHA" ] \
        || { rm -f "$PART"; fail "downloaded tarball sha256 $GOT != pinned $TAR_SHA (the asset was replaced or moved — update scripts/kernel-pin.txt)"; }
    mv -f "$PART" "$TARBALL"
fi

# ─── 3. unpack into the cache layout ───────────────────────────────────────
echo "fetch-kernel: unpacking kernel $KVER from the pinned tarball"
rm -rf "$KERNEL_DIR"
mkdir -p "$KERNEL_DIR" || fail "cannot create $KERNEL_DIR"
EXT="$CACHE/extract.$$"
rm -rf "$EXT"
mkdir -p "$EXT" || fail "cannot create extraction dir"
if ! tar -xzf "$TARBALL" -C "$EXT"; then
    rm -rf "$EXT"
    fail "tar could not unpack the pinned tarball (corrupt cache? delete $TARBALL and re-run)"
fi

[ -f "$EXT/$VMLINUX_PATH" ] || { rm -rf "$EXT"; fail "vmlinuz missing from the tarball at $VMLINUX_PATH (pin out of date?)"; }
[ -f "$EXT/$CONFIG_PATH" ]  || { rm -rf "$EXT"; fail "config missing from the tarball at $CONFIG_PATH (pin out of date?)"; }

mv "$EXT/$VMLINUX_PATH" "$VMLINUZ" || fail "cannot stage vmlinuz"
mv "$EXT/$CONFIG_PATH" "$KERNEL_DIR/config" || fail "cannot stage config"
rm -rf "$EXT"

GOT=$(sha_of "$VMLINUZ")
[ "$GOT" = "$VMLINUZ_SHA" ] \
    || fail "EXTRACTED vmlinuz sha256 $GOT != pinned $VMLINUZ_SHA (tarball verified but contents differ — update scripts/kernel-pin.txt)"
chmod 444 "$VMLINUZ" 2>/dev/null
echo "fetch-kernel: OK — $VMLINUZ ($(wc -c < "$VMLINUZ") bytes, kernel $KVER, zero modules by construction)"
