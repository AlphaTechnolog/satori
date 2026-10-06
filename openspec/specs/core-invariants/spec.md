# Core Invariants Specification

## Purpose

The runtime properties that make satori's central claims true: it never spawns a
subprocess, never allocates on the default path, writes its output exactly once,
and reports absence honestly instead of fabricating numbers. These are the
invariants `zig build check` enforces; breaking any of them fails the build or
the gate suite.

## Requirements

### Requirement: The shipped program contains no subprocess or allocation capability

satori SHALL ship with no code path able to fork, exec, spawn, load a dynamic
library, wait on a child, or allocate on the heap. This is proven by absence,
not by tracing: the capability must be missing from the binary's symbol table,
so no input, environment variable, or code path can reach it.

#### Scenario: The no-fork gate finds the capability absent

- **WHEN** `tools/check-no-fork.sh` inspects the stripped ReleaseFast binary's
  undefined-symbol table
- **THEN** it exits 0 and finds no `fork`, `exec*`, `posix_spawn`, `system`,
  `popen`, `dlopen`, `wait*`, `malloc`, `calloc`, `realloc`, or `free` among the
  undefined symbols

#### Scenario: All default-path work happens on the stack

- **WHEN** satori gathers data and renders with default arguments
- **THEN** every module writes into caller-provided stack buffers and the
  program performs zero allocations; libc is the only dependency and `std` is
  imported solely for `std.mem` and `std.fmt`

### Requirement: Exactly one write to stdout, at exit

satori SHALL compose its entire output into a single fixed-size stack buffer
and flush it once, at the end of `main`. Output must be atomic with respect to
other terminal writers, and streaming rows to stdout as they are produced is
not permitted even where it would save buffer space.

#### Scenario: The final flush is the only write to file descriptor 1

- **WHEN** the source of the default render path is inspected
- **THEN** the program's only write to fd 1 is the single `flush` call in
  `main.zig`, which hands the composed `stdout_buf` contents to `write(2)` once

### Requirement: A missing or failing data source renders `unavailable`

A field whose source is absent or whose system call fails SHALL render as
`unavailable`. The row is never omitted, never blank, and never prints a
fabricated value such as `0 MiB used`; failure is visible in the output rather
than silent.

#### Scenario: An absent platform source still renders its row

- **WHEN** a field has no source on the running platform (e.g. Memory on Linux
  before its `/proc` reader lands)
- **THEN** the row still renders, reading `unavailable`, and the process exits 0

#### Scenario: A failed system call is detected, not rendered as data

- **WHEN** `host_statistics64` returns a non-zero code (e.g.
  `KERN_INVALID_ARGUMENT` from a wrong `HOST_VM_INFO64_COUNT`)
- **THEN** the return code is checked and Memory renders `unavailable` instead
  of `0 MiB used`

### Requirement: Asserted struct layouts are pinned to compiler-measured ground truth

Every `@sizeOf`/`@offsetOf` asserted by `test/layout.zig` SHALL equal a value
measured by the platform C compiler via `tools/gt.c` on that platform, per
target. A layout that disagrees with the system headers must fail at comptime
rather than return garbage at runtime.

#### Scenario: Every asserted value comes from `gt.c`

- **WHEN** `tools/gt.c` is compiled and run on a platform (`cc -O2 tools/gt.c
  -o gt && ./gt`)
- **THEN** its output contains, verbatim, every value the corresponding arm of
  `test/layout.zig` asserts, so no asserted number is hand-entered

#### Scenario: A struct without ground truth on one platform fails the build

- **WHEN** a struct is added to `src/c.h` and asserted in `test/layout.zig`
  without ground truth for both macOS and Linux
- **THEN** the test's `else` branch raises a compile error instead of passing
  silently
