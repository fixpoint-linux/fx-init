module Main exposing (main)

{-| The fx-init documentation site as a plain `Browser.element` app.

This module renders the 6 content pages (landing, boot, supervise, activate,
fxctl, logs) using the shared `Fixpoint.*` design package. It mirrors the
shen / visage / datalog-dafsa docs site structure exactly: one Elm bundle, one
MFE module (`shell/mfe/fx-init-page.js`), and a `{ pathname }` flag that
selects which page to render.

The `/fx-init/demo` page is different: its terminal is the NON-Elm @mfe module
`shell/mfe/fx-init-demo.js` (real fxstore/fx-activate/fxctl/dhall compiled to
WebAssembly over an in-memory /fx/store), mounted by the shell router into the
page's `[data-mfe="fx-init-demo"]` slot entirely client-side — that page is
never Elm-rendered and is not pre-rendered by the SSG. The `Demo` page below
exists so a stray Elm render of that path (and the nav link, which is Elm) has
an honest page to show instead of silently falling back to the landing page.

-}

import Browser
import Fixpoint.Callout
import Fixpoint.Checks
import Fixpoint.Code
import Fixpoint.Cta
import Fixpoint.Footer
import Fixpoint.Headline
import Fixpoint.Hero
import Fixpoint.Nav
import Fixpoint.Section
import Fixpoint.Style
import Html exposing (Attribute, Html, a, b, code, div, em, li, p, span, strong, table, tbody, td, text, th, thead, tr, ul)
import Html.Attributes exposing (attribute, class, href)


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }


type alias Flags =
    { pathname : String }


type Page
    = Landing
    | Boot
    | Supervise
    | Activate
    | Fxctl
    | Logs
    | Demo


type alias Model =
    Page


type Msg
    = NoOp


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( parsePage (stripFxInitPrefix flags.pathname), Cmd.none )


{-| Strip a leading `/fx-init` prefix and any surrounding slashes so the result
is the bare sub-page slug (e.g. `"/fx-init/boot/"` -> `"boot"`, `"/fx-init/"` ->
`""`). Falls back to `""` for `/`.
-}
stripFxInitPrefix : String -> String
stripFxInitPrefix raw =
    let
        withoutPrefix =
            if String.startsWith "/fx-init" raw then
                String.dropLeft (String.length "/fx-init") raw

            else if raw == "/" then
                ""

            else
                raw
    in
    withoutPrefix
        |> String.dropLeft (if String.startsWith "/" withoutPrefix then 1 else 0)
        |> (\s -> if String.endsWith "/" s then String.dropRight 1 s else s)


parsePage : String -> Page
parsePage path =
    case path of
        "" ->
            Landing

        "boot" ->
            Boot

        "supervise" ->
            Supervise

        "activate" ->
            Activate

        "fxctl" ->
            Fxctl

        "logs" ->
            Logs

        "demo" ->
            Demo

        _ ->
            Landing


update : Msg -> Model -> ( Model, Cmd Msg )
update _ model =
    ( model, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.none


view : Model -> Html Msg
view model =
    div [] [ Fixpoint.Style.stylesheet, navView, pageView model, footerView ]



-- Route helpers (absolute hrefs + `data-mfe-route` for in-shell nav)


routeHref : String -> String
routeHref sub =
    "https://fixpointlinux.org/fx-init" ++ sub ++ "/"


routeAttr : String -> Attribute Msg
routeAttr sub =
    attribute "data-mfe-route" ("/fx-init" ++ sub)


docLink : String -> String -> Html Msg
docLink sub label =
    a [ href (routeHref sub), routeAttr sub ] [ text label ]



-- Top nav


navView : Html Msg
navView =
    Fixpoint.Nav.view
        { brand =
            span []
                [ span [ class "fx" ] [ text "fx" ]
                , text "://fx-init"
                ]
        , links =
            [ docLink "" "Overview"
            , docLink "/boot" "Boot"
            , docLink "/supervise" "Supervise"
            , docLink "/activate" "Activate"
            , docLink "/fxctl" "fxctl"
            , docLink "/logs" "Logs"
            , docLink "/demo" "Demo"
            ]
        , extra =
            [ a [ class "home", href "https://fixpointlinux.org/", attribute "data-mfe-route" "/" ] [ text "fixpoint-linux" ]
            ]
        }


pageView : Model -> Html Msg
pageView model =
    case model of
        Landing ->
            landingView

        Boot ->
            bootView

        Supervise ->
            superviseView

        Activate ->
            activateView

        Fxctl ->
            fxctlView

        Logs ->
            logsView

        Demo ->
            demoView


footerView : Html Msg
footerView =
    Fixpoint.Footer.view
        [ text "fx-init source lives in "
        , a [ href "https://github.com/fixpoint-linux/fx-init" ] [ text "github.com/fixpoint-linux/fx-init" ]
        , Fixpoint.Footer.sep
        , text "part of "
        , a [ href "https://fixpointlinux.org" ] [ text "fixpoint-linux" ]
        ]



-- Landing


landingView : Html Msg
landingView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " fx-init "
                , Fixpoint.Hero.dollar
                , text " fx-init"
                , Fixpoint.Hero.blink
                ]
            , title =
                [ text "The running "
                , Fixpoint.Hero.fx [ text "fixpoint-linux" ]
                , text " system"
                ]
            , tagline =
                [ text "the M4 init system — a lean PID1/supervisor with roll-forward rollback · a datalog control/query plane over /run/fx/control.sock · a DAFSA-interned service log DB"
                ]
            }
        , Fixpoint.Section.view
            { id = "thesis"
            , title = "One binary, the whole running system"
            , hint = "// fx-init is PID1 + supervisor + sole writer of runtime state"
            , children =
                [ p []
                    [ text "fx-init is a single cosmocc APE binary with one "
                    , strong [] [ text "poll(2)" ]
                    , text " event loop. It reads the CURRENT store generation, performs boot-status + roll-forward rollback, execs "
                    , Fixpoint.Code.inline "dhake"
                    , text " on the generation's buildfile to materialize the rootfs ("
                    , Fixpoint.Code.inline "/etc"
                    , text ", "
                    , Fixpoint.Code.inline "/bin"
                    , text " symlinks, "
                    , Fixpoint.Code.inline "/run"
                    , text "), then starts and supervises services with readiness, health, restart policy, and backoff."
                    ]
                , p []
                    [ text "It is the "
                    , strong [] [ text "sole writer" ]
                    , text " of the volatile runtime DB and the log DB. The actor model is enforced structurally: "
                    , Fixpoint.Code.inline "dl_open"
                    , text " takes a process-lifetime exclusive "
                    , Fixpoint.Code.inline "fcntl"
                    , text " lock, so the immutable store DB is opened only transiently for reads / rollback / activate — never held. fxctl never opens a DB directly; every query goes through the control socket."
                    ]
                , Fixpoint.Cta.view
                    { body =
                        [ strong [] [ text "How a boot decides ok" ]
                        , text " — activation → generation → Dhakefile → rootfs, then a START-ONLY grace rule, then roll-forward rollback on the next boot."
                        ]
                    , href = routeHref "/boot"
                    , label = "The boot sequence →"
                    , attrs = [ routeAttr "/boot" ]
                    }
                , Fixpoint.Checks.view
                    [ li [] [ b [] [ text "PID1 + supervisor" ], text " — mkdirs run-dir, signal handlers, holds the runtime + log DBs for life, execs dhake, supervises services." ]
                    , li [] [ b [] [ text "Sole writer" ], text " — the only process that ever writes the runtime datalog DB; fxctl queries via the socket, never the DB." ]
                    , li [] [ b [] [ text "Roll-forward rollback" ], text " — a stale in-progress/failed boot for the current version rolls forward to the newest known-good predecessor, monotonically." ]
                    , li [] [ b [] [ text "No Dhall at boot" ], text " — config is evaluated at activation time; fx-init reads service facts back out of the store DB. It links no dhall-c." ]
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "binaries"
            , title = "Four binaries"
            , hint = "// fx-init · fx-activate · fxctl · fx_probe/fx_log"
            , children =
                [ table [ class "features" ]
                    [ thead []
                        [ tr []
                            [ th [] [ text "Binary" ]
                            , th [] [ text "Role" ]
                            ]
                        ]
                    , tbody []
                        [ tr []
                            [ td [ class "name" ] [ text "fx-init" ]
                            , td [] [ text "Lean PID1/supervisor (U-C1). Boot-status + roll-forward rollback, execs dhake to materialize rootfs, supervises services, sole writer of the runtime DB." ]
                            ]
                        , tr []
                            [ td [ class "name" ] [ text "fx-activate" ]
                            , td [] [ text "Build-time activation (U-B). Evaluates ", Fixpoint.Code.inline "config.dhall", text ", computes the closure, emits a per-generation Dhakefile, writes generation facts, publishes a store snapshot." ]
                            ]
                        , tr []
                            [ td [ class "name" ] [ text "fxctl" ]
                            , td [] [ text "The datalog control/query plane (U-D). Pure POSIX client — links nothing from vendor; every request is one line over ", Fixpoint.Code.inline "/run/fx/control.sock", text "." ]
                            ]
                        , tr []
                            [ td [ class "name" ] [ text "fx_probe / fx_log" ]
                            , td [] [ text "The init-hosted probe loop (U-C2) over ", Fixpoint.Code.inline "/proc,/sys", text " and the compact DAFSA-interned service log DB." ]
                            ]
                        ]
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "components"
            , title = "Composed, not built"
            , hint = "// vendored submodules in vendor/"
            , children =
                [ p []
                    [ text "This repo is self-contained — it owns the entire running-system surface and composes the org's proven components as vendored submodules. No glue scripts; each component is a real, independently-built artifact."
                    ]
                , table [ class "features" ]
                    [ thead []
                        [ tr []
                            [ th [] [ text "Component" ]
                            , th [] [ text "Role" ]
                            ]
                        ]
                    , tbody []
                        [ tr [] [ td [ class "name" ] [ text "fxstore" ], td [] [ text "the content-addressed store — store / closure / snapshot primitives." ] ]
                        , tr [] [ td [ class "name" ] [ text "datalog-dafsa" ], td [] [ text "the Datalog / DAFSA engine — runtime + log relations, hybrid search." ] ]
                        , tr [] [ td [ class "name" ] [ text "dafsa" ], td [] [ text "the compact shared-suffix store — log message interning." ] ]
                        , tr [] [ td [ class "name" ] [ text "dhake" ], td [] [ text "the Dhall build runner — rootfs materialization at boot." ] ]
                        , tr [] [ td [ class "name" ] [ text "dhall-c" ], td [] [ text "the config language evaluator — activation." ] ]
                        ]
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "reference"
            , title = "Reference pages"
            , hint = "// boot · supervise · activate · fxctl · logs"
            , children =
                [ ul []
                    [ li [] [ docLink "/boot" "Boot", text " — activation → generation → Dhakefile → rootfs; boot-status; roll-forward rollback." ]
                    , li [] [ docLink "/supervise" "Supervise", text " — the on= readiness graph, restart policy + backoff, START-ONLY boot-ok, reap." ]
                    , li [] [ docLink "/activate" "Activate", text " — config.dhall → closure → per-generation Dhakefile → facts → store snapshot." ]
                    , li [] [ docLink "/fxctl" "fxctl", text " — the datalog control/query plane over /run/fx/control.sock." ]
                    , li [] [ docLink "/logs" "Logs", text " — the probe loop and the DAFSA-interned service log DB." ]
                    ]
                ]
            }
        ]



-- Boot


bootView : Html Msg
bootView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " fx-init "
                , Fixpoint.Hero.dollar
                , text " dhake -f Dhakefile.dhall rootfs"
                , Fixpoint.Hero.blink
                ]
            , title = [ text "Boot" ]
            , tagline = []
            }
        , Fixpoint.Section.view
            { id = "sequence"
            , title = "The pinned boot sequence"
            , hint = "// mkdirs → DBs → bootlog → store facts → dhake → boot_status → main loop"
            , children =
                [ p []
                    [ text "Boot is a fixed, ordered sequence. fx-init mkdirs the run-dir, installs signal handlers ("
                    , Fixpoint.Code.inline "SIGTERM/SIGINT"
                    , text " → shutdown, "
                    , Fixpoint.Code.inline "SIGCHLD"
                    , text " → self-pipe), then holds the runtime DB ("
                    , Fixpoint.Code.inline "state.db"
                    , text ") and the log DB ("
                    , Fixpoint.Code.inline "log.db"
                    , text ") open for the life of the process. It reads the durable "
                    , Fixpoint.Code.inline ".bootlog"
                    , text ", transiently opens the store to read the CURRENT generation's facts AS-OF that version, then execs dhake to materialize the rootfs."
                    ]
                , Fixpoint.Code.block
                    [ text "1. mkdirs run-dir; signal handlers (SIGTERM/SIGINT->shutdown, SIGCHLD->self-pipe)\n"
                    , text "2. dl_open(run-dir/state.db) held for life; declare runtime + probe relations\n"
                    , text "3. fx_log_open(run-dir/log.db) held for life\n"
                    , text "4. read durable <store>/.bootlog (\"<version> <status> <epoch>\")\n"
                    , text "5. transient store open: current v; read gen/svc facts AS-OF v (or rolled-back v')\n"
                    , text "6. boot decision: stale in-progress/failed for v + known-good v'<v -> roll forward\n"
                    , text "7. append .bootlog (v, in-progress, now)\n"
                    , text "8. fork+exec dhake -f <buildfile> rootfs; pipe output to the log DB\n"
                    , text "9. txn: generation_current(v), boot_status(v, in-progress)\n"
                    , text "10. build on= readiness graph, validate, enter main loop"
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "materialize"
            , title = "Materializing the rootfs"
            , hint = "// fork+exec dhake on the generation's buildfile"
            , children =
                [ p []
                    [ text "The stored buildfile embeds the activation-time host store root in its "
                    , Fixpoint.Code.inline "let GEN = \"<host_store>/...\""
                    , text " and every "
                    , Fixpoint.Code.inline "Symlink"
                    , text " "
                    , text "from"
                    , text ". At boot the store may live under a different root (chroot: "
                    , Fixpoint.Code.inline "/fx/store"
                    , text ", or any "
                    , Fixpoint.Code.inline "--store"
                    , text "), so fx-init rewrites that host root to its own store ("
                    , Fixpoint.Code.inline "fx_reloc_rewrite_buildfile"
                    , text ") and execs dhake on the rewritten copy under the run dir. The "
                    , Fixpoint.Code.inline "to"
                    , text " paths ("
                    , Fixpoint.Code.inline "/etc/.../bin/.../run/..."
                    , text ") are absolute and pass through unchanged."
                    ]
                , Fixpoint.Callout.warn
                    [ text "A failed rootfs materialization means the boot can never reach ok: "
                    , Fixpoint.Code.inline "/etc"
                    , text " + "
                    , Fixpoint.Code.inline "/bin"
                    , text " were not materialized. fx-init pins the decision the moment dhake exits non-zero, so the START-ONLY grace rule can never flip boot_status to ok afterward."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "boot-status"
            , title = "boot_status: START-ONLY"
            , hint = "// ok is decided at grace-end, never before"
            , children =
                [ p []
                    [ text "Boot-ok is decided exactly once, at grace-end. Every service must have reached "
                    , strong [] [ text "STARTED" ]
                    , text " and none may have exited during the grace window — a service that crashes during boot is a start-failure, pinned "
                    , Fixpoint.Code.inline "failed"
                    , text " in "
                    , Fixpoint.Code.inline "reap_children"
                    , text ". A hang (a service that never starts) fails via the grace timeout. After boot-ok is decided, health regressions restart in place and never touch boot_status."
                    ]
                , p []
                    [ text "Waiting until grace-end is what closes the race: declaring ok the instant all services are STARTED would race a service that crashes a few hundred milliseconds later, still inside the window. Letting the window elapse lets reap pin any in-window exit as failed before ok can be said."
                    ]
                , Fixpoint.Headline.view
                    [ Fixpoint.Headline.card
                        { n = "1"
                        , title = [ text "config-bad-exit" ]
                        , body = [ p [] [ text "A crasher exits during the grace window → failed via the reap pin. The service keeps restarting per its restart policy; rollback happens on the next boot." ] ]
                        }
                    , Fixpoint.Headline.card
                        { n = "2"
                        , title = [ text "config-bad-hang" ]
                        , body = [ p [] [ text "A gate never comes ready, so a service never starts → failed via the grace-timeout branch. The boot never reaches ok." ] ]
                        }
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "rollforward"
            , title = "Roll-forward rollback"
            , hint = "// monotonic: re-publish a known-good predecessor as a new version"
            , children =
                [ p []
                    [ text "On boot, fx-init reads the durable "
                    , Fixpoint.Code.inline ".bootlog"
                    , text ". If the last boot of the CURRENT version "
                    , Fixpoint.Code.inline "v"
                    , text " was "
                    , Fixpoint.Code.inline "in-progress"
                    , text " or "
                    , Fixpoint.Code.inline "failed"
                    , text ", and a known-good "
                    , Fixpoint.Code.inline "ok"
                    , text " predecessor "
                    , Fixpoint.Code.inline "v' < v"
                    , text " exists in the snapshot versions, fx-init rolls forward: it re-publishes "
                    , Fixpoint.Code.inline "v'"
                    , text "'s full state as a new CURRENT and reads facts AS-OF the new CURRENT. The system stays up; rollback takes effect on the next boot."
                    ]
                , Fixpoint.Callout.note
                    [ text "fx_store_rollback only restores fxstore's own package facts — not the M4 init relations (svc, generation, …) written by fx-activate. Those would otherwise stay as the failed boot's, so the re-published snapshot would carry the wrong service set. fx-init restores the predecessor's M4 facts into the live WAL "
                    , em [] [ text "before" ]
                    , text " the rollback, so its publish captures the predecessor's full state (packages + service set)."
                    ]
                ]
            }
        ]



-- Supervise


superviseView : Html Msg
superviseView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " fx-init "
                , Fixpoint.Hero.dollar
                , text " fxctl status"
                , Fixpoint.Hero.blink
                ]
            , title = [ text "Supervise" ]
            , tagline = []
            }
        , Fixpoint.Section.view
            { id = "readiness"
            , title = "The on= readiness graph"
            , hint = "// all · up:X · net · sock:tcp:port · sock:unix:path · time:ms"
            , children =
                [ p []
                    [ text "A service is "
                    , strong [] [ text "not" ]
                    , text " launched until its "
                    , Fixpoint.Code.inline "on="
                    , text " readiness condition is met, even though it is "
                    , Fixpoint.Code.inline "PENDING"
                    , text ". The gate is evaluated each loop iteration so a service gated on "
                    , Fixpoint.Code.inline "on=up:X"
                    , text " (or a socket / time / net condition) launches the moment X becomes ready."
                    ]
                , table [ class "features" ]
                    [ thead []
                        [ tr [] [ th [] [ text "on=" ], th [] [ text "Ready when" ] ]
                        ]
                    , tbody []
                        [ tr [] [ td [ class "name" ] [ text "all" ], td [] [ text "immediately (default)." ] ]
                        , tr [] [ td [ class "name" ] [ text "up:X" ], td [] [ text "service X has reached ready." ] ]
                        , tr [] [ td [ class "name" ] [ text "net" ], td [] [ text "any non-lo interface is up." ] ]
                        , tr [] [ td [ class "name" ] [ text "sock:tcp:port" ], td [] [ text "a connect to 127.0.0.1:port succeeds." ] ]
                        , tr [] [ td [ class "name" ] [ text "sock:unix:path" ], td [] [ text "a connect to the unix socket path succeeds." ] ]
                        , tr [] [ td [ class "name" ] [ text "time:ms" ], td [] [ text "ms of monotonic boot time have elapsed." ] ]
                        ]
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "restart"
            , title = "Restart policy + backoff"
            , hint = "// always · on-failure · never · doubling cap 30s · 60s-stable reset"
            , children =
                [ p []
                    [ text "On a child exit, fx-init applies the service's restart policy: "
                    , Fixpoint.Code.inline "always"
                    , text " restarts unconditionally, "
                    , Fixpoint.Code.inline "on-failure"
                    , text " only on a non-zero exit, "
                    , Fixpoint.Code.inline "never"
                    , text " leaves it stopped/failed. A restarting service is held in "
                    , Fixpoint.Code.inline "BACKOFF"
                    , text " until its "
                    , Fixpoint.Code.inline "next_start"
                    , text " deadline."
                    ]
                , p []
                    [ text "Backoff is in "
                    , strong [] [ text "milliseconds" ]
                    , text ": the sleep is "
                    , Fixpoint.Code.inline "fx_backoff_sleep_ms(cur, base)"
                    , text " (base defaults to 1000, capped at 30 s), and the next accumulated backoff is the slept value doubled, capped. A service that stays "
                    , Fixpoint.Code.inline "STARTED"
                    , text " for 60 s without crashing earns a reset of its accumulated backoff to base, so a "
                    , em [] [ text "later" ]
                    , text " crash restarts promptly instead of at the doubled value it had reached during a flappy boot."
                    ]
                , Fixpoint.Callout.warn
                    [ text "An explicitly-stopped service (fxctl stop sets "
                    , code [] [ text "ST_STOPPED" ]
                    , text " before the kill) is excluded from both restart and the boot start-failure accounting — it was intentional, not a crash."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "health"
            , title = "Readiness probes"
            , hint = "// none · tcp · unix · file — the connect contract is shared with on=sock:"
            , children =
                [ p []
                    [ text "A service with a probe stays "
                    , Fixpoint.Code.inline "STARTED"
                    , text " but not "
                    , Fixpoint.Code.inline "ready"
                    , text " until its probe succeeds. A service with no probe is ready the moment it is STARTED. The "
                    , Fixpoint.Code.inline "tcp"
                    , text " / "
                    , Fixpoint.Code.inline "unix"
                    , text " probes share the exact connect contract with "
                    , Fixpoint.Code.inline "on=sock:tcp/unix"
                    , text " — a successful connect means the service is accepting."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "reap"
            , title = "Reap + the start-failure pin"
            , hint = "// a grace-window exit is a start-failure, pinned failed"
            , children =
                [ p []
                    [ text "A single "
                    , Fixpoint.Code.inline "waitpid(-1, WNOHANG)"
                    , text " drain reaps every child. For a reaped service, fx-init records the exit, applies the restart policy, and — if the exit happened during the boot grace window and the service was not explicitly stopped — pins "
                    , Fixpoint.Code.inline "boot_status"
                    , text " failed and sets "
                    , Fixpoint.Code.inline "g_boot_decided"
                    , text " so "
                    , Fixpoint.Code.inline "evaluate_boot_ok"
                    , text " can never flip it to ok. After boot-ok, exits restart in place and never touch boot_status."
                    ]
                ]
            }
        ]



-- Activate


activateView : Html Msg
activateView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " fx-activate "
                , Fixpoint.Hero.dollar
                , text " fx-activate --config config.dhall"
                , Fixpoint.Hero.blink
                ]
            , title = [ text "Activate" ]
            , tagline = []
            }
        , Fixpoint.Section.view
            { id = "flow"
            , title = "Build-time activation"
            , hint = "// config.dhall → closure → Dhakefile → facts → snapshot"
            , children =
                [ p []
                    [ text "fx-activate is the build-time tool that turns a "
                    , Fixpoint.Code.inline "config.dhall"
                    , text " into a bootable generation. It evaluates the config (dhall-c), loads the package set, computes the dependency closure, verifies every closure package is built, and requires "
                    , Fixpoint.Code.inline "dhake"
                    , text ", "
                    , Fixpoint.Code.inline "fx-init"
                    , text ", "
                    , Fixpoint.Code.inline "fxctl"
                    , text " and "
                    , Fixpoint.Code.inline "fx-activate"
                    , text " in the closure."
                    ]
                , Fixpoint.Code.block
                    [ text "1. fx_packageset_load + fx_config_load(config.dhall)\n"
                    , text "2. fx_store_open\n"
                    , text "3. compute_paths (closure over config.packages)\n"
                    , text "4. verify every closure package is BUILT (store fact + stat dir)\n"
                    , text "5. resolve each service argv[0] against its pkg's store path + target\n"
                    , text "6. render the generation in memory (Dhakefile + etc/* + bin symlinks)\n"
                    , text "7. gen hash = sha256_hex over a canonical serialization\n"
                    , text "8. write + rename to <root>/<genhash>-system-generation (adopt if exists)\n"
                    , text "9. declare + txn_add_fact the generation facts; dl_publish_snapshot\n"
                    , text "10. print \"activated <genhash> as version <v>; buildfile <path>\""
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "buildfile"
            , title = "The per-generation Dhakefile"
            , hint = "// /etc files via Copy + Chmod, /bin via Rm+Symlink, all targets phony"
            , children =
                [ p []
                    [ text "The emitted Dhakefile is a small, validated template. "
                    , Fixpoint.Code.inline "/etc"
                    , text " files are copied from the generation dir with "
                    , Fixpoint.Code.inline "Copy{from=GEN/etc/<f>}"
                    , text " and always followed by "
                    , Fixpoint.Code.inline "Chmod"
                    , text " (umask independence). Every "
                    , Fixpoint.Code.inline "/bin"
                    , text " symlink is preceded by "
                    , Fixpoint.Code.inline "Rm<Plain>"
                    , text " — dhake's bare "
                    , Fixpoint.Code.inline "symlink(2)"
                    , text " fails on EEXIST. All targets are phony (always re-asserted)."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "genhash"
            , title = "Content-addressed generations"
            , hint = "// canonical serialization → sha256 → adopt-if-exists"
            , children =
                [ p []
                    [ text "The generation hash is "
                    , Fixpoint.Code.inline "sha256"
                    , text " over a canonical serialization: a "
                    , Fixpoint.Code.inline "fxgen-v1"
                    , text " magic, the hostname, the sorted "
                    , Fixpoint.Code.inline "/etc"
                    , text " files, the sorted services (with argv, pkg, on, restart, backoff, probe), and the sorted closure store paths. The same inputs always produce the same hash, so re-activation of an identical config "
                    , em [] [ text "adopts" ]
                    , text " the existing generation dir instead of rebuilding it."
                    ]
                , Fixpoint.Callout.note
                    [ text "Store paths are recorded "
                    , strong [] [ text "store-relative" ]
                    , text " ("
                    , code [] [ text "<hash>-<name>" ]
                    , text ", not "
                    , code [] [ text "<store_root>/<hash>-<name>" ]
                    , text ") so the genhash is independent of the store root. A generation activated against a host temp dir boots identically after the store is relocated to "
                    , code [] [ text "/fx/store" ]
                    , text " in the chroot."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "facts"
            , title = "The generation facts"
            , hint = "// generation · svc · svc_argv · svc_bin · svc_backoff · svc_env · svc_probe · user · boot_grace"
            , children =
                [ p []
                    [ text "fx-activate declares the M4 init relations and writes one self-consistent set of facts per activation — clearing the previous activation's facts first, so a re-activation boots exactly this generation's service set, not the union of all past ones. "
                    , Fixpoint.Code.inline "boot_grace(ms)"
                    , text " is persisted as a raw u32 so fx-init (which cannot read Dhall) honors the per-activation grace timeout from config."
                    ]
                , Fixpoint.Cta.view
                    { body =
                        [ strong [] [ text "How fx-init consumes these facts" ]
                        , text " — at boot it reads them AS-OF the current version (or the rolled-back predecessor) and builds the in-memory service table."
                        ]
                    , href = routeHref "/boot"
                    , label = "The boot sequence →"
                    , attrs = [ routeAttr "/boot" ]
                    }
                ]
            }
        ]



-- fxctl


fxctlView : Html Msg
fxctlView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " fxctl "
                , Fixpoint.Hero.dollar
                , text " fxctl status"
                , Fixpoint.Hero.blink
                ]
            , title = [ text "fxctl" ]
            , tagline = []
            }
        , Fixpoint.Section.view
            { id = "plane"
            , title = "The control / query plane"
            , hint = "// one request line over /run/fx/control.sock"
            , children =
                [ p []
                    [ text "fxctl is a pure POSIX client that links "
                    , strong [] [ text "nothing" ]
                    , text " from vendor. It maps a subcommand to a single newline-terminated request line over "
                    , Fixpoint.Code.inline "$FX_RUN/control.sock"
                    , text " (default "
                    , Fixpoint.Code.inline "/run/fx"
                    , text ") and streams the response lines to stdout, terminating on "
                    , Fixpoint.Code.inline "OK"
                    , text " (exit 0) or "
                    , Fixpoint.Code.inline "ERR <msg>"
                    , text " (exit 1)."
                    ]
                , Fixpoint.Callout.note
                    [ text "fxctl never opens a datalog DB directly. The actor / sole-writer model is enforced structurally: "
                    , code [] [ text "dl_open" ]
                    , text " takes a process-lifetime exclusive "
                    , code [] [ text "fcntl" ]
                    , text " lock, so direct access would block fx-init. Every read goes through the socket."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "subcommands"
            , title = "Subcommands"
            , hint = "// status · q · start/stop/restart · probe · activate · rollback · shutdown · grep · search"
            , children =
                [ table [ class "features" ]
                    [ thead []
                        [ tr [] [ th [] [ text "Subcommand" ], th [] [ text "Action" ] ]
                        ]
                    , tbody []
                        [ tr [] [ td [ class "name" ] [ text "status" ], td [] [ text "composed boot_status + generation_current + service_runtime snapshot." ] ]
                        , tr [] [ td [ class "name" ] [ text "q <rel> [v..]" ], td [] [ text "runtime relation query (all tuples, or a bound prefix)." ] ]
                        , tr [] [ td [ class "name" ] [ text "start|stop|restart <svc>" ], td [] [ text "service control; recorded as a control(txn,cmd,target) fact." ] ]
                        , tr [] [ td [ class "name" ] [ text "probe" ], td [] [ text "refresh the OS probe relations now." ] ]
                        , tr [] [ td [ class "name" ] [ text "activate <config>" ], td [] [ text "init forks fx-activate (never shell system()); prints the new version." ] ]
                        , tr [] [ td [ class "name" ] [ text "rollback <v>" ], td [] [ text "roll-forward to a known-good version; restores its M4 facts first." ] ]
                        , tr [] [ td [ class "name" ] [ text "shutdown" ], td [] [ text "orderly SIGTERM-style shutdown." ] ]
                        , tr [] [ td [ class "name" ] [ text "grep <regex>" ], td [] [ text "log regex search." ] ]
                        , tr [] [ td [ class "name" ] [ text "search <term>.." ], td [] [ text "log full-text AND search." ] ]
                        ]
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "runtime-relations"
            , title = "The runtime relations"
            , hint = "// what fxctl can query"
            , children =
                [ p [] [ text "The runtime DB holds the live, queryable state fx-init writes each loop:" ]
                , table [ class "features" ]
                    [ thead [] [ tr [] [ th [] [ text "Relation" ], th [] [ text "Arity" ] ] ]
                    , tbody []
                        [ tr [] [ td [ class "name" ] [ text "generation_current" ], td [] [ text "1 — the booted version." ] ]
                        , tr [] [ td [ class "name" ] [ text "boot_status" ], td [] [ text "2 — (version, in-progress|ok|failed)." ] ]
                        , tr [] [ td [ class "name" ] [ text "service_runtime" ], td [] [ text "4 — (name, pid, state, restarts)." ] ]
                        , tr [] [ td [ class "name" ] [ text "ready" ], td [] [ text "1 — service names that are ready." ] ]
                        , tr [] [ td [ class "name" ] [ text "control" ], td [] [ text "3 — (txn, cmd, target) audit of control commands." ] ]
                        , tr [] [ td [ class "name" ] [ text "effect" ], td [] [ text "3 — (txn, key, val) command effects." ] ]
                        ]
                    ]
                ]
            }
        ]



-- Logs


logsView : Html Msg
logsView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " fxctl "
                , Fixpoint.Hero.dollar
                , text " fxctl grep 'boot ok'"
                , Fixpoint.Hero.blink
                ]
            , title = [ text "Logs & probes" ]
            , tagline = []
            }
        , Fixpoint.Section.view
            { id = "probe"
            , title = "The init-hosted probe loop"
            , hint = "// process · fs · file · device · kernel · net · env"
            , children =
                [ p []
                    [ text "fx_probe_refresh rebuilds the probe relations from the live system (or a fixture root for tests) inside a single transaction: delete-all existing tuples, then add fresh. fx-init is the sole writer of the runtime DB, so the probe is the only thing that populates these relations."
                    ]
                , table [ class "features" ]
                    [ thead [] [ tr [] [ th [] [ text "Relation" ], th [] [ text "Columns" ] ] ]
                    , tbody []
                        [ tr [] [ td [ class "name" ] [ text "process" ], td [] [ text "pid, ppid, uid, comm, state, rss_kb." ] ]
                        , tr [] [ td [ class "name" ] [ text "fs" ], td [] [ text "path, fstype, total_kb, used_kb, avail_kb." ] ]
                        , tr [] [ td [ class "name" ] [ text "file" ], td [] [ text "path, size, mode, uid, gid, mtime." ] ]
                        , tr [] [ td [ class "name" ] [ text "device" ], td [] [ text "name, major, minor, type, size." ] ]
                        , tr [] [ td [ class "name" ] [ text "kernel" ], td [] [ text "version, release, hostname, uptime_s, load1_x100, mem_total_kb, mem_free_kb." ] ]
                        , tr [] [ td [ class "name" ] [ text "net" ], td [] [ text "iface, addr, mac, state, rx_bytes, tx_bytes." ] ]
                        , tr [] [ td [ class "name" ] [ text "env" ], td [] [ text "key, value." ] ]
                        ]
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "logdb"
            , title = "The DAFSA-interned service log DB"
            , hint = "// a separate datalog DB, held for life by fx-init"
            , children =
                [ p []
                    [ text "The log DB is a "
                    , strong [] [ text "separate" ]
                    , text " datalog DB from the runtime DB, held for life by fx-init. Its single relation is "
                    , Fixpoint.Code.inline "log(ts_epoch_s, svc, level, msg)"
                    , text ". The "
                    , Fixpoint.Code.inline "svc"
                    , text ", "
                    , Fixpoint.Code.inline "level"
                    , text " and "
                    , Fixpoint.Code.inline "msg"
                    , text " strings are interned via "
                    , Fixpoint.Code.inline "dl_intern_str"
                    , text ", so repeated text collapses to one symbol — the DAFSA shared-suffix store means a thousand copies of the same log line cost one message plus a thousand small tuples."
                    ]
                , p []
                    [ text "Service stdout/stderr is piped to init and drained line-buffered into the log DB, so a service's output is searchable through fxctl alongside init's own status lines."
                    ]
                ]
            }
        , Fixpoint.Section.view
            { id = "search"
            , title = "Hybrid log search"
            , hint = "// grep <regex> · search <term> [term..] — full-text AND"
            , children =
                [ p []
                    [ text "Two search modes over the same log DB, both streamed to the fxctl caller as "
                    , Fixpoint.Code.inline "ts<TAB>svc<TAB>level<TAB>msg"
                    , text " lines. "
                    , Fixpoint.Code.inline "grep"
                    , text " runs a regex walk; "
                    , Fixpoint.Code.inline "search"
                    , text " tokenizes terms and uses the auxiliary "
                    , Fixpoint.Code.inline "__postings__(term, msg)"
                    , text " index for a full-text AND query."
                    ]
                , Fixpoint.Callout.note
                    [ text "The log DB rotates: when it exceeds the cap (default 100 000 tuples) fx-init drops the oldest quarter by timestamp, so the log stays bounded without losing recent history."
                    ]
                ]
            }
        ]



-- Demo


{-| The `/fx-init/demo` page. The interactive terminal on the live site is NOT
Elm — it is the non-Elm @mfe module `shell/mfe/fx-init-demo.js`, mounted
client-side into the page's `[data-mfe="fx-init-demo"]` slot (interactive
WASM, so this page is never pre-rendered by the SSG). This Elm view is the
static story: what the terminal really runs, and where to read the details.
-}
demoView : Html Msg
demoView =
    div []
        [ Fixpoint.Hero.view
            { prompt =
                [ Fixpoint.Hero.hash
                , text " fx-init "
                , Fixpoint.Hero.dollar
                , text " fxstore timeline"
                , Fixpoint.Hero.blink
                ]
            , title = [ text "In your browser" ]
            , tagline =
                [ text "the real fxstore · fx-activate · fxctl · dhall, compiled to WebAssembly over an in-memory /fx/store"
                ]
            }
        , Fixpoint.Section.view
            { id = "terminal"
            , title = "A terminal, not a mockup"
            , hint = "// client-side WASM — the VM boots when the page loads"
            , children =
                [ p []
                    [ text "The terminal on this page mounts at load time and builds a real store in a real virtual machine in this tab: it writes the demo package-set, runs "
                    , Fixpoint.Code.inline "fxstore build"
                    , text " and "
                    , Fixpoint.Code.inline "fx-activate"
                    , text ", activates a second generation from a changed config, publishes store snapshots, rolls one back, normalizes a Dhall expression — and lets "
                    , Fixpoint.Code.inline "fxctl"
                    , text " fail honestly, because there is no PID1 and no control socket in a browser."
                    ]
                , p []
                    [ text "One module is one MEMFS — one virtual machine — so "
                    , Fixpoint.Code.inline "/fx/store"
                    , text " genuinely persists across the commands you type. The story behind each command:"
                    ]
                , ul []
                    [ li [] [ docLink "/activate" "Activate", text " — config.dhall → closure → generation → store snapshot." ]
                    , li [] [ docLink "/boot" "Boot", text " — the boot sequence the activation feeds: boot_status, roll-forward rollback." ]
                    , li [] [ docLink "/fxctl" "fxctl", text " — the control/query plane the demo's fxctl cannot reach — and why." ]
                    ]
                ]
            }
        ]
