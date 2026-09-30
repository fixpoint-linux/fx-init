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

## The pinned kernel (image input)

The bootable image does NOT use the build host's kernel. `scripts/kernel-pin.txt`
pins a fetchable artifact — an openSUSE `kernel-default-base` RPM — and
`scripts/fetch-kernel.sh` downloads it, verifies the RPM sha256, extracts
vmlinuz + the five disk-path modules (crc16, mbcache, jbd2, ext4, virtio_blk) + the
kernel config into `.kernel-cache/` (gitignored; override with `FX_KERNEL_CACHE`),
and verifies the extracted vmlinuz sha256. The QEMU harnesses call it and skip
loudly (77) when offline — there is deliberately no host-kernel fallback.

**Known limitation:** openSUSE prunes old packages from
`download.opensuse.org` (the previously pinned 7.1.8 build is already gone),
so this URL will eventually 404 and the pin will need moving. The durable
fix — not done yet — is to host a trimmed ~19 MB artifact (vmlinuz + the 4
modules + config) as a release asset in a fixpoint-linux repo and pin that
instead.

## Architecture

See the org design [`DESIGN.md`](https://github.com/fixpoint-linux/fixpoint-linux/blob/main/DESIGN.md)
(§3.3, §9 M4, §10). Design + decisions are recorded in the knowledge graph under
`fixpoint-linux M4 init system design (fx-init)`.
