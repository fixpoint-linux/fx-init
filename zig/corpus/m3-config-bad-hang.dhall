-- m3/config-bad-hang.dhall — used by tests/fxinit_boot.sh: a hang boot.
-- gate = fakesvc hang (starts but never ready: probe File /run/fx/never-ready
-- which nothing creates).  hanger on=up:gate so it never STARTS, and the boot
-- grace (2s) expires with an unstarted service -> boot_status=failed.
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "gate", argv = [ "fakesvc", "hang" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 1000,
            probe = Some < File = "/run/fx/never-ready" >,
            env = None (List { key : Text, value : Text }) }
        , { name = "hanger", argv = [ "fakesvc", "hang" ], pkg = Some "fake-service",
            on = "up:gate", restart = Some "never", backoffMs = Some 1000,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 2000
    }
