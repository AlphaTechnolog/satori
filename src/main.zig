//! satori entry point.
//!
//! Pipeline: shared -> modules -> render -> one write(2).
//!
//! INVARIANT: exactly one write(2) for the whole program, at the end. Output is
//! composed into a single stack buffer and flushed once. This is not a style
//! preference — interleaving writes with subprocess pipes is what makes a fetch
//! tool slow, and a single write makes the output atomic with respect to other
//! terminal writers.
//!
//! INVARIANT: nothing on this path forks. See plan §4.

const buf = @import("buf");
const shared = @import("shared");
const render = @import("render");
const c = @import("c");
const std = @import("std");

/// Large enough for the full default field set with generous headroom for long
/// hostnames, package counts and bar rendering. Stack-allocated: the default
/// path performs zero allocations.
const OUTPUT_CAP = 64 * 1024;

var stdout_buf: [OUTPUT_CAP]u8 = undefined;

/// Zig 0.17 replaced `std.process.argsAlloc` with an `Init.Minimal` parameter.
/// That is strictly better here: argv is handed over as a vector of C strings
/// with no copy and no allocation, which keeps "zero allocations on the default
/// path" true for argument handling as well as data gathering.
///
/// `Minimal` rather than the full `Init` on purpose — the full form sets up an
/// arena, a general-purpose allocator and leak checking, none of which a program
/// that writes one buffer needs.
pub fn main(init: std.process.Init.Minimal) !void {
    const opts = parseArgs(init.args);

    if (opts.help) {
        emit(usage);
        return;
    }

    var sh: shared.Shared = .{};
    sh.load();

    var out = buf.Buf.init(&stdout_buf);
    render.render(&out, &sh, .{ .benchmark = opts.benchmark });
    flush(out.written());
}

/// Write the whole program output in one syscall.
fn flush(bytes: []const u8) void {
    if (bytes.len == 0) return;
    _ = c.write(1, bytes.ptr, bytes.len);
}

fn emit(bytes: []const u8) void {
    var b: [256]u8 = undefined;
    const n = @min(bytes.len, b.len);
    @memcpy(b[0..n], bytes[0..n]);
    _ = c.write(2, b[0..n].ptr, n);
}

const Options = struct {
    help: bool = false,
    benchmark: bool = false,
    /// Parsed but deliberately not advertised in `usage` and not honoured yet.
    ///
    /// `--no-color` used to be listed in the help text while `render()` ignored
    /// it, so `--help` documented a flag that demonstrably did nothing
    /// (`satori --no-color | cat -v` still emitted escapes). Advertising it was
    /// the lie; the parser keeps accepting it so a script passing it does not
    /// start failing, but nothing should rely on the output being plain until
    /// `buf.Buf` grows a `color: bool` and `sgr()` early-returns on it.
    disable_color: bool = false,
};

fn parseArgs(args: std.process.Args) Options {
    var o: Options = .{};
    var it = args.iterate();
    _ = it.next(); // argv[0], the program path
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            o.help = true;
        } else if (std.mem.eql(u8, arg, "--benchmark")) {
            o.benchmark = true;
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            o.disable_color = true;
        }
    }
    return o;
}

const usage =
    \\satori — system information, fast
    \\
    \\Usage: satori [options]
    \\
    \\  -h, --help      show this help
    \\      --benchmark  print timing diagnostics
    \\
    \\More fields land incrementally; see plan §15 for the milestone table.
    \\
;
