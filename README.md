# fx-init — the running fixpoint-linux system

The **M4 init system** for [fixpoint-linux](https://github.com/fixpoint-linux/fixpoint-linux):
a Dhall-specified, self-hosting Linux system. This repo is self-contained — it owns
the entire "running system" surface and composes the org's proven components as
vendored submodules:

- **`fx-init`** — a lean PID1/supervisor (Zig, `zig/zig-out/bin/fx-init`). Reads the CURRENT store
  generation, performs boot-status + roll-forward rollback, execs **dhake** on the
  generation's buildfile to materialize the rootfs (`/etc`, `/bin` symlinks, `/run`),
  starts and supervises services (readiness + health, restart policy, backoff), and
  maintains the live runtime datalog DB. It is the **sole writer** of runtime state.
- **`fx-activate`** — build-time activation. Evaluates `config.dhall` (dhall-c),
  computes the dependency closure, emits a per-generation dhake buildfile, writes
  generation facts, and publishes a store snapshot (one generation).
- **`fxctl`** — the datalog control/query plane. Queries any live relation (joining
  the immutable store DB), hybrid log search, and control (`start|stop|restart|
  activate|rollback|shutdown|probe`) — all datalog-framed over `/run/fx/control.sock`.
- **`fx_probe` / `fx_log`** (Zig modules) — the init-hosted probe loop (process/fs/file/device/
  kernel/net/env from `/proc`,`/sys`) and the compact DAFSA-interned service log DB.

## Components this composes (submodules in `vendor/`)

| Component | Role |
|---|---|
| `fxstore` | the content-addressed store (store/closure/snapshot primitives) |
| `datalog-dafsa` | the Datalog/DAFSA engine (runtime + log relations, hybrid search) |
| `dafsa` | compact shared-suffix store (log message interning) |
| `dhake` | the Dhall build runner (rootfs materialization at boot) |
| `dhall-c` | the config language evaluator (activation) |

## Build (Zig)

```sh
./vendor/dhake/dhake.com            # default target: all — Zig build + tests
./vendor/dhake/dhake.com fx-init    # the Zig build (also fx-activate/fxctl/fakesvc)
./vendor/dhake/dhake.com test       # zig unit tests + the 7 diff harnesses
```

The production binaries are the Zig port (zig/build.zig -> zig/zig-out/bin/).
The former C oracles were removed after the live differential harnesses
verified the ports byte-identical; the harnesses now pin that verified
behavior under zig/golden/ (see each zig/*_diff.sh header).

## Architecture

See the org design [`DESIGN.md`](https://github.com/fixpoint-linux/fixpoint-linux/blob/main/DESIGN.md)
(§3.3, §9 M4, §10). Design + decisions are recorded in the knowledge graph under
`fixpoint-linux M4 init system design (fx-init)`.
