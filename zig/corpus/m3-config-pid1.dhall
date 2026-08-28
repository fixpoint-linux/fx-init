-- m3/config-pid1.dhall — used by tests/fxinit_pid1.sh: a GENUINE-PID1 boot.
--
-- heartbeat + pid1probe start immediately and stay up, so boot-ok lands at
-- bootGraceMs (5000ms).  pid1probe reports which process holds PID 1 in the
-- namespace (/proc/1/comm); it must be "fx-init" to prove fx-init is real PID1.
--
-- The `daemon` service exercises orphan adoption: it double-forks a daemon
-- grandchild that outlives its tracked direct child.  Its direct child holds
-- `hold`=7s (after the 5s grace) so the boot-ok rule (every service STARTED at
-- grace-end) is satisfied before it exits; the orphan grandchild is then
-- adopted by fx-init (PID1) and must be REAPED when it exits (verified by the
-- fixture's own watchdog, writing /run/fx/daemon.{pid,report}).
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox"
    , packages =
        [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service",
          "fake-service-daemon"
        ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "heartbeat", argv = [ "fakesvc", "ok" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        , { name = "pid1probe", argv = [ "fakesvc_daemon", "pid1" ],
            pkg = Some "fake-service-daemon",
            on = "all", restart = Some "always", backoffMs = Some 500,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        , { name = "daemon",
            argv =
              [ "fakesvc_daemon", "daemon", "7", "8",
                "/run/fx/daemon.pid", "/run/fx/daemon.report"
              ]
            , pkg = Some "fake-service-daemon", on = "all", restart = Some "never",
            backoffMs = Some 1000,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 5000
    }
