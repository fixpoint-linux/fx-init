-- m3/config-console.dhall — the M6 CONSOLE config: config-good plus an
-- interactive fxsh on the serial console (tests/qemu_console.sh).
--
-- The console service:
--   argv = /usr/fx-core/bin/fxsh — the fx-core payload staged by
--     mkinitramfs -b (image.zig's provision builds it); absolute, so
--     pkg = None (fx-core is NOT an m3 package — the image lane builds it)
--   console = Some "console" — init.zig's start_service opens /dev/console
--     onto the child's 0/1/2 instead of the supervisor pipe; the serial
--     line IS the shell's terminal (kernel line discipline stays canonical)
--   restart = Some "never" — a user's `exit` leaves the service ST_STOPPED
--     (no backoff loop fighting the user for the tty)
--   probe = None — the shell is 'started' the moment it spawns (the boot
--     verdict does NOT wait for a human; a console service exiting during
--     grace does NOT fail the boot (reap_children skips console services'
--     exit latch — an interactive shell exiting is the service doing its
--     job, not a boot failure; without the skip the exit would write
--     ('failed') into the store's .bootlog and the NEXT boot would roll the
--     generation back to an older ok one)
--   bootGraceMs = Some 15000 — DELIBERATELY long: the console service
--     spawns at ~2s, so a 15s grace gives the harness's exit-fast
--     regression probe a WIDE window to prove an early `exit` does not
--     latch boot-FAILED (with 3000ms the prompt and the verdict landed
--     within ~100ms of each other and the probe timing-flaked, MEASURED).
--     The interactive arm types only after the verdict, so the long grace
--     costs only boot-wall-clock, no ordering.
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }
        , { name = "fxsh", argv = [ "/usr/fx-core/bin/fxsh" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = Some [ { key = "FX_STATE_DIR", value = "/run/fx/shell" },
                         { key = "TERM", value = "dumb" }
                       ] : Optional (List { key : Text, value : Text }),
            console = Some "console" }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 15000
    }
