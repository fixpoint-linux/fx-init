#!/bin/sh
# tests/qemu_console.sh — the M6 CONSOLE harness: the image boots to an
# INTERACTIVE fxsh on the serial console.
#
# The property: a config-console.dhall image (config-good + a service with
# console = Some "console") boots, reaches boot-ok, and the SERIAL line
# carries fxsh's own `fx> ` prompt; driving the line with one command
# executes it (an fx-* pipeline stage); `exit` leaves the service
# ST_STOPPED (restart = never) with PID1 still running and the boot verdict
# still ok.
#
# THE ARMS (the asymmetry rule):
#   ARM 1 (post-fix): the config-console image MUST produce `fx> `, echo
#       back the probe marker, and stay boot-ok after `exit`.
#   ARM 2 (pre-fix control): a config-good image (no console service, no
#       fx-core payload usage as a shell) MUST NOT produce `fx> ` within
#       the same bounded wait — the console harness cannot pass on a boot
#       that happens to print a prompt from somewhere else.
#   Chain evidence (both arms): the RAMDISK line at the loader-placed
#       0x02000000 + the `Run /fx/store/...-fx-init/fx-init as init process`
#       line, exactly like qemu_image_boot.sh, so a broken boot that
#       happens to emit `fx> ` cannot pass.
#
# DRIVER: python3 stdlib only (no pexpect on this host).  qemu runs with
# `-serial pty`; the driver parses the pty path from qemu's stderr, opens
# it O_RDWR|O_NOCTTY, and select()s with bounded waits.  The guest side is
# the SERIAL line (console=ttyS0), not a vport — that is why the driver
# must WRITE to the line too (the kernel line discipline is canonical; a
# line ends with \n and the echo comes back on the same fd).
#
# Env:
#   QEMU_CONFIG       console-arm config (default m3/config-console.dhall)
#   QEMU_NEG_CONFIG   pre-fix-arm config (default m3/config-good.dhall)
#   QEMU_BOOT_TIMEOUT seconds to wait per boot verdict (default 120)
#   FX_IMAGE_BIN      override the fx-image under test (default: the
#                     zig-built zig-out/bin/fx-image; built first if absent)
#   FX_KERNEL_CACHE   kernel cache override (fetch-kernel + fx-image)
#   FX_SIBLINGS       sibling checkouts (fx-image default: repo/..)
#   QEMU_KEEP=1       keep the scratch dir (debugging; prints its path)
set -u

fail() { echo "console-boot: FAIL: $*" >&2; exit 1; }
skip() { echo "console-boot: SKIP ($*)"; exit 77; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || skip "qemu-system-x86_64 not found"
command -v timeout >/dev/null 2>&1 || skip "timeout not found"
command -v sha256sum >/dev/null 2>&1 || skip "sha256sum not found"
command -v python3 >/dev/null 2>&1 || skip "python3 not found (the pty driver)"
[ -e /dev/kvm ]                   || skip "/dev/kvm absent (console boot requires kvm)"
[ -w /dev/kvm ]                   || skip "/dev/kvm not writable"

cd "$(dirname "$0")/.." || fail "cannot cd to repo root"
REPO="$PWD"
QEMU_CONFIG="${QEMU_CONFIG:-$REPO/m3/config-console.dhall}"
QEMU_NEG_CONFIG="${QEMU_NEG_CONFIG:-$REPO/m3/config-good.dhall}"
QEMU_BOOT_TIMEOUT="${QEMU_BOOT_TIMEOUT:-120}"
qemu-system-x86_64 --version | head -1

# ─── pinned kernel pre-flight (same contract as qemu_image_boot.sh) ────────
PIN="$REPO/scripts/kernel-pin.txt"
[ -f "$PIN" ] || skip "scripts/kernel-pin.txt missing"
FETCH_OUT=$(sh "$REPO/scripts/fetch-kernel.sh" 2>&1)
FETCH_RC=$?
echo "$FETCH_OUT"
[ "$FETCH_RC" = 0 ] || [ "$FETCH_RC" = 77 ] || fail "fetch-kernel failed (rc=$FETCH_RC)"
[ "$FETCH_RC" = 0 ] || skip "pinned kernel artifact unavailable (offline) — no host-kernel fallback by design"

# ─── the builder under test ────────────────────────────────────────────────
FXIMAGE="${FX_IMAGE_BIN:-$REPO/zig/zig-out/bin/fx-image}"
if [ ! -x "$FXIMAGE" ]; then
    command -v zig >/dev/null 2>&1 || skip "zig not found and $FXIMAGE absent (build it or set FX_IMAGE_BIN)"
    echo "=== console-boot: fx-image absent — zig build ==="
    ( cd "$REPO/zig" && zig build ) >/dev/null 2>&1
    [ -x "$FXIMAGE" ] || skip "zig build did not produce zig-out/bin/fx-image"
fi

# ─── scratch ───────────────────────────────────────────────────────────────
SCRATCH="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "$SCRATCH/qemucon.XXXXXX")" || fail mktemp
if [ "${QEMU_KEEP:-0}" = "1" ]; then
    trap 'echo "console-boot: scratch kept at $WORK"' EXIT
else
    trap 'rm -rf "$WORK"' EXIT
fi
# the FIXED store root is a derivation-hash input; a shared default would
# collide with any concurrent builder — the harness gives the run its own
FXWORK="$WORK/fxwork"

case "$QEMU_CONFIG" in /*) ;; *) QEMU_CONFIG="$REPO/$QEMU_CONFIG" ;; esac
case "$QEMU_NEG_CONFIG" in /*) ;; *) QEMU_NEG_CONFIG="$REPO/$QEMU_NEG_CONFIG" ;; esac
[ -r "$QEMU_CONFIG" ]     || skip "console config not readable: $QEMU_CONFIG"
[ -r "$QEMU_NEG_CONFIG" ] || skip "negative config not readable: $QEMU_NEG_CONFIG"

# ─── build one image (the concurrent-peer retry of qemu_image_boot.sh) ─────
build_image() { # build_image CONFIG OUT LOGTAG (log at $WORK/build-LOGTAG.log)
    _cfg=$1 _out=$2 _log="$WORK/build-$3.log" _try=0
    while :; do
        echo "=== console-boot: fx-image --config $(basename "$_cfg") -> $(basename "$_out") ===" >&2
        if "$FXIMAGE" --config "$_cfg" \
            --package-set "$REPO/m3/package-set.dhall" \
            --pin "$PIN" --out "$_out" --size-mb 512 \
            --work "$FXWORK" >"$_log" 2>&1; then
            break
        fi
        _try=$((_try + 1))
        if [ "$_try" -ge 2 ]; then
            echo "--- fx-image build log (last 40) ---" >&2; tail -40 "$_log" >&2
            fail "fx-image build failed for $(basename "$_cfg") (rc above; log $_log)"
        fi
        echo "--- fx-image attempt 1 failed (zig cache contention with a concurrent peer is the expected transient) — retrying once ---" >&2
    done
    cat "$_log" >&2
    [ -f "$_out.sha256" ] || fail "fx-image wrote no $_out.sha256 sidecar"
}

parse_version() { # parse_version LOGTAG -> the single numeric token
    sed -n 's/.*activated version \([0-9][0-9]*\).*/\1/p' "$WORK/build-$1.log" | head -1
}

# ─── the pty driver: boot IMG, drive the serial line, assert PROBE_SPEC ────
# Driver contract (python3 stdlib; prints its own diagnostics):
#   argv: IMG WANT_VERDICT WANT_PROMPT TIMEOUT_SECS CONSOLE_LOG
#   WANT_VERDICT: 'ok'    -> the boot-ok v$V verdict MUST appear
#                 'none'  -> no verdict is required (the pre-fix arm still
#                             boots, but the harness asserts no `fx> `)
#   WANT_PROMPT:  'fx>'   -> the interactive probe (post-fix arm): wait
#                            for `fx> `, send an echo probe, assert the
#                            marker occurs TWICE (tty echo + the fxsh reply —
#                            a reply-less boot passes only the first), then
#                            `exit`; the shell must be really gone: exactly
#                            ONE prompt ever and a further sent line gets NO
#                            echo back (no live reader on the guest side)
#                 'exit-fast' -> the F2 regression probe: `exit` is sent the
#                            moment the prompt is up (BEFORE the 3000ms
#                            grace verdict) and the boot must STILL reach
#                            boot-ok v$V with NO boot-FAILED (pre-fix, this
#                            very exit latched boot-FAILED in reap_children
#                            and wrote 'failed' into the disk store's
#                            .bootlog — the reviewer reproduced it live)
#                 'no'    -> `fx> ` MUST NOT appear within the bounded wait
#   exit 0 = all assertions held; nonzero (with diagnostics) = a failure
drive_console() { # drive_console IMG WANT_VERDICT WANT_PROMPT TAG VERSION
    python3 - "$1" "$2" "$3" "$QEMU_BOOT_TIMEOUT" "$WORK/console-$4.log" "$4" "$5" <<'PYEOF'
import os, re, select, subprocess, sys, time

img, want_verdict, want_prompt, timeout_s, conlog, tag, version = (
    sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5], sys.argv[6], sys.argv[7])

def bail(msg):
    print("console-driver[%s]: FAIL: %s" % (tag, msg))
    sys.exit(1)

# qemu with -serial pty ALLOCATES its own pty and prints the redirect line
# on STDOUT (MEASURED: "char device redirected to /dev/pts/N (label ...)" —
# NOT stderr; a stderr-only reader hangs for the whole boot).  Both stdout
# and stderr go to one pipe we keep draining, and we poll IT for the path.
qemu_log = "/tmp/qemu-console-%s.qemu.log" % tag
qemu_out = open(qemu_log, "wb+")
qemu = subprocess.Popen(
    ["qemu-system-x86_64", "-machine", "q35", "-accel", "kvm", "-cpu", "host",
     "-m", "2048", "-smp", "1", "-display", "none", "-no-reboot",
     "-monitor", "none",
     "-chardev", "pty,id=con", "-serial", "chardev:con",
     "-drive", "file=%s,format=raw,if=virtio" % img],
    stdout=qemu_out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)

pty_path = None
head = b""  # the drained qemu output so far (also the no-pty diagnostic)
deadline = time.time() + 20
while time.time() < deadline and pty_path is None:
    if qemu.poll() is not None:
        qemu_out.seek(0)
        bail("qemu exited early rc=%s: %r" % (qemu.poll(), qemu_out.read(400)))
    qemu_out.seek(0, 1)  # flush position: seek to end to observe writes
    time.sleep(0.3)
    qemu_out.seek(0)
    head = qemu_out.read()
    m = re.search(rb"redirected to (/dev/pts/\d+)", head)
    if m:
        pty_path = m.group(1).decode()
if pty_path is None:
    qemu.kill()
    qemu_out.seek(0)
    bail("cannot find the pty path in qemu output: %r" % head[:300])

# the pty is nonblocking by nature: qemu poll()s it and the console can
# produce bursts — O_NONBLOCK + select-driven reads
ser = os.open(pty_path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)

buf = b""
log = open(conlog, "wb")
def pump(secs):
    """read the serial line for up to `secs` seconds, returning the new bytes"""
    global buf
    end = time.time() + secs
    got = b""
    while time.time() < end:
        r, _, _ = select.select([ser], [], [], max(0, end - time.time()))
        if r:
            chunk = os.read(ser, 65536)
            if chunk:
                got += chunk
    if got:
        buf += got
        log.write(got); log.flush()
    return got

def wait_for(pattern, secs, what=""):
    """wait until `pattern` (bytes) appears in the accumulated buffer"""
    global buf
    end = time.time() + secs
    while time.time() < end:
        if pattern in buf:
            return True
        pump(1)
    return False

verdict_re = re.compile(rb"fx-init: boot-(ok|FAILED) v(\d+)")
start = time.time()
verdict = None
deadline = start + timeout_s
# exit-fast ONLY: break the verdict wait the moment the prompt shows — the
# exit must be sent DURING the grace window, before any verdict can latch
early_prompt = (want_prompt == "exit-fast")
prompt_seen = False
while time.time() < deadline:
    pump(1)
    if early_prompt and b"fx> " in buf:
        prompt_seen = True
        break
    m = verdict_re.search(buf)
    if m:
        verdict = (m.group(1).decode(), m.group(2).decode())
        break
    if qemu.poll() is not None:
        break

# chain evidence (both arms): the initrd reached the kernel at the loader's
# fixed address and the store's fx-init is PID1 (qemu_image_boot.sh's exact
# greps)
if b"RAMDISK: [mem 0x02000000" not in buf:
    qemu.kill(); os.close(ser)
    bail("no RAMDISK line at the loader-placed 0x02000000 — the image's initrd did not reach the kernel")
if not re.search(rb"Run /fx/store/.*-fx-init/fx-init as init process", buf):
    qemu.kill(); os.close(ser)
    bail("no 'Run /fx/store/...-fx-init/fx-init as init process' — the baked rdinit did not exec")

# exit-fast asserts the verdict ITSELF after sending the early exit (the
# verdict cannot exist yet — the wait broke at the prompt); every other arm
# asserts it here.
if want_verdict == "ok" and want_prompt != "exit-fast":
    if verdict is None:
        qemu.kill(); os.close(ser)
        bail("no boot verdict within %ds (exit %s)" % (timeout_s, qemu.poll()))
    if verdict[0] != "ok" or verdict[1] != version:
        qemu.kill(); os.close(ser)
        bail("verdict mismatch: got %s, want ok v%s" % (verdict, version))
elif want_prompt != "exit-fast" and verdict is not None and verdict[0] == "FAILED":
    qemu.kill(); os.close(ser)
    bail("unexpected boot-FAILED v%s" % verdict[1])

if want_prompt == "exit-fast":
    # ── the F2 regression probe ──
    # 'exit' is sent the MOMENT the prompt is seen.  config-console.dhall's
    # bootGraceMs is 15000 (deliberately wide) and the shell spawns at ~2s,
    # so the exit lands ~13s INSIDE the grace window regardless of poll
    # granularity — pre-fix, this exit latches boot-FAILED in
    # reap_children (the reviewer's live repro: 'fx-init: boot-FAILED v3' +
    # ('failed') in the disk store's .bootlog -> the next boot rolls the
    # generation back to an older ok one).  A 3000ms grace made this probe
    # timing-flake (prompt and verdict within ~100ms of each other,
    # MEASURED) — that is WHY the config's grace is 15000.
    if not prompt_seen:
        qemu.kill(); os.close(ser)
        bail("no 'fx> ' prompt within %ds (exit-fast arm — the shell never spawned?)" % timeout_s)
    os.write(ser, b"exit\n")
    if not wait_for(b"fx-init: boot-ok v" + version.encode(), 45):
        qemu.kill(); os.close(ser)
        bail("no boot-ok v%s within 30s after the early shell exit" % version)
    if b"boot-FAILED" in buf:
        qemu.kill(); os.close(ser)
        bail("boot-FAILED after the early shell exit — the F2 regression is BACK (a console service exiting during grace must not fail the boot)")
    time.sleep(3)
    pump(3)
    if buf.count(b"fx> ") != 1:
        qemu.kill(); os.close(ser)
        bail("expected exactly one 'fx> ' prompt — saw %d" % buf.count(b"fx> "))
elif want_prompt == "fx>":
    # ── the interactive probe ──
    # verdict FIRST (it is already required above for want_verdict == ok,
    # so it is in buf), then the prompt: with grace=15000 the prompt lands
    # ~13s before the verdict, so this wait_for is the real one — the
    # probe types only once the shell is live AND the verdict is latched.
    if not wait_for(b"fx> ", 45):
        qemu.kill(); os.close(ser)
        bail("no 'fx> ' prompt within 45s (interactive arm — the shell never spawned?)")
    # the marker must occur TWICE: the canonical tty ECHOES the sent line
    # 'echo <marker>' (occurrence 1, the driver's own text) and fxsh's
    # fx-echo stage prints the reply (occurrence 2).  A boot where the
    # shell reads the line but the command never runs (exec failure, a
    # pipeline regression, a silent REPL) yields only occurrence 1 and
    # FAILS here — that is exactly what makes this assertion fireable.
    marker = "console-harness-probe-9331"
    os.write(ser, ("echo %s\n" % marker).encode())
    m_deadline = time.time() + 30
    while time.time() < m_deadline and buf.count(marker.encode()) < 2:
        pump(1)
    if buf.count(marker.encode()) < 2:
        qemu.kill(); os.close(ser)
        bail("the echo probe did not round-trip: marker occurs %d time(s) (want 2: tty echo + fxsh reply)" % buf.count(marker.encode()))
    # `exit`: the service is ST_STOPPED (restart=never), PID1 keeps running.
    # Quietness is ASSERTED, not assumed: exactly one prompt ever, and a
    # further sent line gets NO echo back (no live reader on the guest).
    os.write(ser, b"exit\n")
    time.sleep(3)
    pump(3)
    if b"boot-FAILED" in buf:
        qemu.kill(); os.close(ser)
        bail("boot-FAILED appeared after the shell exit")
    # the REPL prints one prompt per line it reads: prompt#1 preceded the
    # echo probe, prompt#2 precedes the exit — exactly TWO prompts for the
    # two lines, and NO third (a respawned or un-exited shell would print
    # more; the alive-check below pins it fully)
    if buf.count(b"fx> ") != 2:
        qemu.kill(); os.close(ser)
        bail("expected exactly two 'fx> ' prompts (one per line sent: echo probe + exit) — saw %d" % buf.count(b"fx> "))
    # quietness, ASSERTED fireably: send one more echo probe AFTER the
    # exit.  A dead shell leaves ONLY the tty's line echo (marker occurs
    # exactly ONCE — the guest's line discipline echoes input with no
    # reader); a LIVE shell would run fx-echo and print the bare reply
    # line too (marker occurs TWICE, the F1 class again).  So the count
    # must be exactly 1 — 0 means the line never reached the guest (a
    # driver/pty fault), 2 means the shell never exited.
    alive = "alive-check-777"
    os.write(ser, ("echo %s\n" % alive).encode())
    a_deadline = time.time() + 10
    while time.time() < a_deadline and buf.count(alive.encode()) < 1:
        pump(1)
    time.sleep(2)
    pump(2)
    n_alive = buf.count(alive.encode())
    if n_alive != 1:
        qemu.kill(); os.close(ser)
        bail("post-exit alive-check marker occurs %d time(s), want exactly 1 (0 = the line never reached the guest; >=2 = the shell is still live)" % n_alive)
else:
    # the pre-fix arm: fx> must NOT appear within a bounded ~20s window
    # (10s sleep + 10s pump).  This is DELIBERATELY not arm 1's 30s prompt
    # wait: the plain image boots in ~3s, so 20s is generous; the bound
    # stated here is the one enforced.
    time.sleep(10)
    pump(10)
    if b"fx> " in buf:
        qemu.kill(); os.close(ser)
        bail("the pre-fix image produced 'fx> ' (the gate would be trivially satisfiable)")

qemu.kill()
qemu.wait()
os.close(ser)
log.close()
print("console-driver[%s]: OK (verdict=%s, %d console bytes)" % (
    tag, verdict, len(buf)))
PYEOF
}

# ═══ ARM 1 — the console image: boot-ok v$V -> 'fx> ' -> echo probe -> exit ═
GOOD="$WORK/console.raw"
build_image "$QEMU_CONFIG" "$GOOD" console
V=$(parse_version console)
case $V in ''|*[!0-9]*) fail "cannot parse 'activated version <N>' from fx-image output: $(tail -5 "$WORK/build-console.log")";; esac
echo "=== console-boot: build activated version v$V ==="
[ -f "$GOOD.sha256" ] || fail "no sidecar for $GOOD"

echo "=== console-boot: boot 1/2 of $(basename "$GOOD") — the F2 regression probe (exit BEFORE the grace verdict) ==="
drive_console "$GOOD" ok "exit-fast" console-f2 "$V" || fail "arm 1 boot 1 (F2 regression probe) driver failed"
echo "arm 1 boot 1 (F2 probe): early exit -> boot-ok v$V, NO boot-FAILED, one prompt — OK"

echo "=== console-boot: boot 2/2 of $(basename "$GOOD") — the interactive probe (prompt -> echo round-trip -> exit -> quiet) ==="
drive_console "$GOOD" ok "fx>" console "$V" || fail "arm 1 boot 2 (interactive probe) driver failed"
echo "arm 1 boot 2 (interactive): boot-ok v$V, prompt, echo round-trip (2x marker), exit, quiet — OK"

# ═══ ARM 2 — the pre-fix image: NO 'fx> ' within the bounded wait ══════════
NEG="$WORK/plain.raw"
build_image "$QEMU_NEG_CONFIG" "$NEG" plain
VNEG=$(parse_version plain)
case $VNEG in ''|*[!0-9]*) fail "cannot parse 'activated version <N>' from fx-image output: $(tail -5 "$WORK/build-plain.log")";; esac
echo "=== console-boot: negative build activated version v$VNEG ==="

echo "=== console-boot: booting $(basename "$NEG") (pre-fix control, expecting NO 'fx> ') ==="
drive_console "$NEG" ok no plain "$VNEG" || fail "arm 2 (pre-fix control) driver failed"
echo "arm 2 (pre-fix control): no 'fx> ' — OK"

echo "console-boot: PASS (config-console image: early exit during grace -> boot-ok, no boot-FAILED, no generation roll-back; interactive: prompt -> echo round-trip -> exit -> quiet; the pre-fix image never prints 'fx> ')"
exit 0
