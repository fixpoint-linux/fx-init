-- empty-svc.dhall — minimal config: no users, no services, no extraEtc.
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "empty"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate" ]
    , users = [ { name = "root", uid = 0, groups = [ "root" ] : List Text } ]
    , services = [] : List Service
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = None Natural }
