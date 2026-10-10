-- agent-console-ok.dhall — the HONEST agent shape: agentService names a
-- service that exists and IS a console service.  Loads (rc 0), the dump
-- prints agent_service=agentd.
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox"
    , packages = [ "dhake", "fx-init", "fxctl", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "agentd", argv = [ "/usr/fx-agent/bin/fx-agent" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" } ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 5000
    , agentService = Some "agentd"
    }
