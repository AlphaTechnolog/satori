//! Slice-based output buffer.
//!
//! Why this exists: satori never handles C strings. `utsname` fields,
//! `getenv` results, and `sysctl` buffers are all `[*:0]u8` with off-by-one
//! traps. Every one of those becomes a `[:0]` sentinel-terminated slice that
//! `sliceTo` converts once, at the boundary. Downstream code only ever sees
//! `[]const u8` with an explicit length, which cannot be misread.
//!
//! No sentinels, no allocator, no `strdup`. Writes clamp rather than panic, so
//! a long hostname degrades to truncated output instead of a crash.

const std = @import("std");

/// Maximum bytes in a `Str`. Matches Darwin's `utsname` field width, which is
/// the largest string satori stores on the default path.
pub const MAX_FIELD = 256;

/// Fixed-capacity inline string carrying its own storage.
///
/// This exists instead of `[]const u8` pointing into a shared arena because of a
/// subtle hazard: a struct of arena-backed slices becomes invalid the moment it
/// is copied by value, since the slices still point at the original's arena.
/// `Shared` is returned by value from `load()`, so that hazard is real. Carrying
/// the buffer inline makes copying safe by construction, at the cost of ~256
/// bytes per field on the stack. No allocation either way.
pub const Str = struct {
    buf: [MAX_FIELD]u8 = @splat(0),
    len: usize = 0,

    pub fn slice(self: *const Str) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *Str, s: []const u8) void {
        const n = @min(s.len, MAX_FIELD);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
    }

    /// Set from a NUL-terminated C buffer of unknown length. `sliceTo` requires
    /// the NUL to actually be there; a field with no terminator would run off
    /// the end, which is why the caller passes a correctly-sized array.
    pub fn setZ(self: *Str, raw: []const u8) void {
        self.set(std.mem.sliceTo(raw, 0));
    }
};

pub fn strEq(a: Str, b: []const u8) bool {
    return std.mem.eql(u8, a.slice(), b);
}

pub const Buf = struct {
    buf: []u8,
    len: usize = 0,

    /// Wrap caller-owned storage. The caller owns the lifetime; `Buf` never
    /// allocates. This is what makes "zero allocations on the default path"
    /// structurally true rather than a convention.
    pub fn init(storage: []u8) Buf {
        return .{ .buf = storage };
    }

    pub fn written(self: *const Buf) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn remaining(self: *const Buf) usize {
        return self.buf.len - self.len;
    }

    pub fn isFull(self: *const Buf) bool {
        return self.len == self.buf.len;
    }

    /// Append, truncating on overflow.
    ///
    /// Returns nothing: every call site is appending to a buffer sized with
    /// headroom, and making them all discard a count was pure noise. Use
    /// `writeCount` where truncation actually needs detecting.
    pub fn write(self: *Buf, s: []const u8) void {
        _ = self.writeCount(s);
    }

    /// Append and report how many bytes were actually written, so a caller can
    /// detect truncation. A short return means the buffer filled up.
    pub fn writeCount(self: *Buf, s: []const u8) usize {
        const room = self.buf[self.len..];
        const n = @min(s.len, room.len);
        @memcpy(room[0..n], s[0..n]);
        self.len += n;
        return n;
    }

    pub fn writeByte(self: *Buf, b: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = b;
            self.len += 1;
        }
    }

    /// Repeat a byte, for bars and underlines.
    pub fn writeRepeat(self: *Buf, b: u8, count: usize) void {
        var i: usize = 0;
        while (i < count) : (i += 1) self.writeByte(b);
    }

    /// Base-10 unsigned. Hand-rolled rather than std.fmt: this is the hottest
    /// formatting path, and std.fmt's return type already changed once between
    /// Zig 0.16 and 0.17 (plan §5).
    pub fn writeUint(self: *Buf, v: u64) void {
        var tmp: [20]u8 = undefined;
        var i: usize = tmp.len;
        var n = v;
        if (n == 0) {
            self.writeByte('0');
            return;
        }
        while (n > 0) {
            i -= 1;
            tmp[i] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        self.write(tmp[i..]);
    }

    pub fn writeInt(self: *Buf, v: i64) void {
        if (v < 0) {
            self.writeByte('-');
            // -(minInt(i64)) overflows, so go through the unsigned domain.
            self.writeUint(@as(u64, @intCast(-(v + 1))) + 1);
        } else {
            self.writeUint(@intCast(v));
        }
    }

    /// Fixed-point with exactly `decimals` digits. Truncates rather than rounds
    /// so output is byte-stable across runs — golden tests depend on that.
    pub fn writeFixed(self: *Buf, v: u64, decimals: u8) void {
        var div: u64 = 1;
        var i: u8 = 0;
        while (i < decimals) : (i += 1) div *= 10;
        self.writeUint(v / div);
        if (decimals == 0) return;
        self.writeByte('.');

        // Emit digits left to right, letting `place` decrease. An earlier version
        // built them into a scratch buffer back to front and printed "0.50" for
        // the value 5, because the slice was emitted in the wrong order.
        const frac = v % div;
        var place = div / 10;
        while (place >= 1) {
            self.writeByte('0' + @as(u8, @intCast((frac / place) % 10)));
            place /= 10;
        }
    }

    /// SGR escape, e.g. `sgr("1;36")` emits ESC[1;36m.
    pub fn sgr(self: *Buf, code: []const u8) void {
        self.write("\x1b[");
        self.write(code);
        self.write("m");
    }

    /// The common "label: value" field row.
    pub fn field(self: *Buf, label: []const u8, value: []const u8) void {
        self.write(label);
        self.writeByte(':');
        self.writeByte(' ');
        self.write(value);
        self.writeByte('\n');
    }
};

test "uint and int formatting" {
    var storage: [64]u8 = undefined;
    var b = Buf.init(&storage);

    b.writeUint(0);
    b.writeByte(' ');
    b.writeUint(1);
    b.writeByte(' ');
    b.writeUint(18446744073709551615);
    try @import("std").testing.expectEqualStrings("0 1 18446744073709551615", b.written());
}

test "negative minInt does not overflow" {
    var storage: [32]u8 = undefined;
    var b = Buf.init(&storage);
    b.writeInt(std.math.minInt(i64));
    try @import("std").testing.expectEqualStrings("-9223372036854775808", b.written());
}

test "fixed point zero-pads the fraction" {
    var storage: [32]u8 = undefined;
    var b = Buf.init(&storage);
    b.writeFixed(5, 2); // 0.05, not 0.5
    b.writeByte(' ');
    b.writeFixed(1234, 1); // 123.4
    try @import("std").testing.expectEqualStrings("0.05 123.4", b.written());
}

test "writes truncate instead of panicking" {
    var storage: [4]u8 = undefined;
    var b = Buf.init(&storage);
    try @import("std").testing.expectEqual(@as(usize, 4), b.writeCount("abcdefgh"));
    try @import("std").testing.expect(b.isFull());
    b.writeByte('x'); // must not panic
    try @import("std").testing.expectEqualStrings("abcd", b.written());
}
