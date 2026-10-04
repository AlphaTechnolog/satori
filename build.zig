const std = @import("std");

/// Every module in the dependency graph, for one target.
///
/// Building this in a function rather than inline keeps the native build and the
/// cross-compile matrix from drifting apart — an earlier version of this file
/// duplicated the whole graph and the matrix entries silently lacked imports.
const Deps = struct {
    c: *std.Build.Module,
    buf: *std.Build.Module,
    fmt: *std.Build.Module,
    posix: *std.Build.Module,
    macos: *std.Build.Module,
    linux: *std.Build.Module,
    shared: *std.Build.Module,
};

fn buildDeps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_file: []const u8,
) Deps {
    // ---- generated C interop -------------------------------------------------
    // src/c.zig is COMMITTED and regenerated per target (plan §6). It is not
    // generated at build time: translate-c is now a separately versioned external
    // package, and a network fetch at build time would break distro packaging
    // and air-gapped CI. tools/regen-c.sh regenerates and CI fails on any diff.
    // c_file lets the cross-compile matrix be built against bindings generated
    // for a target other than the one src/c.zig was committed for, without
    // mutating the committed file. Build with:
    //   zig build -Dc-file=.zig-out/c.x86_64-linux-gnu.zig -Dtarget=x86_64-linux-gnu
    const m_c = b.createModule(.{
        .root_source_file = b.path(c_file),
        .target = target,
        .optimize = optimize,
    });

    const m_buf = b.createModule(.{
        .root_source_file = b.path("src/buf.zig"),
        .target = target,
        .optimize = optimize,
    });
    m_buf.addImport("c", m_c);

    const m_fmt = b.createModule(.{
        .root_source_file = b.path("src/fmt.zig"),
        .target = target,
        .optimize = optimize,
    });
    m_fmt.addImport("c", m_c);
    m_fmt.addImport("buf", m_buf);

    const m_posix = b.createModule(.{
        .root_source_file = b.path("src/platform/posix.zig"),
        .target = target,
        .optimize = optimize,
    });
    m_posix.addImport("c", m_c);

    const m_macos = b.createModule(.{
        .root_source_file = b.path("src/platform/macos.zig"),
        .target = target,
        .optimize = optimize,
    });
    m_macos.addImport("c", m_c);
    m_macos.addImport("posix", m_posix);

    const m_linux = b.createModule(.{
        .root_source_file = b.path("src/platform/linux.zig"),
        .target = target,
        .optimize = optimize,
    });
    m_linux.addImport("c", m_c);
    m_linux.addImport("posix", m_posix);

    // shared.zig selects its platform layer with
    //   @import("platform/" ++ platFile())
    // which is resolved at comptime from builtin.os.tag. Both files are supplied
    // under their real names so the string import resolves; the unused one is
    // never instantiated and costs nothing.
    const m_shared = b.createModule(.{
        .root_source_file = b.path("src/shared.zig"),
        .target = target,
        .optimize = optimize,
    });
    m_shared.addImport("c", m_c);
    m_shared.addImport("buf", m_buf);
    m_shared.addImport("posix", m_posix);
    m_shared.addImport("macos", m_macos);
    m_shared.addImport("linux", m_linux);

    return .{
        .c = m_c,
        .buf = m_buf,
        .fmt = m_fmt,
        .posix = m_posix,
        .macos = m_macos,
        .linux = m_linux,
        .shared = m_shared,
    };
}

/// Attach the standard imports to a root module.
fn wire(root: *std.Build.Module, d: Deps) void {
    root.link_libc = true;
    root.addImport("c", d.c);
    root.addImport("buf", d.buf);
    root.addImport("fmt", d.fmt);
    root.addImport("posix", d.posix);
    root.addImport("macos", d.macos);
    root.addImport("linux", d.linux);
    root.addImport("shared", d.shared);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c_file = b.option([]const u8, "c-file", "Generated C interop module to use") orelse "src/c.zig";
    const deps = buildDeps(b, target, optimize, c_file);

    // ---- executable ----------------------------------------------------------
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    wire(exe_mod, deps);

    const exe = b.addExecutable(.{
        .name = "satori",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Note: Zig 0.17 removed `b.args`, so `zig build run -- --flag` no longer
    // forwards arguments. Run the installed binary directly instead:
    //     zig build && ./zig-out/bin/satori --help
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run satori");
    run_step.dependOn(&run_cmd.step);

    // ---- tests ---------------------------------------------------------------
    // One test binary per source module, not one aggregate.
    //
    // Zig 0.17 does not collect `test` blocks from a separately declared module:
    // a root that does `test { _ = @import("buf"); }` builds and passes while
    // running exactly one test, silently skipping every real assertion. Separate
    // binaries also isolate failures and compile in parallel.
    const test_step = b.step("test", "Run all tests");

    const test_units = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "buf", .path = "src/buf.zig" },
        .{ .name = "fmt", .path = "src/fmt.zig" },
        .{ .name = "shared", .path = "src/shared.zig" },
        // Layout assertions are a separate compilation for a second reason: a
        // @compileError there must fail the build loudly rather than being
        // folded into another binary's test list.
        .{ .name = "layout", .path = "test/layout.zig" },
    };

    for (test_units) |u| {
        const m = b.createModule(.{
            .root_source_file = b.path(u.path),
            .target = target,
            .optimize = optimize,
        });
        wire(m, deps);
        const t = b.addTest(.{ .name = u.name, .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // The data layer for the *current* platform only. linux.zig references
    // sysinfo and struct_sysinfo, which a macOS-generated src/c.zig does not
    // define, so compiling it on Darwin fails.
    {
        const plat_path = switch (target.result.os.tag) {
            .macos => "src/platform/macos.zig",
            .linux => "src/platform/linux.zig",
            else => "src/platform/posix.zig",
        };
        const m = b.createModule(.{
            .root_source_file = b.path(plat_path),
            .target = target,
            .optimize = optimize,
        });
        wire(m, deps);
        const t = b.addTest(.{ .name = "platform", .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ---- benchmark harness ---------------------------------------------------
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("test/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    wire(bench_mod, deps);
    const bench = b.addExecutable(.{ .name = "satori-bench", .root_module = bench_mod });
    const bench_step = b.step("bench", "Measure each data-gathering phase");
    bench_step.dependOn(&b.addRunArtifact(bench).step);

    // ---- release build, and the gates that run against it --------------------
    //
    // The startup and no-fork gates describe the artifact that ships, so they get
    // their own ReleaseFast build rather than whatever -Doptimize was passed.
    // Measuring a Debug build and reporting "1.9 ms" would be a true statement
    // about the wrong binary.
    const rel_deps = buildDeps(b, target, .ReleaseFast, c_file);
    const rel_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    wire(rel_mod, rel_deps);
    const rel_exe = b.addExecutable(.{ .name = "satori", .root_module = rel_mod });
    // A custom dest_dir keeps this from colliding with the developer's default
    // zig-out/bin/satori, which may be any optimization mode. It is relative to
    // the install prefix, so this yields zig-out/release/satori — writing
    // "zig-out/release" here would produce the doubled path zig-out/zig-out/.
    const rel_install = b.addInstallArtifact(rel_exe, .{
        .dest_dir = .{ .override = .{ .custom = "release" } },
    });
    const rel_bin = "zig-out/release/satori";

    // ---- startup gate --------------------------------------------------------
    const startup_mod = b.createModule(.{
        .root_source_file = b.path("test/startup.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    wire(startup_mod, rel_deps);
    const startup_exe = b.addExecutable(.{ .name = "satori-startup", .root_module = startup_mod });
    const startup_run = b.addRunArtifact(startup_exe);
    startup_run.addArg(rel_bin);
    startup_run.step.dependOn(&rel_install.step);
    const startup_step = b.step("startup", "Gate: end-to-end startup median under 3.5 ms");
    startup_step.dependOn(&startup_run.step);

    // ---- every gate, one command ---------------------------------------------
    //
    // CI runs `zig build check` and nothing else. Anything worth enforcing has to
    // be reachable from here, or it is documentation rather than a gate.
    const check_step = b.step("check", "Run every CI gate");

    check_step.dependOn(&b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("src"), b.path("test") },
        .check = true,
    }).step);

    check_step.dependOn(test_step);

    // C bindings still translate for every supported target, and the committed
    // native file is current. Catches a libc change before a release does.
    {
        const ccheck = b.addSystemCommand(&.{ "sh", "tools/regen-c.sh", "--matrix" });
        ccheck.setEnvironmentVariable("ZIG", b.graph.zig_exe);
        ccheck.has_side_effects = true;
        check_step.dependOn(&ccheck.step);
    }

    // Zero forks, zero allocations — proven from the symbol table, with a
    // negative control proving the check can still fail.
    {
        const nofork = b.addSystemCommand(&.{ "sh", "tools/check-no-fork.sh", rel_bin });
        nofork.setEnvironmentVariable("ZIG", b.graph.zig_exe);
        nofork.has_side_effects = true;
        nofork.step.dependOn(&rel_install.step);
        check_step.dependOn(&nofork.step);

        const negctl = b.addSystemCommand(&.{ "sh", "tools/check-negative-control.sh" });
        negctl.setEnvironmentVariable("ZIG", b.graph.zig_exe);
        negctl.has_side_effects = true;
        check_step.dependOn(&negctl.step);
    }

    check_step.dependOn(&startup_run.step);

    // ---- formatting gate -----------------------------------------------------
    const fmt_step = b.step("fmt", "Check formatting");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = &.{
            b.path("build.zig"),
            b.path("src"),
            b.path("test"),
        },
        .check = b.option(bool, "check-fmt", "Fail instead of rewriting") orelse true,
    }).step);

    // ---- cross-compile matrix ------------------------------------------------
    // Explicit step rather than implicit configuration, so `zig build` on a dev
    // machine stays fast.
    //
    // Each target gets its OWN generated bindings, produced by the matrix step
    // itself. src/c.zig is committed for the native target only, so building a
    // Linux target against it cannot work: the file contains aarch64-macOS
    // headers and defines no sysinfo, no statvfs and no CLOCK_BOOTTIME. Making
    // the matrix generate per-target bindings is what turns this step from
    // "documented as manual" into one command that actually checks five targets.
    const matrix_step = b.step("matrix", "Build every supported target");

    // CI gate from the plan. Generous enough that no legitimate target fails it,
    // tight enough that an accidental dependency on libc++ or a debug-info
    // regression would be caught.
    const MAX_BINARY_BYTES: u64 = 1_000_000;

    const matrix = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
    };

    for (matrix) |q| {
        const mt = b.resolveTargetQuery(q);

        // Name from the *resolved* target. The full triple is used rather than
        // arch/os, because "x86_64-linux" is ambiguous: gnu and musl produce the
        // same pair and would install into the same directory, with the second
        // silently overwriting the first. That shipped a matrix step which built
        // five targets, reported five passes, and left four binaries on disk.
        const arch = @tagName(mt.result.cpu.arch);
        const os_tag = @tagName(mt.result.os.tag);

        // translate-c needs the ABI-qualified triple (x86_64-linux-gnu), not the
        // arch/os pair. It is composed here rather than taken from
        // `mt.result.zigTriple`, which returns the verbose form
        // ("x86_64-linux.5.10...7.2-musl") — a legal Zig triple but not something
        // translate-c's -target parser accepts, and using it produced bindings
        // paths that matched no file the generator had written.
        const abi: []const u8 = switch (mt.result.abi) {
            .gnu => "gnu",
            .musl => "musl",
            else => "none",
        };
        const label = if (std.mem.eql(u8, abi, "none"))
            b.fmt("{s}-{s}", .{ arch, os_tag })
        else
            b.fmt("{s}-{s}-{s}", .{ arch, os_tag, abi });
        const triple = label;
        const bindings = b.fmt("zig-out/bindings/c.{s}.zig", .{triple});

        const gen = b.addSystemCommand(&.{ "sh", "tools/regen-c.sh", "--gen", "--out", bindings, triple });
        gen.setEnvironmentVariable("ZIG", b.graph.zig_exe);
        gen.has_side_effects = true;
        gen.step.dependOn(b.getInstallStep()); // ensure zig-out/ exists

        const d = buildDeps(b, mt, .ReleaseFast, bindings);
        const root = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = mt,
            // ReleaseFast for every matrix target, not the developer's -Doptimize:
            // a cross-compilation gate that measured Debug builds would be
            // measuring the wrong artifact, and the size gate below would be
            // meaningless.
            .optimize = .ReleaseFast,
        });
        wire(root, d);
        // Ship stripped. Zig embeds debug info by default even in ReleaseFast;
        // it is dead weight in a distributed binary and it would let the 1 MB
        // gate pass on a build that is three times the size it ships as. In
        // Zig 0.17 `strip` is a Module field, not an ExecutableOptions field.
        root.strip = true;

        // dest_dir is relative to the install prefix, so this yields
        // zig-out/matrix/<label>/. Writing "zig-out/matrix/..." here would produce
        // the doubled path zig-out/zig-out/matrix/..., which is silently wrong:
        // the build succeeds and the size gate then measures nothing.
        const dest = b.fmt("matrix/{s}", .{label});
        const exe_name = b.fmt("satori-{s}", .{label});
        const dest_bin = b.fmt("zig-out/{s}/{s}", .{ dest, exe_name });

        const m_exe = b.addExecutable(.{
            .name = exe_name,
            .root_module = root,
        });

        // Order matters, and it is the Compile step that has to wait — not the
        // install. Depending only on the install leaves the compile free to start
        // before the bindings exist, which succeeds on any machine where the
        // files are left over from a previous run and fails on a clean CI runner.
        m_exe.step.dependOn(&gen.step);

        const inst = b.addInstallArtifact(m_exe, .{
            .dest_dir = .{ .override = .{ .custom = dest } },
        });

        // Size gate, checked against the artifact that actually ships.
        //
        // `sh -c SCRIPT ARG...` sets $0 to the FIRST argument, so the args below
        // need a leading placeholder. Without it the binary path lands in $0 and
        // the shell tries to run an ELF file as a script — which fails with a
        // baffling "line 2: 1000000: No such file or directory" instead of
        // anything pointing at the real problem.
        const size = b.addSystemCommand(&.{
            "sh", "-c",
            \\set -eu
            \\f="$1"; limit="$2"
            \\sz=$(wc -c < "$f" | tr -d ' ')
            \\if [ "$sz" -gt "$limit" ]; then
            \\  echo "FAIL  $3: $sz bytes exceeds the $limit byte gate"
            \\  exit 1
            \\fi
            \\printf 'ok  %-24s %8s bytes\n' "$3" "$sz"
        });
        size.addArg("satori-size-gate"); // $0
        size.addFileArg(b.path(dest_bin)); // $1
        size.addArg(b.fmt("{d}", .{MAX_BINARY_BYTES}));
        size.addArg(label);
        size.has_side_effects = true;
        size.step.dependOn(&inst.step);

        matrix_step.dependOn(&size.step);
    }
}
