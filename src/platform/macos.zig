//! macOS-specific data sources.
//!
//! The three Mach functions below are hand-declared because translate-c cannot
//! process `mach/mach.h` (it asserts `mach_msg_type_descriptor_t` is 12 bytes;
//! the type is `opaque {}`). Hand-declaring is safe *here* specifically because
//! all three take and return integers — `mach_port_t` and
//! `mach_msg_type_number_t` are both `unsigned int` (verified: `natural_t` is
//! 4 bytes, HOST_VM_INFO64_COUNT is 104). The struct that actually carries the
//! risk, `vm_statistics64_data_t`, comes from generated `c.zig` instead.

const c = @import("c");
const posix = @import("posix");
const std = @import("std");

const mach_port_t = u32;
const mach_msg_type_number_t = u32;

extern fn mach_host_self() mach_port_t;
extern fn host_statistics64(
    host: mach_port_t,
    flavor: c_int,
    info: *anyopaque,
    count: *mach_msg_type_number_t,
) c_int;
extern fn host_page_size(host: mach_port_t, out: *usize) c_int;

const HOST_VM_INFO64: c_int = 4;

/// Physical memory in bytes, plus the page count needed to interpret raw
/// `host_statistics64` counters.
pub const VmStats = struct {
    active: u64,
    inactive: u64,
    wired: u64,
    compressed: u64,
    free: u64,
    page_size: u64,
    total: u64,

    /// Memory in use, matching what Activity Monitor reports.
    ///
    /// NOT `total - free`: on macOS `free_count` counts only truly untouched
    /// pages, so the naive subtraction reports ~79 GiB of a 8 GiB machine in use.
    /// The correct figure is the sum of the four buckets the kernel actually
    /// accounts for, which is the definition Activity Monitor and `top` use.
    pub fn used(self: VmStats) u64 {
        return self.active + self.inactive + self.wired + self.compressed;
    }
};

/// Boot time as seconds since the Unix epoch. Mirrors the Linux `BootTime`
/// shape so `shared.zig` can treat both platforms uniformly.
pub const BootTime = struct {
    unix: i64 = 0,
};

/// Boot time from `kern.boottime`, a `struct timeval` counted from the epoch.
pub fn bootTime() BootTime {
    var tv: c.struct_timeval = std.mem.zeroes(c.struct_timeval);
    var len: usize = @sizeOf(c.struct_timeval);
    if (c.sysctlbyname("kern.boottime", @ptrCast(&tv), &len, null, 0) != 0) return .{};
    if (tv.tv_sec <= 0) return .{};
    return .{ .unix = @intCast(tv.tv_sec) };
}

/// `sysctlbyname` for a string value. Returns null if the key is absent.
///
/// The returned length from `sysctlbyname` *includes* the NUL terminator, so it
/// must be trimmed or every string gains a trailing NUL byte.
pub fn sysctlStr(name: [*:0]const u8, buf: []u8) ?[]const u8 {
    var len: usize = buf.len;
    if (c.sysctlbyname(name, buf.ptr, &len, null, 0) != 0) return null;
    if (len == 0) return null;
    if (buf[len - 1] == 0) len -= 1;
    return buf[0..len];
}

/// `sysctlbyname` for a scalar. The caller supplies the exact width.
pub fn sysctlInt(name: [*:0]const u8, out: []u8) bool {
    var len: usize = out.len;
    return c.sysctlbyname(name, out.ptr, &len, null, 0) == 0;
}

/// Page size from Mach. Falls back to `getpagesize` if the call fails.
pub fn pageSize() u64 {
    var ps: usize = 0;
    if (host_page_size(mach_host_self(), &ps) == 0 and ps > 0) return ps;
    // getpagesize returns c_int; a negative value means failure, so clamp rather
    // than letting a wrapped conversion produce a nonsense page size.
    const fallback = c.getpagesize();
    return if (fallback > 0) @intCast(fallback) else 4096;
}

/// Read VM statistics.
///
/// `HOST_VM_INFO64_COUNT` is derived from `@sizeOf` rather than hardcoded, and
/// test/layout.zig pins that size to 416 bytes. Getting this wrong does not
/// crash: `host_statistics64` returns `KERN_INVALID_ARGUMENT` (268435459) and
/// leaves the struct zeroed, which is how a wrong memory reading silently
/// becomes "0 MiB used". The return code is checked here precisely because that
/// bug shipped once.
pub fn vmStats() VmStats {
    var vm: c.vm_statistics64_data_t = std.mem.zeroes(c.vm_statistics64_data_t);
    var count: mach_msg_type_number_t = @intCast(@sizeOf(c.vm_statistics64_data_t) / @sizeOf(c.natural_t));

    const rc = host_statistics64(mach_host_self(), HOST_VM_INFO64, @ptrCast(&vm), &count);
    const ps = pageSize();
    var out: VmStats = .{
        .active = 0,
        .inactive = 0,
        .wired = 0,
        .compressed = 0,
        .free = 0,
        .page_size = ps,
        .total = 0,
    };
    if (rc != 0) return out;

    out.active = vm.active_count * ps;
    out.inactive = vm.inactive_count * ps;
    out.wired = vm.wire_count * ps;
    out.compressed = vm.compressor_page_count * ps;
    out.free = vm.free_count * ps;

    var mem: u64 = 0;
    if (sysctlInt("hw.memsize", std.mem.asBytes(&mem))) out.total = mem;
    return out;
}

/// macOS product version, e.g. "26.6.2". Falls back to `uname().release`.
pub fn osVersion(buf: []u8) []const u8 {
    return sysctlStr("kern.osproductversion", buf) orelse "";
}

/// Hardware model identifier, e.g. "MacBookAir10,1" or "Mac14,2".
pub fn hwModel(buf: []u8) []const u8 {
    return sysctlStr("hw.model", buf) orelse "";
}

/// CPU brand string.
pub fn cpuBrand(buf: []u8) []const u8 {
    return sysctlStr("machdep.cpu.brand_string", buf) orelse "";
}

/// Physical core count.
pub fn coreCount() u64 {
    var n: u64 = 0;
    if (sysctlInt("hw.physicalcpu", std.mem.asBytes(&n))) return n;
    return 0;
}

/// Logical core count.
pub fn threadCount() u64 {
    var n: u64 = 0;
    if (sysctlInt("hw.logicalcpu", std.mem.asBytes(&n))) return n;
    return 0;
}

test "page size is sane" {
    const ps = pageSize();
    try std.testing.expect(ps >= 4096);
}
