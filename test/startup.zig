//! End-to-end startup benchmark and CI gate.
//!
//! test/bench.zig measures the phases *inside* satori. This measures the thing
//! users actually feel: the wall-clock time from "I typed the command" to "the
//! output appeared". Those differ by two orders of magnitude — all of satori's
//! data gathering is about 17 us, while a full run is over 1 ms — because the
//! cost is process creation, dynamic linking and the exit path, not work.
//!
//! WHY THIS IS ZIG AND NOT A SHELL SCRIPT OR PYTHON
//!
//! Every other gate in this project runs with no external tooling, because
//! "zero dependencies, hermetic build" is a property of the project rather than
//! an aspiration. Reaching for hyperfine or python3 here would make the
//! headline number the one measurement that cannot run anywhere the build
//! cannot. `zig build check` runs this; nothing else is needed.
//!
//! THIS HARNESS FORKS. That is deliberate and it is why this file is not part of
//! the shipped binary: tools/check-no-fork.sh proves the *program* cannot fork,
//! and a benchmark that spawns 400 processes obviously can. The invariant is
//! about satori, not about satori's test harness. The libc functions needed to
//! spawn are declared locally rather than pulled through src/c.h, because their
//! signatures are integer-only and trivial — the exact case where a hand-written
//! declaration cannot be subtly wrong (see src/platform/macos.zig for why that
//! distinction matters for layouts).

const buf = @import("buf");
const posix = @import("posix");
const c = @import("c");
const std = @import("std");

/// CI gate from the plan: startup median must stay under 3.5 ms.
const MEDIAN_GATE_US: u64 = 3_500;

/// Fixed capacity so the sample array lives on the stack and the harness itself
/// allocates nothing. Enough for a stable median; more runs only add noise from
/// the machine rather than information about satori.
const MAX_RUNS = 512;

const DEFAULT_RUNS = 200;

/// Discarded before measuring. The first executions pay for cold page cache and
/// first-touch vnode lookups; they are part of a real cold start but including
/// them in a median of 200 would tell us about the machine, not about satori.
const WARMUP = 20;

/// Longest binary path we will measure. PATH_MAX is 1024 on both platforms.
const PATH_MAX = 1024;

// --- spawning, declared locally ----------------------------------------------
// All integer or pointer-to-int signatures. No struct layout is involved, so
// unlike a hand-written extern struct these cannot be silently wrong.

extern fn fork() c_int;
extern fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
extern fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern fn _exit(code: c_int) noreturn;

const WNOHANG: c_int = 1;

/// Child exit code used when exec fails, so the parent can tell "measured a
/// program that ran" apart from "measured a program that failed instantly".
/// Without this a broken build would report a wonderful, meaningless startup
/// time, because a binary that dies at once is very fast.
const EXEC_FAILED: c_int = 127;

/// Child process exit code when it ran but reported failure.
const CHILD_FAILED: c_int = 1;

pub fn main(init: std.process.Init.Minimal) void {
    var it = init.args.iterate();
    _ = it.next(); // argv[0]

    const path_z = it.next() orelse {
        fail("usage: satori-startup <path-to-binary> [runs]");
        return;
    };
    const runs: usize = if (it.next()) |r| (std.fmt.parseInt(usize, r, 10) catch {
        fail("runs must be a positive integer");
        return;
    }) else DEFAULT_RUNS;

    if (runs == 0 or runs > MAX_RUNS) {
        fail("runs must be between 1 and 512");
        return;
    }

    // execv needs a NUL-terminated path. buf.Str is not suitable: it stores a
    // length and does not terminate, which is right for its purpose (carrying
    // fields) and wrong for this one. A sentinel-terminated array carries the
    // terminator in its type, so the guarantee cannot be forgotten.
    var path: [PATH_MAX:0]u8 = @splat(0);
    const path_len = @min(path.len - 1, path_z.len);
    @memcpy(path[0..path_len], path_z[0..path_len]);
    path[path_len] = 0;
    const path_c: [*:0]const u8 = &path;

    var samples: [MAX_RUNS]u64 = undefined;
    var failures: usize = 0;

    for (0..WARMUP + runs) |i| {
        const t0 = posix.monotonicNs();
        const ok = runOnce(path_c);
        const dt = posix.monotonicNs() - t0;

        if (!ok) {
            failures += 1;
            // A failed run has no meaningful duration, and including it would
            // drag the median down toward zero and pass the gate.
            continue;
        }
        if (i >= WARMUP) samples[i - WARMUP] = if (dt < 0) 0 else @intCast(@divTrunc(dt, 1000));
    }

    if (failures > 0) {
        var e: [512]u8 = undefined;
        var b = buf.Buf.init(&e);
        b.write("FAIL: ");
        b.writeUint(failures);
        b.write(" of ");
        b.writeUint(WARMUP + runs);
        b.write(" runs did not exit cleanly.\n");
        b.write("      A binary that dies immediately is very fast; measuring it\n");
        b.write("      would report a great startup time for a broken program.\n");
        flush(&b);
        _exit(CHILD_FAILED);
    }

    sort(samples[0..runs]);

    var out: [1024]u8 = undefined;
    var b = buf.Buf.init(&out);
    b.write("satori startup: ");
    b.writeUint(runs);
    b.write(" runs after ");
    b.writeUint(WARMUP);
    b.write(" warm-up\n\n");

    line(&b, "min", samples[0]);
    line(&b, "p25", samples[runs / 4]);
    line(&b, "median", samples[runs / 2]);
    line(&b, "p95", samples[(runs * 95) / 100]);
    line(&b, "max", samples[runs - 1]);

    const median = samples[runs / 2];
    b.write("\n  gate: median under 3.5 ms  ->  ");
    if (median < MEDIAN_GATE_US) {
        b.write("PASS (");
        b.writeFixed(median, 3);
        b.write(" ms)\n");
        flush(&b);
        return;
    }

    b.write("FAIL (");
    b.writeFixed(median, 3);
    b.write(" ms)\n");
    b.write("      neofetch takes about 138 ms on the same hardware, so this\n");
    b.write("      is still a large win — but the gate exists to stop the\n");
    b.write("      regression going unnoticed, not to be negotiated.\n");
    flush(&b);
    _exit(CHILD_FAILED);
}

/// Spawn the binary once with its output discarded. Returns false if it did not
/// exit cleanly, which the caller must treat as a failure rather than a sample.
fn runOnce(path: [*:0]const u8) bool {
    const pid = fork();
    if (pid < 0) return false;

    if (pid == 0) {
        // --- child: only async-signal-safe work from here ---
        // Redirect stdout and stderr to /dev/null so the child's output does not
        // land in the benchmark's own report, and so writing it is not measured.
        const devnull = c.open("/dev/null", c.O_WRONLY, @as(c_uint, 0));
        if (devnull >= 0) {
            _ = dup2(devnull, 1);
            _ = dup2(devnull, 2);
            if (devnull > 2) _ = c.close(devnull);
        }

        const argv = [_:null]?[*:0]const u8{ path, null };
        _ = execv(path, &argv);
        _exit(EXEC_FAILED); // only reached if exec failed
    }

    // --- parent: wait for the child, we want the whole lifetime ---
    var status: c_int = 0;
    while (true) {
        const r = waitpid(pid, &status, 0);
        if (r == pid) break;
        if (r < 0) return false;
        // Interrupted by a signal: retry rather than recording a bogus sample.
    }

    // Decode wait status without libc macros. A low byte of 0 means the child
    // exited normally; anything else means it was killed by a signal, which for
    // a fetch-info program would be a bug worth failing on.
    if ((status & 0x7f) != 0) return false;
    return ((status >> 8) & 0xff) == 0;
}

fn line(b: *buf.Buf, label: []const u8, us: u64) void {
    b.write("  ");
    b.write(label);
    b.writeRepeat(' ', 7 - label.len);
    b.writeFixed(us, 3);
    b.write(" ms\n");
}

/// Insertion sort. Slower than a real sort and irrelevant here: the harness runs
/// once, outside every measurement it takes, and has no allocator to sort with.
fn sort(s: []u64) void {
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        const v = s[i];
        var j = i;
        while (j > 0 and s[j - 1] > v) : (j -= 1) s[j] = s[j - 1];
        s[j] = v;
    }
}

fn fail(msg: []const u8) void {
    var e: [256]u8 = undefined;
    var b = buf.Buf.init(&e);
    b.write(msg);
    b.writeByte('\n');
    flush(&b);
    _exit(CHILD_FAILED);
}

/// One write(2) at exit, same as the shipped binary.
fn flush(b: *buf.Buf) void {
    const w = b.written();
    _ = posix.write(1, w.ptr, w.len);
}
