-- crasher.dhall — unit-6 diff fixture: a service that exits 7.  crasher =
-- fakesvc exit 7, restart=always, so fx-init keeps restarting it (backoff)
-- and the boot never reaches ok -> boot_status=failed (reap pin).
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fakesvc" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "crasher", argv = [ "fakesvc", "exit", "7" ], pkg = Some "fakesvc",
            on = "all", restart = Some "always", backoffMs = Some 200,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 1500
    }
