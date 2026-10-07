//! Human-readable formatters.
//!
//! Each writes into the caller's `Buf` and returns the slice it produced, so the
//! caller can use the value inline (`out.field("Uptime", fmt.duration(out, s))`)
//! without a temporary buffer. Returning a sub-slice of the same buffer keeps the
//! zero-allocation property intact.

const buf = @import("buf");
const std = @import("std");

/// Binary units, matching `df -h` and Activity Monitor: 1024-based with IEC
/// labels. neofetch used 1024-based with SI labels (kB/MB/GB), which is
/// technically wrong; this is the correctness improvement noted in the plan.
pub fn bytes(out: *buf.Buf, v: u64) []const u8 {
    const start = out.len;
    const unit = "B";
    const KiB: u64 = 1024;
    const MiB = KiB * 1024;
    const GiB = MiB * 1024;
    const TiB = GiB * 1024;

    if (v < KiB) {
        out.writeUint(v);
        out.writeByte(' ');
        out.write(unit);
    } else if (v < MiB) {
        out.writeFixed(v * 10 / KiB, 1);
        out.write(" KiB");
    } else if (v < GiB) {
        out.writeFixed(v * 10 / MiB, 1);
        out.write(" MiB");
    } else if (v < TiB) {
        out.writeFixed(v * 10 / GiB, 1);
        out.write(" GiB");
    } else {
        out.writeFixed(v * 10 / TiB, 1);
        out.write(" TiB");
    }
    return out.written()[start..];
}

/// `3d 4h 5m`, dropping leading zero units. Matches neofetch's shape.
pub fn duration(out: *buf.Buf, seconds: i64) []const u8 {
    const start = out.len;
    if (seconds <= 0) return out.written()[start..];

    const days = @divTrunc(seconds, 86_400);
    const hours = @divTrunc(@mod(seconds, 86_400), 3_600);
    const mins = @divTrunc(@mod(seconds, 3_600), 60);
    const secs = @mod(seconds, 60);

    if (days > 0) {
        out.writeUint(@intCast(days));
        out.write("d ");
    }
    if (days > 0 or hours > 0) {
        out.writeUint(@intCast(hours));
        out.write("h ");
    }
    if (days > 0 or hours > 0 or mins > 0) {
        out.writeUint(@intCast(mins));
        out.write("m ");
    }
    out.writeUint(@intCast(secs));
    out.write("s");
    return out.written()[start..];
}

/// Unsigned integer.
pub fn uint(out: *buf.Buf, v: u64) []const u8 {
    const start = out.len;
    out.writeUint(v);
    return out.written()[start..];
}

/// Percentage with one decimal, e.g. `46.2%`.
pub fn percent(out: *buf.Buf, numerator: u64, denominator: u64) []const u8 {
    const start = out.len;
    if (denominator == 0) return out.written()[start..];
    // Multiply before dividing to keep two decimal places of precision without
    // floating point.
    out.writeFixed(numerator * 1000 / denominator, 1);
    out.writeByte('%');
    return out.written()[start..];
}

/// Left-pad `s` to `width` bytes so columns line up.
pub fn padLeft(out: *buf.Buf, s: []const u8, width: usize) void {
    var i = s.len;
    while (i < width) : (i += 1) out.writeByte(' ');
    out.write(s);
}

/// Right-pad `s` to `width` bytes.
pub fn padRight(out: *buf.Buf, s: []const u8, width: usize) void {
    out.write(s);
    var i = s.len;
    while (i < width) : (i += 1) out.writeByte(' ');
}

test "bytes uses IEC units" {
    var storage: [64]u8 = undefined;
    var b = buf.Buf.init(&storage);
    try std.testing.expectEqualStrings("0 B", bytes(&b, 0));
    b.len = 0;
    try std.testing.expectEqualStrings("1.0 KiB", bytes(&b, 1024));
    b.len = 0;
    try std.testing.expectEqualStrings("1.5 MiB", bytes(&b, 1024 * 1024 * 3 / 2));
    b.len = 0;
    try std.testing.expectEqualStrings("999 B", bytes(&b, 999));
}

test "duration drops leading zero units" {
    var storage: [64]u8 = undefined;
    var b = buf.Buf.init(&storage);
    try std.testing.expectEqualStrings("5s", duration(&b, 5));
    b.len = 0;
    try std.testing.expectEqualStrings("2m 5s", duration(&b, 125));
    b.len = 0;
    try std.testing.expectEqualStrings("1d 0h 0m 0s", duration(&b, 86_400));
    b.len = 0;
    try std.testing.expectEqualStrings("1h 1m 1s", duration(&b, 3_661));
}

test "percent guards divide by zero" {
    var storage: [32]u8 = undefined;
    var b = buf.Buf.init(&storage);
    try std.testing.expectEqualStrings("", percent(&b, 1, 0));
    b.len = 0;
    try std.testing.expectEqualStrings("46.2%", percent(&b, 462, 1000));
}
