#!/bin/sh
# init_diff.sh — unit-6 regression harness for the Zig fx-init PID1/
# supervisor port (zig/src/init.zig).  L1 in-sandbox smoke vs pinned
# goldens (zig/golden/init/, no cosmocc, no bwrap, no fxstore binary): it
# builds a fixture store via the ZIG fx-activate (unit 5) + the
# activate_paths helper, installs a zig-cc-built fakesvc at its svc_bin
# target and a FAKE dhake (cats its -f arg to stdout, exit 0 or
# FAKE_DHAKE_EXIT), then boots the Zig fx-init HOST-side with
# FX_INIT_FORCE=1 and compares a NORMALIZED transcript (fxctl status +
# q service_runtime + q boot_status + grep heartbeat + grep 'let GEN' +
# .bootlog; epochs/pids/restarts/store-path sed-normalized) against the
# goldens.
#
# Golden provenance: this was a LIVE differential against the C oracle
# (src/fx-init.c + its C twins, since removed) — the last pre-deletion
# live runs (2026-08-29) booted the C and the Zig PID1 side by side and
# byte-matched the normalized transcripts (good/crasher/dhake-fail/stop+
# start; 3 of 4 runs fully green, one run flaked only on the crasher
# case's instantaneous service state — see below); the goldens were then
# captured from the Zig side, i.e. golden == the C oracle's verified
# behavior.
#
# CRASHER-CASE NOTE: for the crasher service the instantaneous
# service_runtime state token (backoff|started) depends on where the
# status poll lands inside the crash/restart cycle — it is unassertable
# by construction (that race is what the one flaky live run hit).  For
# that case only, the state token is normalized to CYCLE; the crash
# cycle HISTORY stays fully asserted via .bootlog + the grep lines.
#
# The store is activated into $WORK/pre (so the buildfile bakes the HOST
# root $WORK/pre) then MOVED to $WORK/store before boot: run_dhake must
# reloc-rewrite $WORK/pre -> $WORK/store, so `grep 'let GEN'` pins the
# fx_reloc wiring (the rewritten GEN line, not the activation-time root).
set -u
cd "$(dirname "$0")/.."

CORPUS=zig/corpus/init
PKGSET=zig/corpus/activate/package-set.dhall
ROOTS="dhake fx-init fxctl fx-activate fakesvc"
GOLDEN=zig/golden/init
PIN=0
[ "${1:-}" = "--pin" ] && PIN=1

echo "== building fixtures (fakesvc + fake dhake) + activate helpers =="
zig cc -std=gnu11 -O2 -o zig/zig-out/init_fakesvc tests/fixtures/fakesvc/fakesvc.c
zig cc -std=gnu11 -O2 -o zig/zig-out/init_dhake zig/dhake_smoke.c

echo "== building Zig port + activate helpers =="
( cd zig && zig build -Doptimize=ReleaseSafe )

INIT_Z=zig/zig-out/bin/fx-init
FXCTL=zig/zig-out/bin/fxctl
FAKESVC=zig/zig-out/init_fakesvc
DHAKE=zig/zig-out/init_dhake
PATHS=zig/zig-out/activate_paths
ACT_Z=zig/zig-out/bin/fx-activate

mkdir -p "$GOLDEN"

WORK="$(mktemp -d -t init_diff.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
PRE="$WORK/pre"
STORE="$WORK/store"
RUN="$WORK/run"

fail() { echo "init_diff: FAIL: $*" >&2; exit 1; }

# wait_status RUN — poll fxctl status until boot_status reaches ok/failed.
wait_status() {
    run=$1
    i=1
    while [ "$i" -le 100 ]; do
        out=$(FX_RUN="$run" "$FXCTL" status 2>/dev/null) || { sleep 0.2; i=$((i+1)); continue; }
        bs=$(echo "$out" | grep -A1 '^boot_status:' | tail -n1 | sed 's/^ *//')
        case "$bs" in
            *ok|*failed) echo "$out" > "$WORK/waitstatus.out"; return 0;;
        esac
        sleep 0.2
        i=$((i+1))
    done
    return 1
}

# normalize — epochs/pids/restarts/store-path out of a transcript.
normalize() {
    sed -e "s|$WORK|WORK|g" \
        -e 's/[0-9]\{10\}/EPOCH/g' \
        -e 's/\t[0-9][0-9]*\t/\tPID\t/g' \
        -e 's/\t[0-9][0-9]*$/\tN/'
}

# cycle_normalize — crasher-case only: the instantaneous service state
# token is cycle-phase, not behavior (see header).
cycle_normalize() {
    sed -e 's/\tbackoff\t/\tCYCLE\t/g' -e 's/\tstarted\t/\tCYCLE\t/g'
}

# run_side CASE CFG DHAKE_EXIT GREPTERM — fresh store, boot, capture the
# (normalized) transcript.
run_side() {
    case_name=$1 cfg=$2 dhexit=$3 grepterm=$4

    rm -rf "$PRE" "$STORE" "$RUN"
    mkdir -p "$PRE"

    rels=$("$PATHS" --store "$PRE" --package-set "$PKGSET" $ROOTS) \
        || fail "activate_paths failed ($case_name)"
    for d in $rels; do
        mkdir -p "$PRE/$d" && echo built > "$PRE/$d/payload"
    done

    "$ACT_Z" --store "$PRE" --package-set "$PKGSET" --config "$CORPUS/$cfg" \
        >"$WORK/act.out" 2>"$WORK/act.err" \
        || fail "fx-activate failed ($case_name): $(tail -1 "$WORK/act.err")"

    # install the compiled fixtures at their svc_bin / dhake targets.  The
    # target FILE does not exist yet, so `cp src dir/*-x/file` would not glob;
    # resolve the content-addressed dir first, then copy into it.
    set -- "$PRE"/*-fakesvc
    fdir=$1
    [ -d "$fdir" ] || fail "fakesvc install failed ($case_name) — no *-fakesvc dir?"
    cp "$FAKESVC" "$fdir/fakesvc"
    set -- "$PRE"/*-dhake
    ddir=$1
    [ -d "$ddir" ] || fail "dhake install failed ($case_name) — no *-dhake dir?"
    cp "$DHAKE" "$ddir/dhake.com"
    mv "$PRE" "$STORE"

    mkdir -p "$RUN"
    FX_INIT_FORCE=1 FAKE_DHAKE_EXIT="$dhexit" "$INIT_Z" \
        --store "$STORE" --run-dir "$RUN" --grace-ms 1500 --probe-interval-s 100000 \
        >"$WORK/boot.out" 2>&1 &
    BPID=$!

    wait_status "$RUN" || {
        echo "--- boot.out ---" >&2
        sed 's/^/    /' "$WORK/boot.out" >&2
        fail "boot_status never reached ok/failed ($case_name)"
    }

    FX_RUN="$RUN" "$FXCTL" status            | normalize >"$WORK/n.status" 2>&1
    FX_RUN="$RUN" "$FXCTL" q service_runtime | normalize >"$WORK/n.sr" 2>&1
    FX_RUN="$RUN" "$FXCTL" grep "$grepterm"  | head -1 | normalize >"$WORK/n.grep" 2>&1
    FX_RUN="$RUN" "$FXCTL" grep 'let GEN'    | head -1 | normalize >"$WORK/n.gen" 2>&1

    FX_RUN="$RUN" "$FXCTL" shutdown >/dev/null 2>&1
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$BPID" 2>/dev/null || break
        sleep 0.3
    done
    kill "$BPID" 2>/dev/null
    wait "$BPID" 2>/dev/null

    normalize < "$STORE/.bootlog" > "$WORK/n.bootlog"
    [ -s "$WORK/n.bootlog" ] || fail ".bootlog empty after boot ($case_name)"

    # crasher case: the instantaneous service state is cycle-phase
    if [ "$case_name" = "crasher" ]; then
        cycle_normalize < "$WORK/n.status" > "$WORK/n.status.tmp" && mv "$WORK/n.status.tmp" "$WORK/n.status"
        cycle_normalize < "$WORK/n.sr" > "$WORK/n.sr.tmp" && mv "$WORK/n.sr.tmp" "$WORK/n.sr"
    fi
}

pass=0; fail=0

# check_one CASE KIND — compare/golden one transcript artifact
check_one() {
    case_name=$1 kind=$2
    g="$GOLDEN/$case_name.$kind"
    if [ "$PIN" = 1 ]; then
        cp "$WORK/n.$kind" "$g" || { echo "    pin failed [$kind]"; return 1; }
        return 0
    fi
    diff -u "$g" "$WORK/n.$kind" > "/tmp/init.d.$kind" 2>&1 && return 0
    echo "    diff [$kind]:"
    sed 's/^/      /' "/tmp/init.d.$kind" | head -12
    return 1
}

run_case() {
    case_name=$1; cfg=$2; dhexit=$3; grepterm=$4

    run_side "$case_name" "$cfg" "$dhexit" "$grepterm"

    ok=1
    for f in status sr grep gen bootlog; do
        check_one "$case_name" "$f" || ok=0
    done

    if [ "$ok" = 1 ]; then
        pass=$((pass + 1))
        if [ "$PIN" = 1 ]; then echo "PIN $case_name"; else echo "PASS $case_name"; fi
    else
        fail=$((fail + 1))
        echo "FAIL $case_name"
    fi
}

# good boot: heartbeat reaches started, boot -> ok at grace-end
run_case good          good.dhall    0 heartbeat
# crasher: fakesvc exit 7 restarts (backoff), boot pinned failed via reap
run_case crasher       crasher.dhall 0 "fakesvc exit"
# dhake-fail: fake dhake exits 3, boot pinned failed
run_case dhake-fail    good.dhall    3 heartbeat

# ── stop/start via fxctl (control-socket supervision path) ────────────────
echo "== stop/start case =="
run_side stopstart good.dhall 0 heartbeat
FX_RUN="$RUN" "$FXCTL" stop heartbeat >/dev/null 2>&1
i=1
while [ "$i" -le 50 ]; do
    sr=$(FX_RUN="$RUN" "$FXCTL" q service_runtime 2>/dev/null)
    echo "$sr" | grep -q '^heartbeat.*stopped' && break
    sleep 0.2; i=$((i+1))
done
echo "$sr" | normalize > "$WORK/n.stop"
FX_RUN="$RUN" "$FXCTL" start heartbeat >/dev/null 2>&1
i=1
while [ "$i" -le 50 ]; do
    sr=$(FX_RUN="$RUN" "$FXCTL" q service_runtime 2>/dev/null)
    echo "$sr" | grep -q '^heartbeat.*started' && break
    sleep 0.2; i=$((i+1))
done
echo "$sr" | normalize > "$WORK/n.start"
FX_RUN="$RUN" "$FXCTL" shutdown >/dev/null 2>&1
sleep 1

ok=1
check_one stopstart stop || ok=0
check_one stopstart start || ok=0
if [ "$ok" = 1 ]; then
    pass=$((pass + 1))
    if [ "$PIN" = 1 ]; then echo "PIN stop/start"; else echo "PASS stop/start"; fi
else
    fail=$((fail + 1))
    echo "FAIL stop/start"
fi

echo "init_diff: $pass passed, $fail failed"
[ "$fail" = 0 ]
