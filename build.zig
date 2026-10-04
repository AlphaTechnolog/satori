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
    const bench_step = b.step("bench", "Run the startup benchmark");
    bench_step.dependOn(&b.addRunArtifact(bench).step);

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
    const matrix_step = b.step("matrix", "Build every supported target");

    const matrix = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
    };

    for (matrix) |q| {
        const mt = b.resolveTargetQuery(q);
        const d = buildDeps(b, mt, optimize, c_file);
        const root = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = mt,
            .optimize = optimize,
        });
        wire(root, d);
        // Name from the *resolved* target: Query's fields are optionals, and in
        // Zig 0.17 Target.Cpu.Arch / Target.Os.Tag no longer implement `format`,
        // so @tagName is the way to stringify them.
        const arch = @tagName(mt.result.cpu.arch);
        const os_tag = @tagName(mt.result.os.tag);
        const m_exe = b.addExecutable(.{
            .name = b.fmt("satori-{s}-{s}", .{ arch, os_tag }),
            .root_module = root,
        });
        matrix_step.dependOn(&b.addInstallArtifact(m_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("zig-out/{s}-{s}", .{ arch, os_tag }) } },
        }).step);
    }
}
