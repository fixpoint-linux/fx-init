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
-- The fx-init/fx-activate/fxctl packages build the ZIG PORT (the C oracles
-- were removed once the ports were verified); their recipes run `zig build`
-- over THIS repo's own tree, which carries the engine and the store core as
-- submodules (vendor/datalog-dafsa, vendor/fxstore).  The engine is compiled
-- IN-GRAPH into a static libdatalog.a (zig/build.zig), so no package links
-- another checkout's build output and there is no runtime .so to stage.
-- dhall-c is the one remaining sibling read: it is modeled as a DEP (like
-- datalog-dafsa and fxstore) — each dep's store path derives from its
-- clean-tree hash, dep store paths feed the dependent's derivation hash, and
-- the recipe points the build at the dep's content-addressed store output via
-- FX_SIB_DHALL_C (see zig/build.zig `sib`) — so a different dhall-c revision
-- yields a different store path AND the fixture compiles exactly the hashed
-- dep content.  Keep `zig` on PATH (tests/prov_e2e.sh + tests/fxinit_boot.sh
-- arrange it).
--
-- HERMETICITY NOTE: the dhall-c/fxstore roots are the deps' store outputs
-- (readable under fxstore's Landlock sandbox spec: store r, workdir rwcx)
-- and every recipe WRITE stays inside the workdir.  The engine needs no
-- outside input at all: it is compiled from the vendored vendor/datalog-dafsa
-- inside the workdir, so the old residual (a .so read from
-- $FX_SIBLINGS/datalog-dafsa/zig-out/lib, which the hermetic sandbox did NOT
-- grant) is gone.  One residual remains: fxstore's startup probe itself — on
-- merged-usr hosts (/bin a symlink) its hermetic bwrap cannot --ro-bind /bin
-- and the fixture build runs via fxstore's sanctioned LOUD non-hermetic
-- fallback (prov_e2e.sh deliberately triggers it).  That belongs to the
-- fxstore repo, not this one.
--
-- NOTE: src paths are RELATIVE to this file (.. = the fx-init repo root,
-- ../vendor/<name> = a vendored submodule).  Both dafsa copies are pinned to
-- the SAME commit: vendor/dafsa (top-level) and vendor/datalog-dafsa/vendor/
-- dafsa (nested — the copy the engine's build actually reads).
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

-- dhall-c C sources (the only C sources any recipe in this set still
-- compiles: the dhake package).  The engine and dafsa C source lists that
-- used to sit here are GONE — the engine has no .c files left at its pinned
-- revision (src/ is headers only) and is built by its own zig build below.
let dhallc =
      "vendor/dhall-c/src/arena.c vendor/dhall-c/src/lexer.c "
      ++ "vendor/dhall-c/src/parser.c vendor/dhall-c/src/ast.c "
      ++ "vendor/dhall-c/src/normalize.c vendor/dhall-c/src/typecheck.c "
      ++ "vendor/dhall-c/src/builtins.c vendor/dhall-c/src/serialize.c "
      ++ "vendor/dhall-c/src/import.c vendor/dhall-c/src/bignum.c "
      ++ "vendor/dhall-c/src/sha256.c vendor/dhall-c/src/ssrf.c "
      ++ "vendor/dhall-c/src/http.c"

in  { packages =
      [ -- ── sibling deps (see header): store paths content-address the
        -- sibling checkouts so the fx-init/* derivations hash their inputs.
        -- Recipe copies the subtrees the build reads; the derivation hash
        -- still walks the WHOLE clean src tree (minus excludes), and the
        -- excludes list only non-inputs (caches, node_modules, docs,
        -- vendored trees this build never reads).
        --
        -- datalog-dafsa IS buildable in-recipe at this pin: its src/ is
        -- HEADERS ONLY and the engine's own `zig build -Drelease` produces
        -- libdatalog.so + libdatalog.a from zig/src/hybrid.zig (the C source
        -- lists this file used to carry cannot work — there are no .c files
        -- left).  The recipe runs exactly that build in the workdir, so this
        -- dep's store path holds a REAL engine build; the dependents do NOT
        -- link it (they compile the same vendored sources in-graph from
        -- their own tree — see zig/build.zig), but this dep's store path
        -- still content-addresses the engine SOURCES, so an engine revision
        -- shifts every dependent's store path.
        { name = "datalog-dafsa", version = "0.1.0", src = < Path = "../vendor/datalog-dafsa" >,
          deps = [] : List Text,
          excludes = [ "node_modules", "elm-stuff", "models", "dl-test-db", "dl-embed",
                        "design", "dlp", "docs", "dist",
                        "vendor/mfe-framework", "vendor/ggml", "vendor/dhake",
                        "vendor/yyjson", "vendor/@mfe", "vendor/design", "vendor/http_client",
                        "zig-out", "zig/zig-out", "zig/.zig-cache", "zig/.zig-global" ],
          build = { target = "out/lib/libdatalog.so",
                    recipe =
                      [ < Shell =
                            "cp -a \"$FX_SRC\"/. . "
                          ++ "&& ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global "
                          ++ "zig build -Drelease -p out --build-file zig/build.zig"
                        > ] } }
      , { name = "dhall-c", version = "0.1.0", src = < Path = "../../dhall-c" >,
          deps = [] : List Text,
          excludes = [ "node_modules", "elm-stuff", "vendor", "docs", "dist",
                        "zig-out", "zig/zig-out", "zig/.zig-cache", "zig/.zig-global" ],
          build = { target = "zig/src/dhall_mod.zig",
                    recipe = [ < Shell = "cp -a \"$FX_SRC\"/zig ." > ] } }
      , { name = "fxstore", version = "0.1.0", src = < Path = "../../fxstore" >,
          deps = [] : List Text,
          excludes = [ "node_modules", "elm-stuff", "vendor", "mfe-framework", "design",
                        "dhake", "shell", "dist",
                        "zig-out", "zig/zig-out", "zig/.zig-cache", "zig/.zig-global" ],
          build = { target = "zig/src/store.zig",
                    recipe = [ < Shell = "cp -a \"$FX_SRC\"/zig ." > ] } }
      -- ── this repo's own packages ──
      , { name = "dhake", version = "0.1.0", src = < Path = "../vendor/dhake" >,
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
          deps = [ "datalog-dafsa", "dhall-c", "fxstore" ],
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist",
                        "zig/.zig-cache", "zig/zig-out", "zig/.zig-global", "zig-out", ".git",
                        "vendor/mfe-framework", "vendor/dhake" ],
          build = { target = "fx-init",
                    recipe =
                      [ < Shell =
                            "cp -a \"$FX_SRC\"/. . && cd zig "
                          ++ "&& FX_SIB_DHALL_C=\"$FX_DEP_DHALL_C\" "
                          ++ "FX_SIB_FXSTORE=\"$FX_DEP_FXSTORE\" "
                          ++ "ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global zig build "
                          ++ "&& cp zig-out/bin/fx-init ../fx-init"
                        > ] } }
      , { name = "fx-activate", version = "0.1.0", src = < Path = ".." >,
          deps = [ "datalog-dafsa", "dhall-c", "fxstore" ],
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist",
                        "zig/.zig-cache", "zig/zig-out", "zig/.zig-global", "zig-out", ".git",
                        "vendor/mfe-framework", "vendor/dhake" ],
          build = { target = "fx-activate",
                    recipe =
                      [ < Shell =
                            "cp -a \"$FX_SRC\"/. . && cd zig "
                          ++ "&& FX_SIB_DHALL_C=\"$FX_DEP_DHALL_C\" "
                          ++ "FX_SIB_FXSTORE=\"$FX_DEP_FXSTORE\" "
                          ++ "ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global zig build "
                          ++ "&& cp zig-out/bin/fx-activate ../fx-activate"
                        > ] } }
      , { name = "fxctl", version = "0.1.0", src = < Path = ".." >,
          deps = [ "datalog-dafsa", "dhall-c", "fxstore" ],
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist",
                        "zig/.zig-cache", "zig/zig-out", "zig/.zig-global", "zig-out", ".git",
                        "vendor/mfe-framework", "vendor/dhake" ],
          build = { target = "fxctl",
                    recipe =
                      [ < Shell =
                            "cp -a \"$FX_SRC\"/. . && cd zig "
                          ++ "&& FX_SIB_DHALL_C=\"$FX_DEP_DHALL_C\" "
                          ++ "FX_SIB_FXSTORE=\"$FX_DEP_FXSTORE\" "
                          ++ "ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-global zig build "
                          ++ "&& cp zig-out/bin/fxctl ../fxctl"
                        > ] } }
      , { name = "fake-service", version = "0.1.0", src = < Path = ".." >,
          deps = [] : List Text,
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist",
                        "zig/.zig-cache", "zig-out", ".git",
                        "vendor/mfe-framework", "vendor/dhake" ],
          build = { target = "fakesvc",
                    recipe =
                      [ < Shell =
                            "cp -a \"$FX_SRC\"/. . && cosmocc -std=c11 -O2 -g -Wall -Wextra "
                          ++ "-o fakesvc tests/fixtures/fakesvc/fakesvc.c"
                        > ] } }
      , { name = "fake-service-daemon", version = "0.1.0", src = < Path = ".." >,
          deps = [] : List Text,
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist",
                        "zig/.zig-cache", "zig-out", ".git",
                        "vendor/mfe-framework", "vendor/dhake" ],
          build = { target = "fakesvc_daemon",
                    recipe =
                      [ < Shell =
                            "cp -a \"$FX_SRC\"/. . && cosmocc -std=c11 -O2 -g -Wall -Wextra "
                          ++ "-o fakesvc_daemon tests/fixtures/fakesvc_daemon/fakesvc_daemon.c"
                        > ] } }
      ] }
  : PackageSet
