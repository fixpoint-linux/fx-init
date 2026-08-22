-- m3/package-set.dhall — fixpoint-linux fx-init repo self-hosting package set.
--
-- Specifies this repo's own packages as fxstore derivations so the M4 boot
-- harness can build every closure root (dhake, fx-init, fx-activate, fxctl,
-- fake-service) into a store with `fxstore build`.  Each package's src is its
-- whole tree (vendored deps included, so the datalog closure/topo is meaningful
-- without Makefile/Dhakefile changes); the recipe copies $FX_SRC into the
-- workdir and links with cosmocc.
--
-- Usage:  cd fx-init/m3 && fxstore build --store /fx/store   (or any root)
--
-- NOTE: src paths are RELATIVE to this file (.. = the fx-init repo root,
-- ../vendor/<name> = a vendored submodule).  This repo vendors dafsa as a
-- TOP-LEVEL submodule (vendor/dafsa/), not under vendor/datalog-dafsa/vendor/.
-- version values are placeholders.

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

-- shared compile flags (mirror Dhakefile.dhall)
let opt = "-std=c11 -O2 -g -Wall -Wextra -ffunction-sections -fdata-sections -Wl,--gc-sections"
let inc = "-I src -I vendor/fxstore -I vendor/datalog-dafsa/src -I vendor/datalog-dafsa/vendor -I vendor/dafsa -I vendor/dhall-c/src"
let def = "-DFXSTORE_STAGE3_PATH=\\\"/fx/store/share/stage3\\\""

-- datalog-dafsa engine + dafsa (top-level vendor/dafsa) source lists
let engine =
      "vendor/datalog-dafsa/src/intern.c vendor/datalog-dafsa/src/termstore.c "
      ++ "vendor/datalog-dafsa/src/relation.c vendor/datalog-dafsa/src/vrelation.c "
      ++ "vendor/datalog-dafsa/src/tupleset.c vendor/datalog-dafsa/src/parser.c "
      ++ "vendor/datalog-dafsa/src/compiler.c vendor/datalog-dafsa/src/vm.c "
      ++ "vendor/datalog-dafsa/src/snapshot.c vendor/datalog-dafsa/src/regexwalk.c "
      ++ "vendor/datalog-dafsa/src/permindex.c vendor/datalog-dafsa/src/util.c "
      ++ "vendor/datalog-dafsa/src/dl.c vendor/datalog-dafsa/src/iter.c "
      ++ "vendor/datalog-dafsa/src/magic.c vendor/datalog-dafsa/src/topdown.c "
      ++ "vendor/datalog-dafsa/src/analyze.c vendor/datalog-dafsa/src/schema.c "
      ++ "vendor/datalog-dafsa/src/typecheck.c vendor/datalog-dafsa/src/json.c "
      ++ "vendor/datalog-dafsa/src/txnwal.c vendor/datalog-dafsa/src/index.c"
let dafsa =
      "vendor/dafsa/dafsa.c vendor/dafsa/dafsa_state.c vendor/dafsa/dafsa_core.c "
      ++ "vendor/dafsa/dafsa_persist.c vendor/dafsa/dafsa_view.c "
      ++ "vendor/dafsa/dafsa_crc32.c vendor/dafsa/dafsa_wal.c "
      ++ "vendor/dafsa/dafsa_build.c vendor/dafsa/dafsa_rank.c "
      ++ "vendor/dafsa/dafsa_view_rank.c"
let dhallc =
      "vendor/dhall-c/src/arena.c vendor/dhall-c/src/lexer.c "
      ++ "vendor/dhall-c/src/parser.c vendor/dhall-c/src/ast.c "
      ++ "vendor/dhall-c/src/normalize.c vendor/dhall-c/src/typecheck.c "
      ++ "vendor/dhall-c/src/builtins.c vendor/dhall-c/src/serialize.c "
      ++ "vendor/dhall-c/src/import.c vendor/dhall-c/src/bignum.c "
      ++ "vendor/dhall-c/src/sha256.c vendor/dhall-c/src/ssrf.c "
      ++ "vendor/dhall-c/src/http.c"

in  { packages =
      [ { name = "dhake", version = "0.1.0", src = < Path = "../vendor/dhake" >,
          deps = [] : List Text,
          excludes = [ "dist", "mfe-framework", "node_modules", "elm-stuff" ],
          build = { target = "dhake.com",
                    recipe =
                      [ < Shell =
                            "cp -a \"$FX_SRC\"/. . && cosmocc -std=c11 -O2 -g -Wall -Wextra "
                          ++ "-D_POSIX_C_SOURCE=200809L -I vendor/dhall-c/src -o dhake.com "
                          ++ "src/dhake.c " ++ dhallc
                        > ] } }
      , { name = "fx-init", version = "0.1.0", src = < Path = ".." >,
          deps = [] : List Text,
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist" ],
          build = { target = "fx-init",
                    recipe =
                      [ < Shell =
                            "cp -a \"$FX_SRC\"/. . && cosmocc " ++ opt ++ " " ++ def
                          ++ " " ++ inc ++ " -o fx-init src/fx-init.c src/fx_probe.c "
                          ++ "src/fx_log.c vendor/fxstore/store.c "
                          ++ "vendor/fxstore/closure.c vendor/fxstore/build.c "
                          ++ "vendor/fxstore/packageset.c " ++ engine ++ " " ++ dafsa
                        > ] } }
      , { name = "fx-activate", version = "0.1.0", src = < Path = ".." >,
          deps = [] : List Text,
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist" ],
          build = { target = "fx-activate",
                    recipe =
                      [ < Shell =
                            "cp -a \"$FX_SRC\"/. . && cosmocc " ++ opt ++ " " ++ def
                          ++ " " ++ inc ++ " -o fx-activate src/config.c src/fx-activate.c "
                          ++ "vendor/fxstore/packageset.c vendor/fxstore/derivation.c "
                          ++ "vendor/fxstore/closure.c vendor/fxstore/store.c "
                          ++ "vendor/fxstore/build.c " ++ engine ++ " " ++ dafsa
                          ++ " " ++ dhallc
                        > ] } }
      , { name = "fxctl", version = "0.1.0", src = < Path = ".." >,
          deps = [] : List Text,
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist" ],
          build = { target = "fxctl",
                    recipe =
                      [ < Shell =
                            "cp -a \"$FX_SRC\"/. . && cosmocc -std=c11 -O2 -g -Wall -Wextra "
                          ++ "-I src -o fxctl src/fxctl.c"
                        > ] } }
      , { name = "fake-service", version = "0.1.0", src = < Path = ".." >,
          deps = [] : List Text,
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist" ],
          build = { target = "fakesvc",
                    recipe =
                      [ < Shell =
                            "cp -a \"$FX_SRC\"/. . && cosmocc -std=c11 -O2 -g -Wall -Wextra "
                          ++ "-o fakesvc tests/fixtures/fakesvc/fakesvc.c"
                        > ] } }
      ] }
  : PackageSet
