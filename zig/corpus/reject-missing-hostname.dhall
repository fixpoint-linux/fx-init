let Probe = < Tcp : Natural | Unix : Text | File : Text >
let U = { name : Text, uid : Natural, groups : List Text }
in { packages = [] : List Text, users = [] : List U,
     services = [] : List { name : Text, argv : List Text, pkg : Optional Text, on : Text, restart : Optional Text, backoffMs : Optional Natural, probe : Optional Probe, env : Optional (List { key : Text, value : Text }) },
     extraEtc = None (List { path : Text, content : Text }), bootGraceMs = None Natural }
