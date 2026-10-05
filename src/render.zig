//! The renderer: output composition only.
//!
//! Split out of `main.zig` for step 2 of plan `satori-phase-2.md`. The reason is
//! mechanical rather than aesthetic: `zig build` compiles one test binary per
//! source module (Zig 0.17 does not collect `test` blocks out of a separately
//! declared module), so a function private to the entry point cannot be reached
//! by any test at all. The renderer is the first thing in the project that needs
//! one.
//!
//! INVARIANT — `render` is a pure function of `*const shared.Shared`.
//!
//! It performs no syscall, reads no environment and consults no global. Both
//! `macos.osVersion` and `macos.vmStats` used to be called from here; both moved
//! into `Shared.load()` in this change, because a renderer that performs live
//! syscalls bakes the machine it ran on into whatever a golden test compares
//! against. A field that needs a value it cannot get belongs in `load()`.
//!
//! INVARIANT — no escape sequence reaches the output except through `Buf.sgr`.
//! That is what lets `--no-color` be one `color` flag on `Buf` rather than a
//! flag threaded through every writer in the program.

const buf = @import("buf");
const fmt = @import("fmt");
const shared = @import("shared");
const builtin = @import("builtin");

/// Test-only: `std.testing`. Nothing else from `std` is used here. In
/// particular nothing is read from disk — `std.fs` is banned project-wide, so a
/// golden file would need hand-rolled `open`/`read` purely to hold test data.
/// The expected output lives in this file as literals instead.
const std = @import("std");

/// Capacity for one field's formatted value.
///
/// Every field formats into the same stack array, each starting from an empty
/// `Buf` over it, so no two values are ever live at once and the peak cost is one
/// array rather than one per field.
const VALUE_CAP = 512;

/// Output knobs. Deliberately not the CLI `Options`: `main` owns flag parsing,
/// and this is the rendering configuration derived from it.
pub const Options = struct {
    /// `--benchmark`: append the timing trailer.
    benchmark: bool = false,
};

/// Write the whole report into `out`. The caller owns `out`'s storage; nothing
/// here allocates.
pub fn render(out: *buf.Buf, sh: *const shared.Shared, opts: Options) void {
    var storage: [VALUE_CAP]u8 = undefined;
    var val = buf.Buf.init(&storage);

    header(out, sh);

    out.field("OS", osValue(sh));
    out.field("Kernel", sh.release.slice());
    out.field("Arch", sh.machine.slice());
    out.field("Shell", sh.shell.slice());

    // Format into a SEPARATE buffer before calling field. Passing `out` to both
    // fmt.duration and field mutates the same buffer twice: argument evaluation
    // runs duration first, so the value lands *before* its own label and the row
    // reads "50sUptime: 50s". Compute, then emit. The field registry that
    // replaces this (step 2, commit B) removes the hazard structurally — a
    // formatter is handed a scratch buffer and can only ever write there — so
    // this comment and the separate `value_storage` in main.zig both go away
    // then.
    _ = fmt.duration(&val, sh.uptimeSeconds());
    out.field("Uptime", val.written());

    if (sh.mem.total > 0) {
        out.write("Memory: ");
        val.len = 0;
        _ = fmt.bytes(&val, sh.mem.used);
        out.write(val.written());
        out.write(" / ");
        val.len = 0;
        _ = fmt.bytes(&val, sh.mem.total);
        out.write(val.written());
        out.writeByte('\n');
    }

    if (opts.benchmark) {
        out.writeByte('\n');
        out.write("shared load complete; no forks, one write\n");
    }
}

/// The `user@host` line above the fields.
fn header(out: *buf.Buf, sh: *const shared.Shared) void {
    out.sgr("1;36");
    out.write(sh.user.slice());
    out.sgr("1;34");
    out.write("@");
    out.sgr("0");
    out.write(sh.hostname.slice());
    out.writeByte('\n');
    out.sgr("0");
}

/// Which string the OS row carries.
///
/// The two platforms answer the same question differently. On macOS `sysname` is
/// "Darwin", which tells a reader nothing, and the product version is what "OS"
/// has always meant on that platform; `uname().release` is the fallback when the
/// sysctl is unavailable. On Linux `uname().sysname` already carries the
/// distribution name ("Debian GNU/Linux", "Ubuntu"), and there is no product
/// version to prefer, so `release` would be the *kernel* version and would
/// mislabel the row.
fn osValue(sh: *const shared.Shared) []const u8 {
    switch (builtin.os.tag) {
        .macos => if (sh.os_version.len > 0) return sh.os_version.slice() else return sh.release.slice(),
        else => return sh.sysname.slice(),
    }
}

// ---------------------------------------------------------------------------
// Golden tests
// ---------------------------------------------------------------------------
//
// The expected output below is written from the renderer, by hand, and then
// reconciled against actual output by reading it — not generated by running the
// program and pasting the result. A golden test produced from the program's own
// output ratifies whatever it produced, bugs included; if the renderer is wrong
// the expectation has to record the *intended* text so the test fails.
//
// Each arm is one literal, chosen by the same comptime switch the renderer uses,
// from a fixed `Shared`. Only the *shape* varies by target — never the data.

/// ESC, spelled once. Written with `++` rather than embedded as a raw byte so
/// the literal stays reviewable in a diff.
const ESC = "\x1b";

/// A `Shared` with every value fixed, so the expected output is a property of
/// the renderer rather than of the machine that ran the test.
///
/// Returned by value deliberately: `Shared` carries its string storage inline,
/// so copying it is safe (see the type's doc comment in shared.zig).
fn fixture() shared.Shared {
    var sh: shared.Shared = .{};
    sh.user.set("tester");
    sh.hostname.set("testbox");
    // Only the Linux OS row reads `sysname`; macOS prefers `os_version`. It is
    // set here so that the same fixture serves both arms unchanged.
    sh.sysname.set("Linux");
    sh.release.set("25.6.0");
    sh.machine.set("arm64");
    sh.shell.set("zsh");
    sh.os_version.set("26.6.2");

    // 3661 s = 1h 1m 1s. `boot_mono` is non-zero on purpose: `uptimeSeconds`
    // returns 0 when it is 0, which would render the row empty.
    sh.boot_mono = 1;
    sh.mono_now = 1 + 3_661_000_000_000;

    // Exactly 1.5 GiB and 8.0 GiB, so the expectation reads "1.5 GiB / 8.0 GiB"
    // rather than a truncated 1.3/1.4 that would be harder to check by eye.
    sh.mem = .{ .used = 1_610_612_736, .total = 8_589_934_592 };
    return sh;
}

test "golden: the default report" {
    var storage: [4096]u8 = undefined;
    var out = buf.Buf.init(&storage);
    const sh = fixture();
    render(&out, &sh, .{});

    const expected = switch (builtin.os.tag) {
        // macOS: "Darwin" as an OS name says nothing, so the row carries the
        // product version that Shared.load() gathered from kern.osproductversion.
        .macos => ESC ++
            // header: user in bold cyan, "@" in bold blue, hostname uncoloured.
            "[1;36mtester" ++ ESC ++ "[1;34m@" ++ ESC ++ "[0mtestbox\n" ++
            // a trailing reset that the reset above the hostname already made a
            // no-op — see commit B, which deletes it.
            ESC ++ "[0m" ++
            "OS: 26.6.2\n" ++ // osValue: os_version, 5 bytes, no padding (step 2B)
            "Kernel: 25.6.0\n" ++ // sh.release
            "Arch: arm64\n" ++ // sh.machine
            "Shell: zsh\n" ++ // sh.shell
            "Uptime: 1h 1m 1s\n" ++ // fmt.duration(3661)
            "Memory: 1.5 GiB / 8.0 GiB\n", // hand-written row, one space after the colon
        // Linux: the OS row reads sysname, and there is no vm source yet, so the
        // Memory row is absent rather than wrong. Step 2B changes that to
        // "unavailable".
        else => ESC ++
            "[1;36mtester" ++ ESC ++ "[1;34m@" ++ ESC ++ "[0mtestbox\n" ++
            ESC ++ "[0m" ++
            "OS: Linux\n" ++
            "Kernel: 25.6.0\n" ++
            "Arch: arm64\n" ++
            "Shell: zsh\n" ++
            "Uptime: 1h 1m 1s\n",
    };
    try std.testing.expectEqualStrings(expected, out.written());
}

test "golden: --benchmark appends its trailer" {
    var storage: [4096]u8 = undefined;
    var out = buf.Buf.init(&storage);
    const sh = fixture();
    render(&out, &sh, .{ .benchmark = true });

    // Deliberately a substring check on the trailer only, not the whole report:
    // the report itself is pinned by the test above and a second full literal
    // would be a second thing to keep in step for no extra coverage.
    const trailer = "\nshared load complete; no forks, one write\n";
    const got = out.written();
    try std.testing.expect(got.len > trailer.len);
    try std.testing.expectEqualStrings(trailer, got[got.len - trailer.len ..]);
}

test "render does not reach for the platform layer" {
    // The purity invariant, stated as an executable claim: a `Shared` whose
    // strings are all empty still renders every row, so no row depends on a
    // syscall. The *content* of those rows is a separate question, and step 2B
    // answers it by printing "unavailable" rather than nothing.
    var storage: [1024]u8 = undefined;
    var out = buf.Buf.init(&storage);
    const empty: shared.Shared = .{};
    render(&out, &empty, .{});

    // Counting rows rather than matching text keeps this from becoming a third
    // copy of the golden literal. Header + OS + Kernel + Arch + Shell + Uptime;
    // Memory is skipped because total is 0, which is the encoding that commit B
    // turns into "unavailable". No benchmark trailer, so no seventh row.
    var rows: usize = 0;
    for (out.written()) |b| {
        if (b == '\n') rows += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), rows);
}
