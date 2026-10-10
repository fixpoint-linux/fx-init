-- reject-agent-nonconsole.dhall — the declared agent service EXISTS but is
-- NOT a console service.  fx-init pins 'failed' for a NON-console service
-- that exits during the boot grace window without consulting the exit
-- status, and the agent's refusal path deliberately exits 0 — this shape
-- would turn every refusal into a roll-forward oscillator, so activation
-- refuses it LOUDLY, naming the service.
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
        [ { name = "agentd", argv = [ "/usr/fx-agent/bin/fx-agent" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) } ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 5000
    , agentService = Some "agentd"
    }
