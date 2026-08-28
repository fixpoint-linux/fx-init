let Probe = < Tcp : Natural | Unix : Text | File : Text >
let U = { name : Text, uid : Natural, groups : List Text }
in { hostname = "x", packages = [] : List Text, users = [] : List U,
     services = [ { name = "a", argv = ["x"], pkg = None Text, on = "sock:tcp:0", restart = None Text, backoffMs = None Natural, probe = Some < Tcp = 0 >, env = None (List { key : Text, value : Text }) } ],
     extraEtc = None (List { path : Text, content : Text }), bootGraceMs = None Natural }
