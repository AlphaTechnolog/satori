//! NEGATIVE CONTROL — this file MUST fail to compile.
//!
//! It asserts a deliberately wrong @sizeOf for struct statfs. If it ever
//! compiles, the layout assertions in test/layout.zig have gone vacuous (wrong
//! comptime_fn plumbing, wrong import path, a typo) and the whole safety net is
//! worthless while appearing green.
//!
//! tools/check-negative-control.sh verifies the failure. This file is
//! deliberately NOT referenced by build.zig's test step.

const c = @import("c");
const builtin = @import("builtin");

comptime {
    // The control has to be wrong in the same *way* the real assertions are, or
    // it proves nothing. Naming one platform's struct outright would make this
    // file fail on every other platform for the wrong reason — "no member named
    // struct_statfs" is a compile error too, and check-negative-control.sh
    // correctly rejected that, but the run taught us the control must select its
    // struct the same way test/layout.zig does.
    const probe = switch (builtin.os.tag) {
        .macos => c.struct_statfs,
        .linux => c.struct_statvfs,
        else => @compileError("negative control: add a struct for this platform"),
    };

    if (@sizeOf(probe) != 9999) {
        @compileError("NEGATIVE CONTROL TRIGGERED: this file must not compile");
    }
}

test "unreachable" {}
