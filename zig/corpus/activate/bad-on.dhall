-- bad-on.dhall — on= grammar violation (config walker must reject).
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "badon"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate" ]
    , users = [] : List { name : Text, uid : Natural, groups : List Text }
    , services =
        [ { name = "s", argv = [ "/bin/true" ], pkg = None Text,
            on = "bogus:thing", restart = None Text, backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) } ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = None Natural }
