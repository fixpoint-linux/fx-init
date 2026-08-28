let Probe = < Tcp : Natural | Unix : Text | File : Text >
let U = { name : Text, uid : Natural, groups : List Text }
in { hostname = "x", packages = [] : List Text, users = [] : List U,
     services = [ { name = "a", argv = [] : List Text, pkg = None Text, on = "all", restart = None Text, backoffMs = None Natural, probe = None Probe, env = None (List { key : Text, value : Text }) } ],
     extraEtc = None (List { path : Text, content : Text }), bootGraceMs = None Natural }
