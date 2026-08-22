-- Dhakefile.dhall — self-hosting build of the fixpoint-linux M4 init system.
--
--   ./dhake/dhake.com            # default target: fx-init
--   ./dhake/dhake.com fx-activate fxctl fakesvc   # the other binaries
--   ./dhake/dhake.com test        # build + run the in-sandbox unit tests
--   ./dhake/dhake.com clean       # remove the built binaries
--
-- Four cosmocc APE binaries live in this repo:
--   fx-init      — lean PID1/supervisor (U-C1); links fxstore(store,closure,build,
--                  packageset) + datalog-dafsa + dafsa, NO dhall-c.  -ffunction-
--                  sections -Wl,--gc-sections drops packageset's unused dhall-c
--                  runtime calls (fx_packageset_load) so no dhall-c link is needed.
--   fx-activate  — activation tool (U-B); links config.c + fx-activate.c + fxstore
--                  (full) + datalog-dafsa + dafsa + dhall-c (config.dhall eval).
--   fxctl        — pure-POSIX control/query client (U-D); links ONLY src/fxctl.c.
--   fakesvc      — test fixture service; links ONLY tests/fixtures/fakesvc/fakesvc.c.
--
-- NOTE: this repo vendors dafsa as a TOP-LEVEL submodule (vendor/dafsa/), NOT
-- under vendor/datalog-dafsa/vendor/ as fxstore does — the dafsa source paths
-- below reflect that.  cosmocc must be on PATH.

let Action =
      < Shell : Text
      | Copy : { from : Text, to : Text }
      | Mkdir : < Plain : Text | Parents : { path : Text, parents : Bool } >
      | Rm : < Plain : Text | Recursive : { path : Text, recursive : Bool } >
      | Touch : Text
      | Move : { from : Text, to : Text }
      | Symlink : { from : Text, to : Text }
      | Chmod : { path : Text, mode : Text }
      | Echo : Text
      | Env : { key : Text, value : Text }
      | Run : { argv : List Text }
      >

let Target = { deps : List Text, phony : Bool, recipe : List Action }

-- shared compile flags / include dirs
let inc =
      "-I src -I vendor/fxstore -I vendor/datalog-dafsa/src "
      ++ "-I vendor/datalog-dafsa/vendor -I vendor/dafsa -I vendor/dhall-c/src"

let def = "-DFXSTORE_STAGE3_PATH=\\\"/fx/store/share/stage3\\\""

let opt = "-std=c11 -O2 -g -Wall -Wextra -ffunction-sections -fdata-sections -Wl,--gc-sections"

-- datalog-dafsa engine sources (mirror fxstore/Dhakefile.dhall:146-166)
let engine =
      "vendor/datalog-dafsa/src/intern.c "
      ++ "vendor/datalog-dafsa/src/termstore.c "
      ++ "vendor/datalog-dafsa/src/relation.c "
      ++ "vendor/datalog-dafsa/src/vrelation.c "
      ++ "vendor/datalog-dafsa/src/tupleset.c "
      ++ "vendor/datalog-dafsa/src/parser.c "
      ++ "vendor/datalog-dafsa/src/compiler.c "
      ++ "vendor/datalog-dafsa/src/vm.c "
      ++ "vendor/datalog-dafsa/src/snapshot.c "
      ++ "vendor/datalog-dafsa/src/regexwalk.c "
      ++ "vendor/datalog-dafsa/src/permindex.c "
      ++ "vendor/datalog-dafsa/src/util.c "
      ++ "vendor/datalog-dafsa/src/dl.c "
      ++ "vendor/datalog-dafsa/src/iter.c "
      ++ "vendor/datalog-dafsa/src/magic.c "
      ++ "vendor/datalog-dafsa/src/topdown.c "
      ++ "vendor/datalog-dafsa/src/analyze.c "
      ++ "vendor/datalog-dafsa/src/schema.c "
      ++ "vendor/datalog-dafsa/src/typecheck.c "
      ++ "vendor/datalog-dafsa/src/json.c "
      ++ "vendor/datalog-dafsa/src/txnwal.c "
      ++ "vendor/datalog-dafsa/src/index.c"

-- dafsa sources (TOP-LEVEL vendor/dafsa submodule in THIS repo)
let dafsa =
      "vendor/dafsa/dafsa.c "
      ++ "vendor/dafsa/dafsa_state.c "
      ++ "vendor/dafsa/dafsa_core.c "
      ++ "vendor/dafsa/dafsa_persist.c "
      ++ "vendor/dafsa/dafsa_view.c "
      ++ "vendor/dafsa/dafsa_crc32.c "
      ++ "vendor/dafsa/dafsa_wal.c "
      ++ "vendor/dafsa/dafsa_build.c "
      ++ "vendor/dafsa/dafsa_rank.c "
      ++ "vendor/dafsa/dafsa_view_rank.c"

-- dhall-c interpreter core (linked by fx-activate for config.dhall eval)
let dhallc =
      "vendor/dhall-c/src/arena.c "
      ++ "vendor/dhall-c/src/lexer.c "
      ++ "vendor/dhall-c/src/parser.c "
      ++ "vendor/dhall-c/src/ast.c "
      ++ "vendor/dhall-c/src/normalize.c "
      ++ "vendor/dhall-c/src/typecheck.c "
      ++ "vendor/dhall-c/src/builtins.c "
      ++ "vendor/dhall-c/src/serialize.c "
      ++ "vendor/dhall-c/src/import.c "
      ++ "vendor/dhall-c/src/bignum.c "
      ++ "vendor/dhall-c/src/sha256.c "
      ++ "vendor/dhall-c/src/ssrf.c "
      ++ "vendor/dhall-c/src/http.c"

-- fxstore C library (vendored, read-only).  fx-init links the subset it needs
-- (store+closure+build+packageset); fx-activate links the full set (+derivation).
let fxstore_sub =
      "vendor/fxstore/store.c vendor/fxstore/closure.c "
      ++ "vendor/fxstore/build.c vendor/fxstore/packageset.c"
let fxstore_full =
      "vendor/fxstore/packageset.c vendor/fxstore/derivation.c "
      ++ "vendor/fxstore/closure.c vendor/fxstore/store.c vendor/fxstore/build.c"

in  { default = "fx-init"
    , targets =
        [ { mapKey = "fx-init"
          , mapValue =
              { deps =
                  [ "src/fx-init.c", "src/fx_supervise.c", "src/fx_reloc.c", "src/fx_probe.c", "src/fx_log.c"
                  , "src/fx.h", "src/fx_supervise.h", "src/fx_reloc.h", "src/fx_probe.h", "src/fx_log.h", "fxstore.h"
                  ]
              , phony = False
              , recipe =
                  [ < Shell =
                        "cosmocc " ++ opt ++ " " ++ def ++ " " ++ inc
                        ++ " -o fx-init src/fx-init.c src/fx_supervise.c src/fx_reloc.c src/fx_probe.c src/fx_log.c "
                        ++ fxstore_sub ++ " " ++ engine ++ " " ++ dafsa
                    >
                  ]
              }
          }
        , { mapKey = "fx-activate"
          , mapValue =
              { deps =
                  [ "src/fx-activate.c", "src/config.c", "src/fx.h", "fxstore.h"
                  ]
              , phony = False
              , recipe =
                  [ < Shell =
                        "cosmocc " ++ opt ++ " " ++ def ++ " " ++ inc
                        ++ " -o fx-activate src/config.c src/fx-activate.c "
                        ++ fxstore_full ++ " " ++ engine ++ " " ++ dafsa
                        ++ " " ++ dhallc
                    >
                  ]
              }
          }
        , { mapKey = "fxctl"
          , mapValue =
              { deps = [ "src/fxctl.c" ]
              , phony = False
              , recipe =
                  [ < Shell =
                        "cosmocc -std=c11 -O2 -g -Wall -Wextra -I src "
                        ++ "-o fxctl src/fxctl.c"
                    >
                  ]
              }
          }
        , { mapKey = "fakesvc"
          , mapValue =
              { deps = [ "tests/fixtures/fakesvc/fakesvc.c" ]
              , phony = False
              , recipe =
                  [ < Shell =
                        "cosmocc -std=c11 -O2 -g -Wall -Wextra "
                        ++ "-o fakesvc tests/fixtures/fakesvc/fakesvc.c"
                    >
                  ]
              }
          }

        -- ─── tests ──────────────────────────────────────────────────────────
        , { mapKey = "config-test"
          , mapValue =
              { deps = [ "src/config.c", "tests/config_test.c" ]
              , phony = True
              , recipe =
                  [ < Shell =
                        "sh tests/build_unit.sh && ./build-tmp/config_test"
                    >
                  ]
              }
          }
        , { mapKey = "log-test"
          , mapValue =
              { deps = [ "src/fx_log.c", "tests/log_test.c" ]
              , phony = True
              , recipe =
                  [ < Shell = "sh tests/build_log.sh && ./build-tmp/log_test" > ]
              }
          }
        , { mapKey = "probe-test"
          , mapValue =
              { deps = [ "src/fx_probe.c", "tests/probe_test.c" ]
              , phony = True
              , recipe =
                  [ < Shell = "sh tests/build_probe.sh && ./build-tmp/probe_test" > ]
              }
          }
        , { mapKey = "reloc-test"
          , mapValue =
              { deps = [ "src/fx_reloc.c", "tests/reloctest.c" ]
              , phony = True
              , recipe =
                  [ < Shell = "sh tests/build_reloctest.sh && ./build-tmp/reloctest" > ]
              }
          }
        , { mapKey = "supervise-test"
          , mapValue =
              { deps = [ "src/fx_supervise.c", "tests/supervise_test.c" ]
              , phony = True
              , recipe =
                  [ < Shell = "sh tests/build_supervise.sh && ./build-tmp/supervise_test" > ]
              }
          }
        , { mapKey = "activate-test"
          , mapValue =
              { deps = [ "fx-activate", "fakesvc" ]
              , phony = True
              , recipe =
                  [ < Shell = "sh tests/activate.sh ./fx-activate ./build-tmp/fakesvc" > ]
              }
          }
        , { mapKey = "test"
          , mapValue =
              { deps =
                  [ "config-test", "log-test", "probe-test", "reloc-test", "supervise-test", "activate-test" ]
              , phony = True
              , recipe = [] : List Action
              }
          }

        -- ─── docs site (fixpoint design components) ─────────────────────────
        -- The docs site is an Elm app (src/Main.elm) rendered against the shared
        -- Fixpoint.* design package (vendor/design) + the @mfe/framework shell
        -- (vendor/mfe-framework). Pipeline, mirroring shen/visage:
        --
        --   vendor/mfe-framework -> vendor/@mfe -> dist/elm.js -> dist/index.html
        --
        -- The `dist/index.html` target produces the full multi-route site
        -- (dist/index.html + the five sub-page index.html files). Run it
        -- explicitly with `dhake dist/index.html`.
        , { mapKey = "mfe-framework"
          , mapValue =
              { deps = [] : List Text
              , phony = True
              , recipe =
                  [ < Shell = "cd vendor/mfe-framework && npm ci && npm run build" > ]
              }
          }
        , { mapKey = "vendor-mfe"
          , mapValue =
              { deps = [ "mfe-framework" ]
              , phony = True
              , recipe =
                  [ < Rm = { path = "vendor/@mfe", recursive = True } >
                  , < Mkdir = { path = "vendor/@mfe/core", parents = True } >
                  , < Mkdir = { path = "vendor/@mfe/framework", parents = True } >
                  , < Shell =
                        "cp vendor/mfe-framework/packages/core/dist/*.js vendor/@mfe/core/"
                    >
                  , < Shell =
                        "cp vendor/mfe-framework/packages/framework/dist/*.js vendor/@mfe/framework/"
                    >
                  ]
              }
          }
        , { mapKey = "dist/elm.js"
          , mapValue =
              { deps = [ "src/Main.elm", "elm.json", "vendor/design/src" ]
              , phony = False
              , recipe =
                  [ < Shell =
                        "node_modules/elm/bin/elm make src/Main.elm --output=dist/elm.js --optimize"
                    >
                  ]
              }
          }
        , { mapKey = "dist/index.html"
          , mapValue =
              { deps =
                  [ "dist/elm.js"
                  , "vendor-mfe"
                  , "shell/index.html"
                  , "shell/pages.js"
                  , "shell/shell.js"
                  , "shell/templates/fx-init-landing.html"
                  , "shell/templates/fx-init-boot.html"
                  , "shell/templates/fx-init-supervise.html"
                  , "shell/templates/fx-init-activate.html"
                  , "shell/templates/fx-init-fxctl.html"
                  , "shell/templates/fx-init-logs.html"
                  , "shell/mfe/fx-init-page.js"
                  , "scripts/ssg.mjs"
                  ]
              , phony = False
              , recipe = [ < Shell = "node scripts/ssg.mjs" > ]
              }
          }

        -- ─── clean ──────────────────────────────────────────────────────────
        , { mapKey = "clean"
          , mapValue =
              { deps = [] : List Text
              , phony = True
              , recipe =
                  [ < Rm = "fx-init" >
                  , < Rm = "fx-activate" >
                  , < Rm = "fxctl" >
                  , < Rm = "fakesvc" >
                  ]
              }
          }
        ]
    } : { default : Text, targets : List { mapKey : Text, mapValue : Target } }
