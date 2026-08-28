-- zig/corpus/activate/package-set.dhall — fixture package set for the unit-5
-- differential harness (activate_diff.sh).  Five packages named exactly like
-- the tool check requires (fx-activate.c:557: dhake, fx-init, fxctl,
-- fx-activate) plus fakesvc (service pkg); src = tiny committed fixture trees
-- under src/ (relative to THIS file — packageset.c realpaths them), so the
-- content hashes are STABLE across runs and machines.  Recipe content is
-- irrelevant to activation (never executed); fakesvc deps on fxctl so the
-- closure/topo is non-trivial.

let Src = < Path : Text | Fetch : { url : Text, hash : Text } >
let Action = < Shell : Text >
let Build = { target : Text, recipe : List Action }
let Package = { name : Text, version : Text, src : Src, deps : List Text,
                excludes : List Text, build : Build }
let PackageSet = { packages : List Package }

in  { packages =
        [ { name = "dhake", version = "0.1.0", src = < Path = "src/dhake" >,
            deps = [] : List Text, excludes = [] : List Text,
            build = { target = "dhake.com", recipe = [] : List Action } }
        , { name = "fx-init", version = "0.1.0", src = < Path = "src/fx-init" >,
            deps = [] : List Text, excludes = [] : List Text,
            build = { target = "fx-init", recipe = [] : List Action } }
        , { name = "fxctl", version = "0.1.0", src = < Path = "src/fxctl" >,
            deps = [] : List Text, excludes = [] : List Text,
            build = { target = "fxctl", recipe = [] : List Action } }
        , { name = "fx-activate", version = "0.1.0", src = < Path = "src/fx-activate" >,
            deps = [] : List Text, excludes = [] : List Text,
            build = { target = "fx-activate", recipe = [] : List Action } }
        , { name = "fakesvc", version = "0.1.0", src = < Path = "src/fakesvc" >,
            deps = [ "fxctl" ] : List Text, excludes = [] : List Text,
            build = { target = "fakesvc", recipe = [] : List Action } }
        ] }
  : PackageSet
