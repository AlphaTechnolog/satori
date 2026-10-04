//! Shared libc surface.
//!
//! Struct *layouts* always come from the generated `src/c.zig` — never from
//! hand-written `extern struct` declarations. See test/layout.zig for why.
//!
//! Function *signatures* are re-exported from `c.zig` where it already provides
//! them, so there is exactly one declaration per libc function in the project.
//! Signatures are hand-written only where translate-c could not reach the
//! header (see macos.zig), and only when they take and return integers, which
//! cannot be subtly wrong the way a struct layout can.

const c = @import("c");
const std = @import("std");

pub const uname = c.uname;
pub const gethostname = c.gethostname;
pub const getenv = c.getenv;
pub const sysconf = c.sysconf;
pub const write = c.write;
pub const getpagesize = c.getpagesize;

pub const utsname = c.struct_utsname;

/// Hostname buffer size. `gethostname` truncates rather than failing, so this
/// only needs to be as large as a legal hostname plus the NUL.
pub const MAX_HOSTNAME = 256;

// --- struct timespec, and why musl needs a fallback ----------------------------
//
// glibc and Darwin give us a complete `struct_timespec` and we use it unchanged.
// musl does not, and the reason is specific:
//
//     struct timespec { time_t tv_sec;
//                       int :8*(sizeof(time_t)-sizeof(long))*(__BYTE_ORDER==4321);
//                       long tv_nsec;
//                       int :8*(sizeof(time_t)-sizeof(long))*(__BYTE_ORDER!=4321); };
//
// Those are *zero-width anonymous bitfields*, a musl endianness-assertion
// idiom. translate-c cannot represent an unnamed bitfield, so it gives up on the
// whole struct and emits `pub const struct_timespec = opaque {}`.
//
// The important part is that the layout is still *derivable*, not a guess: each
// bitfield is `8 * (sizeof(time_t) - sizeof(long))` bits wide, which is zero
// exactly when `sizeof(time_t) == sizeof(long)`. When those are equal the padding
// contributes nothing regardless of endianness and the struct is precisely
//
//     { time_t tv_sec; long tv_nsec; }
//
// so the declaration below is correct by construction on every target where the
// assertion holds. The `comptime` block enforces that premise instead of hoping
// it: a musl target with a 32-bit `long` and 64-bit `time_t` would fail to
// compile here rather than silently read the clock at the wrong offsets.
//
// This is the sanctioned exception to "never hand-write a struct layout", and it
// is narrow on purpose: it applies to exactly one struct, on exactly one libc,
// and only where the generator has demonstrably given up. test/layout.zig pins
// the resulting offsets, so the premise is checked a second time from the other
// direction.
const timespec_is_opaque = @typeInfo(c.struct_timespec) == .@"opaque";

const MuslTimespec = extern struct {
    tv_sec: c.time_t,
    tv_nsec: c_long,
};

comptime {
    if (timespec_is_opaque) {
        if (@sizeOf(MuslTimespec) != 16) {
            @compileError("musl struct timespec fallback is the wrong size");
        }
        if (c.time_t != c_long) {
            @compileError(
                "musl's struct timespec carries non-zero-width anonymous " ++
                    "bitfields on this target (sizeof(time_t) != sizeof(long)), " ++
                    "so its layout is NOT {time_t, long}. Refusing to build.",
            );
        }
    }
}

/// The effective `struct timespec` for this target.
pub const timespec = if (timespec_is_opaque) MuslTimespec else c.struct_timespec;

/// The generated bindings disagree on `clockid_t`: c_uint on Darwin, c_int on
/// glibc. Take the bindings' own type rather than assuming.
pub const clockid_t = c.clockid_t;

pub fn clockGetTime(clockid: clockid_t, ts: *timespec) c_int {
    // Both branches are pruned at comptime, so exactly one symbol is ever
    // referenced. Without `comptime` on the condition, both survive to codegen
    // and the local declaration reaches the linker as an undefined symbol —
    // libc exports clock_gettime, never this alias. That is what broke the musl
    // link with `undefined symbol: musl_clock_gettime`.
    if (comptime timespec_is_opaque) {
        return musl_clock_gettime(clockid, ts);
    } else {
        return c.clock_gettime(clockid, ts);
    }
}

/// musl-only. libc exports `clock_gettime`; this exists purely to bind that
/// symbol to the effective timespec type, since the generated declaration takes
/// a pointer to an `opaque {}` struct that cannot be pointed at anything.
///
/// `linkName` is what makes this correct. A plain `extern fn musl_clock_gettime`
/// asks the linker for a symbol literally named that, which does not exist and
/// failed with `undefined symbol: musl_clock_gettime`. Pruning the *call site* at
/// comptime is not enough: the extern declaration still reaches the linker.
/// Naming the real symbol sidesteps the problem entirely, and there is then no
/// way for this to break the link on any target.
const musl_clock_gettime = @extern(*const fn (clockid_t, *MuslTimespec) callconv(.c) c_int, .{
    .name = "clock_gettime",
});

/// Copy a NUL-terminated C buffer into a bounded slice.
///
/// Every C-string boundary in satori funnels through here. The NUL search is
/// bounded by the buffer length so an unterminated field cannot run off the
/// end — the exact off-by-one class of bug that motivates never handling C
/// strings directly. A buffer with no NUL yields the whole buffer rather than
/// reading garbage.
pub fn strFromC(raw: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
    return raw[0..end];
}

/// Read a `getenv` result as a bounded slice. Returns null when unset.
pub fn env(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    return v[0..std.mem.len(v)];
}

/// Monotonic clock in nanoseconds. Used for every duration measurement so that
/// wall-clock adjustments cannot produce a negative uptime.
pub fn monotonicNs() i64 {
    var ts: timespec = std.mem.zeroes(timespec);
    if (clockGetTime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(i64, @intCast(ts.tv_nsec));
}

/// Wall clock in nanoseconds since the Unix epoch.
pub fn realtimeNs() i64 {
    var ts: timespec = std.mem.zeroes(timespec);
    if (clockGetTime(c.CLOCK_REALTIME, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(i64, @intCast(ts.tv_nsec));
}

test "monotonic clock advances" {
    const a = monotonicNs();
    const b = monotonicNs();
    try std.testing.expect(a > 0);
    // Monotonic means non-decreasing. A decreasing reading would be a real bug,
    // and it is the one property uptime depends on.
    try std.testing.expect(b >= a);
}

test "wall clock is near the monotonic clock's magnitude" {
    // Not an equality check: the two differ by uptime. This catches a swapped
    // clock id or a seconds/nanoseconds mix-up, which would show up as a value
    // wildly out of range rather than as a subtle drift.
    const wall = realtimeNs();
    const mono = monotonicNs();
    try std.testing.expect(wall > 1_600_000_000_000_000_000);
    try std.testing.expect(mono > 0);
}
