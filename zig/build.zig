// build.zig — fx-init Zig port, unit 1: the config walker + differential
// harness.  The dhall-c Zig core is imported as a single module via the
// facade file, EXACTLY as fx-core/build.zig:15-20 (the sibling modules'
// bare-filename imports only resolve when the module root lives in the
// dhall-c zig/src dir).  fx-init's vendored dhall-c has no zig core; the
// canonical one lives in the sibling checkout ../../dhall-c.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dhall_mod = b.createModule(.{
        .root_source_file = b.path("../../dhall-c/zig/src/dhall_mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // config: the FxConfig types + walker + load pipeline (port of src/config.c).
    const config_mod = b.createModule(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dhall", .module = dhall_mod },
        },
    });

    // config_check: the CLI under test (canonical dump, same format as the
    // C oracle zig/config_dump.c).
    const check = b.addExecutable(.{
        .name = "config_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/config_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "config", .module = config_mod },
            },
        }),
    });
    b.installArtifact(check);

    const run_step = b.step("run", "Run config_check");
    const run_cmd = b.addRunArtifact(check);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    // reloc: the buildfile store-root rewrite (port of src/fx_reloc.c) +
    // reloc_check: the CLI under test (same format as the C oracle
    // zig/reloc_dump.c, built by reloc_diff.sh with zig cc).
    const reloc_mod = b.createModule(.{
        .root_source_file = b.path("src/reloc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const reloc_check = b.addExecutable(.{
        .name = "reloc_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/reloc_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "reloc", .module = reloc_mod },
            },
        }),
    });
    b.installArtifact(reloc_check);

    // supervise: the supervision helpers (port of src/fx_supervise.c) +
    // supervise_check: the pure-math sweep twin of zig/supervise_dump.c
    // (fx_sock_ready itself is exercised live by supervise_diff.sh).
    const supervise_mod = b.createModule(.{
        .root_source_file = b.path("src/supervise.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const supervise_check = b.addExecutable(.{
        .name = "supervise_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/supervise_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "supervise", .module = supervise_mod },
            },
        }),
    });
    b.installArtifact(supervise_check);

    // ─── UNIT 3: fx_log + fx_probe ─────────────────────────────────────────
    //
    // The datalog-dafsa + dafsa engine is no longer compiled from the stale
    // vendored C sources: the dl_*/aux_*/tokenize/regex_* externs the Zig
    // ports declare are resolved against the Zig-built libdatalog.so in the
    // sibling ../../datalog-dafsa checkout (linkDatalog, below).  The C
    // headers are still vendored so the C driver log_probe_live.c keeps
    // compiling unchanged.

    // log_port / probe_port: the Zig ports as objects exposing zig_log_* /
    // zig_probe_* to the C live driver (the supervise_extern.o pattern, now
    // inside zig build).  Objects carry no linkage; the driver's final link
    // resolves the dl_* externs against libdatalog.so.
    const log_mod = b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const log_obj = b.addObject(.{ .name = "log_port", .root_module = log_mod });
    // dedicated test module: linking the engine into log_mod itself would
    // pull the dl_* objects twice into the live driver (duplicate symbols)
    const log_test_mod = b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkDatalog(b, log_test_mod);
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const probe_obj = b.addObject(.{ .name = "probe_port", .root_module = probe_mod });
    const probe_test_mod = b.createModule(.{
        .root_source_file = b.path("src/probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    linkDatalog(b, probe_test_mod);

    // log_probe_live: the one-process regression driver (C), linking the
    // Zig port objects and libdatalog.so.  (It used to link the C originals
    // src/fx_log.c + src/fx_probe.c for a live C-vs-Zig diff; the C oracle
    // was removed and the driver now compares against pinned goldens.)
    const live_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    live_mod.addIncludePath(b.path("../vendor/datalog-dafsa/src"));
    live_mod.addCSourceFiles(.{
        .root = b.path(".."),
        .files = &.{
            "zig/log_probe_live.c",
        },
        .flags = &.{ "-std=gnu11", "-O2", "-fno-stack-check" },
    });
    live_mod.addObject(log_obj);
    live_mod.addObject(probe_obj);
    linkDatalog(b, live_mod);
    const live = b.addExecutable(.{ .name = "log_probe_live", .root_module = live_mod });
    b.installArtifact(live);

    // ─── UNIT 4: fxctl (the control/query client) ──────────────────────────
    //
    // fxctl: the port CLI (fxctl_diff.sh execs it against the UNMODIFIED C
    // client over a fake fx-init socket); fxctl_check: the request-line twin
    // of zig/fxctl_dump.c (the builder lives inline in fxctl.c main(), so
    // the oracle is a labeled verbatim copy — the live diff pins the real C
    // main end-to-end).
    const fxctl_mod = b.createModule(.{
        .root_source_file = b.path("src/fxctl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const fxctl_exe = b.addExecutable(.{ .name = "fxctl", .root_module = fxctl_mod });
    b.installArtifact(fxctl_exe);
    const fxctl_check = b.addExecutable(.{
        .name = "fxctl_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fxctl_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "fxctl", .module = fxctl_mod },
            },
        }),
    });
    b.installArtifact(fxctl_check);

    // ─── UNIT 5: fx-activate (build-time activation) ──────────────────────
    //
    // The fxstore store core is NO LONGER compiled from the vendored C (the
    // 5-file store core + the dhall-c interpreter): it is the fxstore Zig
    // port in the sibling ../fxstore checkout (fxstore/zig/src/{packageset,
    // derivation,closure,store,build}.zig), imported as modules and composed
    // exactly as fxstore's own build.zig composes them — ONE shared
    // packageset module so every unit sees a single Package type.  The dl_*
    // externs those modules declare resolve against libdatalog.so at the
    // activate/init final links.  config.zig and the fxstore modules share
    // the SAME dhall Zig core (dhall_mod), so the single `dhall_arena`
    // global replaces the C's renamed `c_dhall_arena` (the C dhall core is
    // gone).
    const packageset_mod = b.createModule(.{
        .root_source_file = b.path("../../fxstore/zig/src/packageset.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dhall", .module = dhall_mod },
        },
    });
    const derivation_mod = b.createModule(.{
        .root_source_file = b.path("../../fxstore/zig/src/derivation.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dhall", .module = dhall_mod },
            .{ .name = "packageset", .module = packageset_mod },
        },
    });
    const closure_mod = b.createModule(.{
        .root_source_file = b.path("../../fxstore/zig/src/closure.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "packageset", .module = packageset_mod },
        },
    });
    // closure unit tests open LIVE dbs (the dedicated-test-module pattern).
    linkDatalog(b, closure_mod);
    const build_mod = b.createModule(.{
        .root_source_file = b.path("../../fxstore/zig/src/build.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "packageset", .module = packageset_mod },
        },
    });
    const store_mod = b.createModule(.{
        .root_source_file = b.path("../../fxstore/zig/src/store.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "packageset", .module = packageset_mod },
            .{ .name = "derivation", .module = derivation_mod },
            .{ .name = "closure", .module = closure_mod },
            .{ .name = "build", .module = build_mod },
        },
    });
    linkDatalog(b, store_mod);

    // fxstore: the facade re-exporting the surface activate.zig + init.zig
    // use, with one consistent DlDb opaque type across the port.
    const fxstore_mod = b.createModule(.{
        .root_source_file = b.path("src/fxstore.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dhall", .module = dhall_mod },
            .{ .name = "packageset", .module = packageset_mod },
            .{ .name = "derivation", .module = derivation_mod },
            .{ .name = "closure", .module = closure_mod },
            .{ .name = "store", .module = store_mod },
        },
    });

    // activate: the port CLI (activate_diff.sh execs it and compares the
    // output against pinned goldens captured from the C oracle's verified
    // behavior).  Its test module round-trips a real package-set load.
    const activate_mod = b.createModule(.{
        .root_source_file = b.path("src/activate.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
            .{ .name = "fxstore", .module = fxstore_mod },
        },
    });
    linkDatalog(b, activate_mod);
    const activate_exe = b.addExecutable(.{ .name = "fx-activate", .root_module = activate_mod });
    b.installArtifact(activate_exe);

    // ─── UNIT 6: fx-init (PID1/supervisor) ───────────────────────────────
    //
    // init: the port CLI (init_diff.sh execs it and compares against pinned
    // goldens captured from the C oracle's verified behavior), importing the
    // ported log/probe/reloc/supervise modules and the fxstore Zig facade
    // (which pulls the store core) + libdatalog.so.
    const init_mod = b.createModule(.{
        .root_source_file = b.path("src/init.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "log", .module = log_mod },
            .{ .name = "probe", .module = probe_mod },
            .{ .name = "reloc", .module = reloc_mod },
            .{ .name = "supervise", .module = supervise_mod },
            .{ .name = "fxstore", .module = fxstore_mod },
        },
    });
    linkDatalog(b, init_mod);
    const init_exe = b.addExecutable(.{ .name = "fx-init", .root_module = init_mod });
    b.installArtifact(init_exe);

    // config.zig unit tests (on grammar, validation, extraEtc path rules),
    // plus the reloc/supervise/log/probe/fxctl/activate module tests.
    const cfg_tests = b.addTest(.{ .root_module = config_mod });
    const run_cfg_tests = b.addRunArtifact(cfg_tests);
    const reloc_tests = b.addTest(.{ .root_module = reloc_mod });
    const run_reloc_tests = b.addRunArtifact(reloc_tests);
    const sup_tests = b.addTest(.{ .root_module = supervise_mod });
    const run_sup_tests = b.addRunArtifact(sup_tests);
    const log_tests = b.addTest(.{ .root_module = log_test_mod });
    const run_log_tests = b.addRunArtifact(log_tests);
    const probe_tests = b.addTest(.{ .root_module = probe_test_mod });
    const run_probe_tests = b.addRunArtifact(probe_tests);
    const fxctl_tests = b.addTest(.{ .root_module = fxctl_mod });
    const run_fxctl_tests = b.addRunArtifact(fxctl_tests);
    const activate_tests = b.addTest(.{ .root_module = activate_mod });
    const run_activate_tests = b.addRunArtifact(activate_tests);
    const init_tests = b.addTest(.{ .root_module = init_mod });
    const run_init_tests = b.addRunArtifact(init_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_cfg_tests.step);
    test_step.dependOn(&run_reloc_tests.step);
    test_step.dependOn(&run_sup_tests.step);
    test_step.dependOn(&run_log_tests.step);
    test_step.dependOn(&run_probe_tests.step);
    test_step.dependOn(&run_fxctl_tests.step);
    test_step.dependOn(&run_activate_tests.step);
    test_step.dependOn(&run_init_tests.step);
}

// Link the Zig-built datalog-dafsa engine .so (sibling ../../datalog-dafsa
// checkout, since the build root is zig/) into `m`.  The library path and the
// baked rpath are both the .so's absolute directory, so linked binaries/tests
// resolve it at runtime from any cwd.
fn linkDatalog(b: *std.Build, m: *std.Build.Module) void {
    m.linkSystemLibrary("datalog", .{});
    m.addLibraryPath(b.path("../../datalog-dafsa/zig-out/lib"));
    m.addRPath(b.path("../../datalog-dafsa/zig-out/lib"));
}
