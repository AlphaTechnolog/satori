//! Startup and per-phase benchmark harness.
//!
//! This is the gate for the project's central claim, so it is a real feature
//! (`--benchmark` in the main binary, this harness for CI) rather than a debug
//! flag. Plan §11: no concurrency work is allowed until this says a phase
//! actually costs something. On current hardware every phase is buried under
//! ~2 ms of process startup, which is exactly why the project is single-threaded.
//!
//! Timing uses `posix.monotonicNs()` — CLOCK_MONOTONIC via libc — rather than
//! `std.time.Timer`, which was removed in Zig 0.17. Two reasons that is not a
//! downgrade: the project is libc-only by design, and the same clock the program
//! already uses for uptime is the one the harness should measure with.
//!
//! Method: N repetitions of each phase after a discarded warm-up, because the
//! first call into any syscall family is several times more expensive than
//! steady state (vnode lookup, lazy symbol binding). Reported in microseconds,
//! since that is where every number actually lives.

const shared = @import("shared");
const render = @import("render");
const posix = @import("posix");
const macos = @import("macos");
const buf = @import("buf");
const c = @import("c");
const builtin = @import("builtin");
const std = @import("std");

/// Repetitions per phase. High enough that per-call cost is well below timer
/// resolution, low enough that the harness itself finishes instantly.
const RUNS = 1000;

pub fn main() !void {
    // --- warm-up, discarded ---------------------------------------------------
    // First-call costs (dynamic symbol resolution, vnode cache misses) are real
    // but they happen once in the actual binary too, so excluding them here
    // measures steady-state cost. The end-to-end measurement in test/startup.zig
    // is what captures cold-start reality.
    var warm: shared.Shared = .{};
    warm.load();
    var warm_scratch: [256]u8 = undefined;
    if (builtin.os.tag == .macos) {
        // Still warmed directly, even though load() now calls both: these two
        // lines are what makes the sub-measurements below comparable to the
        // earlier ones, and a phase whose first call is the only warm call in the
        // harness measures cold-start cost.
        _ = macos.osVersion(&warm_scratch);
        _ = macos.vmStats();
    }
    {
        var out: [16 * 1024]u8 = undefined;
        var b = buf.Buf.init(&out);
        render.render(&b, &warm, .{});
    }

    // --- phase timings --------------------------------------------------------
    var load_us: u64 = 0;
    {
        const t0 = posix.monotonicNs();
        for (0..RUNS) |_| {
            var s: shared.Shared = .{};
            s.load();
        }
        load_us = elapsedUs(t0, RUNS);
    }

    // Measured separately to show what load() is made of. Since step 2 these are
    // *inside* load(), so they are components of load_us and are no longer added
    // into the total — doing that would count them twice.
    var sysctl_us: u64 = 0;
    var vm_us: u64 = 0;
    if (builtin.os.tag == .macos) {
        var scratch: [256]u8 = undefined;
        const t1 = posix.monotonicNs();
        for (0..RUNS) |_| _ = macos.osVersion(&scratch);
        sysctl_us = elapsedUs(t1, RUNS);

        var sink: u64 = 0;
        const t2 = posix.monotonicNs();
        for (0..RUNS) |_| sink +%= macos.vmStats().total;
        std.mem.doNotOptimizeAway(sink);
        vm_us = elapsedUs(t2, RUNS);
    }

    // The renderer itself: pure formatting over data already in hand, and the
    // only thing step 2 added to the default path. It has to stay in the noise
    // next to load(), or the move into Shared bought nothing.
    var render_us: u64 = 0;
    {
        var out: [16 * 1024]u8 = undefined;
        var b = buf.Buf.init(&out);
        const t3 = posix.monotonicNs();
        for (0..RUNS) |_| {
            b.len = 0;
            render.render(&b, &warm, .{});
        }
        render_us = elapsedUs(t3, RUNS);
        std.mem.doNotOptimizeAway(b.written().len);
    }

    // --- output ---------------------------------------------------------------
    var out: [2048]u8 = undefined;
    var b = buf.Buf.init(&out);
    b.write("satori phase benchmark (");
    b.writeUint(RUNS);
    b.write(" iterations, warm)\n\n");

    b.write("  shared.load()           ");
    b.writeUint(load_us);
    b.write(" us   (every syscall the program makes)\n");

    if (builtin.os.tag == .macos) {
        b.write("    sysctl osprodversion ");
        b.writeUint(sysctl_us);
        b.write(" us     (inside load())\n");
        b.write("    host_statistics64    ");
        b.writeUint(vm_us);
        b.write(" us     (inside load())\n");
    }

    b.write("  render()                ");
    b.writeUint(render_us);
    b.write(" us   (formatting only, no syscall)\n");

    const total = load_us;
    b.write("\n  total data gathering   ");
    b.writeUint(total);
    b.write(" us\n");

    // The whole point. Amdahl's law says a thread is only worth adding if the
    // work it would overlap exceeds its own setup cost; at these numbers there is
    // nothing left to win, and a thread would cost more to create than the work
    // it could hide.
    if (total < 1000) {
        b.write("\n  verdict: data gathering is under 1 ms, so it is buried in\n");
        b.write("          process startup. No thread can pay for itself (plan §11).\n");
    } else {
        b.write("\n  verdict: data gathering exceeds 1 ms. Re-check before adding\n");
        b.write("          any concurrency: the numbers may have moved (plan §11).\n");
    }

    _ = c.write(1, b.written().ptr, b.written().len);
}

/// Nanoseconds spanned since `t0`, divided by `runs`, in microseconds.
fn elapsedUs(t0: i64, runs: u64) u64 {
    const delta = posix.monotonicNs() - t0;
    if (delta <= 0) return 0;
    return @intCast(@divTrunc(@divTrunc(delta, @as(i64, @intCast(runs))), 1000));
}
