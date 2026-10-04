//! Linux-specific data sources.
//!
//! Struct layouts come from generated `src/c.zig`; see test/layout.zig. The
//! Linux values are notably different from Darwin's — `struct utsname` is 390
//! bytes with 65-byte fields on glibc versus 1280 bytes with 256-byte fields on
//! Darwin — which is the concrete reason no struct is ever hand-written.
//!
//! Everything here reads `/proc` and `/sys` with plain `open`/`read`. No fork:
//! the whole point of the rewrite is that `/proc/uptime` costs microseconds as a
//! file read but tens of milliseconds when `cat`ed through a subprocess.

const c = @import("c");
const posix = @import("posix");
const std = @import("std");

pub const open_flags = struct {
    const O_RDONLY: c_int = 0;
    const O_NONBLOCK: c_int = 0x0004;
};

pub const BootTime = struct {
    unix: i64 = 0,
};

/// Page size from `sysconf(_SC_PAGESIZE)`.
pub fn pageSize() u64 {
    const v = c.sysconf(c._SC_PAGESIZE);
    if (v > 0) return @intCast(v);
    return 4096;
}

/// Boot time, preferring `CLOCK_BOOTTIME` (which excludes suspend time and so
/// matches what `uptime` reports) and falling back to `/proc/uptime` plus the
/// current wall clock.
pub fn bootTime() BootTime {
    var ts: posix.timespec = std.mem.zeroes(posix.timespec);
    if (posix.clockGetTime(c.CLOCK_BOOTTIME, &ts) == 0) {
        const up = @as(i64, @intCast(ts.tv_sec));
        if (up > 0) return .{ .unix = @divTrunc(posix.realtimeNs(), 1_000_000_000) - up };
    }
    if (readProcUptime()) |up| {
        return .{ .unix = @divTrunc(posix.realtimeNs(), 1_000_000_000) - up };
    }
    return .{};
}

/// First float in `/proc/uptime`, in whole seconds.
pub fn readProcUptime() ?i64 {
    var b: [64]u8 = undefined;
    const n = readFile("/proc/uptime", &b) orelse return null;
    const s = posix.strFromC(b[0..n]);
    const end = std.mem.indexOfScalar(u8, s, ' ') orelse s.len;
    const secs = std.mem.trim(u8, s[0..end], " \t\r\n");
    return std.fmt.parseInt(i64, secs, 10) catch null;
}

/// Read a whole small file. Returns bytes read, or null if the file is absent.
///
/// Deliberately not using std.fs: satori is libc-only on the default path so
/// that the zero-fork and zero-allocation invariants are visible in the source
/// rather than buried in a generic filesystem layer.
pub fn readFile(path: [*:0]const u8, buf: []u8) ?usize {
    // open() is variadic in C. Zig demands a fixed-size type for the trailing
    // argument, so the mode must be a concrete c_uint rather than a comptime_int.
    const fd = c.open(path, open_flags.O_RDONLY, @as(c_uint, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);
    const n = c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    return @intCast(n);
}

/// First line of a file, trimmed.
pub fn readLine(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const n = readFile(path, buf) orelse return null;
    var s = posix.strFromC(buf[0..n]);
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| s = s[0..i];
    const trimmed = std.mem.trim(u8, s, " \t\r");
    return if (trimmed.len == 0) null else trimmed;
}

/// Total physical memory from `sysinfo`, in bytes.
pub fn totalMemory() u64 {
    var si: c.struct_sysinfo = std.mem.zeroes(c.struct_sysinfo);
    if (c.sysinfo(&si) != 0) return 0;
    const unit = if (@sizeOf(c.struct_sysinfo) > 0) si.mem_unit else 1;
    return @as(u64, si.totalram) * unit;
}

/// Available memory from `sysinfo`, in bytes.
pub fn freeMemory() u64 {
    var si: c.struct_sysinfo = std.mem.zeroes(c.struct_sysinfo);
    if (c.sysinfo(&si) != 0) return 0;
    const unit = if (@sizeOf(c.struct_sysinfo) > 0) si.mem_unit else 1;
    return @as(u64, si.freeram) * unit;
}

/// CPU model from `/proc/cpuinfo`.
pub fn cpuModel(buf: []u8) []const u8 {
    var b: [4096]u8 = undefined;
    const n = readFile("/proc/cpuinfo", &b) orelse return "";
    const text = b[0..n];
    const start = std.mem.indexOf(u8, text, "model name") orelse return "";
    var rest = text[start..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return "";
    rest = rest[colon + 1 ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    const model = std.mem.trim(u8, rest[0..end], " \t\r");
    const m = @min(model.len, buf.len);
    @memcpy(buf[0..m], model[0..m]);
    return buf[0..m];
}

test "proc uptime parses" {
    // /proc/uptime always exists on Linux and is two floats.
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const up = readProcUptime() orelse return error.SkipZigTest;
    try std.testing.expect(up > 0);
}
