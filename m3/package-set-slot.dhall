-- m3/package-set-slot.dhall — the SLOT PACKAGE SET for the first
-- self-modification task's ground (fx-harness todo.md §5, "the deployment
-- pre-declares a SLOT").  This is a SIBLING of package-set.dhall, not a
-- change to it: the self-hosting set stays untouched, and the two are never
-- mixed (a closure is activated from exactly one set).
--
-- WHAT A SLOT IS.  The agent may not write the package set (the closed
-- write set, FX_AGENT_WRITABLE, defaults to ONE path and that is
-- deliberate), so the component it authors enters the closure only through
-- a package whose src.path is a directory the DEPLOYMENT names and the
-- AGENT fills: `oslot` below.  The agent supplies SOURCE ONLY (one .elm
-- file); the package set, the recipe, and everything else that turns that
-- source into a runnable artifact are HOST-FROZEN — they are this file,
-- which the agent cannot reach.
--
-- THE RECIPE IS A STUB, AND SAYS SO AT THE ARTIFACT.  There is no
-- Osier→Lua compiler yet (todo.md §5: the Lua backend is not ready), so
-- the recipe does NOT compile: it installs the agent's source BESIDE a
-- host-written busybox-sh stand-in runner plus a STUB-NOTE file, and the
-- note + the runner's own first lines label the artifact a stub and say
-- why.  When the backend lands, this recipe becomes the real compile step
-- and svc_bin points at the produced Lua artifact running under the
-- in-guest LuaJIT — until then NOTHING here may be read as an Osier
-- toolchain.  (The guest LuaJIT artifact that exists is i386 and the
-- qemu lane's pinned kernel has CONFIG_IA32_EMULATION unset, so it cannot
-- exec there at all; the v86 lane is where that shape belongs.)
--
-- WHY `oslot` HAS NO DEPS — LOAD-BEARING, DO NOT ADD ONE CASUALLY.  The
-- derivation hash serialises each dep's FULL store path
-- (fx_derivation_hash_ex), so a dep-carrying package hashes differently
-- under every store root: built on the host and activated in the guest
-- (/fx/disk/store), the two would disagree and the guest's fx-activate
-- would not find the host-built <hash>-oslot dir.  Dep-free, the hash is
-- a function of name/version/src_hash/target/recipe only, and the host
-- build and the in-guest activation agree by construction.
--
-- WHY src.path IS AN ABSOLUTE GUEST PATH.  mkinitramfs -p keeps absolute
-- src paths verbatim, so the image ships this entry pointing INSIDE the
-- machine at /fx/disk/agent-src/oslot: in the guest, the slot's source is
-- PRESENT (the agent wrote it) and fx-activate hashes the live tree —
-- the same bytes the host build read back off the disk, hence the same
-- src_hash and the same <hash>-oslot dir.  The clean-tree hash covers
-- name|type|content only (never mode/mtime), so the round trip through
-- the disk is invisible to it.  The src PATH ITSELF is not part of the
-- derivation hash — only its content hash is — which is what lets the
-- host-side build copy of this set spell the same tree at a host path.
--
-- THE OTHER ENTRIES mirror package-set.dhall with two deliberate
-- differences: (1) `fake-service`'s src is the fakesvc FIXTURE DIRECTORY
-- (one .c file), not this whole repo — the repo tree carries .elm files
-- under vendor/ and would pollute an Osier-share numerator measured over
-- a service that is not Osier at all; (2) `fake-service-daemon` is
-- dropped (the slot ground does not run it).  The harness freezes these
-- trees and rewrites the relative paths to its frozen copies before use,
-- exactly as tests/qemu-agent-observe.sh does for package-set.dhall.
--
-- usage (host build of the slot only — see fx-harness
-- tests/qemu-agent-slot.sh for the full chain):
--   cd <dir with a path-rewritten copy named package-set.dhall>
--   fxstore build --store <store> oslot

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

-- The stub runner's lines, built by printf so the recipe needs no
-- compiler, no dep, and no host path.  IT MUST SURVIVE THE PIVOTED ROOT:
-- fx-init pivots to a tmpfs whose /bin holds ONLY the dhake-materialized
-- links (the pivot binds /lib64 and /usr — MEASURED, pivot_binds), so
-- #!/bin/sh DOES NOT EXIST where services run; the interpreter is
-- /usr/bin/busybox (bound with /usr, shipped by mkinitramfs).  The script
-- uses shell builtins for logic and absolute busybox applet calls; it
-- stays ALIVE through the boot grace window (fx-init pins `failed` for
-- ANY non-console service exit during grace, whatever the status) and
-- writes one marker line to the disk so the harness can prove the
-- artifact EXECUTED, not merely installed.
let stub_runner =
          "printf '%s\\n' '#!/usr/bin/busybox sh' 'd=$(/usr/bin/busybox dirname \"$0\")' "
      ++  "'echo oslot-mcp STUB runner: HOST-FROZEN STAND-IN, not an Osier toolchain.' "
      ++  "'echo oslot-mcp STUB: no Osier-to-Lua compiler exists yet; I sit beside the source.' "
      ++  "'if [ -f \"$d/Mcp.elm\" ]; then echo oslot-mcp STUB: agent source present at $d/Mcp.elm;' "
      ++  "'else echo oslot-mcp STUB: SOURCE MISSING; fi' "
      ++  "'echo oslot-stub-ran >> /fx/disk/oslot-stub-ran' "
      ++  "'zzz() { /usr/bin/busybox sleep 5 && return; i=0; while [ \"$i\" -lt 900000 ]; do i=$((i+1)); done; }' "
      ++  "'while :; do zzz; done' > mcp-stub-runner "
      ++  "&& chmod 755 mcp-stub-runner "
      ++  "&& cp \"$FX_SRC/Mcp.elm\" Mcp.elm "
      ++  "&& printf '%s\\n' "
      ++  "'STUB - this artifact is NOT an Osier toolchain.' "
      ++  "'There is no Osier-to-Lua compiler yet (fx-harness todo.md section 5).' "
      ++  "'The recipe that built this dir installs the agent-authored Mcp.elm' "
      ++  "'beside a host-written stand-in runner to prove the slot plumbing' "
      ++  "'(package -> store -> svc_bin -> service RUNNING) with the compiler' "
      ++  "'absent.  Nothing in here compiles, interprets, or executes Osier.' "
      ++  "> STUB-NOTE"

in  { packages =
      [ -- ── sibling deps (package-set.dhall's shape; hashed, never built
        -- by the slot ground — the harness provisions their store dirs
        -- toolchain-free and fx-activate adopts existing dirs).
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
      -- ── this repo's own packages (fx-activate requires all four in every
      -- closure; only their hashes are consumed in-guest, resolved src-free
      -- from the srcstore facts the host-side activation commits) ──
      , { name = "dhake", version = "0.1.0", src = < Path = "../vendor/dhake" >,
          deps = [] : List Text,
          excludes = [ "dist", "mfe-framework", "node_modules", "elm-stuff" ],
          build = { target = "dhake.com",
                    recipe = [ < Shell = "cp -a \"$FX_SRC\"/. ." > ] } }
      , { name = "fx-init", version = "0.1.0", src = < Path = ".." >,
          deps = [ "datalog-dafsa", "dhall-c", "fxstore" ],
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist",
                        "zig/.zig-cache", "zig/zig-out", "zig/.zig-global", "zig-out", ".git",
                        "vendor/mfe-framework", "vendor/dhake" ],
          build = { target = "fx-init",
                    recipe = [ < Shell = "cp -a \"$FX_SRC\"/. ." > ] } }
      , { name = "fxctl", version = "0.1.0", src = < Path = ".." >,
          deps = [ "datalog-dafsa", "dhall-c", "fxstore" ],
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist",
                        "zig/.zig-cache", "zig/zig-out", "zig/.zig-global", "zig-out", ".git",
                        "vendor/mfe-framework", "vendor/dhake" ],
          build = { target = "fxctl",
                    recipe = [ < Shell = "cp -a \"$FX_SRC\"/. ." > ] } }
      , { name = "fx-activate", version = "0.1.0", src = < Path = ".." >,
          deps = [ "datalog-dafsa", "dhall-c", "fxstore" ],
          excludes = [ "build-tmp", "mfe-framework", "node_modules", "elm-stuff", "dist",
                        "zig/.zig-cache", "zig/zig-out", "zig/.zig-global", "zig-out", ".git",
                        "vendor/mfe-framework", "vendor/dhake" ],
          build = { target = "fx-activate",
                    recipe = [ < Shell = "cp -a \"$FX_SRC\"/. ." > ] } }
      -- fake-service: src is the FIXTURE DIR (one .c file), NOT this repo —
      -- the repo tree carries .elm under vendor/ and would put non-slot
      -- Osier bytes into a component the machine RUNs (the heartbeat),
      -- breaking the 0%-before / non-zero-after asymmetry for a reason
      -- that has nothing to do with the slot.
      , { name = "fake-service", version = "0.1.0",
          src = < Path = "../tests/fixtures/fakesvc" >,
          deps = [] : List Text,
          excludes = [] : List Text,
          build = { target = "fakesvc",
                    recipe = [ < Shell =
                          "cp -a \"$FX_SRC\"/fakesvc.c . && cosmocc -std=c11 -O2 -o fakesvc fakesvc.c" > ] } }
      -- ── THE SLOT ── the one package whose source the AGENT authors.
      -- src.path is the in-guest directory the deployment pre-creates on
      -- the disk and the task's FX_AGENT_WRITABLE names the exact FILE
      -- inside it (the writable set is exact paths, never prefixes).  The
      -- agent's file decides the src_hash; the src_hash decides the store
      -- dir; the store dir is what the generation must contain for
      -- fx-osier-share to move.  The recipe is the STUB above.
      , { name = "oslot", version = "0.1.0",
          src = < Path = "/fx/disk/agent-src/oslot" >,
          deps = [] : List Text,
          excludes = [] : List Text,
          build = { target = "mcp-stub-runner",
                    recipe = [ < Shell = stub_runner > ] } }
      ] }
  : PackageSet
