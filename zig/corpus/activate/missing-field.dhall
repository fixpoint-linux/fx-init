-- missing-field.dhall — record without the required services field.
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "nofields"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate" ]
    , users = [] : List { name : Text, uid : Natural, groups : List Text }
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = None Natural }
