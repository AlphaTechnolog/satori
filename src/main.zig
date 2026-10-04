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
const posix = @import("posix");
const macos = @import("macos");
const fmt = @import("fmt");
const c = @import("c");
const builtin = @import("builtin");
const std = @import("std");

/// Large enough for the full default field set with generous headroom for long
/// hostnames, package counts and bar rendering. Stack-allocated: the default
/// path performs zero allocations.
const OUTPUT_CAP = 64 * 1024;

var stdout_buf: [OUTPUT_CAP]u8 = undefined;

/// Scratch space for a formatted field value. Kept separate from stdout_buf so a
/// value can be formatted before its label is written — see render().
var value_storage: [256]u8 = undefined;

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
    render(&out, &sh, opts);
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

fn render(out: *buf.Buf, sh: *const shared.Shared, opts: Options) void {
    var scratch: [512]u8 = undefined;

    out.sgr("1;36");
    out.write(sh.user.slice());
    out.sgr("1;34");
    out.write("@");
    out.sgr("0");
    out.write(sh.hostname.slice());
    out.writeByte('\n');
    out.sgr("0");

    if (builtin.os.tag == .macos) {
        const ver = macos.osVersion(&scratch);
        out.field("OS", if (ver.len > 0) ver else sh.release.slice());
        out.field("Kernel", sh.release.slice());
        out.field("Arch", sh.machine.slice());
    } else {
        out.field("OS", sh.sysname.slice());
        out.field("Kernel", sh.release.slice());
        out.field("Arch", sh.machine.slice());
    }

    out.field("Shell", sh.shell.slice());

    // Format into a SEPARATE buffer before calling field. Passing `out` to both
    // fmt.duration and field mutates the same buffer twice: argument evaluation
    // runs duration first, so the value lands *before* its own label and the row
    // reads "50sUptime: 50s". Compute, then emit.
    var val: buf.Buf = buf.Buf.init(&value_storage);
    val.len = 0;
    _ = fmt.duration(&val, sh.uptimeSeconds());
    out.field("Uptime", val.written());

    if (builtin.os.tag == .macos) {
        const vm = macos.vmStats();
        if (vm.total > 0) {
            out.write("Memory: ");
            _ = fmt.bytes(out, vm.used());
            out.write(" / ");
            _ = fmt.bytes(out, vm.total);
            out.writeByte('\n');
        }
    }

    if (opts.benchmark) {
        out.writeByte('\n');
        out.write("shared load complete; no forks, one write\n");
    }
}

const usage =
    \\satori — system information, fast
    \\
    \\Usage: satori [options]
    \\
    \\  -h, --help      show this help
    \\      --no-color   disable ANSI colour
    \\      --benchmark  print timing diagnostics
    \\
    \\More fields land incrementally; see plan §15 for the milestone table.
    \\
;
