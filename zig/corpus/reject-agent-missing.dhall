-- reject-agent-missing.dhall — a fully valid config whose ONLY defect is the
-- OMITTED agentService field.  The field is REQUIRED (an optional field is
-- silently inert for every deployment that forgets it): "this system has no
-- agent" must be DECLARED (None Text), not defaulted to.
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox"
    , packages = [ "dhake", "fx-init", "fxctl", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) } ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 5000
    }
