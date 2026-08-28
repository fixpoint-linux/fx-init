let Probe = < Tcp : Natural | Unix : Text | File : Text >
let S = { name : Text, argv : List Text, pkg : Optional Text, on : Text, restart : Optional Text, backoffMs : Optional Natural, probe : Optional Probe, env : Optional (List { key : Text, value : Text }) }
let U = { name : Text, uid : Natural, groups : List Text }
in { hostname = "x", packages = [] : List Text, users = [] : List U,
     services = [ { name = "dup", argv = ["a"], pkg = None Text, on = "all", restart = None Text, backoffMs = None Natural, probe = None Probe, env = None (List { key : Text, value : Text }) }
                , { name = "dup", argv = ["b"], pkg = None Text, on = "all", restart = None Text, backoffMs = None Natural, probe = None Probe, env = None (List { key : Text, value : Text }) } ],
     extraEtc = None (List { path : Text, content : Text }), bootGraceMs = None Natural }
