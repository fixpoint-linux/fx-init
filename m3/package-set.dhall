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
-- were removed once the ports were verified); their recipes run `zig build`,
-- which reads THREE SIBLING CHECKOUTS (datalog-dafsa, dhall-c, fxstore).
-- The siblings are modeled as DEPS (datalog-dafsa, dhall-c, fxstore packages
-- below): each dep's store path derives from its clean-tree hash, dep store
-- paths feed the dependent's derivation hash, and the recipe points the build
-- at the deps' content-addressed store outputs via FX_SIB_* (see
-- zig/build.zig `sib`) — so a different sibling revision yields a different
-- store path AND the fixture compiles exactly the hashed sibling content.
-- Keep `zig` on PATH and export FX_SIBLINGS=<dir containing the siblings>
-- (the engine .so input — see the datalog-dafsa note below).
-- tests/prov_e2e.sh + tests/fxinit_boot.sh arrange both.
--
-- HERMETICITY NOTE: the dhall-c/fxstore roots are the deps' store outputs
-- (readable under fxstore's Landlock sandbox spec: store r, workdir rwcx)
-- and every recipe WRITE stays inside the workdir — the old
-- `ln -sfn ... ../../<name>` symlinks outside the workdir are gone.  Two
-- residuals remain: (1) the engine .so is read from
-- $FX_SIBLINGS/datalog-dafsa/zig-out/lib, which the hermetic sandbox does
-- NOT grant (see the datalog-dafsa note below), and (2) fxstore's startup
-- probe itself: on merged-usr hosts (/bin a symlink) its hermetic bwrap
-- cannot --ro-bind /bin and the fixture build runs via fxstore's sanctioned
-- LOUD non-hermetic fallback (prov_e2e.sh deliberately triggers it).  Both
-- belong to the fxstore / datalog-dafsa repos, not this one.
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
      [ -- ── sibling deps (see header): store paths content-address the
        -- sibling checkouts so the fx-init/* derivations hash their inputs.
        -- Recipe copies the subtrees the build reads; the derivation hash
        -- still walks the WHOLE clean src tree (minus excludes), and the
        -- excludes list only non-inputs (caches, node_modules, docs,
        -- vendored trees this build never reads).
        --
        -- datalog-dafsa CANNOT build its libdatalog.so in-recipe: the
        -- engine's own `zig build` is broken at its HEAD (@cImport of
        -- dafsa_internal.h, removed by its 5c7b8cc) and fxstore's clean
        -- walk auto-excludes *.so from src anyway.  The dependents link
        -- the sibling's PREBUILT zig-out/lib/libdatalog.so via
        -- FX_SIB_DATALOG_LIB (an env input, like today); this dep's store
        -- path still content-addresses the sibling SOURCES, so a sibling
        -- revision shifts every dependent's store path.  Closing the last
        -- gap (building the .so in-recipe) needs the sibling repo's build
        -- fixed — out of scope here.
        { name = "datalog-dafsa", version = "0.1.0", src = < Path = "../../datalog-dafsa" >,
          deps = [] : List Text,
          excludes = [ "node_modules", "elm-stuff", "models", "dl-test-db", "dl-embed",
                        "design", "dlp", "docs", "dist",
                        "vendor/mfe-framework", "vendor/ggml", "vendor/dhake",
                        "vendor/yyjson", "vendor/@mfe", "vendor/design", "vendor/http_client",
                        "zig-out", "zig/zig-out", "zig/.zig-cache", "zig/.zig-global" ],
          build = { target = "zig/src/dl.zig",
                    recipe = [ < Shell = "cp -a \"$FX_SRC\"/zig ." > ] } }
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
                            "cp -a \"$FX_SRC\"/. . && cd zig && [ -n \"$FX_SIBLINGS\" ] "
                          ++ "|| { echo m3: FX_SIBLINGS missing; exit 1; } "
                          ++ "&& FX_SIB_DHALL_C=\"$FX_DEP_DHALL_C\" "
                          ++ "FX_SIB_FXSTORE=\"$FX_DEP_FXSTORE\" "
                          ++ "FX_SIB_DATALOG_LIB=\"$FX_SIBLINGS/datalog-dafsa/zig-out/lib\" "
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
                            "cp -a \"$FX_SRC\"/. . && cd zig && [ -n \"$FX_SIBLINGS\" ] "
                          ++ "|| { echo m3: FX_SIBLINGS missing; exit 1; } "
                          ++ "&& FX_SIB_DHALL_C=\"$FX_DEP_DHALL_C\" "
                          ++ "FX_SIB_FXSTORE=\"$FX_DEP_FXSTORE\" "
                          ++ "FX_SIB_DATALOG_LIB=\"$FX_SIBLINGS/datalog-dafsa/zig-out/lib\" "
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
                            "cp -a \"$FX_SRC\"/. . && cd zig && [ -n \"$FX_SIBLINGS\" ] "
                          ++ "|| { echo m3: FX_SIBLINGS missing; exit 1; } "
                          ++ "&& FX_SIB_DHALL_C=\"$FX_DEP_DHALL_C\" "
                          ++ "FX_SIB_FXSTORE=\"$FX_DEP_FXSTORE\" "
                          ++ "FX_SIB_DATALOG_LIB=\"$FX_SIBLINGS/datalog-dafsa/zig-out/lib\" "
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
