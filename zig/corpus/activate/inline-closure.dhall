-- inline-closure.dhall — the BUILDS control: full.dhall plus a valid
-- agent-declared package that IS a closure root (packages) and is RUN by a
-- service (pkg = Some "agentsvc").  The closure grows to six, the store
-- facts gain its provides/src_of rows, and the generation hash MOVES —
-- the "until it is used" half of the genhash-stability contract.  Its
-- store dir is pre-built by the harness (the hardcoded dir name in
-- activate_diff.sh is this fixture's derivation hash; if the src tree or
-- recipe drifts, activation fails 'not built' and the case goes red).
-- full.dhall — unit-5 diff fixture: users+groups (incl. the supplementary-gid
-- rule: "wheel" gets gid from its first claiming user; "root" is skipped as a
-- user's primary group), extraEtc, env, probes, every on= variant, pkg'd +
-- non-pkg'd services, up: cross-reference.
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox-diff"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fakesvc", "agentsvc" ]
    , users =
        [ { name = "root", uid = 0, groups = [ "root" ] : List Text }
        , { name = "al", uid = 1000, groups = [ "wheel", "root" ] : List Text }
        ]
    , services =
        [ { name = "agentsvc-run", argv = [ "agentsvc", "mcp" ], pkg = Some "agentsvc",
            on = "all", restart = Some "on-failure", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }
        , { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fakesvc",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }
        , { name = "ready", argv = [ "/bin/sh", "-c", "echo hi" ], pkg = None Text,
            on = "sock:tcp:4053", restart = Some "on-failure",
            backoffMs = None Natural, probe = Some (< File = "/run/ready" > : Probe),
            env = None (List { key : Text, value : Text }),
            console = None Text }
        , { name = "unixy", argv = [ "fakesvc", "unix" ], pkg = Some "fakesvc",
            on = "sock:unix:/run/x.sock", restart = Some "never",
            backoffMs = Some 250, probe = Some (< Unix = "/run/x.sock" > : Probe),
            env = Some [ { key = "K", value = "V" } ]
              : Optional (List { key : Text, value : Text }),
            console = None Text }
        , { name = "gated", argv = [ "fakesvc", "gated" ], pkg = Some "fakesvc",
            on = "up:heartbeat", restart = Some "on-failure",
            backoffMs = None Natural, probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }
        , { name = "timed", argv = [ "/bin/true" ], pkg = None Text,
            on = "time:250", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = None Text }
        , { name = "netty", argv = [ "/bin/true" ], pkg = None Text,
            on = "net", restart = Some "on-failure", backoffMs = None Natural,
            probe = Some (< Tcp = 7 > : Probe),
            env = None (List { key : Text, value : Text }),
            console = None Text }
        , { name = "consh", argv = [ "/usr/fx-core/bin/fxsh" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" }
        ]
    , extraEtc =
        Some [ { path = "motd", content = "hello from fixbox\n" }
             , { path = "issue.net", content = "fixbox diff fixture" }
             ] : Optional (List { path : Text, content : Text })
    , bootGraceMs = Some 4000
    , inlinePackages =
        Some [ { name = "agentsvc", version = "1.0",
                 src = < Path = "src/agentsvc" >,
                 deps = [] : List Text, excludes = [] : List Text,
                 build = { target = "agentsvc", recipe =
                   [ < Mkdir = "out" >
                   , < Copy = { from = "Mcp.elm", to = "out/mcp.lua" } >
                 ] } } ]
    , agentService = None Text
    }
