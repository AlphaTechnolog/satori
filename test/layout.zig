//! Comptime struct layout assertions.
//!
//! This is the most important test in the project. The failure mode it guards
//! against is *silently wrong data*, not a crash: a hand-written `extern struct`
//! with the wrong field order compiles cleanly and returns garbage. During
//! prototyping, two of two hand-written structs were wrong this way, and
//! `host_statistics64` returned KERN_INVALID_ARGUMENT that went unnoticed
//! because the return code was not checked.
//!
//! Every value below was measured by the platform C compiler, not inferred, and
//! not typed in by hand:
//!   macOS  — clang -O2, Darwin 26.6.2, arm64
//!   Linux  — gcc -O2, Debian fork/sid, x86_64, glibc 2.43
//!
//! Regenerate ground truth with tools/gt.c — its output is the switch arm body:
//!   cc -O2 tools/gt.c -o gt && ./gt
//!
//! Two-sided proof, and both halves are load-bearing. tools/gt.c reports what
//! the *system* headers say; this file asserts that the *translated* declarations
//! in src/c.zig agree. Either side failing loudly is the point: a libc that
//! changes a layout must break the build, not change the number on screen.
//!
//! Verified 2026-10-05 on both hosts: every assertion below is emitted verbatim
//! by tools/gt.c compiled there (21 of 21 per arm), so nothing here is
//! hand-entered. gt.c also measures structs this file does not assert yet
//! (struct sysinfo, struct dirent) — see AGENTS.md "Known gaps".
//!
//! The negative control at the bottom proves these assertions actually fire.
//! Without it, a typo that made every check vacuous would pass silently — which
//! is the same failure mode this file exists to prevent.

const c = @import("c");
const builtin = @import("builtin");
const std = @import("std");

fn expectSize(comptime T: type, want: comptime_int, comptime name: []const u8) void {
    if (@sizeOf(T) != want) {
        @compileError(std.fmt.comptimePrint(
            "{s}: @sizeOf({s}) = {d}, expected {d}. " ++
                "The C ABI changed under us — regenerate src/c.zig and update the value here.",
            .{ name, name, @sizeOf(T), want },
        ));
    }
}

fn expectOffset(comptime T: type, comptime field: []const u8, want: comptime_int) void {
    if (@offsetOf(T, field) != want) {
        @compileError(std.fmt.comptimePrint(
            "{s}.{s} is at offset {d}, expected {d}. " ++
                "A field moved — usually means the header or toolchain changed.",
            .{ @typeName(T), field, @offsetOf(T, field), want },
        ));
    }
}

test "struct layouts match the platform ABI" {
    switch (builtin.os.tag) {
        .macos => {
            // utsname: 5 fields of 256 bytes on Darwin.
            expectSize(c.struct_utsname, 1280, "struct utsname");
            expectOffset(c.struct_utsname, "sysname", 0);
            expectOffset(c.struct_utsname, "nodename", 256);
            expectOffset(c.struct_utsname, "release", 512);
            expectOffset(c.struct_utsname, "version", 768);
            expectOffset(c.struct_utsname, "machine", 1024);

            expectSize(c.struct_timespec, 16, "struct timespec");
            expectOffset(c.struct_timespec, "tv_sec", 0);
            expectOffset(c.struct_timespec, "tv_nsec", 8);

            // struct statfs: the offsets are NOT in declaration order, which is
            // exactly why this struct was hand-written wrong before.
            expectSize(c.struct_statfs, 2168, "struct statfs");
            expectOffset(c.struct_statfs, "f_bsize", 0);
            expectOffset(c.struct_statfs, "f_blocks", 8);
            expectOffset(c.struct_statfs, "f_bfree", 16);
            expectOffset(c.struct_statfs, "f_bavail", 24);
            expectOffset(c.struct_statfs, "f_fsid", 48);
            expectOffset(c.struct_statfs, "f_flags", 64);
            expectOffset(c.struct_statfs, "f_fssubtype", 68);
            expectOffset(c.struct_statfs, "f_fstypename", 72);
            expectOffset(c.struct_statfs, "f_mntonname", 88);

            // vm_statistics64_data_t is 416 bytes: 57 named fields of MIXED
            // width, the first five natural_t (u32, 4-byte stride) and the rest
            // 64-bit (8-byte stride), with reserved gaps at 20, 100 and 148. So
            // neither the size nor the field count can be derived from the other
            // — which is how the hand-written 15 x u64 was wrong twice over.
            // HOST_VM_INFO64_COUNT must be derived from the real size.
            expectSize(c.vm_statistics64_data_t, 416, "vm_statistics64_data_t");
            expectSize(c.natural_t, 4, "natural_t");
        },
        .linux => {
            // utsname: 65-byte fields on glibc — a completely different shape
            // from Darwin's 256. This is the clearest argument against ever
            // hand-writing a cross-platform struct.
            expectSize(c.struct_utsname, 390, "struct utsname");
            expectOffset(c.struct_utsname, "sysname", 0);
            expectOffset(c.struct_utsname, "nodename", 65);
            expectOffset(c.struct_utsname, "release", 130);
            expectOffset(c.struct_utsname, "version", 195);
            expectOffset(c.struct_utsname, "machine", 260);

            expectSize(c.struct_timespec, 16, "struct timespec");
            expectOffset(c.struct_timespec, "tv_sec", 0);
            expectOffset(c.struct_timespec, "tv_nsec", 8);

            expectSize(c.struct_statvfs, 112, "struct statvfs");
            expectOffset(c.struct_statvfs, "f_bsize", 0);
            expectOffset(c.struct_statvfs, "f_frsize", 8);
            expectOffset(c.struct_statvfs, "f_blocks", 16);
            expectOffset(c.struct_statvfs, "f_bfree", 24);
            expectOffset(c.struct_statvfs, "f_bavail", 32);
            expectOffset(c.struct_statvfs, "f_files", 40);
            expectOffset(c.struct_statvfs, "f_ffree", 48);
            expectOffset(c.struct_statvfs, "f_favail", 56);
            expectOffset(c.struct_statvfs, "f_fsid", 64);
            expectOffset(c.struct_statvfs, "f_flag", 72);
            expectOffset(c.struct_statvfs, "f_namemax", 80);
        },
        else => @compileError("add layout ground truth for this OS in test/layout.zig"),
    }
}

test "HOST_VM_INFO64_COUNT derives from the real struct size" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // Must match the value a C compiler computes, measured by tools/gt.c:
    //   sizeof(vm_statistics64_data_t) 416 / sizeof(natural_t) 4 == 104
    // Not 15, and not 52: see the comment in the macOS arm above.
    const count = @sizeOf(c.vm_statistics64_data_t) / @sizeOf(c.natural_t);
    try std.testing.expectEqual(@as(usize, 104), count);
}

// The negative control lives in test/negative_control.zig, deliberately kept out
// of the normal test build: a @compileError here would break the build rather
// than validate the checks. tools/check-negative-control.sh asserts that it
// fails to compile, so we know the assertions above are not vacuous.
