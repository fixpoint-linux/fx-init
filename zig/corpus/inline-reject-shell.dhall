-- inline-reject-shell.dhall — agent-declared package whose recipe carries a
-- Shell action.  Shell is `<shell> -c <arbitrary text>` (fxstore build.zig
-- run_shell): one action that dissolves every other bound, so it is outside
-- the agent-authorable subset (§6a A).  Host-frozen package sets keep it;
-- this config must be REFUSED, naming the package, the action index and
-- tag, and the rule.
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
                 src = < Path = "/fx/disk/agent-src/agentsvc" >,
                 deps = [] : List Text,
                 build = { target = "agentsvc", recipe =
                   [ < Mkdir = "out" >
                   , < Shell = "make all" >
                   ] : List Action } } ] : List Package
    }
