-- m3/config-flapper.dhall — used by tests/qemu_guardrail.sh: content that
-- is good ONCE then bad forever.  flapper = fakesvc flapper /fx/disk/.flap-marker:
-- the marker lives on the DISK OUTSIDE the store, so it survives rollback
-- (store relations only) and adopt (rm -rf of the store dir only) — every
-- recovery that republishes this content re-breaks, the deterministic
-- stand-in for "an actor inside the restored bracket re-breaks the system".
-- Grace 8s so the exit lands inside it even when materialization is slow.
let Probe = < Tcp : Natural | Unix : Text | File : Text >
let Service = { name : Text, argv : List Text, pkg : Optional Text, on : Text,
                restart : Optional Text, backoffMs : Optional Natural,
                probe : Optional Probe,
                env : Optional (List { key : Text, value : Text }) }
let User = { name : Text, uid : Natural, groups : List Text }
in  { hostname = "fixbox"
    , packages = [ "dhake", "fx-init", "fxctl", "fx-activate", "fake-service" ]
    , users = [ { name = "root", uid = 0, groups = [] : List Text } ]
    , services =
        [ { name = "flapper", argv = [ "fakesvc", "flapper", "/fx/disk/.flap-marker" ], pkg = Some "fake-service",
            on = "all", restart = Some "always", backoffMs = Some 200,
            probe = None Probe,
            env = None (List { key : Text, value : Text }) }
        ]
    , extraEtc = None (List { path : Text, content : Text })
    , bootGraceMs = Some 8000
    }
