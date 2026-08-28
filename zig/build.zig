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

    // ─── UNIT 3: fx_log + fx_probe (the C engine stays C) ─────────────────
    //
    // fxengine: the vendored datalog-dafsa + dafsa engines as ONE static lib
    // (the same source lists as tests/build_log.sh / build_probe.sh), linked
    // by the live driver once.  The Zig ports declare the dl_*/aux_*/
    // tokenize/regex_* entry points as externs — the fx-core libdatalog FFI
    // pattern.
    const engine_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    engine_mod.addIncludePath(b.path("../vendor/datalog-dafsa/src"));
    engine_mod.addIncludePath(b.path("../vendor/datalog-dafsa/vendor"));
    engine_mod.addIncludePath(b.path("../vendor/dafsa"));
    engine_mod.addCSourceFiles(.{
        .root = b.path(".."),
        .files = &.{
            "vendor/datalog-dafsa/src/intern.c",
            "vendor/datalog-dafsa/src/termstore.c",
            "vendor/datalog-dafsa/src/relation.c",
            "vendor/datalog-dafsa/src/vrelation.c",
            "vendor/datalog-dafsa/src/tupleset.c",
            "vendor/datalog-dafsa/src/parser.c",
            "vendor/datalog-dafsa/src/compiler.c",
            "vendor/datalog-dafsa/src/vm.c",
            "vendor/datalog-dafsa/src/snapshot.c",
            "vendor/datalog-dafsa/src/regexwalk.c",
            "vendor/datalog-dafsa/src/permindex.c",
            "vendor/datalog-dafsa/src/util.c",
            "vendor/datalog-dafsa/src/dl.c",
            "vendor/datalog-dafsa/src/iter.c",
            "vendor/datalog-dafsa/src/magic.c",
            "vendor/datalog-dafsa/src/topdown.c",
            "vendor/datalog-dafsa/src/analyze.c",
            "vendor/datalog-dafsa/src/schema.c",
            "vendor/datalog-dafsa/src/typecheck.c",
            "vendor/datalog-dafsa/src/json.c",
            "vendor/datalog-dafsa/src/txnwal.c",
            "vendor/datalog-dafsa/src/index.c",
            "vendor/dafsa/dafsa.c",
            "vendor/dafsa/dafsa_state.c",
            "vendor/dafsa/dafsa_core.c",
            "vendor/dafsa/dafsa_persist.c",
            "vendor/dafsa/dafsa_view.c",
            "vendor/dafsa/dafsa_crc32.c",
            "vendor/dafsa/dafsa_wal.c",
            "vendor/dafsa/dafsa_build.c",
            "vendor/dafsa/dafsa_rank.c",
            "vendor/dafsa/dafsa_view_rank.c",
        },
        // gnu11 not c11: the engines use POSIX decls (zig cc c11 hides them).
        .flags = &.{ "-std=gnu11", "-O2", "-fno-stack-check" },
    });
    const engine = b.addLibrary(.{
        .linkage = .static,
        .name = "fxengine",
        .root_module = engine_mod,
    });

    // log_port / probe_port: the Zig ports as objects exposing zig_log_* /
    // zig_probe_* to the C live driver (the supervise_extern.o pattern, now
    // inside zig build).  Objects carry no linkage; the driver's final link
    // resolves the dl_* externs against fxengine.
    const log_mod = b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const log_obj = b.addObject(.{ .name = "log_port", .root_module = log_mod });
    // dedicated test module: linking the engine into log_mod itself would
    // pull fxengine twice into the live driver (duplicate symbols)
    const log_test_mod = b.createModule(.{
        .root_source_file = b.path("src/log.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    log_test_mod.linkLibrary(engine);
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
    probe_test_mod.linkLibrary(engine);

    // log_probe_live: the one-process differential driver (C), linking the
    // C originals (src/fx_log.c + src/fx_probe.c), both Zig port objects and
    // the shared engine lib.
    const live_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    live_mod.addIncludePath(b.path("../src"));
    live_mod.addIncludePath(b.path("../vendor/datalog-dafsa/src"));
    live_mod.addCSourceFiles(.{
        .root = b.path(".."),
        .files = &.{
            "zig/log_probe_live.c",
            "src/fx_log.c",
            "src/fx_probe.c",
        },
        .flags = &.{ "-std=gnu11", "-O2", "-fno-stack-check" },
    });
    live_mod.addObject(log_obj);
    live_mod.addObject(probe_obj);
    live_mod.linkLibrary(engine);
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
    // fxstore_c: the vendored C store core (packageset/derivation/closure/
    // store/build — the same source lists as tests/build_activate.sh) plus
    // the dhall-c 13, as ONE static lib linking fxengine (the dl_* symbols
    // store.c needs).  The activate port drives it through the extern block
    // in activate.zig; config.c is NOT in the lib (config.zig replaces it —
    // the log.zig "C engine stays C" pattern).
    const fxc_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fxc_mod.addIncludePath(b.path("../vendor/fxstore"));
    fxc_mod.addIncludePath(b.path("../vendor/datalog-dafsa/src"));
    fxc_mod.addIncludePath(b.path("../vendor/datalog-dafsa/vendor"));
    fxc_mod.addIncludePath(b.path("../vendor/dafsa"));
    fxc_mod.addIncludePath(b.path("../vendor/dhall-c/src"));
    fxc_mod.addCSourceFiles(.{
        .root = b.path(".."),
        .files = &.{
            "vendor/fxstore/packageset.c",
            "vendor/fxstore/derivation.c",
            "vendor/fxstore/closure.c",
            "vendor/fxstore/store.c",
            "vendor/fxstore/build.c",
            "vendor/dhall-c/src/arena.c",
            "vendor/dhall-c/src/lexer.c",
            "vendor/dhall-c/src/parser.c",
            "vendor/dhall-c/src/ast.c",
            "vendor/dhall-c/src/normalize.c",
            "vendor/dhall-c/src/typecheck.c",
            "vendor/dhall-c/src/builtins.c",
            "vendor/dhall-c/src/serialize.c",
            "vendor/dhall-c/src/import.c",
            "vendor/dhall-c/src/bignum.c",
            "vendor/dhall-c/src/sha256.c",
            "vendor/dhall-c/src/ssrf.c",
            "vendor/dhall-c/src/http.c",
        },
        // gnu11 (POSIX decls) + the store.c stage3-path default.
        // -Ddhall_arena=c_dhall_arena: config.zig's dhall Zig core exports a
        // C-ABI global `dhall_arena` (dhall-c zig arena.zig:48) — rename the C
        // core's global so the two dhall cores (Zig for config, C for
        // packageset) link side-by-side without colliding.
        .flags = &.{ "-std=gnu11", "-O2", "-fno-stack-check", "-DFXSTORE_STAGE3_PATH=\"/fx/store/share/stage3\"", "-Ddhall_arena=c_dhall_arena" },
    });
    fxc_mod.linkLibrary(engine);
    const fxstore_c = b.addLibrary(.{
        .linkage = .static,
        .name = "fxstore_c",
        .root_module = fxc_mod,
    });

    // activate: the port CLI (activate_diff.sh execs it against the C oracle
    // built from UNMODIFIED src/fx-activate.c + src/config.c); its test
    // module runs the extern-struct round-trip through the real C loader.
    const activate_mod = b.createModule(.{
        .root_source_file = b.path("src/activate.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
        },
    });
    activate_mod.linkLibrary(fxstore_c);
    const activate_exe = b.addExecutable(.{ .name = "fx-activate", .root_module = activate_mod });
    b.installArtifact(activate_exe);

    // ─── UNIT 6: fx-init (PID1/supervisor) ───────────────────────────────
    //
    // init: the port CLI (init_diff.sh execs it against the C oracle built
    // from UNMODIFIED src/fx-init.c + its C twins), importing the ported
    // log/probe/reloc/supervise modules and linking fxstore_c + fxengine.
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
        },
    });
    init_mod.linkLibrary(fxstore_c);
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
