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

comptime {
    if (@sizeOf(c.struct_statfs) != 9999) {
        @compileError("NEGATIVE CONTROL TRIGGERED: this file must not compile");
    }
}

test "unreachable" {}
