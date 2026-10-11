-- inline-reject-fetch.dhall — agent-declared package whose src is a Fetch.
-- A fetch is network egress, and the guest has none (CONFIG_NET unset on
-- the pinned kernel): permitting it here would be a capability hole rather
-- than a shortcut, so an agent package's src must be a Path (§6a A).
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }),
                console : Optional Text }
let User = { name : Text, uid : Natural, groups : List Text }
let Src = < Path : Text | Fetch : { url : Text, hash : Text } >
let Action =
      < Shell : Text
      | Copy : { from : Text, to : Text }
      | Mkdir : Text
      | Rm : Text
      | Touch : Text
      | Move : { from : Text, to : Text }
      | Symlink : { from : Text, to : Text }
      | Chmod : { path : Text, mode : Text }
      | Echo : Text
      | Env : { key : Text, value : Text }
      | Run : { argv : List Text }
      >
let Package = { name : Text, version : Text, src : Src, deps : List Text,
                excludes : List Text, build : { target : Text, recipe : List Action } }
in  { hostname = "fixbox"
    , packages = [] : List Text
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "sh", argv = [ "/usr/fx-core/bin/fxsh" ], pkg = None Text,
            on = "all", restart = Some "never", backoffMs = None Natural,
            probe = None Probe,
            env = None (List { key : Text, value : Text }),
            console = Some "console" } ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 3000
    , agentService = Some "sh"
    , inlinePackages =
        Some [ { name = "agentsvc", version = "1.0",
                 src = < Fetch = { url = "https://example.com/agentsvc-1.0.tar.gz",
                                   hash = "f2ca1bb3c199e6c9eda0f4d1e7bb8b4b0f1b2a3c4d5e6f708192a3b4c5d6e7f8" } >,
                 deps = [] : List Text,
                 build = { target = "agentsvc", recipe =
                   [ < Echo = "x" > ] : List Action } } ] : List Package
    }
