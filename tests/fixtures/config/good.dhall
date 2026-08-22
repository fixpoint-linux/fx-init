-- tests/fixtures/config/good.dhall — a well-formed config for the walker test.
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox"
    , packages = [ "dhake", "fx-init", "fxctl", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text }
              , { name = "alice", uid = 1000, groups = [ "wheel", "audio" ] }
              ]
    , services =
        [ { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = Some < File = "/run/fx/ready-heartbeat" >,
            env = Some [ { key = "BEAT", value = "hz2" } ] }
        , { name = "after-heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "up:heartbeat", restart = None Text, probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        ]
    , extraEtc = Some [ { path = "motd", content = "welcome to fixbox" } ]
    , bootGraceMs = Some 5000
    }
