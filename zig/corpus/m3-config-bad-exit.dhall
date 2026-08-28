-- m3/config-bad-exit.dhall — used by tests/fxinit_boot.sh: a service that exits 7.
-- crasher = fakesvc exit 7, restart=always, so fx-init keeps restarting it
-- (backoff doubling) and the boot never reaches ok -> boot_status=failed.
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
        [ { name = "crasher", argv = [ "fakesvc", "exit", "7" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 200,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 2000
    }
