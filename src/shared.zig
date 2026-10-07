//! Data fetched exactly once and shared by every module.
//!
//! This is the cutefetch pattern and the reason nothing is recomputed: `uname`,
//! boot time, page size, hostname and the environment are gathered a single time
//! in `load()`, then passed by pointer to each module as `*Shared`. A module
//! that wants the kernel version does not call `uname()` again.
//!
//! `Shared` is safe to copy: every string is a `buf.Str`, which carries its own
//! inline storage rather than pointing into a shared arena. Returning by value
//! would otherwise leave slices aimed at the original's arena.

const buf = @import("buf");
const posix = @import("posix");
const c = @import("c");
const builtin = @import("builtin");
const std = @import("std");

const Str = buf.Str;

/// Memory in bytes.
///
/// The platform layers disagree about what "used" means — on macOS it is
/// active+inactive+wired+compressed, *not* `total - free`, because `free_count`
/// there counts only untouched pages — so the figure is computed where the
/// semantics live and carried, never re-derived by the renderer.
pub const MemStats = struct {
    used: u64 = 0,
    total: u64 = 0,
};

pub const Shared = struct {
    // --- strings, all resolved once ---
    sysname: Str = .{},
    release: Str = .{},
    machine: Str = .{},
    hostname: Str = .{},
    user: Str = .{},
    shell: Str = .{},

    /// macOS product version ("26.6.2"), empty when the sysctl is unavailable.
    /// There is no Linux equivalent and that is not a gap: on Linux
    /// `uname().sysname` already carries the distribution name, so the OS row
    /// reads that instead. See render.zig's `osValue`.
    os_version: Str = .{},
    /// Hardware model identifier, e.g. "MacBookAir10,1". Empty when unavailable.
    hw_model: Str = .{},
    /// CPU brand string. Empty when unavailable.
    cpu_brand: Str = .{},

    // --- scalars ---
    page_size: u64 = 0,
    /// Memory, resolved once. `total == 0` is the absence encoding: the renderer
    /// prints "unavailable" rather than a plausible "0 B / 0 B". It is also
    /// today's encoding on Linux, where no memory source is gathered yet (step 4).
    mem: MemStats = .{},
    /// Logical CPU core count. `cpu_threads == 0` is the absence encoding.
    cpu_threads: u64 = 0,
    /// Boot time as seconds since the Unix epoch, 0 if unavailable.
    boot_unix: i64 = 0,
    /// CLOCK_MONOTONIC reading taken at the same moment as boot_unix, so
    /// uptime can be computed without a second syscall.
    boot_mono: i64 = 0,
    /// CLOCK_MONOTONIC now.
    mono_now: i64 = 0,
    /// CLOCK_REALTIME now.
    real_now: i64 = 0,

    /// Gather everything. Safe to call on a freshly default-initialised value.
    ///
    /// `load` takes `*Shared` and mutates in place rather than returning a new
    /// value, so the inline string buffers keep the addresses the caller sees.
    pub fn load(self: *Shared) void {
        var uts: posix.utsname = std.mem.zeroes(posix.utsname);
        if (c.uname(&uts) == 0) {
            self.sysname.setZ(&uts.sysname);
            self.release.setZ(&uts.release);
            self.machine.setZ(&uts.machine);
            // Darwin reports a 256-byte machine field ("arm64"); Linux a
            // 65-byte one ("x86_64"). setZ trims at the NUL for both.
        }

        var hb: [posix.MAX_HOSTNAME]u8 = @splat(0);
        if (c.gethostname(&hb, hb.len - 1) == 0) {
            self.hostname.set(posix.strFromC(&hb));
        }

        if (posix.env("USER")) |v| self.user.set(v);
        if (posix.env("LOGNAME")) |v| {
            // Prefer LOGNAME when set: on many systems USER is inherited from a
            // login shell and stale, while LOGNAME tracks the actual session.
            if (self.user.len == 0) self.user.set(v);
        }
        if (posix.env("SHELL")) |v| self.shell.set(basename(v));

        self.real_now = posix.realtimeNs();

        const plat = switch (builtin.os.tag) {
            .macos => @import("macos"),
            .linux => @import("linux"),
            else => @import("posix"),
        };
        self.page_size = plat.pageSize();

        // The remaining rows. `osVersion` and `vmStats` were called by render()
        // itself until step 2, which made the renderer impure: a golden test of
        // it would have baked in whatever machine the test ran on. Everything the
        // renderer prints is gathered here instead, which is the whole point of
        // this type.
        //
        // The comptime switch is load-bearing rather than tidy. `linux.zig` has
        // no `vmStats` at all (step 4 adds it), so an unconditional call would
        // not compile there; and the Mach calls do not exist on Linux. A field
        // with no source on this platform keeps its default, and the renderer
        // reports that as "unavailable".
        switch (builtin.os.tag) {
            .macos => {
                const macos = @import("macos");
                var scratch: [256]u8 = undefined;
                self.os_version.set(macos.osVersion(&scratch));
                self.hw_model.set(macos.hwModel(&scratch));
                self.cpu_brand.set(macos.cpuBrand(&scratch));
                self.cpu_threads = macos.threadCount();
                const vm = macos.vmStats();
                self.mem.used = vm.used();
                self.mem.total = vm.total;
            },
            else => {},
        }

        // kern.boottime / CLOCK_BOOTTIME report boot as an instant counted from
        // the wall-clock epoch, but uptime must be measured on CLOCK_MONOTONIC so
        // that an NTP step or a DST change cannot make it jump or go negative.
        // So: take boot time in wall-clock terms, then convert it into the
        // monotonic domain by subtracting the elapsed wall-clock interval.
        //
        // Reading the monotonic clock *before* boot time and subtracting would
        // give a negative delta — that bug shipped once and printed an empty
        // uptime field.
        const bt = plat.bootTime();
        self.boot_unix = bt.unix;
        self.mono_now = posix.monotonicNs();
        if (bt.unix > 0) {
            const uptime_ns = self.real_now - bt.unix * 1_000_000_000;
            self.boot_mono = self.mono_now - uptime_ns;
        } else {
            self.boot_mono = 0;
        }
    }

    /// Whole seconds since boot, from the monotonic clock.
    pub fn uptimeSeconds(self: *const Shared) i64 {
        if (self.boot_mono == 0) return 0;
        const delta = self.mono_now - self.boot_mono;
        if (delta <= 0) return 0;
        return @divTrunc(delta, 1_000_000_000);
    }

    /// Uptime computed from wall-clock difference to boot time. Used as a
    /// cross-check against the monotonic value; a large disagreement means
    /// something is wrong with one of them.
    pub fn uptimeFromClock(self: *const Shared) i64 {
        if (self.boot_unix == 0) return 0;
        return @divTrunc(self.real_now - self.boot_unix * 1_000_000_000, 1_000_000_000);
    }

    fn basename(path: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
        return path;
    }
};

test "basename strips directories" {
    try std.testing.expectEqualStrings("zsh", Shared.basename("/bin/zsh"));
    try std.testing.expectEqualStrings("zsh", Shared.basename("zsh"));
    try std.testing.expectEqualStrings("", Shared.basename("/"));
}

test "uptime never goes negative" {
    var s: Shared = .{};
    s.mono_now = 100;
    s.boot_mono = 200; // clock went backwards
    try std.testing.expectEqual(@as(i64, 0), s.uptimeSeconds());
}
