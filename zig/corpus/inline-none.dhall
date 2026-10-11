-- inline-none.dhall — inlinePackages = None (List Package): the DECLARED
-- "this system has no agent-authored packages" state.  Absent, None, and []
-- all load as an empty list; unlike agentService the absence is not a
-- silent hole, because a package that does not exist cannot be built.
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
    , packages = [ "dhake" ] : List Text
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
    , inlinePackages = None (List Package)
    }
