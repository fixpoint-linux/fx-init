-- m3/config-good.dhall — used by tests/fxinit_boot.sh: a healthy boot.
-- heartbeat = fakesvc ok (prints "heartbeat from heartbeat" every 500ms),
-- started-as-ready (no probe) so the boot reaches ok within bootGraceMs.
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
        [ { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 5000
    }
