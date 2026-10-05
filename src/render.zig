//! The renderer: a comptime field registry over already-gathered data.
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
//! into `Shared.load()`, because a renderer that performs live syscalls bakes
//! the machine it ran on into whatever a golden test compares against. A field
//! that needs a value it cannot get belongs in `load()`.
//!
//! INVARIANT — no escape sequence reaches the output except through `Buf.sgr`,
//! and there is exactly one function (`row`) that writes a label and its value.
//!
//! `Buf.field` used to be that second path, and it is how the Memory row ended
//! up hand-writing `"Memory: "`: a row emitter that knows nothing about colour
//! or alignment is a row emitter that can be forgotten. Deleting it means the
//! registry is structurally the only way a row gets printed.
//!
//! INVARIANT — a formatter writes into a scratch buffer, never into `out`.
//!
//! This is what kills the `50sUptime: 50s` ordering bug. The old code passed
//! `out` to both `fmt.duration` and `field`, and argument evaluation ran the
//! formatter first, so the value landed before its own label; it was held off by
//! a separate `value_storage` buffer plus a comment warning about exactly this.
//! The descriptor's signature makes the hazard unrepresentable: `fmtFn` is handed
//! a `scratch` it owns and is given no way to reach the output.

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
    /// `--no-color`: emit no SGR escapes. Defaults to colour on, so a caller
    /// that says nothing gets today's behaviour.
    color: bool = true,
    /// `--benchmark`: append the timing trailer.
    benchmark: bool = false,
};

/// One output row.
///
/// `color` is the SGR code its *label* is painted; the value is left at the
/// terminal's default, as neofetch's `print_info` does. It is per-row rather than
/// one program-wide constant because rows group into two kinds of information
/// and the two are worth telling apart at a glance.
const Field = struct {
    label: []const u8,
    color: []const u8,
    /// Writes this field's value into `scratch`, which it owns. Never writes to
    /// `out`, and never retains the slice — the renderer consumes it immediately.
    fmtFn: *const fn (scratch: *buf.Buf, sh: *const shared.Shared) void,
};

/// Label colours, grouped by what the row is telling you.
const palette = struct {
    /// What this machine *is*.
    const identity = "1;32"; // bold green
    /// What it is doing *right now*.
    const state = "1;33"; // bold yellow
    /// The header line, which is not a field.
    const user = "1;36"; // bold cyan
    const at = "1;34"; // bold blue
};

/// The registry: every default row, in output order.
///
/// One array, because every field today has a defined answer on every supported
/// platform — `total == 0` rather than "this row does not exist here". Where the
/// *source* of a row differs by platform (the OS row) the difference lives in
/// that field's formatter, which switches on `builtin.os.tag` at comptime. When
/// step 4 adds a row that exists on only one platform, that array becomes a
/// per-platform comptime switch around a shared base.
///
/// Adding a field is one line here plus one `fn`. Nothing about ordering,
/// alignment or colour needs to change.
const fields = [_]Field{
    .{ .label = "OS", .color = palette.identity, .fmtFn = os },
    .{ .label = "Kernel", .color = palette.identity, .fmtFn = kernel },
    .{ .label = "Arch", .color = palette.identity, .fmtFn = arch },
    .{ .label = "Shell", .color = palette.identity, .fmtFn = shell },
    .{ .label = "Uptime", .color = palette.state, .fmtFn = uptime },
    .{ .label = "Memory", .color = palette.state, .fmtFn = memory },
};

/// Width of the `Label:` column, derived from the registry at comptime.
///
/// Hardcoding it would mean step 3's longer labels ("Terminal Font",
/// "Resolution") silently broke the alignment and nobody would notice until it
/// was looked at; deriving it means adding a field cannot. This is the concrete
/// return on making the registry comptime.
///
/// The guarantee the row emitter relies on: `LABEL_COLON_WIDTH >= label.len + 1`
/// for every row, so the padding subtraction cannot underflow.
const LABEL_COLON_WIDTH = blk: {
    var w: usize = 0;
    for (fields) |f| {
        if (f.label.len + 1 > w) w = f.label.len + 1;
    }
    break :blk w;
};

/// Write the whole report into `out`. The caller owns `out`'s storage; nothing
/// here allocates.
pub fn render(out: *buf.Buf, sh: *const shared.Shared, opts: Options) void {
    var storage: [VALUE_CAP]u8 = undefined;

    // Set once, here, and nowhere else. Every escape in the program is emitted
    // by `Buf.sgr`, which consults this, so this assignment is the complete
    // implementation of --no-color.
    out.color = opts.color;

    header(out, sh);

    for (fields) |f| {
        var scratch = buf.Buf.init(&storage);
        f.fmtFn(&scratch, sh);
        row(out, f, scratch.written());
    }

    if (opts.benchmark) {
        out.writeByte('\n');
        out.write("shared load complete; no forks, one write\n");
    }
}

/// One `Label: value` line.
///
/// The only place a label is written, which is what makes "every escape goes
/// through `sgr`" and "every row is aligned" the same statement.
///
/// The pad goes *after* the colon rather than after the label, so values line up
/// on one column regardless of label length: `OS:     26.6.2` and
/// `Kernel: 25.6.0` share a value column. Padding the label instead would put
/// the colon in a ragged place, which is what neofetch avoids.
fn row(out: *buf.Buf, f: Field, value: []const u8) void {
    out.sgr(f.color);
    out.write(f.label);
    out.sgr("0");
    out.writeByte(':');
    // Safe by construction: LABEL_COLON_WIDTH is the max of label.len + 1 over
    // this same array.
    out.writeRepeat(' ', LABEL_COLON_WIDTH - (f.label.len + 1));
    out.writeByte(' ');
    out.write(value);
    out.writeByte('\n');
}

/// The `user@host` line above the fields.
///
/// Not a registry entry: it is not a `Label: value` row, and pretending otherwise
/// would mean a `Field` variant with the column layout switched off. Its escapes
/// still go through `sgr()`, which is the part that has to be total.
fn header(out: *buf.Buf, sh: *const shared.Shared) void {
    out.sgr(palette.user);
    out.write(text(sh.user.slice()));
    out.sgr(palette.at);
    out.writeByte('@');
    out.sgr("0");
    out.write(text(sh.hostname.slice()));
    out.writeByte('\n');
}

// ---------------------------------------------------------------------------
// Formatters — one per registry entry
// ---------------------------------------------------------------------------

/// Copy a resolved string, or say so.
///
/// An empty source is not a value. `Shell: ` with nothing after it reads like a
/// bug in the tool rather than a fact about the environment, and an empty
/// `Uptime:` is the exact symptom of a boot-time source that failed — which
/// shipped once. Every missing source in this project prints `unavailable`.
fn text(s: []const u8) []const u8 {
    return if (s.len == 0) "unavailable" else s;
}

fn os(scratch: *buf.Buf, sh: *const shared.Shared) void {
    switch (builtin.os.tag) {
        // "Darwin" as an OS name tells a reader nothing, and the product version
        // is what "OS" has always meant on macOS; `uname().release` is the
        // fallback when the sysctl is unavailable.
        .macos => scratch.write(if (sh.os_version.len > 0)
            sh.os_version.slice()
        else
            text(sh.release.slice())),
        // On Linux `uname().sysname` already carries the distribution name
        // ("Debian GNU/Linux", "Ubuntu") and there is no product version to
        // prefer — `release` would be the *kernel* version and would mislabel
        // the row.
        else => scratch.write(text(sh.sysname.slice())),
    }
}

fn kernel(scratch: *buf.Buf, sh: *const shared.Shared) void {
    scratch.write(text(sh.release.slice()));
}

fn arch(scratch: *buf.Buf, sh: *const shared.Shared) void {
    scratch.write(text(sh.machine.slice()));
}

fn shell(scratch: *buf.Buf, sh: *const shared.Shared) void {
    scratch.write(text(sh.shell.slice()));
}

fn uptime(scratch: *buf.Buf, sh: *const shared.Shared) void {
    // `uptimeSeconds` returns 0 when boot time was unavailable, and
    // `fmt.duration` renders 0 as the empty string, so this row needs the same
    // absence handling as a string source — otherwise it prints `Uptime: `.
    const secs = sh.uptimeSeconds();
    if (secs <= 0) return scratch.write("unavailable");
    _ = fmt.duration(scratch, secs);
}

fn memory(scratch: *buf.Buf, sh: *const shared.Shared) void {
    // total == 0 is `Shared`'s absence encoding. Printing "0 B / 0 B" would be a
    // plausible-looking wrong answer, which is the failure mode this project
    // treats as worse than a crash.
    if (sh.mem.total == 0) return scratch.write("unavailable");
    _ = fmt.bytes(scratch, sh.mem.used);
    scratch.write(" / ");
    _ = fmt.bytes(scratch, sh.mem.total);
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

/// ESC, spelled once. Concatenated rather than embedded as a raw byte so the
/// literal stays reviewable in a diff.
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
    // returns 0 when it is 0, which would render the row as `unavailable`.
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
        .macos => blk: {
            // header: user in bold cyan, "@" in bold blue, hostname uncoloured.
            // The reset before the hostname is load-bearing; the one this commit
            // removed sat after the newline, where it was a no-op.
            // Rows: label painted, reset, colon, pad to LABEL_COLON_WIDTH (7,
            // from "Kernel:"/"Memory:"), then one space. Every value therefore
            // starts at column 8.
            break :blk ESC ++ "[1;36mtester" ++ ESC ++ "[1;34m@" ++
                ESC ++ "[0mtestbox\n" ++
                ESC ++ "[1;32mOS" ++ ESC ++ "[0m:     26.6.2\n" ++ // osVersion
                ESC ++ "[1;32mKernel" ++ ESC ++ "[0m: 25.6.0\n" ++ // uname release
                ESC ++ "[1;32mArch" ++ ESC ++ "[0m:   arm64\n" ++ // uname machine
                ESC ++ "[1;32mShell" ++ ESC ++ "[0m:  zsh\n" ++ // basename of $SHELL
                ESC ++ "[1;33mUptime" ++ ESC ++ "[0m: 1h 1m 1s\n" ++ // fmt.duration(3661)
                ESC ++ "[1;33mMemory" ++ ESC ++ "[0m: 1.5 GiB / 8.0 GiB\n"; // used / total
        },
        // Linux: the OS row reads sysname, and no memory source is gathered yet
        // (step 4), so total == 0 and the row says so rather than vanishing.
        // The row *shape* is now identical on both arms — only these two values
        // differ.
        else => blk: {
            break :blk ESC ++ "[1;36mtester" ++ ESC ++ "[1;34m@" ++
                ESC ++ "[0mtestbox\n" ++
                ESC ++ "[1;32mOS" ++ ESC ++ "[0m:     Linux\n" ++
                ESC ++ "[1;32mKernel" ++ ESC ++ "[0m: 25.6.0\n" ++
                ESC ++ "[1;32mArch" ++ ESC ++ "[0m:   arm64\n" ++
                ESC ++ "[1;32mShell" ++ ESC ++ "[0m:  zsh\n" ++
                ESC ++ "[1;33mUptime" ++ ESC ++ "[0m: 1h 1m 1s\n" ++
                ESC ++ "[1;33mMemory" ++ ESC ++ "[0m: unavailable\n";
        },
    };
    try std.testing.expectEqualStrings(expected, out.written());
}

test "golden: every source absent" {
    // The all-missing case, which is the whole reason `unavailable` exists. It
    // needs no comptime switch: on both arms every field resolves to the absence
    // encoding, so both arms produce the identical bytes. That equality is itself
    // the assertion — an arm that ever printed a real value here would mean a
    // formatter was reading something it should not.
    var storage: [4096]u8 = undefined;
    var out = buf.Buf.init(&storage);
    const empty: shared.Shared = .{};
    render(&out, &empty, .{});

    // Header: no user and no hostname, but it still says so. Then the same seven
    // rows as the populated fixture with every value replaced by the absence
    // marker. Padding is unchanged, because padding comes from the labels and
    // not from the values.
    const expected = ESC ++ "[1;36munavailable" ++ ESC ++ "[1;34m@" ++
        ESC ++ "[0munavailable\n" ++
        ESC ++ "[1;32mOS" ++ ESC ++ "[0m:     unavailable\n" ++
        ESC ++ "[1;32mKernel" ++ ESC ++ "[0m: unavailable\n" ++
        ESC ++ "[1;32mArch" ++ ESC ++ "[0m:   unavailable\n" ++
        ESC ++ "[1;32mShell" ++ ESC ++ "[0m:  unavailable\n" ++
        ESC ++ "[1;33mUptime" ++ ESC ++ "[0m: unavailable\n" ++
        ESC ++ "[1;33mMemory" ++ ESC ++ "[0m: unavailable\n";
    try std.testing.expectEqualStrings(expected, out.written());
}

test "the registry is the only thing that decides row order and labels" {
    // Pins the registry itself, so a reordering or a renamed label cannot slip
    // past by also updating the golden literal. Cheap: 6 labels.
    const labels = [_][]const u8{ "OS", "Kernel", "Arch", "Shell", "Uptime", "Memory" };
    try std.testing.expectEqual(labels.len, fields.len);
    for (fields, labels) |f, want| {
        try std.testing.expectEqualStrings(want, f.label);
    }
    // LABEL_COLON_WIDTH is derived, not declared, so assert the consequence the
    // rows depend on rather than the constant: the widest label always fits.
    for (fields) |f| {
        try std.testing.expect(f.label.len + 1 <= LABEL_COLON_WIDTH);
    }
}

test "golden: --no-color emits the same report with zero escapes" {
    var storage: [4096]u8 = undefined;

    var plain = buf.Buf.init(&storage);
    const sh = fixture();
    render(&plain, &sh, .{ .color = false });

    const expected = switch (builtin.os.tag) {
        .macos => "tester@testbox\n" ++
            "OS:     26.6.2\n" ++
            "Kernel: 25.6.0\n" ++
            "Arch:   arm64\n" ++
            "Shell:  zsh\n" ++
            "Uptime: 1h 1m 1s\n" ++
            "Memory: 1.5 GiB / 8.0 GiB\n",
        else => "tester@testbox\n" ++
            "OS:     Linux\n" ++
            "Kernel: 25.6.0\n" ++
            "Arch:   arm64\n" ++
            "Shell:  zsh\n" ++
            "Uptime: 1h 1m 1s\n" ++
            "Memory: unavailable\n",
    };
    try std.testing.expectEqualStrings(expected, plain.written());

    // The claim `--no-color` makes is "no escape sequences", so count them over
    // the WHOLE output rather than trusting the equality above to imply it. Two
    // escapes that happened to cancel, or an escape byte inside a value, would
    // both pass a string comparison and fail this.
    var escapes: usize = 0;
    for (plain.written()) |b| {
        if (b == 0x1b) escapes += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), escapes);
}

test "colour changes the escapes and nothing else" {
    // The property that makes --no-color safe rather than merely present: turning
    // it off must not shift, drop or pad a byte of the report's actual content.
    // A naive "strip ESC and compare" would leave the SGR parameter text
    // ("[1;32m") behind, so the comparison removes whole escape sequences —
    // ESC '[' params 'm' — which is exactly what colour adds and nothing else.
    var coloured_storage: [4096]u8 = undefined;
    var plain_storage: [4096]u8 = undefined;

    const sh = fixture();
    var coloured = buf.Buf.init(&coloured_storage);
    render(&coloured, &sh, .{});
    var plain = buf.Buf.init(&plain_storage);
    render(&plain, &sh, .{ .color = false });

    var without = buf.Buf.init(coloured_storage[2048..]);
    try std.testing.expectEqualStrings(
        plain.written(),
        dropSgr(coloured.written(), &without),
    );
}

/// Copy `src` into `dst`, omitting every complete SGR sequence.
///
/// Deliberately only strips complete `ESC [ ... m` sequences: a lone ESC is
/// copied through, so an escape the renderer emitted in a shape this does not
/// recognise shows up as a test failure rather than being silently forgiven.
fn dropSgr(src: []const u8, dst: *buf.Buf) []const u8 {
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == 0x1b and i + 1 < src.len and src[i + 1] == '[') {
            var j = i + 2;
            while (j < src.len and src[j] != 'm') j += 1;
            if (j < src.len) {
                i = j + 1; // skip through the 'm'
                continue;
            }
        }
        dst.writeByte(src[i]);
        i += 1;
    }
    return dst.written();
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
