// build.zig — fx-init Zig port, unit 1: the config walker + differential
// harness.  The dhall-c Zig core is imported as a single module via the
// facade file, EXACTLY as fx-core/build.zig:15-20 (the sibling modules'
// bare-filename imports only resolve when the module root lives in the
// dhall-c zig/src dir).
//
// INPUT PROVENANCE (every engine/store input comes from THIS repo's
// submodules):
//   vendor/datalog-dafsa               the engine, compiled in-graph into a
//                                      static libdatalog.a (block at the top
//                                      of build())
//   vendor/datalog-dafsa/vendor/dafsa  the engine's nested dafsa (abi.zig)
//   vendor/fxstore                     the store core Zig units
//   vendor/dhall-c                     NOT read by the default build: the
//                                      dhall-c Zig core comes from the
//                                      sibling ../../dhall-c
//                                      (FX_SIB_DHALL_C).  The vendored copy
//                                      at its pinned commit also carries a
//                                      zig/ core, but at a DIFFERENT pin —
//                                      switching that default is a separate
//                                      measurement, not part of the engine
//                                      migration.
const std = @import("std");

/// A dependency path used as a module root: `rel` (../vendor/<name>/...)
/// relative to this build root in a dev checkout, overridable via the
/// FX_SIB_<NAME> env var (an absolute path) so the m3 fixture recipes can
/// point the build at the dep's content-addressed STORE output
/// ($FX_DEP_<NAME>, exported by fxstore for each dep) — the fixture then
/// compiles exactly the dep content its derivation hash records, and never
/// reads or writes outside the build workdir.
fn sib(b: *std.Build, comptime env: []const u8, comptime rel: []const u8) std.Build.LazyPath {
    if (b.graph.environ_map.get(env)) |p| {
        if (p.len > 0) return .{ .cwd_relative = p };
    }
    return b.path(rel);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // libdatalog linkage (the still-Zig datalog core, C-FFI).
    //
    // The engine is compiled IN THIS BUILD GRAPH, for BOTH targets, from the
    // engine sources vendored as a submodule of THIS repo:
    //   vendor/datalog-dafsa/zig/src/hybrid.zig
    //   vendor/datalog-dafsa/vendor/dafsa/zig/src/abi.zig  (nested submodule)
    // Nothing here reads another checkout's build output: no library path, no
    // rpath, no prebuilt .so.  A STATIC libdatalog.a is preferred —
    // the resulting binaries carry the engine themselves and need no
    // runtime-resolvable shared object at all (an i386-musl link also cannot
    // use a glibc .so: ld.lld "libdatalog.so is incompatible with elf_i386").
    // In-graph rather than a prebuilt path because the artifact must be
    // target-coupled to whatever -Dtarget the user passes.
    //
    // ENGINE OPTIMIZE MODE — ReleaseSafe is mapped to ReleaseFast.  MEASURED
    // (Zig 0.16, this host's glibc): the engine's dl.zig @cImports
    // <fcntl.h>, and Zig predefines _FORTIFY_SOURCE only for ReleaseSafe, so
    // translating that header fails there ("call to '__error__' declared
    // with attribute error: ..." out of /usr/include/bits/fcntl2.h).  The
    // engine's own build prefers ReleaseFast, so the engine keeps its own
    // preferred mode instead of dragging the whole build back to Debug.
    const engine_optimize: std.builtin.OptimizeMode =
        if (optimize == .ReleaseSafe) .ReleaseFast else optimize;
    // -----------------------------------------------------------------------
    const datalog_mod = b.createModule(.{
        .root_source_file = b.path("../vendor/datalog-dafsa/zig/src/hybrid.zig"),
        .target = target,
        .optimize = engine_optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dafsa_abi", .module = b.createModule(.{
                .root_source_file = b.path("../vendor/datalog-dafsa/vendor/dafsa/zig/src/abi.zig"),
                .target = target,
                .optimize = engine_optimize,
                .link_libc = true,
            }) },
        },
    });
    // Created unconditionally (as in fx-core/fxstore): an unreferenced step is
    // never compiled, so a build that links nothing still succeeds.
    const datalog_lib = b.addLibrary(.{
        .name = "datalog",
        .linkage = .static,
        .root_module = datalog_mod,
    });
    datalog_lib.root_module.addIncludePath(b.path("../vendor/datalog-dafsa/src"));
    datalog_lib.root_module.addIncludePath(b.path("../vendor/datalog-dafsa/vendor/dafsa"));

    const dhall_mod = b.createModule(.{
        .root_source_file = sib(b, "FX_SIB_DHALL_C", "../../dhall-c")
            .join(b.allocator, "zig/src/dhall_mod.zig") catch @panic("OOM"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // fxstat: the ONE target-correct C-ABI stat/timespec surface (its layout
    // is MEASURED per target and pinned by a comptime guard — see fxstat.zig).
    const fxstat_mod = b.createModule(.{
        .root_source_file = b.path("src/fxstat.zig"),
        .target = target,
        .optimize = optimize,
    });

    // operator_journal: THE ONE definition of <store>/.operator — the header
    // text (the contract, written into the file), the data-line grammar and
    // the boot-nonce parse.  Imported by BOTH writers (fx-init's control
    // handler and fx-activate's self-record), so the grammar and the header
    // — which IS the definition — can never drift.
    const operator_journal_mod = b.createModule(.{
        .root_source_file = b.path("src/operator_journal.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "fxstat", .module = fxstat_mod },
        },
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
    // The dl_*/aux_*/tokenize/regex_* externs the Zig ports declare are
    // resolved against the in-graph static libdatalog.a built at the top of
    // this build() from vendor/datalog-dafsa (linkDatalog, below).  The C
    // headers (dl.h and the vector.h it includes) come from that SAME
    // vendored submodule via FX_SIB_DATALOG_SRC (sib(), below), so the C
    // driver log_probe_live.c compiles against the headers paired with the
    // engine it links — the submodule carries both.

    // log_port / probe_port: the Zig ports as objects exposing zig_log_* /
    // zig_probe_* to the C live driver (the supervise_extern.o pattern, now
    // inside zig build).  Objects carry no linkage; the driver's final link
    // resolves the dl_* externs against the in-graph libdatalog.a.
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
    linkDatalog(b, log_test_mod, datalog_lib);
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "fxstat", .module = fxstat_mod },
        },
    });
    const probe_obj = b.addObject(.{ .name = "probe_port", .root_module = probe_mod });
    const probe_test_mod = b.createModule(.{
        .root_source_file = b.path("src/probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "fxstat", .module = fxstat_mod },
        },
    });
    linkDatalog(b, probe_test_mod, datalog_lib);

    // log_probe_live: the one-process regression driver (C), linking the
    // Zig port objects and the in-graph libdatalog.a.  (It used to link the C originals
    // src/fx_log.c + src/fx_probe.c for a live C-vs-Zig diff; the C oracle
    // was removed and the driver now compares against pinned goldens.)
    const live_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    live_mod.addIncludePath(sib(b, "FX_SIB_DATALOG_SRC", "../vendor/datalog-dafsa/src"));
    live_mod.addCSourceFiles(.{
        .root = b.path(".."),
        .files = &.{
            "zig/log_probe_live.c",
        },
        .flags = &.{ "-std=gnu11", "-O2", "-fno-stack-check" },
    });
    live_mod.addObject(log_obj);
    live_mod.addObject(probe_obj);
    linkDatalog(b, live_mod, datalog_lib);
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
    // The fxstore store core is the fxstore Zig port vendored as THIS repo's
    // submodule (vendor/fxstore/zig/src/{packageset,derivation,closure,
    // store,build}.zig), imported as modules and composed exactly as
    // fxstore's own build.zig composes them — ONE shared packageset module so
    // every unit sees a single Package type.  The dl_* externs those modules
    // declare resolve against the in-graph libdatalog.a at the activate/init
    // final links.  config.zig and the fxstore modules share the SAME dhall
    // Zig core (dhall_mod), so the single `dhall_arena` global replaces the
    // C's renamed `c_dhall_arena` (the C dhall core is gone).
    const packageset_mod = b.createModule(.{
        .root_source_file = sib(b, "FX_SIB_FXSTORE", "../vendor/fxstore")
            .join(b.allocator, "zig/src/packageset.zig") catch @panic("OOM"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dhall", .module = dhall_mod },
        },
    });
    const derivation_mod = b.createModule(.{
        .root_source_file = sib(b, "FX_SIB_FXSTORE", "../vendor/fxstore")
            .join(b.allocator, "zig/src/derivation.zig") catch @panic("OOM"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "dhall", .module = dhall_mod },
            .{ .name = "packageset", .module = packageset_mod },
        },
    });
    const closure_mod = b.createModule(.{
        .root_source_file = sib(b, "FX_SIB_FXSTORE", "../vendor/fxstore")
            .join(b.allocator, "zig/src/closure.zig") catch @panic("OOM"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "packageset", .module = packageset_mod },
        },
    });
    // closure unit tests open LIVE dbs (the dedicated-test-module pattern).
    linkDatalog(b, closure_mod, datalog_lib);
    const build_mod = b.createModule(.{
        .root_source_file = sib(b, "FX_SIB_FXSTORE", "../vendor/fxstore")
            .join(b.allocator, "zig/src/build.zig") catch @panic("OOM"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "packageset", .module = packageset_mod },
        },
    });
    const store_mod = b.createModule(.{
        .root_source_file = sib(b, "FX_SIB_FXSTORE", "../vendor/fxstore")
            .join(b.allocator, "zig/src/store.zig") catch @panic("OOM"),
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
    linkDatalog(b, store_mod, datalog_lib);

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
            .{ .name = "fxstat", .module = fxstat_mod },
            .{ .name = "operator_journal", .module = operator_journal_mod },
        },
    });
    linkDatalog(b, activate_mod, datalog_lib);
    const activate_exe = b.addExecutable(.{ .name = "fx-activate", .root_module = activate_mod });
    b.installArtifact(activate_exe);

    // activate_paths / activate_facts: the twin drivers activate_diff.sh uses
    // to (a) pre-create the closure store dirs and (b) dump the store facts.
    // Zig replacements for zig/activate_paths.c + zig/activate_facts.c (the C
    // oracle twins, removed with the vendored C engine) — same byte output,
    // importing the fxstore facade + the in-graph libdatalog.a.
    const paths_exe = b.addExecutable(.{
        .name = "activate_paths",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/activate_paths.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "fxstore", .module = fxstore_mod },
            },
        }),
    });
    linkDatalog(b, paths_exe.root_module, datalog_lib);
    b.installArtifact(paths_exe);
    const facts_exe = b.addExecutable(.{
        .name = "activate_facts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/activate_facts.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "fxstore", .module = fxstore_mod },
            },
        }),
    });
    linkDatalog(b, facts_exe.root_module, datalog_lib);
    b.installArtifact(facts_exe);

    // ─── UNIT 6: fx-init (PID1/supervisor) ───────────────────────────────
    //
    // init: the port CLI (init_diff.sh execs it and compares against pinned
    // goldens captured from the C oracle's verified behavior), importing the
    // ported log/probe/reloc/supervise modules and the fxstore Zig facade
    // (which pulls the store core) + the in-graph libdatalog.a.
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
            .{ .name = "fxstat", .module = fxstat_mod },
            .{ .name = "operator_journal", .module = operator_journal_mod },
        },
    });
    linkDatalog(b, init_mod, datalog_lib);
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
    const opj_tests = b.addTest(.{ .root_module = operator_journal_mod });
    const run_opj_tests = b.addRunArtifact(opj_tests);
    const fxctl_tests = b.addTest(.{ .root_module = fxctl_mod });
    const run_fxctl_tests = b.addRunArtifact(fxctl_tests);
    const activate_tests = b.addTest(.{ .root_module = activate_mod });
    const run_activate_tests = b.addRunArtifact(activate_tests);
    const init_tests = b.addTest(.{ .root_module = init_mod });
    const run_init_tests = b.addRunArtifact(init_tests);

    // ─── fx-image (standalone disk-image builder) ────────────────────────
    //
    // Host-side orchestration: provisions a store (qemu_boot.sh's
    // toolchain-free path), builds the -E initramfs, assembles the raw
    // image with direct pwrite.  image_check pins the frozen header/MBR
    // byte offsets stage1 (U3) and stage2 (U4) read.
    const image_exe = b.addExecutable(.{
        .name = "fx-image",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/image.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(image_exe);
    const image_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/image_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "image", .module = b.createModule(.{
                    .root_source_file = b.path("src/image.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }) },
            },
        }),
    });
    const run_image_tests = b.addRunArtifact(image_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_cfg_tests.step);
    test_step.dependOn(&run_reloc_tests.step);
    test_step.dependOn(&run_sup_tests.step);
    test_step.dependOn(&run_log_tests.step);
    test_step.dependOn(&run_probe_tests.step);
    test_step.dependOn(&run_opj_tests.step);
    test_step.dependOn(&run_fxctl_tests.step);
    test_step.dependOn(&run_activate_tests.step);
    test_step.dependOn(&run_init_tests.step);
    test_step.dependOn(&run_image_tests.step);
}

// Link the datalog-dafsa engine into `m`.  THE SAME PATH FOR EVERY TARGET:
// the in-graph static libdatalog.a built above from this repo's vendored
// engine submodule.  No library path, no rpath, no prebuilt .so — nothing
// points into another checkout's build output, so a linked binary is
// self-contained and resolves the dl_* externs with no runtime lookup.
fn linkDatalog(b: *std.Build, m: *std.Build.Module, datalog_lib: *std.Build.Step.Compile) void {
    _ = b;
    m.linkLibrary(datalog_lib);
}
