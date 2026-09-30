#!/bin/sh
# scripts/fetch-kernel.sh — fetch + verify the PINNED kernel artifact
# (DESIGN.md §8.5 v1 "fetch-with-hash"; the input scripts/kernel-pin.txt
# names).  The image's kernel is NO LONGER the build host's — this script
# makes it a download any machine can reproduce.
#
# Downloads the pinned openSUSE kernel-default-base RPM, verifies its
# sha256 against scripts/kernel-pin.txt, extracts ONLY vmlinuz + the four
# disk-path modules (+ the kernel's own config, useful for future config
# assertions) into a cache layout the harnesses consume, and verifies the
# EXTRACTED vmlinuz sha256 against the pin as well.
#
# Cache layout (CACHE defaults to $REPO/.kernel-cache, FX_KERNEL_CACHE
# overrides; the dir is gitignored):
#   CACHE/rpm                     the verified RPM (56 MB; kept so a second
#                                 run never re-downloads)
#   CACHE/kernel/vmlinuz          the kernel the harnesses boot (-kernel)
#   CACHE/kernel/config           the kernel's own config
#   CACHE/kernel/modules/<...>    the .ko.zst files at their in-RPM
#                                 relative paths (mkinitramfs decompresses
#                                 them into /lib/modules/<version>/)
#
# IDEMPOTENT: a cache hit (RPM hash ok AND vmlinuz hash ok AND every
# module present) does NO work and prints "cache hit".  A cached file that
# FAILS its hash is re-fetched (or re-extracted), never trusted — corrupt
# the cached RPM and the next run re-downloads it.
#
# Env: FX_KERNEL_CACHE  cache dir override (default $repo/.kernel-cache)
#
# exit 0 on a verified cache; 77 when offline (curl/wget cannot fetch the
# pinned RPM — the callers skip loudly, they do NOT fall back to the host
# kernel); 1 on any other failure (bad pin file, hash mismatch after a
# FRESH download, extraction failure).
set -u

fail() { echo "fetch-kernel: FAIL: $*" >&2; exit 1; }
offline() { echo "fetch-kernel: SKIP ($*)"; exit 77; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$REPO/scripts/kernel-pin.txt"
[ -f "$PIN" ] || fail "scripts/kernel-pin.txt missing"
[ -r "$PIN" ] || fail "scripts/kernel-pin.txt not readable"

command -v sha256sum >/dev/null 2>&1 || fail "sha256sum not found"
command -v rpm2cpio >/dev/null 2>&1 || fail "rpm2cpio not found (rpm extraction)"
command -v cpio >/dev/null 2>&1      || fail "cpio not found (rpm extraction)"

# ─── the pin (single source of truth) ──────────────────────────────────────
pin() { sed -n "s/^$1 //p" "$PIN" | head -1; }
URL=$(pin url)
RPM_SHA=$(pin rpm_sha256)
RPM_SIZE=$(pin rpm_size)
KVER=$(pin kernel_version)
VMLINUZ_PATH=$(pin vmlinuz_path)
VMLINUZ_SHA=$(pin vmlinuz_sha256)
CONFIG_PATH=$(pin config_path)
[ -n "$URL" ]        && [ -n "$RPM_SHA" ]      && [ -n "$KVER" ] \
    && [ -n "$VMLINUZ_PATH" ] && [ -n "$VMLINUZ_SHA" ] \
    || fail "scripts/kernel-pin.txt malformed (needs url, rpm_sha256, kernel_version, vmlinuz_path, vmlinuz_sha256)"
# every module line, in pin order
MODULES=$(sed -n 's/^module //p' "$PIN")
[ -n "$MODULES" ] || fail "scripts/kernel-pin.txt has no 'module ...' lines"
case "$VMLINUZ_PATH" in
    usr/lib/modules/"$KVER"/*) ;;
    *) fail "vmlinuz_path '$VMLINUZ_PATH' is not under usr/lib/modules/$KVER/" ;;
esac
case "$CONFIG_PATH" in
    usr/lib/modules/"$KVER"/config) ;;
    *) fail "config_path '$CONFIG_PATH' is not <kernel_version>/config" ;;
esac

CACHE="${FX_KERNEL_CACHE:-$REPO/.kernel-cache}"
RPM_FILE="$CACHE/rpm"
KERNEL_DIR="$CACHE/kernel"
VMLINUZ="$KERNEL_DIR/vmlinuz"
MOD_DIR="$KERNEL_DIR/modules"

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# ─── 1. the RPM: cache hit (hash ok) or (re-)download ──────────────────────
NEED_RPM=1
if [ -f "$RPM_FILE" ]; then
    if [ "$(sha_of "$RPM_FILE")" = "$RPM_SHA" ]; then
        NEED_RPM=0
    else
        echo "fetch-kernel: cached RPM fails its pin — re-fetching"
        rm -f "$RPM_FILE"
    fi
fi
if [ "$NEED_RPM" = 1 ]; then
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
        || offline "neither curl nor wget found (cannot fetch the pinned kernel)"
    mkdir -p "$CACHE" || fail "cannot create cache dir $CACHE"
    echo "fetch-kernel: downloading $URL"
    echo "              to $RPM_FILE (~$((${RPM_SIZE:-0} / 1048576)) MB)"
    PART="$CACHE/rpm.part"
    rm -f "$PART"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$PART" "$URL" || { rm -f "$PART"; offline "curl could not fetch $URL"; }
    else
        wget -O "$PART" "$URL" || { rm -f "$PART"; offline "wget could not fetch $URL"; }
    fi
    [ -s "$PART" ] || { rm -f "$PART"; offline "download came back empty ($URL)"; }
    [ -n "$RPM_SIZE" ] && [ "$(wc -c < "$PART")" = "$RPM_SIZE" ] \
        || fail "downloaded RPM size $(wc -c < "$PART") != pinned $RPM_SIZE (update scripts/kernel-pin.txt)"
    GOT=$(sha_of "$PART")
    [ "$GOT" = "$RPM_SHA" ] \
        || { rm -f "$PART"; fail "downloaded RPM sha256 $GOT != pinned $RPM_SHA (the URL moved — update scripts/kernel-pin.txt)"; }
    mv -f "$PART" "$RPM_FILE"
fi

# ─── 2. extraction: vmlinuz + config + modules, only if not already good ───
extracted_ok() {
    [ "$(sha_of "$VMLINUZ")" = "$VMLINUZ_SHA" ] || return 1
    [ -f "$KERNEL_DIR/config" ] || return 1
    for m in $MODULES; do
        [ -f "$MOD_DIR/$m" ] || return 1
    done
    return 0
}
if extract_lease=$(extracted_ok); then
    echo "fetch-kernel: cache hit — $VMLINUZ ($(wc -c < "$VMLINUZ") bytes, kernel $KVER)"
    exit 0
fi

echo "fetch-kernel: extracting kernel $KVER from the pinned RPM"
rm -rf "$KERNEL_DIR"
mkdir -p "$KERNEL_DIR" "$MOD_DIR" || fail "cannot create $KERNEL_DIR"

# rpm2cpio | cpio would extract the WHOLE RPM (~100 MB unpacked); -E pulls
# only the pinned members.  RPM cpio member names carry a leading "./", so
# each pattern is the in-RPM path under ./usr/lib/modules/<KVER>/.
EXT="$CACHE/extract.$$"
WANTLIST="$CACHE/want.$$"
rm -rf "$EXT"
mkdir -p "$EXT" || fail "cannot create extraction dir"
{
    printf './usr/lib/modules/%s/vmlinuz\n' "$KVER"
    printf './usr/lib/modules/%s/config\n' "$KVER"
    for m in $MODULES; do
        printf './usr/lib/modules/%s/%s\n' "$KVER" "$m"
    done
} > "$WANTLIST"
if ! rpm2cpio "$RPM_FILE" | (cd "$EXT" && cpio -idm --quiet -E "$WANTLIST" 2>/dev/null); then
    rm -rf "$EXT" "$WANTLIST"
    fail "rpm2cpio|cpio extraction failed for the pinned RPM"
fi
rm -f "$WANTLIST"

[ -f "$EXT/$VMLINUZ_PATH" ] || { rm -rf "$EXT"; fail "vmlinuz missing from the RPM at $VMLINUZ_PATH (pin out of date?)"; }
[ -f "$EXT/$CONFIG_PATH" ]  || { rm -rf "$EXT"; fail "config missing from the RPM at $CONFIG_PATH (pin out of date?)"; }
for m in $MODULES; do
    [ -f "$EXT/usr/lib/modules/$KVER/$m" ] || { rm -rf "$EXT"; fail "module $m missing from the RPM (pin out of date?)"; }
done

# move into the cache layout; keep modules at their in-RPM relative paths
# so mkinitramfs can stage them by bare name
mv "$EXT/$VMLINUZ_PATH" "$VMLINUZ" || fail "cannot stage vmlinuz"
mv "$EXT/$CONFIG_PATH" "$KERNEL_DIR/config" || fail "cannot stage config"
for m in $MODULES; do
    d="$MOD_DIR/$(dirname "$m")"
    mkdir -p "$d" || fail "cannot create module dir $d"
    mv "$EXT/usr/lib/modules/$KVER/$m" "$MOD_DIR/$m" || fail "cannot stage module $m"
done
rm -rf "$EXT"

GOT=$(sha_of "$VMLINUZ")
[ "$GOT" = "$VMLINUZ_SHA" ] \
    || fail "EXTRACTED vmlinuz sha256 $GOT != pinned $VMLINUZ_SHA (RPM verified but contents differ — update scripts/kernel-pin.txt)"
chmod 444 "$VMLINUZ" 2>/dev/null
echo "fetch-kernel: OK — $VMLINUZ ($(wc -c < "$VMLINUZ") bytes, kernel $KVER, $(printf '%s\n' "$MODULES" | wc -l) modules)"
