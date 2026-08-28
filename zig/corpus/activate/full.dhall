-- full.dhall — unit-5 diff fixture: users+groups (incl. the supplementary-gid
-- rule: "wheel" gets gid from its first claiming user; "root" is skipped as a
-- user's primary group), extraEtc, env, probes, every on= variant, pkg'd +
-- non-pkg'd services, up: cross-reference.
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox-diff"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fakesvc" ]
    , users =
        [ { name = "root", uid = 0, groups = [ "root" ] : List Text }
        , { name = "al", uid = 1000, groups = [ "wheel", "root" ] : List Text }
        ]
    , services =
        [ { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fakesvc",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        , { name = "ready", argv = [ "/bin/sh", "-c", "echo hi" ], pkg = None Text,
            on = "sock:tcp:4053", restart = Some "on-failure",
            backoffMs = None Natural, probe = Some (< File = "/run/ready" > : Probe),
            env = None (List { key : Text, value : Text }) }
        , { name = "unixy", argv = [ "fakesvc", "unix" ], pkg = Some "fakesvc",
            on = "sock:unix:/run/x.sock", restart = Some "never",
            backoffMs = Some 250, probe = Some (< Unix = "/run/x.sock" > : Probe),
            env = Some [ { key = "K", value = "V" } ]
              : Optional (List { key : Text, value : Text }) }
        , { name = "gated", argv = [ "fakesvc", "gated" ], pkg = Some "fakesvc",
            on = "up:heartbeat", restart = Some "on-failure",
            backoffMs = None Natural, probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        , { name = "timed", argv = [ "/bin/true" ], pkg = None Text,
            on = "time:250", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        , { name = "netty", argv = [ "/bin/true" ], pkg = None Text,
            on = "net", restart = Some "on-failure", backoffMs = None Natural,
            probe = Some (< Tcp = 7 > : Probe),
            env = None (List { key : Text, value : Text }) }
        ]
    , extraEtc =
        Some [ { path = "motd", content = "hello from fixbox\n" }
             , { path = "issue.net", content = "fixbox diff fixture" }
             ] : Optional (List { path : Text, content : Text })
    , bootGraceMs = Some 4000
    }
