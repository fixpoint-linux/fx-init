-- inline-good.dhall — the ADMITTED CONTROL for agent-declared packages
-- (baliveau §6a): one inlinePackages entry whose recipe uses every one of
-- the TEN admitted action kinds (all eleven minus Shell) with an ABSOLUTE
-- Run argv[0], a Path src and no deps.  It must LOAD — this fixture is
-- what proves the subset refusals are a subset and not a blanket refusal.
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
    , inlinePackages =
        Some [ { name = "agentsvc", version = "1.0",
                 src = < Path = "/fx/disk/agent-src/agentsvc" >,
                 deps = [] : List Text, excludes = [ "scratch" ] : List Text,
                 build = { target = "agentsvc", recipe =
                   [ < Mkdir = "out" >
                   , < Copy = { from = "Mcp.elm", to = "out/mcp.lua" } >
                   , < Chmod = { path = "out/mcp.lua", mode = "0755" } >
                   , < Echo = "built" >
                   , < Env = { key = "FX", value = "1" } >
                   , < Touch = "out/stamp" >
                   , < Run = { argv = [ "/usr/fx-agent/bin/luajit", "-b", "Mcp.elm", "out/mcp.lua" ] } >
                   , < Symlink = { from = "out/mcp.lua", to = "mcp" } >
                   , < Move = { from = "out/mcp.lua", to = "out/mcp2.lua" } >
                   , < Rm = "out/stamp" >
                   ] : List Action } }
             , { name = "agentsvc2", version = "0.1",
                 src = < Path = "src/agentsvc2" >,
                 deps = [] : List Text,
                 excludes = [] : List Text,
                 build = { target = "agentsvc2", recipe = [] : List Action } }
             ] : List Package
    }
