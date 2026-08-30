-- Dhakefile.dhall — build of the fixpoint-linux M4 init system (Zig).
--
--   ./vendor/dhake/dhake.com            # default target: all (build + test)
--   ./vendor/dhake/dhake.com fx-init    # the Zig build (also fx-activate/fxctl/fakesvc)
--   ./vendor/dhake/dhake.com test       # zig unit tests + the 7 diff harnesses
--   ./vendor/dhake/dhake.com clean      # remove build outputs
--
-- The C oracles (src/fx-init.c, src/fx-activate.c, src/fxctl.c, src/config.c
-- and the fx_log/fx_probe/fx_reloc/fx_supervise twins) were removed after
-- their Zig ports were verified byte-identical by live differential
-- harnesses; those harnesses now regression-test the Zig implementations
-- against the pinned goldens in zig/golden/ (captured from the verified C
-- behavior, see each zig/*_diff.sh header).  The production binaries are
-- the Zig build (zig/build.zig):
--
--   fx-init      — lean PID1/supervisor (U-C1); links fxstore_c (vendored C
--                  fxstore + dhall-c core) + the datalog-dafsa/dafsa engine,
--                  NO dhall-c link beyond what packageset needs.
--   fx-activate  — activation tool (U-B); drives fxstore_c through the
--                  extern block in activate.zig.
--   fxctl        — pure-POSIX control/query client (U-D).
--   fakesvc      — test fixture service (tests/fixtures/fakesvc/fakesvc.c,
--                  kept C — it is a fixture the harness compiles, not an
--                  oracle).
--
-- NOTE: this repo vendors dafsa as a TOP-LEVEL submodule (vendor/dafsa/),
-- NOT under vendor/datalog-dafsa/vendor/ as fxstore does.

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

-- the Zig port build (all production binaries land in zig/zig-out/bin/)
let zig_build = "cd zig && zig build -Doptimize=ReleaseSafe"

-- the zig module unit tests (config/reloc/supervise/log/probe/fxctl/
-- activate/init test blocks in build.zig)
let zig_test = "cd zig && zig build test"

in  { default = "all"
    , targets =
        [ { mapKey = "fx-init"
          , mapValue =
              { deps = [ "zig/src/init.zig", "zig/src/activate.zig", "zig/src/fxctl.zig" ]
              , phony = False
              , recipe = [ < Shell = "${zig_build}" > ]
              }
          }
        , { mapKey = "fx-activate"
          , mapValue =
              { deps = [ "zig/src/activate.zig" ]
              , phony = False
              , recipe = [ < Shell = "${zig_build}" > ]
              }
          }
        , { mapKey = "fxctl"
          , mapValue =
              { deps = [ "zig/src/fxctl.zig" ]
              , phony = False
              , recipe = [ < Shell = "${zig_build}" > ]
              }
          }
        , { mapKey = "fakesvc"
          , mapValue =
              { deps = [ "tests/fixtures/fakesvc/fakesvc.c" ]
              , phony = False
              , recipe =
                  [ < Shell =
                        "zig cc -std=gnu11 -O2 -g -Wall -Wextra "
                        ++ "-o fakesvc tests/fixtures/fakesvc/fakesvc.c"
                  >
                  ]
              }
          }

        -- ─── tests: zig unit tests + the 7 diff/regression harnesses ─────
        , { mapKey = "zig-test"
          , mapValue =
              { deps = [ "zig/build.zig" ]
              , phony = True
              , recipe = [ < Shell = "${zig_test}" > ]
              }
          }
        , { mapKey = "config-diff"
          , mapValue =
              { deps = [ "zig/config_diff.sh", "zig/src/config.zig" ]
              , phony = True
              , recipe = [ < Shell = "sh zig/config_diff.sh" > ]
              }
          }
        , { mapKey = "reloc-diff"
          , mapValue =
              { deps = [ "zig/reloc_diff.sh", "zig/src/reloc.zig" ]
              , phony = True
              , recipe = [ < Shell = "sh zig/reloc_diff.sh" > ]
              }
          }
        , { mapKey = "supervise-diff"
          , mapValue =
              { deps = [ "zig/supervise_diff.sh", "zig/src/supervise.zig" ]
              , phony = True
              , recipe = [ < Shell = "sh zig/supervise_diff.sh" > ]
              }
          }
        , { mapKey = "fxctl-diff"
          , mapValue =
              { deps = [ "zig/fxctl_diff.sh", "zig/src/fxctl.zig" ]
              , phony = True
              , recipe = [ < Shell = "sh zig/fxctl_diff.sh" > ]
              }
          }
        , { mapKey = "log-probe-diff"
          , mapValue =
              { deps = [ "zig/log_probe_diff.sh", "zig/src/log.zig", "zig/src/probe.zig" ]
              , phony = True
              , recipe = [ < Shell = "sh zig/log_probe_diff.sh" > ]
              }
          }
        , { mapKey = "activate-diff"
          , mapValue =
              { deps = [ "zig/activate_diff.sh", "zig/src/activate.zig" ]
              , phony = True
              , recipe = [ < Shell = "sh zig/activate_diff.sh" > ]
              }
          }
        , { mapKey = "init-diff"
          , mapValue =
              { deps = [ "zig/init_diff.sh", "zig/src/init.zig" ]
              , phony = True
              , recipe = [ < Shell = "sh zig/init_diff.sh" > ]
              }
          }
        , { mapKey = "test"
          , mapValue =
              { deps =
                  [ "zig-test"
                  , "config-diff"
                  , "reloc-diff"
                  , "supervise-diff"
                  , "fxctl-diff"
                  , "log-probe-diff"
                  , "activate-diff"
                  , "init-diff"
                  ]
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

        -- ─── all / clean ────────────────────────────────────────────────────
        , { mapKey = "all"
          , mapValue =
              { deps = [ "fx-init", "test" ]
              , phony = True
              , recipe = [] : List Action
              }
          }
        , { mapKey = "clean"
          , mapValue =
              { deps = [] : List Text
              , phony = True
              , recipe =
                  [ < Rm = { path = "build-tmp", recursive = True } >
                  , < Rm = { path = "zig/zig-out", recursive = True } >
                  , < Rm = "fakesvc" >
                  ]
              }
          }
        ]
    } : { default : Text, targets : List { mapKey : Text, mapValue : Target } }
