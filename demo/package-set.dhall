-- demo/package-set.dhall — the in-browser userland demo package set.
-- Same package NAMES + dependency shape as m3/package-set.dhall (the real
-- self-hosting set), but every recipe is PURE-FILESYSTEM (Mkdir/Touch/Echo) so
-- the REAL fxstore runs it unmodified in the browser: no bwrap, no fork/exec —
-- only fxstore's trusted in-process actions (build.c run_action pure-FS arm).
-- On a real host, swap in m3/package-set.dhall and every command in the demo
-- behaves identically, with cosmocc Shell recipes sandboxed under bwrap.
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
let Src = < Path : Text | Fetch : { url : Text, hash : Text } >
let Build = { target : Text, recipe : List Action }
let Package = { name : Text, version : Text, src : Src, deps : List Text,
                excludes : List Text, build : Build }
let PackageSet = { packages : List Package }
in  { packages =
      [ { name = "dhake", version = "0.1.0", src = < Path = "src/dhake" >,
          deps = [] : List Text, excludes = [] : List Text,
          build = { target = "dhake",
                    recipe = [ < Mkdir = "bin" >, < Touch = "bin/dhake" >,
                               < Echo = "built dhake (pure-FS demo recipe)" > ] } }
      , { name = "fxstore", version = "0.1.0", src = < Path = "src/fxstore" >,
          deps = [] : List Text, excludes = [] : List Text,
          build = { target = "fxstore",
                    recipe = [ < Mkdir = "bin" >, < Touch = "bin/fxstore" >,
                               < Echo = "built fxstore (pure-FS demo recipe)" > ] } }
      , { name = "fake-service", version = "0.1.0", src = < Path = "src/fake-service" >,
          deps = [] : List Text, excludes = [] : List Text,
          build = { target = "fakesvc",
                    recipe = [ < Mkdir = "bin" >, < Touch = "bin/fakesvc" >,
                               < Echo = "built fake-service (pure-FS demo recipe)" > ] } }
      , { name = "fx-init", version = "0.1.0", src = < Path = "src/fx-init" >,
          deps = [ "dhake", "fxstore" ], excludes = [] : List Text,
          build = { target = "fx-init",
                    recipe = [ < Mkdir = "bin" >, < Touch = "bin/fx-init" >,
                               < Echo = "built fx-init (pure-FS demo recipe)" > ] } }
      , { name = "fxctl", version = "0.1.0", src = < Path = "src/fxctl" >,
          deps = [ "fx-init" ], excludes = [] : List Text,
          build = { target = "fxctl",
                    recipe = [ < Mkdir = "bin" >, < Touch = "bin/fxctl" >,
                               < Echo = "built fxctl (pure-FS demo recipe)" > ] } }
      , { name = "fx-activate", version = "0.1.0", src = < Path = "src/fx-activate" >,
          deps = [ "fxstore", "fx-init" ], excludes = [] : List Text,
          build = { target = "fx-activate",
                    recipe = [ < Mkdir = "bin" >, < Touch = "bin/fx-activate" >,
                               < Echo = "built fx-activate (pure-FS demo recipe)" > ] } }
      ]
    } : PackageSet
