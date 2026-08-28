-- svc-not-in-closure.dhall — closure covers the 4 tools but the service's
-- pkg (fakesvc) is not among config.packages (fx-activate must reject at the
-- svc_bin resolution, AFTER the tool checks pass).
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "noclosure"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate" ]
    , users = [] : List { name : Text, uid : Natural, groups : List Text }
    , services =
        [ { name = "s", argv = [ "fakesvc" ], pkg = Some "fakesvc",
            on = "all", restart = None Text, backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) } ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = None Natural }
